(* Unison file synchronizer: src/gitrepo.ml *)
(* See LICENSE for terms. *)

type inspection =
  | Missing
  | Ready of Gitstate.snapshot
  | Busy of string
  | Unsupported of string

module StringMap = Map.Make (String)

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

(* ---------------------------------------------------------------------------
   Ref-name validation
   ---------------------------------------------------------------------------
   Rules derived from git-check-ref-format(1) and Git source (refs.c).
   We apply these without invoking Git or reading any repository configuration.

   A valid ref name must:
   - start with "refs/"
   - consist of slash-separated components where each component:
       - is non-empty
       - does not start with '.'
       - does not end with '.'  or '.lock'
       - does not contain: space, control chars (<=0x1F or 0x7F), ':', '?',
         '[', '*', '\', '@{', '..'
   - the full name must not:
       - contain '..' (two consecutive dots)
       - contain '@{'
       - contain any of: space, TAB (0x09), control chars <=0x1F, 0x7F
       - contain '*', '?', '['
       - end with '/'
       - equal "@"
   - Additionally we restrict the supported subset further:
       - refs/bisect/, refs/original/, refs/remotes/, refs/rewritten/,
         refs/worktree/ and refs/stash are rejected (not reconcilable here)

   Note: the '\' character is rejected by the control-char scan (it is
   printable ASCII 0x5C) via the dedicated check below.
*)

(* Centralised character-level rejection for a full ref name string.
   Returns Some reason if the character is forbidden, None if allowed. *)
let refCharForbidden c =
  let code = Char.code c in
  if code <= 0x1F || code = 0x7F then
    Some "control character in ref name"
  else match c with
  | ' '  -> Some "space in ref name"
  | '\\' -> Some "backslash in ref name"
  | '*'  -> Some "wildcard '*' in ref name"
  | '?'  -> Some "wildcard '?' in ref name"
  | '['  -> Some "wildcard '[' in ref name"
  | ':'  -> Some "colon in ref name"
  | '^'  -> Some "caret in ref name"
  | '~'  -> Some "tilde in ref name"
  | _    -> None

(* Check all characters in [s] starting at [start].
   Returns Some reason if any is forbidden. *)
let checkRefChars s =
  let len = String.length s in
  let rec loop i =
    if i >= len then None
    else match refCharForbidden s.[i] with
    | Some _ as err -> err
    | None -> loop (i + 1)
  in
  loop 0

(* Check that [s] (the full ref name or a sub-string) does not contain
   the two-char sequences that Git forbids anywhere. *)
let checkForbiddenSequences name =
  let len = String.length name in
  let rec loop i =
    if i + 1 >= len then None
    else
      let pair = String.sub name i 2 in
      if pair = ".." then Some "'..' sequence in ref name"
      else if pair = "@{" then Some "'@{' sequence in ref name"
      else loop (i + 1)
  in
  loop 0

(* Validate a single path component (between slashes). *)
let componentValid component =
  let clen = String.length component in
  clen > 0
  && component.[0] <> '.'           (* must not start with dot *)
  && component.[clen - 1] <> '.'    (* must not end with dot *)
  && component.[clen - 1] <> ' '    (* must not end with space *)
  && not (Util.endswith component ".lock") (* must not end with .lock *)
  && checkRefChars component = None
  && checkForbiddenSequences component = None

let isSupportedRefName name =
  (* Must start with "refs/" *)
  startsWith name "refs/" &&
  (* Full-name forbidden-sequence check *)
  checkForbiddenSequences name = None &&
  (* All characters must be valid *)
  checkRefChars name = None &&
  (* Must not end with "/" (empty last component handled below) *)
  name.[String.length name - 1] <> '/' &&
  (* All slash-delimited components must be valid *)
  (let components = String.split_on_char '/' name in
   List.for_all componentValid components) &&
  (* Subset restrictions: namespaces not safe to reconcile here *)
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

(* ---------------------------------------------------------------------------
   Filesystem helpers — Windows handle confinement
   ---------------------------------------------------------------------------

   Git metadata is untrusted whenever it resides on the WSL replica.  The
   Windows Fs.confined* primitive opens the configured worktree once through
   NtCreateFile and then opens every metadata child relative to the preceding
   directory handle.  Each open uses OBJ_DONT_REPARSE and
   FILE_OPEN_REPARSE_POINT, validates the actual opened handle (including a
   reparse-tag query), and rejects every reparse tag.  File contents and
   directory entries are read from that same handle; no pathname is reopened
   after validation.

   The generic implementation only keeps this API usable for non-Windows
   regression tests.  wslworkspace itself is native-Windows-only, so it never
   relies on the generic implementation as a security boundary.
*)

let metadataLimit = 1024 * 1024

let withHandle handle f =
  protect (fun () -> Fs.confinedClose handle) (fun () -> f handle)

let withChild directory name f =
  match Fs.confinedOpenChild directory name with
  | None -> None
  | Some handle -> Some (withHandle handle f)

let requireChild directory name =
  match Fs.confinedOpenChild directory name with
  | Some handle -> handle
  | None -> raise (Unix.Unix_error (Unix.ENOENT, "confinedOpenChild", name))

let expectDirectory label handle =
  if Fs.confinedKind handle <> Fs.ConfinedDirectory then
    raise (Util.Transient ("Git metadata is not a directory: " ^ label))

let expectFile label handle =
  if Fs.confinedKind handle <> Fs.ConfinedFile then
    raise (Util.Transient ("Git metadata is not a regular file: " ^ label))

let readSmallFile label handle =
  expectFile label handle;
  Fs.confinedRead handle metadataLimit

let listDirectory label handle =
  expectDirectory label handle;
  Fs.confinedList handle
  |> List.filter (fun name -> name <> "." && name <> "..")
  |> List.sort String.compare

let rec readLooseRefs directory relative =
  listDirectory relative directory
  |> List.fold_left (fun refs name ->
       (* Skip hidden files and lock files; they are not durable ref state. *)
       if startsWith name "." || Util.endswith name ".lock" then refs
       else
         match withChild directory name (fun handle ->
           let fullName = relative ^ "/" ^ name in
           match Fs.confinedKind handle with
           | Fs.ConfinedDirectory ->
               StringMap.union (fun _ _ loose -> Some loose) refs
                 (readLooseRefs handle fullName)
           | Fs.ConfinedFile when isSupportedRefName fullName ->
               begin match parseRefValue (readSmallFile fullName handle) with
               | Some value -> StringMap.add fullName value refs
               | None -> raise (Util.Transient
                   ("unsupported Git ref contents: " ^ fullName))
               end
           | Fs.ConfinedFile -> refs
         ) with
         | None -> refs
         | Some refs -> refs)
     StringMap.empty

(* ---------------------------------------------------------------------------
   Busy detection
   ---------------------------------------------------------------------------
   A repository is busy when any of the following are present under .git:
   - Lock files: index.lock, HEAD.lock, packed-refs.lock, config.lock,
     shallow.lock, or any <ref>.lock file under refs/
   - Operation-state files: MERGE_HEAD, CHERRY_PICK_HEAD, REVERT_HEAD,
     REBASE_HEAD, AUTO_MERGE, BISECT_HEAD
   - Operation-state directories: rebase-apply, rebase-merge, sequencer

   We do NOT treat ORIG_HEAD or FETCH_HEAD as busy indicators: they are written
   frequently as informational heads and do not reliably signal an in-progress
   operation.

   Every probe is a confined handle open.  A replacement by a symlink/reparse
   point therefore either leaves us on the existing handle or fails closed;
   it cannot redirect the later metadata read.
*)
let isBusy gitDir =
  let names = [
    "index.lock"; "HEAD.lock"; "packed-refs.lock"; "config.lock";
    "shallow.lock"; "MERGE_HEAD"; "CHERRY_PICK_HEAD"; "REVERT_HEAD";
    "REBASE_HEAD"; "AUTO_MERGE"; "BISECT_HEAD"; "rebase-apply"; "rebase-merge";
    "sequencer"
  ] in
  let rec firstExisting = function
    | [] -> None
    | name :: rest ->
        begin match withChild gitDir name (fun _ -> ()) with
        | Some () -> Some name
        | None -> firstExisting rest
        end in
  match firstExisting names with
  | Some name -> Some name
  | None ->
      let rec findRefLock directory relative =
        let rec loop = function
          | [] -> None
          | name :: rest ->
              if Util.endswith name ".lock" then Some (relative ^ "/" ^ name)
              else begin match withChild directory name (fun child ->
                match Fs.confinedKind child with
                | Fs.ConfinedDirectory -> findRefLock child (relative ^ "/" ^ name)
                | Fs.ConfinedFile -> None) with
              | Some (Some _ as found) -> found
              | Some None | None -> loop rest
              end in
        loop (listDirectory relative directory) in
      begin match withChild gitDir "refs" (fun refs ->
        expectDirectory "refs" refs;
        findRefLock refs "refs") with
      | None -> None
      | Some result -> result
      end

let inspect worktree =
  try
    match Fs.confinedOpen worktree [".git"] with
    | None -> Missing
    | Some gitDir ->
        withHandle gitDir (fun gitDir ->
          if Fs.confinedKind gitDir <> Fs.ConfinedDirectory then
            (* A regular .git is a gitfile/linked-worktree indirection.  We do
             * not read it, because its workspace-controlled target could
             * escape the designated replica. *)
            Unsupported (".git exists but is not a directory: linked worktrees and \
                          gitfile indirection are not supported")
          else begin match isBusy gitDir with
          | Some path -> Busy ("Git operation or lock is present: " ^ path)
          | None ->
              let head =
                let headHandle = requireChild gitDir "HEAD" in
                withHandle headHandle (fun handle ->
                  match parseRefValue (readSmallFile "HEAD" handle) with
                  | Some value -> Gitstate.Present value
                  | None -> raise (Util.Transient "unsupported Git HEAD contents")) in
              let packedRefs =
                match withChild gitDir "packed-refs" (fun handle ->
                  List.fold_left (fun refs (name, value) -> StringMap.add name value refs)
                    StringMap.empty (parsePackedRefs (readSmallFile "packed-refs" handle))) with
                | Some refs -> refs
                | None -> StringMap.empty in
              let refs =
                match withChild gitDir "refs" (fun refs ->
                  expectDirectory "refs" refs;
                  StringMap.union (fun _ _ loose -> Some loose) packedRefs
                    (readLooseRefs refs "refs")) with
                | Some refs -> refs
                | None -> packedRefs in
              Ready { Gitstate.head; refs = StringMap.bindings refs }
          end)
  with
  | Util.Transient message -> Unsupported message
  | Unix.Unix_error (error, operation, path) ->
      Unsupported (Printf.sprintf "%s failed for %s: %s" operation path
        (Unix.error_message error))
  | Sys_error message -> Unsupported message
  | Failure message -> Unsupported message
  | Invalid_argument message -> Unsupported message
