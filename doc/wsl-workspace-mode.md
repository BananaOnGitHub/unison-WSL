# Windows-to-WSL workspace mode

This fork is developing a narrowly scoped mode for synchronizing a Windows
workspace with a workspace exposed by WSL over `\\wsl.localhost`. The Unison
process runs entirely on Windows. Nothing is installed or run inside WSL, and
the mode does not require Windows-drive mounts or WSL executable interop.

> **Development status:** the foundation mode is intentionally fail-closed,
> but it has not yet completed native Windows/WSL race and integration testing.
> Do not point it at the real workspace until those tests and a deliberate
> baseline procedure are complete.

## Invocation

Use one absolute drive-letter path and one `\\wsl.localhost` path:

```powershell
unison `
  'C:\Users\USER\unison-wsl-test' `
  '\\wsl.localhost\Ubuntu-26.04\home\bananas\unison-wsl-test' `
  -wslworkspace `
  -repeat 5 `
  -batch
```

`repeat` may be omitted or set to a numeric polling interval. `repeat=watch`
and `repeat=watch+N` are rejected because Windows filesystem notifications do
not cover the WSL Plan 9 share reliably.

`wslworkspace` is command-line-only. This lets Unison establish the trusted
Windows configuration-directory guard before it opens the default profile or
any included preference file.

The mode rejects SSH/socket roots, relative roots, `\\wsl$`, drive roots,
parent traversal, and configurations that do not contain exactly one local
Windows path plus one `\\wsl.localhost\DISTRO\...` path.

## Security invariants

When enabled, the mode:

- requires a native Windows build and two locally accessed roots;
- requires every loaded profile/include and the archive directory to remain
  in the Windows-side Unison configuration directory, outside both replicas;
- disables symbolic-link synchronization and rejects `follow` rules;
- rejects Windows reparse points encountered during a workspace scan;
- recognizes WSL's `IO_REPARSE_TAG_LX_SYMLINK` instead of following it as an
  ordinary file;
- disables permission propagation and inode-number fast paths across the WSL
  UNC boundary;
- enforces case-insensitive reconciliation so Linux case collisions are
  reported before they can be represented on the Windows replica;
- relies on Unison's existing Windows-filename checks to report names that
  cannot be represented on Windows;
- rejects automatic merge commands, leaving conflicts explicit; and
- treats every `.git` path as a hard ignore that `ignorenot` cannot override.

The ordinary Unison archive, update detector, reconciler, transactional copy,
and deletion-vs-modification behavior remain unchanged. Regular files are
still compared and transferred byte-for-byte.

### Git metadata confinement

The read-only Git inspection layer no longer performs a path-based
`lstat`-then-open sequence. On native Windows it opens the configured worktree
with `NtCreateFile`, then opens `.git` and every Git metadata descendant
relative to the already-opened parent directory handle. Each open uses
`OBJ_DONT_REPARSE` and `FILE_OPEN_REPARSE_POINT`; the object actually opened is
checked through that handle before it is consumed. If it is any reparse point,
the implementation obtains its tag and rejects it—there is no allow-list for
Windows symlinks, junctions, WSL `IO_REPARSE_TAG_LX_SYMLINK`, or unknown tags.
`HEAD`, `packed-refs`, busy-state probes, directory enumeration, and loose-ref
contents are all read from those already-open handles. A WSL process that
replaces a checked name can therefore only leave the reader on the object it
already opened or make a later open fail; it cannot redirect a metadata read
outside the confined root.

Supported ref names remain validated strictly against Git's
`git-check-ref-format` rules (rejecting `..`, `@{`, control characters, spaces,
wildcards `*`/`?`/`[`, backslashes, colons, carets, tildes, component `.lock`
suffixes, and empty components). Gitfiles and linked worktrees remain rejected
without reading their indirection target. Repository busy states (`MERGE_HEAD`,
`BISECT_HEAD`, `*.lock`, rebase/sequencer directories) are also inspected
through confined handles and block Git handling fail-closed.

This closes the documented Git-metadata pathname TOCTOU escape. It does not
make a concurrent repository snapshot transactional: an already-open regular
file can still be edited in place, and a directory may change while it is being
enumerated. The reader rejects truncation or growth observed during a bounded
file read, but same-length in-place rewrites and cross-file snapshot skew are
reported only through the existing busy/conflict logic when that Git transaction
layer is integrated. Native Windows builds also fail closed if the required NT
handle APIs are unavailable. Ordinary workspace scanning still uses Unison's
existing reparse-point protections and is outside this work.

### Git object transfer

The current branch can now make the immutable object closure reachable from an
already-inspected `Gitstate.snapshot` available in the other existing
repository. This is a standalone library operation only: it does **not** write
`HEAD`, refs, `packed-refs`, indexes, working trees, repository configuration,
or Unison archives, and it is not yet called by a normal synchronization run.

The walker starts only from the snapshot's detached `HEAD` object and supported
durable refs (following validated symbolic refs inside that snapshot). It
validates every object identifier before deriving its two-component
`objects/xx/yyyy…` name, expands commits, trees, annotated tags, and parents,
and transfers blobs exactly as Git object data. Tree gitlinks (`160000`) are
rejected, so submodules remain unsupported. No `.git` directory is copied as a
filesystem subtree.

Loose objects are read from a confined handle, zlib-checked, bounded, parsed as
a canonical Git object, and hashed as SHA-1 or SHA-256 before they are usable.
For standard packed repositories, the implementation supports version-2
`.idx` files and matching `.pack` files. It validates pack/index/filename
checksums, every indexed object boundary and object hash, and OFS/REF delta
chains before publishing a pack pair. The supported transfer limits are 64 MiB
per compressed loose object, 128 MiB after expansion/per packed object, 512
MiB per pack, and one million packed or reachable objects; exceeding a limit
fails closed. Legacy v1 indexes, multi-pack indexes, promisor/partial-clone
state, and object alternates are unsupported. In particular,
`objects/info/alternates` is rejected rather than followed.

Destination publication is also handle-relative. The Windows backend creates a
new temporary regular file beneath the already-confined object directory with
`NtCreateFile`, writes and flushes it, then uses an `NtSetInformationFile`
relative no-replace rename to publish it. The temporary name cannot cause a
write through a reparse point; an existing destination name—including a raced
reparse point—causes a collision and is reopened/validated through a confined
handle. Existing loose objects are accepted only when their canonical content
matches the requested object ID; existing pack and index files are never
overwritten and must be byte-for-byte identical. Failed staging attempts delete
the temporary handle. A pack is published before its index, so an interruption
can leave an unindexed but checksum-validated immutable pack; it does not move
any repository-visible ref and no temporary control artifact is left behind.

This is still not a transaction boundary. A hostile replica can race ordinary
in-place writes while a snapshot is being collected, or replace a valid object
after this library releases its handle. Hash and checksum verification catches
changed content during this operation, and all path/reparse replacement races
on reads and writes fail closed, but cross-object snapshot consistency and
full multi-file transaction integration remain deferred.

### Durable ref and HEAD mutation

The branch now has a separate, standalone `Gitrefs.apply` operation that
applies one direction of an already-reconciled `Gitstate` entry list to an
**existing** repository. It does not perform reconciliation itself, and it is
still not called from a normal Unison run. Its ordering is intentionally:

1. inspect the repository and verify every selected plan entry has the exact
   expected logical value;
2. validate the complete desired object closure in the destination with the
   same confined loose/pack decoder used for object transfer;
3. open `.git` and each changed ref directory with a short Windows mutation
   lease, then reject any busy Git state seen through those retained handles;
4. compare the exact current `HEAD`, loose-ref, or `packed-refs` bytes through
   a no-reparse file handle and publish only when that comparison still holds.

The Windows primitive creates the ordinary sibling `name.lock` under the
already-confined parent, flushes it, and publishes it with a handle-relative
`NtSetInformationFile` rename. For an expected-present file, the current file
is opened with no-follow semantics, byte-range locked before comparison, and
kept protected from new write opens through publication. The retained mutation
directory denies other writers the directory operations needed to create a Git
lock, rename, or replace a child. Expected-absent creation instead uses a
no-replace final rename, so a racing creator produces a mismatch rather than
being overwritten. Deletes first byte-check the already-open ref and then
delete that handle; temporary lock files are deleted on all ordinary failure
paths. Every handle is validated as an ordinary file or directory and every
reparse tag is rejected.

Only supported direct durable refs are mutated. `HEAD` may be either a direct
object ID or `ref: refs/...`; symbolic non-HEAD refs, gitfiles, linked
worktrees, and deletion of `HEAD` remain unsupported. Before publishing a
direct object ID, `Gitobjects.validateSnapshot` verifies its complete
commit/tree/blob/tag closure (including packed and delta decoding) in the
destination object store. Existence of an `objects/...` filename alone is not
accepted as proof. This proves the closure immediately before metadata
publication; the standalone layer deliberately does not hold an object-store
transaction or pin object files after validation. Thus an adversarial actor
can still make a subsequently referenced object unusable by changing it after
validation, but cannot turn the operation into a path escape, arbitrary read,
or write outside the confined repository.

Packed refs are parsed strictly before a rewrite. Valid but non-reconciled
entries, such as a remote-tracking ref, are preserved verbatim. Unknown header
flags, malformed direct or peeled lines, duplicate refs, mixed SHA formats,
and unrepresentable data fail closed. Updating a packed ref normally creates a
loose shadow, which is Git's normal storage behavior and preserves the packed
file. Deleting a ref that is packed first rewrites (or, if empty, removes)
`packed-refs` through the same compare-and-swap primitive, then deletes any
loose shadow. This order prevents an obsolete packed value from being revealed
by the loose deletion.

This operation deliberately makes no all-or-nothing claim across several
refs, `packed-refs`, and `HEAD`. Each individual file mutation is a confined
compare-and-swap: concurrent changes fail rather than being silently
overwritten. A failure after an earlier successful mutation can leave a prefix
of the reconciled durable state applied; for packed deletion, the packed entry
may be removed while a still-present loose shadow preserves the old logical
value. Later main-transaction integration must provide the broader recovery
and user-visible transaction policy. Reflogs, indexes, hooks, config,
operation scratch, and working-tree checkout remain untouched.

The Windows lease blocks normal new Git/file-system write opens while it is
held, and the byte-range lock protects the checked ref file. It cannot revoke
an arbitrary actor's already-open directory or file handle. Such a handle is
outside the standard Git lock protocol and is an unavoidable residual of a
standalone Windows filesystem primitive; later transaction integration still
needs a quiescence and recovery policy for that hostile-concurrency case.

The branch remains limited to disposable fixtures until this library is wired
into the later Git/ref transaction. Do not point it at the real workspace.

## Git policy

Git repositories are one logical repository across the two workspace replicas.
The mode will reconcile Git's durable shared state separately from the ordinary
filesystem tree; it will not turn `.git` into an ordinary Unison subtree.

The durable shared set is Git object data, `HEAD`, and supported refs. Objects
are content-addressed and can be copied by union. `HEAD` and every ref use a
separate Windows-side, three-way Git-state archive: a change on only one side
propagates; two different changes, including deletion-versus-modification,
are reported as a Git conflict and neither side wins. Repository creation on
one side initializes the other from this durable set. Packed refs are handled
as refs, not copied as an opaque file.

Indexes, reflogs, locks, operation state, hooks, and local configuration are
platform-local. An active rebase, merge, cherry-pick, lockfile, or comparable
operation blocks synchronization of that repository's working tree and Git
state until it becomes quiescent. The synchronizer does not create conflict
branches, refs, or project-visible bookkeeping files.

After a shared `HEAD` move, the destination index must be rebuilt or Git will
falsely report a clean working tree as staged/unstaged changes. That rebuild
uses a trusted Windows Git executable configured outside the workspace. It is
run against an isolated helper Git directory under the Windows-side state
directory, with the replica's synchronized object store supplied only as an
alternate object database. It does not load the workspace repository's config,
hooks, filters, attributes, or work tree.

The current foundation still hard-ignores `.git` while this Git transaction
layer is being wired into the Windows-only runtime. It is therefore not yet a
Git-capable release and remains limited to disposable fixtures.

The working tree is not normalized by Unison. In particular, Unison will not
pretend LF and CRLF byte sequences are equal. Doing so would make the archive
describe something other than the bytes on disk and would weaken later change
and conflict detection. The Git reconciler also does not execute Git or consult
workspace-controlled Git configuration; attributes and filters can invoke
external commands.

For a repository that should use LF on both platforms, set the Windows
repository's local checkout policy (not the user's global configuration):

```powershell
git -C C:\path\to\repo config --local core.autocrlf false
git -C C:\path\to\repo config --local core.eol lf
```

A committed `.gitattributes` policy is preferable when the project owns one.
Neither choice changes arbitrary non-Git files.

Git state, synchronizer archives, logs, and conflict records remain in the
trusted Windows-side state directory outside both workspaces. Nothing under
either workspace is used as synchronizer control state.

This is the target transaction boundary. The branch currently contains the
Git ref reconciler, safe read-only repository inspection, handle-confined
immutable-object transfer/validation, standalone confined ref/HEAD mutation,
and the trusted-state archive; none is wired into a synchronization run yet.

| Category | Treatment |
| --- | --- |
| Ordinary working files | Existing Unison archive/reconciliation; byte-exact |
| Git objects | Validated immutable closure union; standalone validation/transfer only |
| `HEAD` and durable refs | Windows-side three-way Git-state archive; standalone confined CAS mutation; not yet in a Unison transaction |
| Index, reflogs, hooks, config, locks, operation scratch | Replica-local; never propagated as shared state |
| Synchronizer state and diagnostics | Trusted Windows-side state directory only |

For the dedicated deployment, set `UNISON` to a Windows-only location such as
`$env:LOCALAPPDATA\Unison-WSL`. The mode rejects it if it resolves inside a
replica or through a reparse point.

## Validation plan

Native Windows/WSL tests must use disposable roots and cover at least:

1. initial sync and independent creates in both directions;
2. same-file edits and deletion-vs-modification conflicts;
3. `.git` non-propagation during commits, resets, restores, and lockfiles;
4. LF/CRLF changes remaining byte-exact and visible;
5. Linux-invalid-on-Windows names and case-only collisions/renames;
6. Linux symlinks to inside and outside the designated root;
7. Windows symlinks, junctions, and other reparse points;
8. executable and permission-bit changes;
9. polling while Git and an editor perform atomic replacements; and
10. archive/configuration placement outside both replicas.

The current native self-test also constructs disposable Git metadata fixtures
and verifies that a handle opened for `HEAD`, `packed-refs`, or a loose ref
continues to read that original object after its pathname is atomically
replaced. It separately replaces a retained `refs` directory name with a
reparse point before a child open, and verifies that the child is still opened
through the retained handle. Reparse-point versions of `HEAD`, `packed-refs`,
and `refs` must all make inspection fail closed. The PowerShell fixture script
runs that self-test across a disposable Windows root and a disposable
`\\wsl.localhost\Ubuntu-26.04` root, in addition to its workspace smoke tests.
It also transfers a fixed loose commit/tree/blob closure, a verified v2 packed
commit graph, and a SHA-256 loose object without invoking Git. Focused fixtures
cover already-present objects, malformed/truncated loose data, alternates,
invalid object identifiers, retained-source-handle replacement, destination
directory/final-name reparse races, and temporary-file cleanup. The ref tests
then compose inspection, existing `Gitstate` reconciliation, object transfer,
and standalone ref/HEAD mutation; they cover creation, update, deletion,
detached/symbolic `HEAD`, loose shadows, packed deletion, stale-plan and
expected-absent races, busy repositories, malformed packed refs, invalid
object closures, reparse targets, and lock cleanup. The index and work tree
are checked to remain unchanged.

Only after those pass should clean real replicas be established from a chosen
source of truth and synchronized for the first time.
