(* Security policy helpers for the Windows-to-WSL workspace mode. *)

val enabled : bool Prefs.t

type root_kind = WindowsLocal | WslUnc | Other

val classifyRoot : string -> root_kind
val validateRoots : string list -> (unit, string) result
val isGitMetadataPath : string -> bool
val isWithin : root:string -> string -> bool
