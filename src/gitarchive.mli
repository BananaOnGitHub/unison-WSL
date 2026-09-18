(* Trusted Windows-side persistence for Git reconciliation baselines.  Callers
   supply a directory outside both replicas. *)

type state = (string * Gitstate.snapshot) list

val keyForRoots : string list -> string
val load : directory:Fspath.t -> key:string -> state
val save : directory:Fspath.t -> key:string -> state -> unit
