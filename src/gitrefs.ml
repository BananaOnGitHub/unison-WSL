(* Unison file synchronizer: src/gitrefs.ml *)
(* See LICENSE for terms. *)

(*
   Durable Git ref and HEAD publication for WSL workspace mode.

   Gitstate remains the only reconciliation model.  This module merely turns
   an already-resolved directional entry list into tightly-scoped mutations of
   an existing .git directory.  It never executes Git or reads repository
   configuration, hooks, attributes, indexes, reflogs, or work-tree files.
*)

module StringMap = Map.Make (String)
module StringSet = Set.Make (String)

type target = Left | Right

type report = {
  refs_changed : int;
  head_changed : bool;
  packed_refs_rewritten : bool;
}

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

let startsWith text prefix =
  let length = String.length prefix in
  String.length text >= length && String.sub text 0 length = prefix

let withHandle handle f =
  protect (fun () -> Fs.confinedClose handle) (fun () -> f handle)

let expectDirectory label handle =
  if Fs.confinedKind handle <> Fs.ConfinedDirectory then
    fail (label ^ " is not an ordinary directory")

let expectFile label handle =
  if Fs.confinedKind handle <> Fs.ConfinedFile then
    fail (label ^ " is not an ordinary regular file")

let metadataLimit = 1024 * 1024

let readFile label handle =
  expectFile label handle;
  Fs.confinedRead handle metadataLimit

let withChild directory name f =
  match Fs.confinedOpenChild directory name with
  | None -> None
  | Some handle -> Some (withHandle handle f)

let mapOfRefs refs =
  List.fold_left (fun map (name, value) -> StringMap.add name value map)
    StringMap.empty refs

let valueOfRef refs name =
  try Gitstate.Present (StringMap.find name refs) with Not_found -> Gitstate.Absent

let validateHeadValue = function
  | Gitstate.Absent -> fail "deleting HEAD is unsupported for an existing repository"
  | Gitstate.Present value ->
      begin match Gitrepo.parseRefValue (value ^ "\n") with
      | Some parsed when parsed = value -> ()
      | _ -> fail "the Gitstate plan has an invalid HEAD value"
      end

let validateRefValue = function
  | Gitstate.Absent -> ()
  | Gitstate.Present value when Gitrepo.isObjectId value -> ()
  | Gitstate.Present _ ->
      fail "symbolic durable refs are unsupported; only symbolic HEAD is supported"

let selectedMutation target entry =
  match entry.Gitstate.action, target with
  | Gitstate.Conflict, _ -> fail ("Gitstate plan has a conflict at " ^ entry.name)
  | Gitstate.CopyLeftToRight desired, Right -> Some (entry.base, entry.right, desired)
  | Gitstate.CopyRightToLeft desired, Left -> Some (entry.base, entry.left, desired)
  | _ -> None

type prepared = {
  expected_head : Gitstate.value option;
  desired_head : Gitstate.value option;
  ref_mutations : (string * Gitstate.value * Gitstate.value) list;
  desired_snapshot : Gitstate.snapshot;
}

let prepare target entries current =
  let refs = ref (mapOfRefs current.Gitstate.refs) in
  let desiredRefs = ref !refs in
  let expectedHead = ref None in
  let desiredHead = ref None in
  let mutations = ref [] in
  let names = ref StringSet.empty in
  List.iter (fun entry ->
    if StringSet.mem entry.name !names then
      fail ("Gitstate plan contains the same entry twice: " ^ entry.name);
    names := StringSet.add entry.name !names;
    begin match entry.Gitstate.action with
    | Gitstate.Conflict -> fail ("Gitstate plan has a conflict at " ^ entry.name)
    | _ -> ()
    end;
    match selectedMutation target entry with
    | None -> ()
    | Some (_, expected, desired) ->
        if entry.name = "HEAD" then begin
          validateHeadValue expected;
          validateHeadValue desired;
          if current.Gitstate.head <> expected then
            fail "HEAD no longer matches the reconciliation plan's expected pre-state";
          expectedHead := Some expected;
          desiredHead := Some desired
        end else begin
          if not (Gitrepo.isSupportedRefName entry.name) then
            fail ("Gitstate plan has an unsupported ref name: " ^ entry.name);
          validateRefValue expected;
          validateRefValue desired;
          if valueOfRef !refs entry.name <> expected then
            fail ("ref no longer matches the reconciliation plan's expected pre-state: "
                  ^ entry.name);
          desiredRefs :=
            match desired with
            | Gitstate.Absent -> StringMap.remove entry.name !desiredRefs
            | Gitstate.Present value -> StringMap.add entry.name value !desiredRefs;
          mutations := (entry.name, expected, desired) :: !mutations
        end)
    entries;
  { expected_head = !expectedHead;
    desired_head = !desiredHead;
    ref_mutations = List.rev !mutations;
    desired_snapshot = {
      Gitstate.head = (match !desiredHead with Some value -> value | None -> current.head);
      refs = StringMap.bindings !desiredRefs;
    }; }

(* Strict packed-refs parsing is intentionally separate from Gitrepo's
   inspection parser.  Inspection can omit unsupported durable namespaces;
   rewriting must preserve any syntactically valid unrelated ref verbatim and
   therefore rejects a file it cannot round-trip safely. *)
type packed_entry = {
  name : string;
  oid : string;
  lines : string list;
}

type packed_piece = PackedComment of string | PackedEntry of packed_entry

type packed = MissingPacked | PresentPacked of string * packed_piece list

let validatePackedHeader line =
  let prefix = "# pack-refs with: " in
  if startsWith line "# pack-refs with:" && not (startsWith line prefix) then
    fail "packed-refs has a malformed header"
  else if startsWith line prefix then
    let flags = String.sub line (String.length prefix)
      (String.length line - String.length prefix)
      |> String.split_on_char ' ' in
    if flags = [] || List.exists (fun flag ->
         flag <> "peeled" && flag <> "fully-peeled" && flag <> "sorted") flags then
      fail "packed-refs has unsupported header flags"

let parsePacked raw =
  if raw = "" || raw.[String.length raw - 1] <> '\n' then
    fail "packed-refs is not newline terminated";
  let lines = String.split_on_char '\n' raw in
  let lines = match List.rev lines with
    | "" :: rest -> List.rev rest
    | _ -> assert false in
  let seen = ref StringSet.empty in
  let hashLength = ref None in
  let checkOid oid =
    if not (Gitrepo.isObjectId oid) then fail "packed-refs contains an invalid object id";
    match !hashLength with
    | None -> hashLength := Some (String.length oid)
    | Some length when length = String.length oid -> ()
    | Some _ -> fail "packed-refs mixes SHA-1 and SHA-256 object ids" in
  let direct line =
    match String.split_on_char ' ' line with
    | [oid; name] when Gitrepo.isValidRefName name ->
        checkOid oid;
        if StringSet.mem name !seen then fail "packed-refs contains a duplicate ref";
        seen := StringSet.add name !seen;
        oid, name
    | _ -> fail "packed-refs contains an unsupported direct-ref line" in
  let rec loop pieces = function
    | [] -> List.rev pieces
    | line :: rest when line = "" -> fail "packed-refs contains an empty line"
    | line :: rest when startsWith line "#" ->
        validatePackedHeader line;
        loop (PackedComment line :: pieces) rest
    | line :: rest when startsWith line "^" ->
        fail "packed-refs has a peeled line without a direct ref"
    | line :: rest ->
        let oid, name = direct line in
        begin match rest with
        | peel :: remaining when startsWith peel "^" ->
            let peeled = String.sub peel 1 (String.length peel - 1) in
            checkOid peeled;
            if String.length peeled <> String.length oid then
              fail "packed-refs peeled id has the wrong object format";
            loop (PackedEntry { name; oid; lines = [line; peel] } :: pieces) remaining
        | _ -> loop (PackedEntry { name; oid; lines = [line] } :: pieces) rest
        end in
  loop [] lines

let packedMap = function
  | MissingPacked -> StringMap.empty
  | PresentPacked (_, pieces) ->
      List.fold_left (fun map -> function
        | PackedComment _ -> map
        | PackedEntry entry -> StringMap.add entry.name entry.oid map)
        StringMap.empty pieces

let readPacked git =
  match withChild git "packed-refs" (fun handle ->
    let raw = readFile "packed-refs" handle in
    raw, parsePacked raw) with
  | None -> MissingPacked
  | Some (raw, pieces) -> PresentPacked (raw, pieces)

let renderPacked pieces removed =
  let lines = List.fold_left (fun lines -> function
    | PackedComment line -> line :: lines
    | PackedEntry entry when StringSet.mem entry.name removed -> lines
    | PackedEntry entry -> List.rev_append entry.lines lines)
    [] pieces |> List.rev in
  String.concat "" (List.map (fun line -> line ^ "\n") lines)

let casResult label = function
  | Fs.ConfinedChanged -> ()
  | Fs.ConfinedMismatch -> fail (label ^ " changed concurrently")
  | Fs.ConfinedBusy -> fail (label ^ " is locked or busy")

let refComponents name =
  match String.split_on_char '/' name with
  | "refs" :: rest when rest <> [] -> rest
  | _ -> fail ("invalid supported ref name: " ^ name)

let withRefParent git name create f =
  let rec descend directory = function
    | [] -> assert false
    | [leaf] -> f directory leaf
    | component :: rest ->
        let child =
          match Fs.confinedOpenMutationDirectory directory component with
          | Some handle -> handle
          | None when create -> Fs.confinedEnsureMutationDirectory directory component
          | None -> raise (Unix.Unix_error (Unix.ENOENT,
              "confinedOpenMutationDirectory", component)) in
        protect (fun () -> Fs.confinedClose child) (fun () -> descend child rest) in
  match Fs.confinedOpenMutationDirectory git "refs" with
  | Some refs -> Some (protect (fun () -> Fs.confinedClose refs)
      (fun () -> descend refs (refComponents name)))
  | None when create ->
      let refs = Fs.confinedEnsureMutationDirectory git "refs" in
      Some (protect (fun () -> Fs.confinedClose refs)
        (fun () -> descend refs (refComponents name)))
  | None -> None

let looseRef parent leaf =
  match withChild parent leaf (fun handle ->
    let raw = readFile leaf handle in
    match Gitrepo.parseRefValue raw with
    | Some value -> raw, value
    | None -> fail ("loose ref has unsupported contents: " ^ leaf)) with
  | None -> None
  | Some value -> Some value

let mutateRef git packed name expected desired changed =
  let packedValue = valueOfRef (packedMap packed) name in
  let create = match desired with Gitstate.Present _ -> true | Gitstate.Absent -> false in
  try
    match withRefParent git name create (fun parent leaf ->
      match looseRef parent leaf with
      | Some (raw, current) ->
          if Gitstate.Present current <> expected then
            fail ("ref changed concurrently before publication: " ^ name);
          begin match desired with
          | Gitstate.Present value when value = current -> ()
          | Gitstate.Present value ->
              casResult name (Fs.confinedCasReplace parent leaf (Some raw) (value ^ "\n"));
              incr changed
          | Gitstate.Absent ->
              casResult name (Fs.confinedCasDelete parent leaf raw);
              incr changed
          end
      | None ->
          begin match desired with
          | Gitstate.Absent ->
              (* A packed value, if any, was removed in the preceding rewrite. *)
              ()
          | Gitstate.Present value ->
              if packedValue <> expected then
                fail ("packed ref changed concurrently before publication: " ^ name);
              casResult name (Fs.confinedCasReplace parent leaf None (value ^ "\n"));
              incr changed
          end) with
    | Some () -> ()
    | None ->
        begin match expected, desired with
        | Gitstate.Absent, Gitstate.Absent -> ()
        | _ -> fail ("ref directory changed concurrently before publication: " ^ name)
        end
  with Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) ->
    begin match expected, desired with
    | Gitstate.Absent, Gitstate.Absent -> ()
    | _ -> fail ("ref directory changed concurrently before publication: " ^ name)
    end

let rewritePacked git packed removed =
  if StringSet.is_empty removed then false
  else match packed with
  | MissingPacked -> fail "a requested packed-ref deletion has no packed-refs file"
  | PresentPacked (raw, pieces) ->
      let replacement = renderPacked pieces removed in
      if replacement = raw then false
      else begin
        if replacement = "" then
          casResult "packed-refs"
            (Fs.confinedCasDelete git "packed-refs" raw)
        else
          casResult "packed-refs"
            (Fs.confinedCasReplace git "packed-refs" (Some raw) replacement);
        true
      end

let apply ~repository ~target entries =
  try
    if not Sys.win32 then
      Error "Git ref mutation requires the native Windows confinement backend"
    else begin
      let current = match Gitrepo.inspect repository with
        | Gitrepo.Ready snapshot -> snapshot
        | Gitrepo.Busy message -> fail ("Git repository is busy: " ^ message)
        | Gitrepo.Missing -> fail "Git repository is missing"
        | Gitrepo.Unsupported message -> fail ("Git repository is unsupported: " ^ message) in
      let prepared = prepare target entries current in
      begin match Gitobjects.validateSnapshot ~repository prepared.desired_snapshot with
      | Ok _ -> ()
      | Error message -> fail ("required destination Git object closure is invalid: " ^ message)
      end;
      match Fs.confinedOpenMutation repository [".git"] with
      | None -> fail "Git repository disappeared before ref publication"
      | Some git ->
          withHandle git (fun git ->
            expectDirectory ".git" git;
            begin match Gitrepo.isBusy git with
            | Some path -> fail ("Git repository became busy before publication: " ^ path)
            | None -> ()
            end;
            let packed = readPacked git in
            let initialPacked = packedMap packed in
            (* The initial inspection checks logical expected state.  This
             * second check catches a replacement that occurred before the
             * mutation lease was acquired, including loose shadowing. *)
            List.iter (fun (name, expected, _) ->
              let actual =
                try
                  match withRefParent git name false (fun parent leaf ->
                    match looseRef parent leaf with
                    | Some (_, value) -> Gitstate.Present value
                    | None -> valueOfRef initialPacked name) with
                  | Some actual -> actual
                  | None -> valueOfRef initialPacked name
                with Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) ->
                  valueOfRef initialPacked name in
              if actual <> expected then
                fail ("ref changed concurrently before publication: " ^ name))
              prepared.ref_mutations;
            let removals = List.fold_left (fun removed (name, _, desired) ->
              match desired with
              | Gitstate.Absent when StringMap.mem name initialPacked ->
                  StringSet.add name removed
              | _ -> removed) StringSet.empty prepared.ref_mutations in
            let packedRefsRewritten = rewritePacked git packed removals in
            let changed = ref 0 in
            List.iter (fun (name, expected, desired) ->
              mutateRef git packed name expected desired changed)
              prepared.ref_mutations;
            let headChanged = match prepared.expected_head, prepared.desired_head with
              | None, None -> false
              | Some expected, Some desired when expected = desired -> false
              | Some expected, Some desired ->
                  let rawHead = match withChild git "HEAD" (fun handle ->
                    let raw = readFile "HEAD" handle in
                    match Gitrepo.parseRefValue raw with
                    | Some value when Gitstate.Present value = expected -> raw
                    | _ -> fail "HEAD changed concurrently before publication") with
                    | Some raw -> raw
                    | None -> fail "HEAD disappeared before publication" in
                  casResult "HEAD"
                    (Fs.confinedCasReplace git "HEAD"
                      (Some rawHead)
                      (match desired with Gitstate.Present value -> value ^ "\n"
                       | Gitstate.Absent -> assert false));
                  true
              | _ -> fail "invalid HEAD mutation plan" in
            Ok { refs_changed = !changed; head_changed = headChanged;
                 packed_refs_rewritten = packedRefsRewritten })
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
