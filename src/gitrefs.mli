(* Apply one side of an already-reconciled [Gitstate] plan to an existing
   repository.  This module deliberately does not reconcile, transfer objects,
   rebuild an index, touch a work tree, invoke Git, or create a repository. *)

type target = Left | Right

type report = {
  refs_changed : int;
  head_changed : bool;
  packed_refs_rewritten : bool;
}

(* [apply ~repository ~target entries] applies only entries whose existing
   [Gitstate.action] copies a value to [target].  Each affected logical value
   is checked against the expected pre-state, desired direct object closures
   are validated through [Gitobjects], and each physical mutation is a
   confined Windows compare-and-swap. *)
val apply :
  repository:Fspath.t ->
  target:target ->
  Gitstate.entry list ->
  (report, string) result
