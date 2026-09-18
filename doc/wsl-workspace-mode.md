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
handle APIs are unavailable. The primitive covers only the read-only Git
inspector; ordinary workspace scanning still uses Unison's existing
reparse-point protections and is outside this milestone.

The foundation remains limited to disposable fixtures because Git object/ref
propagation and the main transaction integration are not implemented yet. Do
not point it at the real workspace.

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
Git ref reconciler, safe read-only repository inspection, and trusted-state
archive; propagation is not wired into a synchronization run yet.

| Category | Treatment |
| --- | --- |
| Ordinary working files | Existing Unison archive/reconciliation; byte-exact |
| Git objects | Safe union/copy after a quiescence check; never blindly deleted |
| `HEAD` and durable refs | Windows-side three-way Git-state archive; conflicts fail closed |
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

Only after those pass should clean real replicas be established from a chosen
source of truth and synchronized for the first time.
