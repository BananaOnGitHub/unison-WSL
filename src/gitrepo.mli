(* Read-only inspection of the durable, safe-to-share subset of a normal
   .git directory.  No Git executable or repository configuration is used. *)

type inspection =
  | Missing
  | Ready of Gitstate.snapshot
  | Busy of string
  | Unsupported of string

val parseRefValue : string -> string option
val parsePackedRefs : string -> (string * string) list
val inspect : Fspath.t -> inspection
