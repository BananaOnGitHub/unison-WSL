(* Read-only inspection of the durable, safe-to-share subset of a normal
   .git directory.  No Git executable or repository configuration is used. *)

type inspection =
  | Missing
  | Ready of Gitstate.snapshot
  | Busy of string
  | Unsupported of string

(* Exported for testing and policy checks. *)
val isObjectId : string -> bool
(* A syntactically valid ordinary Git ref name.  The reconciled subset below
 * is stricter, but packed-ref mutation uses this to retain unrelated valid
 * entries without granting them reconciliation semantics. *)
val isValidRefName : string -> bool
val isSupportedRefName : string -> bool
val parseRefValue : string -> string option
val parsePackedRefs : string -> (string * string) list
(* Operates only on a directory handle already obtained by the caller. *)
val isBusy : Fs.confined_handle -> string option
val inspect : Fspath.t -> inspection
