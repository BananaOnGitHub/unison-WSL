(* Reconciliation rules for the durable part of a Git repository.

   This module deliberately models refs and HEAD as values.  It does not run
   Git or consult repository-local configuration: callers discover and copy
   the safe on-disk subset separately. *)

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

val reconcileValue : base:value -> left:value -> right:value -> action
val reconcileSnapshot : base:snapshot -> left:snapshot -> right:snapshot -> entry list
val reconcileRepository :
  base:repository -> left:repository -> right:repository -> repository_plan
val hasConflicts : repository_plan -> bool
