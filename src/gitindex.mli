(* Rebuild a replica-local Git index without loading that repository's config,
   hooks, filters, or work tree. [gitExe] must name a trusted Windows Git
   executable outside both replicas. *)

val rebuild :
  gitExe:string ->
  helperDirectory:Fspath.t ->
  objectDirectory:Fspath.t ->
  indexPath:Fspath.t ->
  commit:string ->
  (unit, string) result
