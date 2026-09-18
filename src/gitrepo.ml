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
   Filesystem helpers — fail-closed, lstat-only
   ---------------------------------------------------------------------------

   IMPORTANT — residual TOCTOU:
   Each helper below calls Fs.lstat (which does NOT follow symlinks) to check
   the kind of a path before opening it.  However, between the lstat call and
   the subsequent open call the filesystem may be mutated by a racing adversary.
   On Windows, closing this window requires handle-based confinement:
   NtCreateFile with FILE_OPEN_REPARSE_POINT, followed by an explicit reparse-
   tag check on the opened handle, with all subsequent operations going through
   that handle rather than resolving names again.
   That primitive is not currently available through OCaml's Unix or Fs layers.

   Until that confinement is implemented (a subsequent security milestone),
   this code is intentionally fail-closed at the logical level — it will reject
   malicious metadata it detects — but cannot guarantee detection in a race.
   Do NOT use this code against adversarial live repositories on the real
   workspace until handle-based confinement is in place.
*)

(* lstat that returns None on ENOENT/ENOTDIR, raises on everything else.
   Critically, does NOT follow symlinks (unlike Fs.file_exists which uses stat). *)
let lstatNoFollow path =
  try Some (Fs.lstat path)
  with Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) -> None

(* checkedLstat: lstat the path, then reject symlinks and reparse points.
   Returns the stat on success. Raises Util.Transient if the path does not
   exist or is a link/reparse. *)
let checkedLstat path =
  (* TOCTOU: see note above — the check and the later open are not atomic. *)
  match lstatNoFollow path with
  | None ->
      raise (Unix.Unix_error (Unix.ENOENT, "lstat", Fspath.toPrintString path))
  | Some stat ->
      if stat.Unix.LargeFile.st_kind = Unix.S_LNK then
        raise (Util.Transient
          ("Git metadata contains a symbolic link: " ^ Fspath.toPrintString path));
      (* Reparse-point check must come after lstat since isReparsePoint may
         itself follow the path.  On non-Windows platforms it always returns false. *)
      if Fs.isReparsePoint path then
        raise (Util.Transient
          ("Git metadata contains a reparse point: " ^ Fspath.toPrintString path));
      stat

(* lstat-based existence check: returns true iff the path exists and is
   neither a symlink nor a reparse point.  Returns false on ENOENT.
   Raises Util.Transient if the path IS a link or reparse point.
   This replaces Fs.file_exists (which calls stat and thus follows symlinks). *)
let existsNoFollow path =
  match lstatNoFollow path with
  | None -> false
  | Some stat ->
      if stat.Unix.LargeFile.st_kind = Unix.S_LNK then
        raise (Util.Transient
          ("Git metadata contains a symbolic link: " ^ Fspath.toPrintString path));
      if Fs.isReparsePoint path then
        raise (Util.Transient
          ("Git metadata contains a reparse point: " ^ Fspath.toPrintString path));
      true

let readSmallFile path =
  let stat = checkedLstat path in
  if stat.Unix.LargeFile.st_kind <> Unix.S_REG then
    raise (Util.Transient
      ("Git metadata is not a regular file: " ^ Fspath.toPrintString path));
  let size = Int64.to_int stat.Unix.LargeFile.st_size in
  if size > 1024 * 1024 then
    raise (Util.Transient
      ("Git metadata file is unexpectedly large: " ^ Fspath.toPrintString path));
  (* TOCTOU: see note above — open occurs after lstat, not through the handle. *)
  let channel = Fs.open_in_bin path in
  protect (fun () -> close_in_noerr channel) (fun () ->
    really_input_string channel size)

let listDirectory path =
  let stat = checkedLstat path in
  if stat.Unix.LargeFile.st_kind <> Unix.S_DIR then
    raise (Util.Transient
      ("Git metadata is not a directory: " ^ Fspath.toPrintString path));
  (* TOCTOU: see note above — opendir occurs after lstat. *)
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
       (* Skip hidden files and lock files; they are not durable ref state. *)
       if startsWith name "." || Util.endswith name ".lock" then refs
       else
         let path = child directory name in
         let stat = checkedLstat path in
         let fullName = relative ^ "/" ^ name in
         match stat.Unix.LargeFile.st_kind with
         | Unix.S_DIR ->
             StringMap.union (fun _ _ loose -> Some loose) refs
               (readLooseRefs gitDir fullName)
         | Unix.S_REG when isSupportedRefName fullName ->
             begin match parseRefValue (readSmallFile path) with
             | Some value -> StringMap.add fullName value refs
             | None -> raise (Util.Transient
                 ("unsupported Git ref contents: " ^ Fspath.toPrintString path))
             end
         | Unix.S_REG -> refs   (* name not in supported subset — skip silently *)
         | _ -> raise (Util.Transient
             ("unsupported Git ref type: " ^ Fspath.toPrintString path)))
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

   Existence is checked with existsNoFollow to avoid following any symlink or
   reparse point masquerading as a lock file.
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
        (* existsNoFollow raises on symlink/reparse, returns false on ENOENT *)
        if existsNoFollow (child gitDir name) then Some name
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
      (* existsNoFollow: avoid following a symlink named "refs" *)
      if existsNoFollow (child gitDir "refs") then findRefLock "refs" else None

let inspect worktree =
  try
    let gitDir = Fspath.child worktree dotGit in
    (* Use lstat (via existsNoFollow) rather than file_exists (which calls stat
       and thus follows a symlink or reparse point at this path). *)
    if not (existsNoFollow gitDir) then Missing
    else begin
      let stat = checkedLstat gitDir in
      if stat.Unix.LargeFile.st_kind <> Unix.S_DIR then
        (* .git is a regular file: linked worktree gitfile or other unsupported form.
           We do not follow gitfile indirection because the path it contains
           is workspace-controlled and may escape the designated root. *)
        Unsupported (".git exists but is not a directory: linked worktrees and \
                      gitfile indirection are not supported")
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
            (* existsNoFollow: reject a symlink or reparse point named packed-refs *)
            if existsNoFollow packed then
              List.fold_left (fun refs (name, value) -> StringMap.add name value refs)
                StringMap.empty (parsePackedRefs (readSmallFile packed))
            else
              StringMap.empty in
          let refs =
            (* existsNoFollow: reject a symlink or reparse point named refs *)
            if existsNoFollow (child gitDir "refs") then
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
