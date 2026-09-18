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

### Remaining containment work

Rejecting reparse points during update detection closes the known static WSL
symlink traversal path. A hostile process can still attempt a time-of-check to
time-of-use swap between inspection and a later file open. Before this mode is
approved for the real autonomous-agent workspace, Windows file opens need
handle-based confinement (or an equivalently strong mechanism), followed by a
native race test. Until then, use disposable fixtures only.

## Git policy

`.git` is replica-local state. Indices, reflogs, lockfiles, `ORIG_HEAD`, object
databases, hooks, and local configuration never cross the boundary.

The working tree is not normalized by Unison. In particular, Unison will not
pretend LF and CRLF byte sequences are equal. Doing so would make the archive
describe something other than the bytes on disk and would weaken later change
and conflict detection. The mode also does not invoke Git to compare files;
Git attributes and filters can lead to configured external commands.

Each Git repository therefore needs an independent `.git` directory on both
sides and a checkout policy that materializes the same bytes. For a repository
that should use LF on both platforms, set the Windows repository's local
configuration (not the user's global configuration):

```powershell
git -C C:\path\to\repo config --local core.autocrlf false
git -C C:\path\to\repo config --local core.eol lf
```

A committed `.gitattributes` policy is preferable when the project owns one.
Neither choice changes arbitrary non-Git files.

If a repository is cloned or initialized on only one replica, its ordinary
working files can synchronize, but its ignored `.git` directory cannot. The
other replica remains a plain directory until it is independently cloned or
initialized. Automatic repository creation and parity reporting are deferred
until they can be implemented without executing workspace-controlled Git
configuration.

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

Only after those pass should clean real replicas be established from a chosen
source of truth and synchronized for the first time.
