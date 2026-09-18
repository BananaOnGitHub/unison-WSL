(* Unison file synchronizer: src/gitrepo.ml *)
(* See LICENSE for terms. *)

type inspection =
  | Missing
  | Ready of Gitstate.snapshot
  | Busy of string
  | Unsupported of string

module StringMap = Map.Make (String)

let dotGit = Name.fromString ".git"

let child dir name = Fspath.child dir (Name.fromString name)

let startsWith s prefix =
  let length = String.length prefix in
  String.length s >= length && String.sub s 0 length = prefix

let protect finally f =
  try
    let result = f () in
    finally ();
    result
  with error ->
    finally ();
    raise error

let trimOneNewline s =
  let length = String.length s in
  if length > 0 && s.[length - 1] = '\n' then
    String.sub s 0 (length - 1)
  else
    s

let isHex = function
  | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
  | _ -> false

let isObjectId s =
  let length = String.length s in
  let rec allHex index =
    index = length || (isHex s.[index] && allHex (index + 1)) in
  (length = 40 || length = 64) && allHex 0

let componentIsSafe component =
  component <> "" && component <> "." && component <> ".." &&
  not (String.contains component '\\') &&
  not (String.contains component '\000') &&
  component.[String.length component - 1] <> '.' &&
  component.[String.length component - 1] <> ' '

let isSupportedRefName name =
  startsWith name "refs/" &&
  let components = String.split_on_char '/' name in
  List.for_all componentIsSafe components &&
  not (startsWith name "refs/bisect/") &&
  not (startsWith name "refs/original/") &&
  not (startsWith name "refs/remotes/") &&
  not (startsWith name "refs/rewritten/") &&
  not (startsWith name "refs/worktree/") &&
  name <> "refs/stash"

let parseRefValue contents =
  let value = trimOneNewline contents in
  if isObjectId value then Some value
  else if startsWith value "ref: " then begin
    let target = String.sub value 5 (String.length value - 5) in
    if isSupportedRefName target then Some value else None
  end else
    None

let parsePackedRefs contents =
  String.split_on_char '\n' contents
  |> List.fold_left (fun refs line ->
       if line = "" || line.[0] = '#' || line.[0] = '^' then refs
       else
         match String.split_on_char ' ' line with
         | [oid; name] when isObjectId oid && isSupportedRefName name ->
             (name, oid) :: refs
         | _ -> refs)
       []
  |> List.rev

let checkedLstat path =
  if Fs.isReparsePoint path then
    raise (Util.Transient
      ("Git metadata contains a reparse point: " ^ Fspath.toPrintString path));
  let stat = Fs.lstat path in
  if stat.Unix.LargeFile.st_kind = Unix.S_LNK then
    raise (Util.Transient
      ("Git metadata contains a symbolic link: " ^ Fspath.toPrintString path));
  stat

let readSmallFile path =
  let stat = checkedLstat path in
  if stat.Unix.LargeFile.st_kind <> Unix.S_REG then
    raise (Util.Transient
      ("Git metadata is not a regular file: " ^ Fspath.toPrintString path));
  let size = Int64.to_int stat.Unix.LargeFile.st_size in
  if size > 1024 * 1024 then
    raise (Util.Transient
      ("Git metadata file is unexpectedly large: " ^ Fspath.toPrintString path));
  let channel = Fs.open_in_bin path in
  protect (fun () -> close_in_noerr channel) (fun () ->
    really_input_string channel size)

let listDirectory path =
  let stat = checkedLstat path in
  if stat.Unix.LargeFile.st_kind <> Unix.S_DIR then
    raise (Util.Transient
      ("Git metadata is not a directory: " ^ Fspath.toPrintString path));
  let handle = Fs.opendir path in
  protect (fun () -> handle.closedir ()) (fun () ->
    let rec loop names =
      try
        let name = handle.readdir () in
        if name = "." || name = ".." then loop names else loop (name :: names)
      with End_of_file -> List.sort String.compare names
    in
    loop [])

let rec readLooseRefs gitDir relative =
  let directory =
    List.fold_left child gitDir (String.split_on_char '/' relative) in
  listDirectory directory
  |> List.fold_left (fun refs name ->
       if startsWith name "." || Util.endswith name ".lock" then refs
       else
         let path = child directory name in
         let stat = checkedLstat path in
         let name = relative ^ "/" ^ name in
         match stat.Unix.LargeFile.st_kind with
         | Unix.S_DIR ->
             StringMap.union (fun _ _ right -> Some right) refs
               (readLooseRefs gitDir name)
         | Unix.S_REG when isSupportedRefName name ->
             begin match parseRefValue (readSmallFile path) with
             | Some value -> StringMap.add name value refs
             | None -> raise (Util.Transient
                 ("unsupported Git ref contents: " ^ Fspath.toPrintString path))
             end
         | Unix.S_REG -> refs
         | _ -> raise (Util.Transient
             ("unsupported Git ref type: " ^ Fspath.toPrintString path)))
       StringMap.empty

let isBusy gitDir =
  let names = [
    "index.lock"; "HEAD.lock"; "packed-refs.lock"; "config.lock";
    "shallow.lock"; "MERGE_HEAD"; "CHERRY_PICK_HEAD"; "REVERT_HEAD";
    "REBASE_HEAD"; "AUTO_MERGE"; "rebase-apply"; "rebase-merge";
    "sequencer"
  ] in
  let rec firstExisting = function
    | [] -> None
    | name :: rest ->
        if Fs.file_exists (child gitDir name) then Some name
        else firstExisting rest in
  match firstExisting names with
  | Some name -> Some name
  | None ->
      let rec findRefLock relative =
        let directory =
          List.fold_left child gitDir (String.split_on_char '/' relative) in
        let rec loop = function
          | [] -> None
          | name :: rest ->
              let path = child directory name in
              let stat = checkedLstat path in
              if Util.endswith name ".lock" then Some (relative ^ "/" ^ name)
              else if stat.Unix.LargeFile.st_kind = Unix.S_DIR then begin
                match findRefLock (relative ^ "/" ^ name) with
                | None -> loop rest
                | Some _ as found -> found
              end else
                loop rest in
        loop (listDirectory directory) in
      if Fs.file_exists (child gitDir "refs") then findRefLock "refs" else None

let inspect worktree =
  try
    let gitDir = Fspath.child worktree dotGit in
    if not (Fs.file_exists gitDir) then Missing
    else begin
      let stat = checkedLstat gitDir in
      if stat.Unix.LargeFile.st_kind <> Unix.S_DIR then
        Unsupported ".git is not a normal directory (linked worktrees are not supported)"
      else begin match isBusy gitDir with
      | Some path -> Busy ("Git operation or lock is present: " ^ path)
      | None ->
          let headPath = child gitDir "HEAD" in
          let head =
            match parseRefValue (readSmallFile headPath) with
            | Some value -> Gitstate.Present value
            | None -> raise (Util.Transient "unsupported Git HEAD contents") in
          let packed = child gitDir "packed-refs" in
          let packedRefs =
            if Fs.file_exists packed then
              List.fold_left (fun refs (name, value) -> StringMap.add name value refs)
                StringMap.empty (parsePackedRefs (readSmallFile packed))
            else
              StringMap.empty in
          let refs =
            if Fs.file_exists (child gitDir "refs") then
              StringMap.union (fun _ _ loose -> Some loose) packedRefs
                (readLooseRefs gitDir "refs")
            else
              packedRefs in
          Ready { Gitstate.head; refs = StringMap.bindings refs }
      end
    end
  with
  | Util.Transient message -> Unsupported message
  | Unix.Unix_error (error, operation, path) ->
      Unsupported (Printf.sprintf "%s failed for %s: %s" operation path
        (Unix.error_message error))
  | Sys_error message -> Unsupported message
