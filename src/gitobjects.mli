(* Safely copy the immutable Git object closure reachable from an already
   inspected durable snapshot.  This deliberately does not inspect or change
   refs, HEAD, indexes, configuration, hooks, work trees, or any network
   metadata.  It is only available through the native Windows confined-handle
   backend used by WSL workspace mode. *)

type report = {
  objects_seen : int;
  loose_objects_installed : int;
  pack_files_installed : int;
}

(* [validateSnapshot ~repository snapshot] proves, using the same confined
 * loose/pack decoder as [transfer], that every object reachable from
 * [snapshot] is already present and valid in [repository].  It performs no
 * writes and does not inspect refs beyond the ordinary repository readiness
 * check.  Ref publication uses this before exposing a direct object ID. *)
val validateSnapshot :
  repository:Fspath.t ->
  Gitstate.snapshot ->
  (int, string) result

(* [transfer ~source ~destination snapshot] makes every object reachable from
   [snapshot]'s supported refs and HEAD available in [destination]'s existing
   object database.  No ref or repository-visible state is moved. *)
val transfer :
  source:Fspath.t ->
  destination:Fspath.t ->
  Gitstate.snapshot ->
  (report, string) result
