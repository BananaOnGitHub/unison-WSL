(* Unison file synchronizer: src/wslworkspace.ml *)
(* See LICENSE for terms. *)

let enabled =
  Prefs.createBool "wslworkspace" false
    ~category:(`Advanced `Syncprocess)
    ~cli_only:true
    ~local:true
    "enable the confined Windows-to-WSL workspace mode"
    ("This mode is intended for a native Windows Unison process synchronizing "
     ^ "one local drive path with one \\verb|\\\\wsl.localhost\\DISTRO\\...| "
     ^ "path. It applies fail-closed workspace defaults, keeps Git metadata "
     ^ "local to each replica, and requires polling rather than a filesystem "
     ^ "watcher. It does not start or require a process inside WSL.")

type root_kind = WindowsLocal | WslUnc | Other

let slash = function '\\' -> '/' | c -> c

let normalize s = String.map slash (String.trim s)

let rec removeTrailingSlashes s =
  let len = String.length s in
  if len > 0 && s.[len - 1] = '/' then
    removeTrailingSlashes (String.sub s 0 (len - 1))
  else
    s

let isAsciiLetter = function
  | 'a' .. 'z' | 'A' .. 'Z' -> true
  | _ -> false

let validComponents ~minimum s =
  let components = String.split_on_char '/' s in
  List.length components >= minimum &&
  List.for_all (fun c -> c <> "" && c <> "." && c <> "..") components

let wslPrefix = "//wsl.localhost/"

let classifyRoot s =
  let s = removeTrailingSlashes (normalize s) in
  let lower = String.lowercase_ascii s in
  let prefixLen = String.length wslPrefix in
  if String.length lower > prefixLen &&
      String.sub lower 0 prefixLen = wslPrefix &&
      validComponents ~minimum:2
        (String.sub s prefixLen (String.length s - prefixLen)) then
    WslUnc
  else if String.length s > 3 && isAsciiLetter s.[0] && s.[1] = ':' &&
          s.[2] = '/' && validComponents ~minimum:1
            (String.sub s 3 (String.length s - 3)) then
    WindowsLocal
  else
    Other

let validateRoots roots =
  let kinds = List.map classifyRoot roots in
  match kinds with
  | [WindowsLocal; WslUnc] | [WslUnc; WindowsLocal] -> Ok ()
  | _ ->
      Error
        ("wslworkspace requires exactly one absolute local Windows drive path "
         ^ "and one \\wsl.localhost\\DISTRO\\... path; remote roots, "
         ^ "\\wsl$, relative paths, drive roots, and parent traversal are "
         ^ "not accepted")

let isGitMetadataPath path =
  String.split_on_char '/' (normalize path)
  |> List.exists (fun component ->
       String.lowercase_ascii component = ".git")

let isWithin ~root path =
  let root =
    removeTrailingSlashes (normalize root) |> String.lowercase_ascii in
  let path =
    removeTrailingSlashes (normalize path) |> String.lowercase_ascii in
  root = path ||
  let rootPrefix = root ^ "/" in
  let prefixLen = String.length rootPrefix in
  String.length path > prefixLen &&
    String.sub path 0 prefixLen = rootPrefix
