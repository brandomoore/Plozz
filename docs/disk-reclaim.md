# Disk reclaim safety

`tools/reclaim-disk.sh` removes selected rebuildable Apple build caches across
Plozz, Mozz, and Twozz. `tools/prune-deriveddata.sh` is its DerivedData-only
worker. Neither tool may run destructively while release/build ownership is
uncertain.

## Current rollout status: destructive cleanup disabled

Two existing activation gates must remain closed until every owner listed below is
ported or administratively disabled:

1. `~/.config/smart-disk-maintenance/SUSPENDED` must be absent.
2. The exact rollout policy must exist at
   `~/.config/smart-disk-maintenance/apple-build-interlock-v1/rollout-policy-v1`.

The machine currently uses `SUSPENDED`. This repository does not remove it,
create the rollout policy, enable a scheduler, or authorize cleanup.

The legacy rollout file is intentionally all-or-nothing:

```text
protocol=1
global-cleanup-entrypoints
manual-xcode-writers-disabled-or-wrapped
mozz-current-writers
mozz-legacy-writers
plozz-current-writers
plozz-legacy-writers
twozz-current-writers
twozz-legacy-writers
```

Each line means the named owner has confirmed every relevant writer uses this
protocol before its first build-resource write, or cannot run during cleanup.
Listing an owner without completing that work is not authorization. Missing,
reordered, extra, unreadable, replaced, symlinked, or writable-by-other policy
data denies cleanup. There is no environment or command-line bypass.

Only `plozz-current-writers` is implemented by this change. Remaining blockers:

- older Plozz worktrees containing pre-interlock scripts;
- current and older Mozz writer entrypoints;
- current and older Twozz writer entrypoints;
- current and older Hozz writer entrypoints;
- direct/manual Xcode, raw `xcodebuild`, and third-party build tools;
- installed global cleanup entrypoints and reviewed owner evidence.

The exact legacy file cannot express Hozz or time-bounded owner holds. Its wire
format remains frozen for existing readers. **It is not sufficient authorization
for global cleanup.** The separate [attested maintenance-window policy](apple-maintenance-windows.md)
adds Hozz, current/legacy inventories, exact release-manifest scope, and explicit
human approval. Its updater writes only the companion file under the conflicting
policy lock; it never enables the legacy gate or removes suspension.

Until those owners are coordinated, keep `SUSPENDED`, keep broad schedules
disabled, and do not create the rollout file. The interlock alone is not a claim
that cross-app cleanup is ready.

## Shared/exclusive protocol

The same-user host-wide namespace is:

```text
~/.config/smart-disk-maintenance/apple-build-interlock-v1/
```

The path is physically resolved from the effective UID's account record, not
caller `HOME`, so alternate environments or a symlinked home cannot create a
second production lock domain or weaken protected-path comparisons.
It is outside DerivedData, SwiftPM caches, worktrees, and every reclaim target.
The protocol uses Darwin `flock` through the system Python standard library:

- build, test, generation, localization, archive, upload, processing,
  distribution, and tagging lanes hold a shared lease;
- several shared leases may coexist;
- cleanup requests an exclusive lease with `LOCK_NB` and refuses immediately
  when any shared lease is active;
- once exclusive ownership exists, a new cooperative build cannot start until
  cleanup releases it.

Shell and Fastlane callers retain the actual locked file descriptor and export
its authenticated descriptor identity to descendants. Descendants inherit the
same open file description, so a parent exit cannot release the kernel lock
while a child still owns that descriptor. Nested entrypoints validate an
unlinked proof descriptor plus exact lease id/token, record schema, lock inode,
owner, and mode. Partial, forged, closed, replaced, or stale inherited state
fails; it never falls back to a new lease.

Every lease also publishes a durable JSON identity under `leases/`. Normal
completion authenticates a release request, then a background finalizer waits
for all inherited shared descriptors to close before removing that record.
Signals, hard crashes, failed lanes, helper errors, malformed records, unknown
files, or finalizer failure leave evidence behind. Exclusive cleanup refuses
every remaining record and never infers safety from PID age, an empty process
list, or a quiet machine.

Inspect records without changing them:

```bash
/usr/bin/python3 tools/lib/apple_build_lease.py inspect
```

There is deliberately no automatic stale-record deletion. Investigate the
record and its owner while cleanup remains suspended before resolving any exact
fixture or production record.

## Plozz writer coverage

Current Plozz entrypoints acquire a shared lease before their first relevant
write:

- Fastlane `generate_project`, `build`, `beta`, and `release`; outer
  `beta`/`release` ownership spans both platform archives, uploads, processing,
  external distribution, and GitHub tagging;
- `tools/generate-project.sh`;
- `tools/deploy-tv.sh` and `tools/deploy-ios.sh`;
- `tools/run-tests.sh` and `tools/test-fast.sh`;
- `tools/l10n-sync.py`, `tools/l10n-guard.sh`, and
  `tools/l10n-prune-stale-products.sh`;
- `tools/capture-shots.sh`;
- the direct CI simulator build through
  `tools/with-apple-build-lease.sh`.

The lease is independent of output naming and location. Worktree `.build`
folders, per-worktree test/localization roots, and multiple Xcode DerivedData
folders remain distinct real outputs; the lease does not merge, rename, or
reinterpret them.

Swift package resolution follows a separate storage policy:

- the committed root `Package.resolved` is copied into the generated Xcode
  workspace by `tools/generate-project.sh`;
- every Xcode writer passes
  `-onlyUsePackageVersionsFromResolvedFile` and `-skipPackageUpdates`;
- the compressed SwiftPM repository/artifact cache remains shared through
  `~/Library/Caches/org.swift.swiftpm`;
- mutable checkouts and extracted binary artifacts use writer-specific paths
  under `.build`, while sequential work inside one writer (both localization
  platforms, both release archives, and CI build plus tests) reuses that
  writer's path.

Do not replace those writer-specific paths with one machine-wide mutable
`SourcePackages` directory. Concurrent Xcode writers can corrupt or invalidate
shared mutable package state. These settings prevent future redundant stores;
they do not authorize deleting any existing DerivedData or `.build` root.

## Defense in depth

After cleanup acquires exclusive ownership, the previous checks still run:

- a continuous Apple-build quiet interval;
- process checks before each destructive phase and path;
- `lsof` open-path inspection when enabled;
- recent-mtime skips;
- absolute/resolved cache-container and deletion-target validation;
- hard refusal for the shared SwiftPM repository cache.

These checks catch uncooperative or unexpected activity, but they do not replace
the cooperative lease. Process sampling alone has a start-after-check race.

The policy lock is held shared for the whole cleanup lane. Tooling that
changes `SUSPENDED` or rollout policy must take the conflicting exclusive policy
lock. Per-delete verification also confirms the marker is still absent and the
opened policy/coordination files retain the same inode and content. Manual file
changes that ignore this protocol remain a rollout blocker.

Protected source, Git data, worktrees, archives, IPAs, release dSYMs/evidence,
SDKs/toolchains, shared SwiftPM dependencies, simulator data, VMs, personal
data, and Trash are not made eligible by this lease. Target selection and
release-retention policy remain separate mandatory checks.

`--dry-run` does not acquire exclusive ownership and deletes nothing.

## Regression tests

No app build or real cleanup is required:

```bash
tools/tests/test-apple-build-interlock.sh
tools/tests/test-disk-reclaim.sh
```

Tests use temporary HOME/cache roots only. They cover concurrent readers,
nonblocking exclusive refusal, writer-to-reader handoff, release-lane gaps,
nested and exec inheritance, Ruby-to-child descriptor inheritance, children
outliving parents, written identity, effective-UID and physical-home resolution,
forged environments, signal/crash orphan evidence, malformed registry state,
lock replacement, suspension/rollout gates, process checks, open paths, unsafe
targets, test-root confinement, and fixture-only cleanup. Test mode requires its
lock namespace and every destructive target to remain under the same private
system-temporary HOME, and disables cleanup extras.

## Scheduling

Broad daily cleanup workflows and the optional LaunchAgent must remain disabled
while `SUSPENDED` or rollout blockers exist. Enabling multiple schedulers adds
no safety; every installed/manual scheduler must call the same exclusive-lease
entrypoint after rollout approval.
