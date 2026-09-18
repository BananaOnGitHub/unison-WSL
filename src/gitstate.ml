(* Unison file synchronizer: src/gitstate.ml *)
(* See LICENSE for terms. *)

type value = Absent | Present of string

type action =
  | Keep of value
  | CopyLeftToRight of value
  | CopyRightToLeft of value
  | Conflict

type entry = {
  name : string;
  base : value;
  left : value;
  right : value;
  action : action;
}

type snapshot = {
  head : value;
  refs : (string * string) list;
}

type repository = Missing | Repository of snapshot

type repository_plan =
  | NoRepository
  | InitializeLeftFromRight
  | InitializeRightFromLeft
  | Reconcile of entry list
  | RepositoryConflict of string

module StringMap = Map.Make (String)

let reconcileValue ~base ~left ~right =
  if left = right then Keep left
  else if left = base then CopyRightToLeft right
  else if right = base then CopyLeftToRight left
  else Conflict

let refsToMap refs =
  List.fold_left (fun map (name, value) -> StringMap.add name value map)
    StringMap.empty refs

let findRef map name =
  try Present (StringMap.find name map) with Not_found -> Absent

let reconcileSnapshot ~base ~left ~right =
  let baseRefs = refsToMap base.refs in
  let leftRefs = refsToMap left.refs in
  let rightRefs = refsToMap right.refs in
  let names =
    let addKeys map keys =
      StringMap.fold (fun key _ keys -> StringMap.add key () keys) map keys in
    StringMap.empty
    |> addKeys baseRefs
    |> addKeys leftRefs
    |> addKeys rightRefs
    |> StringMap.bindings
    |> List.map fst in
  let head = {
    name = "HEAD";
    base = base.head;
    left = left.head;
    right = right.head;
    action = reconcileValue ~base:base.head ~left:left.head ~right:right.head;
  } in
  let refs =
    List.map (fun name ->
      let base = findRef baseRefs name in
      let left = findRef leftRefs name in
      let right = findRef rightRefs name in
      { name; base; left; right; action = reconcileValue ~base ~left ~right })
      names in
  head :: refs

let reconcileRepository ~base ~left ~right =
  match base, left, right with
  | Missing, Missing, Missing -> NoRepository
  | Missing, Missing, Repository _ -> InitializeLeftFromRight
  | Missing, Repository _, Missing -> InitializeRightFromLeft
  | Missing, Repository left, Repository right ->
      Reconcile (reconcileSnapshot ~base:{head = Absent; refs = []} ~left ~right)
  | Repository _, Missing, Missing ->
      RepositoryConflict "the repository disappeared from both replicas"
  | Repository _, Missing, Repository _
  | Repository _, Repository _, Missing ->
      RepositoryConflict "the repository disappeared from one replica"
  | Repository base, Repository left, Repository right ->
      Reconcile (reconcileSnapshot ~base ~left ~right)

let hasConflicts = function
  | RepositoryConflict _ -> true
  | Reconcile entries -> List.exists (fun entry -> entry.action = Conflict) entries
  | NoRepository | InitializeLeftFromRight | InitializeRightFromLeft -> false
