(* Unison file synchronizer: src/gitobjects.ml *)
(* See LICENSE for terms. *)

(*
   Immutable Git-object union for the Windows-to-WSL mode.

   This module intentionally knows nothing about refs, HEAD mutation, indexes,
   repository configuration, hooks, work trees, or Git executables.  Its only
   inputs are a snapshot that Gitrepo already inspected and two configured
   worktree roots.  Every .git read and every destination publication is made
   through Fs.confined* handles; no derived object filename is ever opened as
   a pathname.
*)

module StringSet = Set.Make (String)

exception Unsupported of string

let fail message = raise (Unsupported message)

let protect finally f =
  try
    let result = f () in
    finally ();
    result
  with error ->
    finally ();
    raise error

let startsWith s prefix =
  let length = String.length prefix in
  String.length s >= length && String.sub s 0 length = prefix

let endsWith s suffix =
  let length = String.length suffix in
  String.length s >= length &&
  String.sub s (String.length s - length) length = suffix

let lowercase = String.lowercase_ascii

(* ------------------------------------------------------------------------- *)
(* Git object hashes                                                        *)
(* ------------------------------------------------------------------------- *)

(* Git's object names use SHA-1 or SHA-256.  Keeping these small, pure OCaml
 * implementations here avoids invoking Git, loading a crypto provider from
 * a workspace, or adding a process/library dependency to the confinement
 * boundary. *)
module Hash = struct
  let rotr value amount =
    Int32.logor (Int32.shift_right_logical value amount)
      (Int32.shift_left value (32 - amount))

  let rotl value amount =
    Int32.logor (Int32.shift_left value amount)
      (Int32.shift_right_logical value (32 - amount))

  let word bytes offset =
    let byte index = Int32.of_int (Char.code bytes.[offset + index]) in
    Int32.logor (Int32.shift_left (byte 0) 24)
      (Int32.logor (Int32.shift_left (byte 1) 16)
        (Int32.logor (Int32.shift_left (byte 2) 8) (byte 3)))

  let paddedByte bytes length total bitLength index =
    if index < length then Char.code bytes.[index]
    else if index = length then 0x80
    else if index >= total - 8 then
      Int64.to_int (Int64.logand 0xffL
        (Int64.shift_right_logical bitLength (8 * (total - 1 - index))))
    else 0

  let blockWord bytes length total bitLength block index =
    let offset = block * 64 + index * 4 in
    let byte index = Int32.of_int
      (paddedByte bytes length total bitLength (offset + index)) in
    Int32.logor (Int32.shift_left (byte 0) 24)
      (Int32.logor (Int32.shift_left (byte 1) 16)
        (Int32.logor (Int32.shift_left (byte 2) 8) (byte 3)))

  let hex words =
    let digits = "0123456789abcdef" in
    let output = Bytes.create (Array.length words * 8) in
    Array.iteri (fun index word ->
      for shift = 0 to 3 do
        let byte = Int32.to_int (Int32.logand 0xffl
          (Int32.shift_right_logical word (24 - shift * 8))) in
        Bytes.set output (index * 8 + shift * 2) digits.[byte lsr 4];
        Bytes.set output (index * 8 + shift * 2 + 1) digits.[byte land 15]
      done) words;
    Bytes.to_string output

  let sha1 bytes =
    let length = String.length bytes in
    let total = ((length + 9 + 63) / 64) * 64 in
    let bitLength = Int64.mul (Int64.of_int length) 8L in
    let h0 = ref 0x67452301l
    and h1 = ref 0xefcdab89l
    and h2 = ref 0x98badcfel
    and h3 = ref 0x10325476l
    and h4 = ref 0xc3d2e1f0l in
    for block = 0 to total / 64 - 1 do
      let schedule = Array.make 80 0l in
      for index = 0 to 15 do
        schedule.(index) <- blockWord bytes length total bitLength block index
      done;
      for index = 16 to 79 do
        schedule.(index) <- rotl
          (Int32.logxor schedule.(index - 3)
            (Int32.logxor schedule.(index - 8)
              (Int32.logxor schedule.(index - 14) schedule.(index - 16)))) 1
      done;
      let a = ref !h0 and b = ref !h1 and c = ref !h2
      and d = ref !h3 and e = ref !h4 in
      for index = 0 to 79 do
        let f, constant =
          if index < 20 then
            (Int32.logor (Int32.logand !b !c)
               (Int32.logand (Int32.lognot !b) !d), 0x5a827999l)
          else if index < 40 then
            (Int32.logxor !b (Int32.logxor !c !d), 0x6ed9eba1l)
          else if index < 60 then
            (Int32.logor (Int32.logor (Int32.logand !b !c)
               (Int32.logand !b !d)) (Int32.logand !c !d), 0x8f1bbcdcl)
          else
            (Int32.logxor !b (Int32.logxor !c !d), 0xca62c1d6l) in
        let temporary = Int32.add (rotl !a 5)
          (Int32.add f (Int32.add !e (Int32.add constant schedule.(index)))) in
        e := !d;
        d := !c;
        c := rotl !b 30;
        b := !a;
        a := temporary
      done;
      h0 := Int32.add !h0 !a;
      h1 := Int32.add !h1 !b;
      h2 := Int32.add !h2 !c;
      h3 := Int32.add !h3 !d;
      h4 := Int32.add !h4 !e
    done;
    hex [| !h0; !h1; !h2; !h3; !h4 |]

  let sha256Constants = Array.map Int32.of_string [|
    "0x428a2f98"; "0x71374491"; "0xb5c0fbcf"; "0xe9b5dba5";
    "0x3956c25b"; "0x59f111f1"; "0x923f82a4"; "0xab1c5ed5";
    "0xd807aa98"; "0x12835b01"; "0x243185be"; "0x550c7dc3";
    "0x72be5d74"; "0x80deb1fe"; "0x9bdc06a7"; "0xc19bf174";
    "0xe49b69c1"; "0xefbe4786"; "0x0fc19dc6"; "0x240ca1cc";
    "0x2de92c6f"; "0x4a7484aa"; "0x5cb0a9dc"; "0x76f988da";
    "0x983e5152"; "0xa831c66d"; "0xb00327c8"; "0xbf597fc7";
    "0xc6e00bf3"; "0xd5a79147"; "0x06ca6351"; "0x14292967";
    "0x27b70a85"; "0x2e1b2138"; "0x4d2c6dfc"; "0x53380d13";
    "0x650a7354"; "0x766a0abb"; "0x81c2c92e"; "0x92722c85";
    "0xa2bfe8a1"; "0xa81a664b"; "0xc24b8b70"; "0xc76c51a3";
    "0xd192e819"; "0xd6990624"; "0xf40e3585"; "0x106aa070";
    "0x19a4c116"; "0x1e376c08"; "0x2748774c"; "0x34b0bcb5";
    "0x391c0cb3"; "0x4ed8aa4a"; "0x5b9cca4f"; "0x682e6ff3";
    "0x748f82ee"; "0x78a5636f"; "0x84c87814"; "0x8cc70208";
    "0x90befffa"; "0xa4506ceb"; "0xbef9a3f7"; "0xc67178f2"
  |]

  let sha256 bytes =
    let length = String.length bytes in
    let total = ((length + 9 + 63) / 64) * 64 in
    let bitLength = Int64.mul (Int64.of_int length) 8L in
    let state = Array.map Int32.of_string [|
      "0x6a09e667"; "0xbb67ae85"; "0x3c6ef372"; "0xa54ff53a";
      "0x510e527f"; "0x9b05688c"; "0x1f83d9ab"; "0x5be0cd19"
    |] in
    for block = 0 to total / 64 - 1 do
      let schedule = Array.make 64 0l in
      for index = 0 to 15 do
        schedule.(index) <- blockWord bytes length total bitLength block index
      done;
      for index = 16 to 63 do
        let s0 = Int32.logxor (rotr schedule.(index - 15) 7)
          (Int32.logxor (rotr schedule.(index - 15) 18)
             (Int32.shift_right_logical schedule.(index - 15) 3)) in
        let s1 = Int32.logxor (rotr schedule.(index - 2) 17)
          (Int32.logxor (rotr schedule.(index - 2) 19)
             (Int32.shift_right_logical schedule.(index - 2) 10)) in
        schedule.(index) <- Int32.add schedule.(index - 16)
          (Int32.add s0 (Int32.add schedule.(index - 7) s1))
      done;
      let a = ref state.(0) and b = ref state.(1) and c = ref state.(2)
      and d = ref state.(3) and e = ref state.(4) and f = ref state.(5)
      and g = ref state.(6) and h = ref state.(7) in
      for index = 0 to 63 do
        let s1 = Int32.logxor (rotr !e 6)
          (Int32.logxor (rotr !e 11) (rotr !e 25)) in
        let choose = Int32.logxor (Int32.logand !e !f)
          (Int32.logand (Int32.lognot !e) !g) in
        let temporary1 = Int32.add !h
          (Int32.add s1 (Int32.add choose
            (Int32.add sha256Constants.(index) schedule.(index)))) in
        let s0 = Int32.logxor (rotr !a 2)
          (Int32.logxor (rotr !a 13) (rotr !a 22)) in
        let majority = Int32.logxor (Int32.logand !a !b)
          (Int32.logxor (Int32.logand !a !c) (Int32.logand !b !c)) in
        let temporary2 = Int32.add s0 majority in
        h := !g; g := !f; f := !e;
        e := Int32.add !d temporary1;
        d := !c; c := !b; b := !a;
        a := Int32.add temporary1 temporary2
      done;
      for index = 0 to 7 do state.(index) <- Int32.add state.(index)
        (match index with
         | 0 -> !a | 1 -> !b | 2 -> !c | 3 -> !d
         | 4 -> !e | 5 -> !f | 6 -> !g | _ -> !h) done
    done;
    hex state

  let forOid oid bytes =
    match String.length oid with
    | 40 -> sha1 bytes
    | 64 -> sha256 bytes
    | _ -> fail "invalid Git object identifier length"
end

let byte bytes index =
  if index < 0 || index >= String.length bytes then
    fail "truncated Git object data"
  else Char.code bytes.[index]

let u32 bytes index =
  if index < 0 || index + 4 > String.length bytes then
    fail "truncated Git pack index"
  else
    Int64.logor (Int64.shift_left (Int64.of_int (byte bytes index)) 24)
      (Int64.logor (Int64.shift_left (Int64.of_int (byte bytes (index + 1))) 16)
        (Int64.logor (Int64.shift_left (Int64.of_int (byte bytes (index + 2))) 8)
          (Int64.of_int (byte bytes (index + 3)))))

let intOfU32 label value =
  if value > Int64.of_int max_int then fail (label ^ " is too large")
  else Int64.to_int value

let hexOfBytes bytes =
  let digits = "0123456789abcdef" in
  let output = Bytes.create (String.length bytes * 2) in
  String.iteri (fun index character ->
    let value = Char.code character in
    Bytes.set output (index * 2) digits.[value lsr 4];
    Bytes.set output (index * 2 + 1) digits.[value land 15]) bytes;
  Bytes.to_string output

let bytesOfHex value =
  let digit = function
    | '0' .. '9' as c -> Char.code c - Char.code '0'
    | 'a' .. 'f' as c -> Char.code c - Char.code 'a' + 10
    | 'A' .. 'F' as c -> Char.code c - Char.code 'A' + 10
    | _ -> fail "invalid hexadecimal Git object identifier" in
  if not (Gitrepo.isObjectId value) then fail "invalid Git object identifier";
  let bytes = Bytes.create (String.length value / 2) in
  for index = 0 to Bytes.length bytes - 1 do
    Bytes.set bytes index (Char.chr ((digit value.[index * 2] lsl 4) lor
      digit value.[index * 2 + 1]))
  done;
  Bytes.to_string bytes

let objectLimit = 128 * 1024 * 1024
let looseLimit = 64 * 1024 * 1024
let packLimit = 512 * 1024 * 1024
let indexLimit = 128 * 1024 * 1024
let packObjectLimit = 1000000
let traversalLimit = 1000000
let deltaDepthLimit = 64

type object_kind = Commit | Tree | Blob | Tag

let kindName = function
  | Commit -> "commit" | Tree -> "tree" | Blob -> "blob" | Tag -> "tag"

let kindOfName = function
  | "commit" -> Commit | "tree" -> Tree | "blob" -> Blob | "tag" -> Tag
  | _ -> fail "unsupported Git object type"

let canonical kind contents =
  kindName kind ^ " " ^ string_of_int (String.length contents) ^ "\000" ^ contents

type packed_entry =
  | PackedBase of object_kind
  | PackedOfsDelta of int
  | PackedRefDelta of string

type pack = {
  stem : string;
  packBytes : string;
  indexBytes : string;
  hashLength : int;
  byOid : (string, int) Hashtbl.t;
  byOffset : (int, string) Hashtbl.t;
  mutable validated : bool;
  mutable validating : bool;
}

type representation = Loose of string | Packed of pack

type decoded = {
  kind : object_kind;
  contents : string;
  representation : representation;
}

type store = {
  git : Fs.confined_handle;
  objects : Fs.confined_handle;
  mutable packs : pack list option;
  decoded : (string, decoded) Hashtbl.t;
  resolving : (string, unit) Hashtbl.t;
}

let withHandle handle f = protect (fun () -> Fs.confinedClose handle) (fun () -> f handle)

let expectDirectory label handle =
  if Fs.confinedKind handle <> Fs.ConfinedDirectory then
    fail (label ^ " is not an ordinary directory")

let expectFile label handle =
  if Fs.confinedKind handle <> Fs.ConfinedFile then
    fail (label ^ " is not an ordinary regular file")

let readFile label maximum handle =
  expectFile label handle;
  Fs.confinedRead handle maximum

let listDirectory label handle =
  expectDirectory label handle;
  Fs.confinedList handle
  |> List.filter (fun name -> name <> "." && name <> "..")
  |> List.sort String.compare

let withChild directory name f =
  match Fs.confinedOpenChild directory name with
  | None -> None
  | Some handle -> Some (withHandle handle f)

let requireChild directory name =
  match Fs.confinedOpenChild directory name with
  | None -> fail ("required Git metadata is missing: " ^ name)
  | Some handle -> handle

let checkNoAlternates objects =
  match withChild objects "info" (fun info ->
    expectDirectory "objects/info" info;
    match withChild info "alternates" (fun _ -> ()) with
    | None -> ()
    | Some () -> fail "Git object alternates are unsupported") with
  | None -> ()
  | Some () -> ()

let openStore worktree =
  match Fs.confinedOpen worktree [".git"] with
  | None -> fail "Git repository is missing"
  | Some git ->
      try
        expectDirectory ".git" git;
        let objects = requireChild git "objects" in
        try
          expectDirectory ".git/objects" objects;
          checkNoAlternates objects;
          { git; objects; packs = None; decoded = Hashtbl.create 251;
            resolving = Hashtbl.create 251 }
        with error ->
          Fs.confinedClose objects;
          Fs.confinedClose git;
          raise error
      with error ->
        Fs.confinedClose git;
        raise error

let openDestinationStore worktree =
  let readStore = openStore worktree in
  match Fs.confinedOpenWritableDirectory readStore.git "objects" with
  | None ->
      Fs.confinedClose readStore.objects;
      Fs.confinedClose readStore.git;
      fail ".git/objects disappeared before object transfer"
  | Some objects ->
      Fs.confinedClose readStore.objects;
      try
        expectDirectory ".git/objects" objects;
        checkNoAlternates objects;
        { readStore with objects; packs = None; decoded = Hashtbl.create 251;
          resolving = Hashtbl.create 251 }
      with error ->
        Fs.confinedClose objects;
        Fs.confinedClose readStore.git;
        raise error

let closeStore store =
  Fs.confinedClose store.objects;
  Fs.confinedClose store.git

let packStem name suffix =
  let prefix = "pack-" in
  if startsWith name prefix && endsWith name suffix then
    let length = String.length name - String.length prefix - String.length suffix in
    if length = 40 || length = 64 then
      let stem = String.sub name (String.length prefix) length in
      if Gitrepo.isObjectId stem then Some (lowercase stem) else None
    else None
  else None

let hashForLength length bytes =
  match length with
  | 20 -> Hash.sha1 bytes
  | 32 -> Hash.sha256 bytes
  | _ -> fail "unsupported Git pack hash length"

let parseIndex ~stem ~idx ~pack =
  let hashLength = String.length stem / 2 in
  let length = String.length idx in
  if String.length pack < 12 + hashLength ||
     String.length pack > packLimit || String.length idx > indexLimit then
    fail "Git pack or index exceeds the transfer limit";
  if length < 8 + 256 * 4 + 2 * hashLength ||
     String.sub idx 0 4 <> "\255tOc" || u32 idx 4 <> 2L then
    fail "only Git pack index version 2 is supported";
  let previous = ref 0L in
  for index = 0 to 255 do
    let current = u32 idx (8 + index * 4) in
    if current < !previous then fail "Git pack index fanout is not monotonic";
    previous := current
  done;
  let count = intOfU32 "Git pack index object count" !previous in
  if count > packObjectLimit then fail "Git pack has too many objects";
  let idsOffset = 8 + 256 * 4 in
  let crcsOffset = idsOffset + count * hashLength in
  let offsetsOffset = crcsOffset + count * 4 in
  if offsetsOffset < crcsOffset || offsetsOffset + count * 4 > length then
    fail "truncated Git pack index";
  let offsetWords = Array.init count (fun index -> u32 idx (offsetsOffset + index * 4)) in
  let largeCount = Array.fold_left (fun total word ->
    if Int64.logand word 0x80000000L <> 0L then total + 1 else total) 0 offsetWords in
  let largeOffset = offsetsOffset + count * 4 in
  let expectedLength = largeOffset + largeCount * 8 + hashLength * 2 in
  if expectedLength <> length then fail "Git pack index has an invalid length";
  let indexDigest = hashForLength hashLength (String.sub idx 0 (length - hashLength)) in
  if indexDigest <> hexOfBytes (String.sub idx (length - hashLength) hashLength) then
    fail "Git pack index checksum does not match";
  let packChecksum = hexOfBytes (String.sub idx (length - hashLength * 2) hashLength) in
  let packPayloadLength = String.length pack - hashLength in
  let actualPackChecksum = hashForLength hashLength
    (String.sub pack 0 packPayloadLength) in
  if actualPackChecksum <> hexOfBytes (String.sub pack packPayloadLength hashLength) ||
     actualPackChecksum <> packChecksum || actualPackChecksum <> lowercase stem then
    fail "Git pack checksum does not match its index or filename";
  if String.sub pack 0 4 <> "PACK" ||
     (u32 pack 4 <> 2L && u32 pack 4 <> 3L) ||
     intOfU32 "Git pack object count" (u32 pack 8) <> count then
    fail "Git pack header is invalid";
  let byOid = Hashtbl.create (count * 2 + 1) in
  let byOffset = Hashtbl.create (count * 2 + 1) in
  let largeSeen = Array.make largeCount false in
  let previousOid = ref None in
  for index = 0 to count - 1 do
    let oid = hexOfBytes (String.sub idx (idsOffset + index * hashLength) hashLength) in
    begin match !previousOid with
    | Some previous when previous >= oid -> fail "Git pack index object ids are not sorted"
    | _ -> ()
    end;
    previousOid := Some oid;
    let word = offsetWords.(index) in
    let offset =
      if Int64.logand word 0x80000000L = 0L then intOfU32 "Git pack offset" word
      else begin
        let entry = intOfU32 "Git pack large-offset index"
          (Int64.logand word 0x7fffffffL) in
        if entry >= largeCount || largeSeen.(entry) then
          fail "Git pack large offsets are invalid";
        largeSeen.(entry) <- true;
        let high = u32 idx (largeOffset + entry * 8) in
        let low = u32 idx (largeOffset + entry * 8 + 4) in
        let value = Int64.logor (Int64.shift_left high 32) low in
        if value > Int64.of_int packPayloadLength then
          fail "Git pack offset exceeds the pack";
        Int64.to_int value
      end in
    if offset < 12 || offset >= packPayloadLength || Hashtbl.mem byOffset offset then
      fail "Git pack contains an invalid or duplicate object offset";
    Hashtbl.add byOid oid offset;
    Hashtbl.add byOffset offset oid
  done;
  if not (Array.for_all (fun seen -> seen) largeSeen) then
    fail "Git pack large-offset table has unused entries";
  { stem = lowercase stem; packBytes = pack; indexBytes = idx; hashLength;
    byOid; byOffset; validated = false; validating = false }

let readPackDirectory store =
  match withChild store.objects "pack" (fun directory ->
    expectDirectory "objects/pack" directory;
    let names = listDirectory "objects/pack" directory in
    let stems = List.fold_left (fun stems name ->
      match packStem name ".idx", packStem name ".pack" with
      | Some stem, _ | _, Some stem -> StringSet.add stem stems
      | None, None -> stems) StringSet.empty names in
    StringSet.elements stems |> List.map (fun stem ->
      let idxName = "pack-" ^ stem ^ ".idx" in
      let packName = "pack-" ^ stem ^ ".pack" in
      let idx = match withChild directory idxName (readFile idxName indexLimit) with
        | Some contents -> contents
        | None -> fail ("Git pack index is missing its pack: " ^ idxName) in
      let pack = match withChild directory packName (readFile packName packLimit) with
        | Some contents -> contents
        | None -> fail ("Git pack is missing its index: " ^ packName) in
      parseIndex ~stem ~idx ~pack)) with
  | None -> []
  | Some packs -> packs

let packs store =
  match store.packs with
  | Some packs -> packs
  | None ->
      let found = readPackDirectory store in
      store.packs <- Some found;
      found

let parseDecimalSize text =
  if text = "" then fail "Git object has an empty size";
  let value = ref 0L in
  String.iter (fun character ->
    if character < '0' || character > '9' then fail "Git object has an invalid size";
    value := Int64.add (Int64.mul !value 10L)
      (Int64.of_int (Char.code character - Char.code '0'));
    if !value > Int64.of_int objectLimit then fail "Git object exceeds the transfer limit") text;
  let size = Int64.to_int !value in
  if text <> string_of_int size then fail "Git object size is non-canonical";
  size

let decodeCanonical oid representation raw =
  let separator = try String.index raw '\000' with Not_found ->
    fail "Git object is missing its header terminator" in
  let header = String.sub raw 0 separator in
  let kind, declared = match String.split_on_char ' ' header with
    | [name; size] -> kindOfName name, parseDecimalSize size
    | _ -> fail "Git object header is malformed" in
  let contents = String.sub raw (separator + 1) (String.length raw - separator - 1) in
  if String.length contents <> declared then fail "Git object size does not match its header";
  if Hash.forOid oid raw <> lowercase oid then
    fail "Git object contents do not match its object identifier";
  { kind; contents; representation }

let decodeLoose oid compressed =
  let raw, consumed = Fs.confinedInflateZlib compressed 0 objectLimit in
  if consumed <> String.length compressed then
    fail "loose Git object contains trailing data";
  decodeCanonical oid (Loose compressed) raw

let rec readLoose store oid =
  let oid = lowercase oid in
  if not (Gitrepo.isObjectId oid) then fail "invalid Git object identifier";
  let prefix = String.sub oid 0 2 in
  let suffix = String.sub oid 2 (String.length oid - 2) in
  match withChild store.objects prefix (fun directory ->
    expectDirectory ("objects/" ^ prefix) directory;
    match withChild directory suffix (readFile ("objects/" ^ prefix ^ "/" ^ suffix) looseLimit) with
    | None -> None
    | Some compressed -> Some (decodeLoose oid compressed)) with
  | None -> None
  | Some decoded -> decoded

let packedHeader pack offset =
  let data = pack.packBytes in
  let payloadLength = String.length data - pack.hashLength in
  if offset < 12 || offset >= payloadLength then fail "Git packed object offset is invalid";
  let first = byte data offset in
  let typeCode = (first lsr 4) land 7 in
  let size = ref (Int64.of_int (first land 15)) in
  let shift = ref 4 in
  let position = ref (offset + 1) in
  let continuation = ref (first land 0x80 <> 0) in
  while !continuation do
    if !position >= payloadLength || !shift > 56 then fail "Git packed object header is truncated";
    let next = byte data !position in
    incr position;
    size := Int64.logor !size (Int64.shift_left (Int64.of_int (next land 0x7f)) !shift);
    shift := !shift + 7;
    continuation := next land 0x80 <> 0
  done;
  if !size > Int64.of_int objectLimit then fail "Git packed object exceeds the transfer limit";
  let entry = match typeCode with
    | 1 -> PackedBase Commit
    | 2 -> PackedBase Tree
    | 3 -> PackedBase Blob
    | 4 -> PackedBase Tag
    | 6 ->
        let first = if !position >= payloadLength then fail "truncated OFS_DELTA" else byte data !position in
        incr position;
        let distance = ref (Int64.of_int (first land 0x7f)) in
        let more = ref (first land 0x80 <> 0) in
        while !more do
          if !position >= payloadLength then fail "truncated OFS_DELTA";
          let next = byte data !position in
          incr position;
          distance := Int64.add (Int64.shift_left (Int64.add !distance 1L) 7)
            (Int64.of_int (next land 0x7f));
          more := next land 0x80 <> 0
        done;
        if !distance > Int64.of_int offset then fail "OFS_DELTA escapes its pack";
        PackedOfsDelta (offset - Int64.to_int !distance)
    | 7 ->
        if !position + pack.hashLength > payloadLength then fail "truncated REF_DELTA";
        let oid = hexOfBytes (String.sub data !position pack.hashLength) in
        position := !position + pack.hashLength;
        PackedRefDelta oid
    | _ -> fail "unsupported Git packed object type" in
  let inflated, consumed = Fs.confinedInflateZlib data !position objectLimit in
  let endOffset = !position + consumed in
  if endOffset > payloadLength then fail "Git packed object crosses the pack trailer";
  begin match entry with
  | PackedBase _ when String.length inflated <> Int64.to_int !size ->
      fail "Git packed object size does not match its header"
  | _ -> ()
  end;
  entry, inflated, endOffset

let deltaInteger data position =
  let value = ref 0L in
  let shift = ref 0 in
  let position = ref position in
  let more = ref true in
  while !more do
    if !position >= String.length data || !shift > 56 then fail "truncated Git delta header";
    let next = byte data !position in
    incr position;
    value := Int64.logor !value
      (Int64.shift_left (Int64.of_int (next land 0x7f)) !shift);
    shift := !shift + 7;
    more := next land 0x80 <> 0
  done;
  if !value > Int64.of_int objectLimit then fail "Git delta exceeds the transfer limit";
  Int64.to_int !value, !position

let applyDelta base delta =
  let sourceSize, position = deltaInteger delta 0 in
  if sourceSize <> String.length base then fail "Git delta base size does not match";
  let destinationSize, position = deltaInteger delta position in
  let output = Bytes.create destinationSize in
  let input = ref position in
  let outputPosition = ref 0 in
  while !input < String.length delta do
    let instruction = byte delta !input in
    incr input;
    if instruction = 0 then fail "Git delta contains a reserved opcode"
    else if instruction land 0x80 <> 0 then begin
      let offset = ref 0 and length = ref 0 in
      let field bit shift =
        if instruction land bit <> 0 then begin
          if !input >= String.length delta then fail "truncated Git delta copy";
          offset := !offset lor (byte delta !input lsl shift);
          incr input
        end in
      field 0x01 0; field 0x02 8; field 0x04 16; field 0x08 24;
      let lengthField bit shift =
        if instruction land bit <> 0 then begin
          if !input >= String.length delta then fail "truncated Git delta copy";
          length := !length lor (byte delta !input lsl shift);
          incr input
        end in
      lengthField 0x10 0; lengthField 0x20 8; lengthField 0x40 16;
      if !length = 0 then length := 0x10000;
      if !offset < 0 || !length > String.length base - !offset ||
         !length > destinationSize - !outputPosition then
        fail "Git delta copy is out of bounds";
      Bytes.blit_string base !offset output !outputPosition !length;
      outputPosition := !outputPosition + !length
    end else begin
      let length = instruction land 0x7f in
      if length > String.length delta - !input ||
         length > destinationSize - !outputPosition then
        fail "Git delta insert is out of bounds";
      Bytes.blit_string delta !input output !outputPosition length;
      input := !input + length;
      outputPosition := !outputPosition + length
    end
  done;
  if !outputPosition <> destinationSize then fail "Git delta produced the wrong size";
  Bytes.to_string output

let rec resolvePacked store pack oid depth =
  if depth > deltaDepthLimit then fail "Git delta chain is too deep";
  let oid = lowercase oid in
  let offset = try Hashtbl.find pack.byOid oid with Not_found ->
    fail "Git pack index does not contain its requested object" in
  let entry, data, _ = packedHeader pack offset in
  let kind, contents = match entry with
    | PackedBase kind -> kind, data
    | PackedOfsDelta baseOffset ->
        let baseOid = try Hashtbl.find pack.byOffset baseOffset with Not_found ->
          fail "OFS_DELTA base is not an indexed pack object" in
        let base = resolveObject store baseOid (depth + 1) in
        base.kind, applyDelta base.contents data
    | PackedRefDelta baseOid ->
        let base = resolveObject store baseOid (depth + 1) in
        base.kind, applyDelta base.contents data in
  let raw = canonical kind contents in
  if Hash.forOid oid raw <> oid then fail "Git packed object hash does not match its index";
  { kind; contents; representation = Packed pack }

and validatePack store pack =
  if not pack.validated && not pack.validating then begin
    pack.validating <- true;
    try
      Hashtbl.iter (fun oid _ ->
        ignore (resolvePacked store pack oid 0)) pack.byOid;
      (* Validate that every index offset is a real object boundary. *)
      let position = ref 12 in
      for _ = 1 to Hashtbl.length pack.byOid do
        if not (Hashtbl.mem pack.byOffset !position) then
          fail "Git pack index offset is not an object boundary";
        let _, _, next = packedHeader pack !position in
        position := next
      done;
      if !position <> String.length pack.packBytes - pack.hashLength then
        fail "Git pack has trailing or missing object data";
      pack.validated <- true;
      pack.validating <- false
    with error ->
      pack.validating <- false;
      raise error
  end

and resolveObject store oid depth =
  let oid = lowercase oid in
  if not (Gitrepo.isObjectId oid) then fail "invalid Git object identifier";
  try Hashtbl.find store.decoded oid with Not_found ->
    if Hashtbl.mem store.resolving oid then fail "cyclic Git object delta";
    Hashtbl.add store.resolving oid ();
    try
      let decoded = match readLoose store oid with
        | Some decoded -> decoded
        | None ->
            let pack = try List.find (fun pack -> Hashtbl.mem pack.byOid oid) (packs store)
              with Not_found -> fail ("required Git object is missing: " ^ oid) in
            resolvePacked store pack oid depth in
      Hashtbl.remove store.resolving oid;
      Hashtbl.replace store.decoded oid decoded;
      begin match decoded.representation with
      | Packed pack -> validatePack store pack
      | Loose _ -> ()
      end;
      decoded
    with error ->
      Hashtbl.remove store.resolving oid;
      raise error

let snapshotRoots snapshot =
  let refs = List.fold_left (fun refs (name, value) ->
    if not (Gitrepo.isSupportedRefName name) then fail "snapshot has an invalid Git ref name";
    if List.mem_assoc name refs then fail "snapshot contains a duplicate Git ref";
    if not (Gitrepo.isObjectId value) && not (startsWith value "ref: ") then
      fail "snapshot has an invalid Git ref value";
    (name, value) :: refs) [] snapshot.Gitstate.refs in
  let lookup name = try List.assoc name refs with Not_found ->
    fail ("symbolic Git ref has no durable target: " ^ name) in
  let rec resolve seen value =
    if Gitrepo.isObjectId value then lowercase value
    else if startsWith value "ref: " then begin
      let target = String.sub value 5 (String.length value - 5) in
      if not (Gitrepo.isSupportedRefName target) || StringSet.mem target seen then
        fail "snapshot contains an invalid or cyclic symbolic Git ref";
      resolve (StringSet.add target seen) (lookup target)
    end else fail "snapshot contains an invalid Git object identifier" in
  let roots = List.fold_left (fun roots (_, value) ->
    StringSet.add (resolve StringSet.empty value) roots) StringSet.empty refs in
  match snapshot.Gitstate.head with
  | Gitstate.Absent -> roots
  | Gitstate.Present value -> StringSet.add (resolve StringSet.empty value) roots

let objectIdsInCommit hashLength contents =
  let tree = ref None in
  let parents = ref [] in
  let headers =
    let rec take result = function
      | [] -> List.rev result
      | "" :: _ -> List.rev result
      | line :: rest -> take (line :: result) rest in
    take [] (String.split_on_char '\n' contents) in
  headers |> List.iter (fun line ->
    if startsWith line "tree " then begin
      let oid = String.sub line 5 (String.length line - 5) in
      if String.length oid <> hashLength * 2 || not (Gitrepo.isObjectId oid) ||
         !tree <> None then fail "Git commit has an invalid tree line";
      tree := Some (lowercase oid)
    end else if startsWith line "parent " then begin
      let oid = String.sub line 7 (String.length line - 7) in
      if String.length oid <> hashLength * 2 || not (Gitrepo.isObjectId oid) then
        fail "Git commit has an invalid parent line";
      parents := lowercase oid :: !parents
    end);
  match !tree with
  | None -> fail "Git commit has no tree"
  | Some tree -> tree :: List.rev !parents

let objectIdsInTag hashLength contents =
  let headers =
    let rec take result = function
      | [] -> List.rev result
      | "" :: _ -> List.rev result
      | line :: rest -> take (line :: result) rest in
    take [] (String.split_on_char '\n' contents) in
  match List.find_opt (fun line -> startsWith line "object ") headers with
  | None -> fail "Git tag has no object line"
  | Some line ->
      let oid = String.sub line 7 (String.length line - 7) in
      if String.length oid <> hashLength * 2 || not (Gitrepo.isObjectId oid) then
        fail "Git tag has an invalid object line";
      [lowercase oid]

let objectIdsInTree hashLength contents =
  let position = ref 0 in
  let objects = ref [] in
  while !position < String.length contents do
    let space = try String.index_from contents !position ' ' with Not_found ->
      fail "Git tree entry has no mode separator" in
    let mode = String.sub contents !position (space - !position) in
    let nul = try String.index_from contents (space + 1) '\000' with Not_found ->
      fail "Git tree entry has no name terminator" in
    let name = String.sub contents (space + 1) (nul - space - 1) in
    if name = "" || name = "." || name = ".." || String.contains name '/' then
      fail "Git tree has an invalid entry name";
    let oidStart = nul + 1 in
    if oidStart + hashLength > String.length contents then fail "truncated Git tree object id";
    let oid = hexOfBytes (String.sub contents oidStart hashLength) in
    begin match mode with
    | "100644" | "100755" | "120000" | "40000" -> objects := oid :: !objects
    | "160000" -> fail "Git submodules are unsupported"
    | _ -> fail "Git tree has an unsupported file mode"
    end;
    position := oidStart + hashLength
  done;
  List.rev !objects

let objectChildren oid decoded =
  let hashLength = String.length oid / 2 in
  match decoded.kind with
  | Blob -> []
  | Commit -> objectIdsInCommit hashLength decoded.contents
  | Tree -> objectIdsInTree hashLength decoded.contents
  | Tag -> objectIdsInTag hashLength decoded.contents

let installExact directory name contents =
  let validateExisting () =
    match withChild directory name (readFile name (String.length contents)) with
    | Some existing when existing = contents -> ()
    | Some _ -> fail ("destination already contains different immutable Git data: " ^ name)
    | None -> fail ("destination object disappeared while being installed: " ^ name) in
  match withChild directory name (readFile name (String.length contents)) with
  | Some existing when existing = contents -> false
  | Some _ -> fail ("destination already contains different immutable Git data: " ^ name)
  | None ->
      begin match Fs.confinedInstall directory name contents with
      | Fs.ConfinedInstalled -> true
      | Fs.ConfinedAlreadyPresent -> validateExisting (); false
      end

type counters = { mutable seen : int; mutable loose : int; mutable packs : int }

let installLoose destination oid compressed counters =
  let prefix = String.sub oid 0 2 in
  let suffix = String.sub oid 2 (String.length oid - 2) in
  let directory = Fs.confinedEnsureDirectory destination.objects prefix in
  protect (fun () -> Fs.confinedClose directory) (fun () ->
    match Fs.confinedInstall directory suffix compressed with
    | Fs.ConfinedInstalled -> counters.loose <- counters.loose + 1
    | Fs.ConfinedAlreadyPresent ->
        (* A concurrent writer may have installed a differently-compressed
         * representation of the same immutable object.  Re-parse that exact
         * opened destination object rather than comparing compressed bytes. *)
        Hashtbl.remove destination.decoded oid;
        ignore (resolveObject destination oid 0))

let installPack destination pack counters installed =
  if not (StringSet.mem pack.stem !installed) then begin
    let directory = Fs.confinedEnsureDirectory destination.objects "pack" in
    protect (fun () -> Fs.confinedClose directory) (fun () ->
      let packInstalled = installExact directory ("pack-" ^ pack.stem ^ ".pack") pack.packBytes in
      let indexInstalled = installExact directory ("pack-" ^ pack.stem ^ ".idx") pack.indexBytes in
      if packInstalled then counters.packs <- counters.packs + 1;
      if indexInstalled then counters.packs <- counters.packs + 1;
      if packInstalled || indexInstalled then begin
        destination.packs <- None;
        Hashtbl.clear destination.decoded
      end;
      installed := StringSet.add pack.stem !installed)
  end

let destinationHas destination oid =
  try
    ignore (resolveObject destination oid 0);
    true
  with
  | Unsupported message when startsWith message "required Git object is missing: " -> false

type report = {
  objects_seen : int;
  loose_objects_installed : int;
  pack_files_installed : int;
}

let snapshotHashLength snapshot =
  let roots = snapshotRoots snapshot in
  StringSet.fold (fun oid length ->
    let current = String.length oid in
    match length with
    | None -> Some current
    | Some previous when previous = current -> length
    | Some _ -> fail "Git snapshot mixes SHA-1 and SHA-256 object ids") roots None

let validateSnapshot ~repository snapshot =
  try
    if not Sys.win32 then
      Error "Git object validation requires the native Windows confinement backend"
    else begin
      let store = openStore repository in
      protect (fun () -> closeStore store) (fun () ->
        begin match Gitrepo.inspect repository with
        | Gitrepo.Ready current ->
            begin match snapshotHashLength snapshot, snapshotHashLength current with
            | Some desiredLength, Some currentLength when desiredLength <> currentLength ->
                fail "repository Git object format differs from the desired snapshot"
            | _ -> ()
            end
        | Gitrepo.Busy message -> fail ("Git repository is busy: " ^ message)
        | Gitrepo.Missing -> fail "Git repository is missing"
        | Gitrepo.Unsupported message -> fail ("Git repository is unsupported: " ^ message)
        end;
        let queue = Queue.create () in
        StringSet.iter (fun oid -> Queue.push oid queue) (snapshotRoots snapshot);
        let visited = Hashtbl.create 251 in
        while not (Queue.is_empty queue) do
          let oid = Queue.pop queue |> lowercase in
          if not (Hashtbl.mem visited oid) then begin
            if Hashtbl.length visited >= traversalLimit then
              fail "Git object graph exceeds the transfer limit";
            Hashtbl.add visited oid ();
            let decoded = resolveObject store oid 0 in
            List.iter (fun child -> Queue.push child queue)
              (objectChildren oid decoded)
          end
        done;
        Ok (Hashtbl.length visited))
    end
  with
  | Unsupported message -> Error message
  | Util.Transient message -> Error message
  | Unix.Unix_error (error, operation, path) ->
      Error (Printf.sprintf "%s failed for %s: %s" operation path
        (Unix.error_message error))
  | Sys_error message -> Error message
  | Failure message -> Error message
  | Invalid_argument message -> Error message

let transfer ~source ~destination snapshot =
  try
    if not Sys.win32 then Error "Git object transfer requires the native Windows confinement backend"
    else begin
      let sourceStore = openStore source in
      protect (fun () -> closeStore sourceStore) (fun () ->
        let destinationStore = openDestinationStore destination in
        protect (fun () -> closeStore destinationStore) (fun () ->
          begin match Gitrepo.inspect destination with
          | Gitrepo.Ready destinationSnapshot ->
              begin match snapshotHashLength snapshot, snapshotHashLength destinationSnapshot with
              | Some sourceLength, Some destinationLength when sourceLength <> destinationLength ->
                  fail "source and destination Git object formats differ"
              | _ -> ()
              end
          | Gitrepo.Busy message -> fail ("destination Git repository is busy: " ^ message)
          | Gitrepo.Missing -> fail "destination Git repository is missing"
          | Gitrepo.Unsupported message -> fail ("destination Git repository is unsupported: " ^ message)
          end;
          let queue = Queue.create () in
          StringSet.iter (fun oid -> Queue.push oid queue) (snapshotRoots snapshot);
          let visited = Hashtbl.create 251 in
          let counters = { seen = 0; loose = 0; packs = 0 } in
          let installedPacks = ref StringSet.empty in
          while not (Queue.is_empty queue) do
            let oid = Queue.pop queue |> lowercase in
            if not (Hashtbl.mem visited oid) then begin
              if counters.seen >= traversalLimit then fail "Git object graph exceeds the transfer limit";
              Hashtbl.add visited oid ();
              counters.seen <- counters.seen + 1;
              let decoded = resolveObject sourceStore oid 0 in
              if not (destinationHas destinationStore oid) then begin
                match decoded.representation with
                | Loose compressed -> installLoose destinationStore oid compressed counters
                | Packed pack -> installPack destinationStore pack counters installedPacks
              end;
              List.iter (fun child -> Queue.push child queue) (objectChildren oid decoded)
            end
          done;
          Ok { objects_seen = counters.seen;
               loose_objects_installed = counters.loose;
               pack_files_installed = counters.packs })
      )
    end
  with
  | Unsupported message -> Error message
  | Util.Transient message -> Error message
  | Unix.Unix_error (error, operation, path) ->
      Error (Printf.sprintf "%s failed for %s: %s" operation path (Unix.error_message error))
  | Sys_error message -> Error message
  | Failure message -> Error message
  | Invalid_argument message -> Error message
