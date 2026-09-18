(* Unison file synchronizer: src/gitarchive.ml *)
(* See LICENSE for terms. *)

type state = (string * Gitstate.snapshot) list

type stored_state = {
  format : int;
  entries : state;
}

let format = 1

let keyForRoots roots =
  Digest.to_hex (Digest.string (String.concat "\000" (List.sort String.compare roots)))

let filename key = "git-state-" ^ key ^ ".bin"

let child directory name = Fspath.child directory (Name.fromString name)

let ensureDirectory directory =
  if Fs.file_exists directory then begin
    if Fs.isReparsePoint directory then
      raise (Util.Transient
        ("Git archive directory is a reparse point: " ^ Fspath.toPrintString directory));
    let stat = Fs.lstat directory in
    if stat.Unix.LargeFile.st_kind <> Unix.S_DIR then
      raise (Util.Transient
        ("Git archive path is not a directory: " ^ Fspath.toPrintString directory))
  end else
    Fs.mkdir directory 0o700

let checkedFile directory key =
  ensureDirectory directory;
  let path = child directory (filename key) in
  if Fs.file_exists path && Fs.isReparsePoint path then
    raise (Util.Transient
      ("Git archive file is a reparse point: " ^ Fspath.toPrintString path));
  path

let load ~directory ~key =
  let path = checkedFile directory key in
  if not (Fs.file_exists path) then []
  else begin
    let stat = Fs.lstat path in
    if stat.Unix.LargeFile.st_kind <> Unix.S_REG then
      raise (Util.Transient
        ("Git archive path is not a regular file: " ^ Fspath.toPrintString path));
    if stat.Unix.LargeFile.st_size > 16777216L then
      raise (Util.Transient
        ("Git archive file is unexpectedly large: " ^ Fspath.toPrintString path));
    let channel = Fs.open_in_bin path in
    try
      let stored : stored_state = Marshal.from_channel channel in
      close_in channel;
      if stored.format <> format then
        raise (Util.Transient "unsupported Git archive format");
      stored.entries
    with error ->
      close_in_noerr channel;
      match error with
      | Util.Transient _ -> raise error
      | _ -> raise (Util.Transient
          ("cannot read trusted Git archive " ^ Fspath.toPrintString path))
  end

let save ~directory ~key entries =
  let path = checkedFile directory key in
  let temporary = child directory
    (filename key ^ ".new-" ^ string_of_int (Unix.getpid ())) in
  if Fs.file_exists temporary then Fs.unlink temporary;
  let channel =
    Fs.open_out_gen [Open_wronly; Open_creat; Open_excl; Open_binary] 0o600 temporary in
  try
    Marshal.to_channel channel {format; entries} [];
    flush channel;
    Unix.fsync (Unix.descr_of_out_channel channel);
    close_out channel;
    Fs.rename temporary path
  with error ->
    close_out_noerr channel;
    if Fs.file_exists temporary then begin
      try Fs.unlink temporary with Unix.Unix_error _ -> ()
    end;
    raise error
