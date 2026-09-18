(* Unison file synchronizer: src/gitindex.ml *)
(* See LICENSE for terms. *)

let child directory name = Fspath.child directory (Name.fromString name)

let ensureDirectory directory =
  if Fs.file_exists directory then begin
    if Fs.isReparsePoint directory then
      raise (Util.Transient
        ("Git helper directory is a reparse point: " ^ Fspath.toPrintString directory));
    let stat = Fs.lstat directory in
    if stat.Unix.LargeFile.st_kind <> Unix.S_DIR then
      raise (Util.Transient
        ("Git helper path is not a directory: " ^ Fspath.toPrintString directory))
  end else
    Fs.mkdir directory 0o700

let without names environment =
  Array.to_list environment
  |> List.filter (fun binding ->
       match String.index_opt binding '=' with
       | None -> true
       | Some index ->
           let name = String.sub binding 0 index in
           not (List.mem name names))

let commandEnvironment ~nullDevice ~helperDirectory ~objectDirectory ~indexPath =
  let removed = [
    "GIT_DIR"; "GIT_WORK_TREE"; "GIT_INDEX_FILE"; "GIT_OBJECT_DIRECTORY";
    "GIT_ALTERNATE_OBJECT_DIRECTORIES"; "GIT_CONFIG_NOSYSTEM";
    "GIT_CONFIG_GLOBAL"; "GIT_CONFIG_COUNT"; "GIT_CONFIG_KEY_0";
    "GIT_CONFIG_VALUE_0"; "GIT_CONFIG_KEY_1"; "GIT_CONFIG_VALUE_1";
    "GIT_CONFIG_KEY_2"; "GIT_CONFIG_VALUE_2"; "GIT_CONFIG_KEY_3";
    "GIT_CONFIG_VALUE_3"; "GIT_CONFIG_KEY_4"; "GIT_CONFIG_VALUE_4";
    "GIT_TERMINAL_PROMPT"; "GIT_OPTIONAL_LOCKS"; "GIT_PAGER";
    "GIT_NO_REPLACE_OBJECTS"
  ] in
  let values = [
    "GIT_DIR=" ^ Fspath.toString helperDirectory;
    "GIT_INDEX_FILE=" ^ Fspath.toString indexPath;
    "GIT_OBJECT_DIRECTORY=" ^ Fspath.toString (child helperDirectory "objects");
    "GIT_ALTERNATE_OBJECT_DIRECTORIES=" ^ Fspath.toString objectDirectory;
    "GIT_CONFIG_NOSYSTEM=1";
    "GIT_CONFIG_GLOBAL=" ^ nullDevice;
    "GIT_CONFIG_COUNT=5";
    "GIT_CONFIG_KEY_0=core.hooksPath";
    "GIT_CONFIG_VALUE_0=NUL";
    "GIT_CONFIG_KEY_1=core.fsmonitor";
    "GIT_CONFIG_VALUE_1=false";
    "GIT_CONFIG_KEY_2=core.attributesFile";
    "GIT_CONFIG_VALUE_2=NUL";
    "GIT_CONFIG_KEY_3=core.excludesFile";
    "GIT_CONFIG_VALUE_3=NUL";
    "GIT_CONFIG_KEY_4=core.autocrlf";
    "GIT_CONFIG_VALUE_4=false";
    "GIT_TERMINAL_PROMPT=0";
    "GIT_OPTIONAL_LOCKS=0";
    "GIT_PAGER=cat";
    "GIT_NO_REPLACE_OBJECTS=1"
  ] in
  Array.of_list (values @ without removed (Unix.environment ()))

let rebuild ~gitExe ~helperDirectory ~objectDirectory ~indexPath ~commit =
  try
    ensureDirectory helperDirectory;
    ensureDirectory (child helperDirectory "objects");
    ensureDirectory (child helperDirectory "refs");
    let nullDevice = if Sys.win32 then "NUL" else "/dev/null" in
    let head = child helperDirectory "HEAD" in
    if Fs.file_exists head && Fs.isReparsePoint head then
      raise (Util.Transient
        ("Git helper HEAD is a reparse point: " ^ Fspath.toPrintString head));
    let headChannel =
      Fs.open_out_gen [Open_wronly; Open_creat; Open_trunc; Open_binary] 0o600 head in
    output_string headChannel "ref: refs/heads/unison-helper\n";
    close_out headChannel;
    let nullIn = Unix.openfile nullDevice [Unix.O_RDONLY] 0 in
    let nullOut = Unix.openfile nullDevice [Unix.O_WRONLY] 0 in
    let arguments = [|
      gitExe; "--no-replace-objects"; "read-tree"; "--reset"; commit
    |] in
    let process =
      Unix.create_process_env gitExe arguments
        (commandEnvironment ~nullDevice ~helperDirectory ~objectDirectory ~indexPath)
        nullIn nullOut nullOut in
    Unix.close nullIn;
    Unix.close nullOut;
    match snd (Unix.waitpid [] process) with
    | Unix.WEXITED 0 -> Ok ()
    | Unix.WEXITED code -> Error (Printf.sprintf "git read-tree exited with %d" code)
    | Unix.WSIGNALED signal -> Error (Printf.sprintf "git read-tree was signaled (%d)" signal)
    | Unix.WSTOPPED signal -> Error (Printf.sprintf "git read-tree stopped (%d)" signal)
  with
  | Util.Transient message -> Error message
  | Unix.Unix_error (error, operation, path) ->
      Error (Printf.sprintf "%s failed for %s: %s" operation path
        (Unix.error_message error))
  | Sys_error message -> Error message
