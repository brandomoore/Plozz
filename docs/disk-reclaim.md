# Plozz build-data lifecycle

## Prevent orphaned output instead of periodically purging everything

Generated projects use Xcode's **user workspace settings**
`DerivedDataLocationStyle=WorkspaceRelativePath` and
`DerivedDataCustomLocation=.build/xcode-gui`. These belong in
`Plozz.xcodeproj/project.xcworkspace/xcuserdata/<user>.xcuserdatad/WorkspaceSettings.xcsettings`,
not `xcshareddata`: Xcode ignores the latter for this user preference.
`tools/generate-project.sh` writes them on full generation **and bake-only**
runs, preserving other settings. The relative location follows a renamed or
moved checkout. Native Xcode previews, indexing, GUI builds and their
SourcePackages stay inside that checkout. Open the generated project, not a
separately created workspace with different settings.

The key/value semantics also appear in
[Geko's native workspace-settings model](https://github.com/geko-tech/geko/blob/6e0ed4650a8bc02db5afdb987c6629ab8c118e7b/Sources/GekoSupport/Models/XCWorkspaceSettingsPlist.swift).
The fixture suite additionally runs **real `xcodebuild -showBuildSettings`**
against a dependency-free generated project and checks the resulting build path;
it does not compile the app or download packages.

| Writer | Disposable intermediates |
| --- | --- |
| Xcode GUI, previews and indexing | `.build/xcode-gui/` |
| TV / iOS device wrappers | `.build/deploy-tv-derived-data/`, `.build/deploy-ios-derived-data/` |
| Package / hosted focus / provider tests | Existing writer-private `.build/*derived-data/` roots |
| Localization | `.build/l10n-deriveddata/` |
| Screenshot / physical UI-test runners | Existing worktree-local `build/*-dd/` or `build/*-derived/` |
| Fastlane | `.build/fastlane-derived-data/<invocation>/<scheme>/` |
| Mutable package checkouts and binary extraction | Writer-private `.build/package-workspaces/` or the test writer's DerivedData |
| CI | Existing lane-private `.build/ci/<lane>/` |

The central package helper registers package and DerivedData paths **after**
the shared lease is acquired. Python and Ruby writers call the same registrar.
Device settings lookup and build receive identical explicit DerivedData paths;
they no longer default to the GUI/global store. Fastlane resolution, settings
and archive retain invocation/platform-private package options, and use a
matching private DerivedData path. Do not run concurrent copies of a fixed-path
writer in the same checkout; separate worktrees/writers have separate stores.
Explicit storage overrides remain supported but are recorded as external;
they do not get the containment benefit.

The shared compressed SwiftPM cache is unchanged and never targeted. This is
not permission to remove checkouts with edits, reset dependencies, or clear
shared caches.

## Release products are not disposable

New Fastlane archives, exported IPAs and dSYMs go to
`~/Library/Developer/Plozz/Releases/<physical-checkout-path-sha256-prefix>/`
instead of the worktree's `build/`. Upload/processing results and per-platform
logs live in its `testflight-uploads/` subdirectory. Both platform archives,
symbol upload, IPA validation and distribution use these same absolute paths.
They retain their existing filenames. This intentionally changes their
**default output location**, not the upload/distribution behavior.

This durable root is registered with a permanent release-evidence hold and
survives checkout removal. There is no automatic deletion or hold-release
command for it. Existing archives/evidence in old worktrees are **not migrated**
by this feature: preserve those before explicitly archiving such a worktree.
The cleanup adapter refuses archives, IPAs, dSYMs (including compressed ones),
xcresults, logs, credentials, sources and Git data even if nominated.

## Automatic reconciliation, without pretending there is an archive callback

There is no supported Copilot archive hook used here. An explicit archive that
actually removes its worktree carries contained output away with it through
the app's normal removal operation. Merely hiding/archiving a session while
retaining its checkout does **not** make that checkout disposable.

Every registration reconciles prior resources; project generation also
attributes existing `Plozz-*` global DerivedData whose `info.plist` points to
that exact current project. This is a bounded metadata/registry pass, **not a
recursive disk scan**, package validation or deletion during a build.
Contained records disappear from the registry once their owner and resource
are physically gone and the Git registration is gone; only an aggregate count
is retained. External records remain reviewable.

The private state is
`~/Library/Application Support/Plozz/BuildLifecycle/registry.json`.
It records schema, epoch, exact resource and parent device/inode/path, kind,
creation/observation times, release hold, all registered references and each
owner's worktree, parent, common Git directory, registration directory and HEAD.
Publication is locked, nofollow, mode 0600, atomic and fsynced. Bounds are 1,024
resources, 128 owners per resource and 4 MiB total; exceeding them stops with an
error rather than silently discarding provenance. Successful repeat builds
update an existing entry instead of accumulating per-command history.

Retirement requires physical checkout absence **and** absence from
`git worktree list --porcelain -z`, removal of its original registration, and
unchanged physical common-directory and checkout-parent identities. A move,
restored path, primary checkout, prunable registration, inaccessible mount,
changed parent, shared living reference or malformed state remains protected.
Pruning Git alone is not evidence of a user archive: these observations create
a **candidate**, not deletion permission. There must then be seven days of
continuously observed retirement before an external candidate can be proposed.
A return or uncertain observation resets that interval.

Normal completed builds need no per-file owner attestation. Their durable
ownership is reused; failed/crashed/queued lanes still retain the existing
v1 lease holds. Missing PID, old mtime or a quiet process list never clears them.

## Read-only inspection and exact cleanup

```bash
python3 -B tools/plozz-build-lifecycle.py status
python3 -B tools/plozz-build-lifecycle.py legacy

# Metadata reconciliation only; no deletion, even under an approved window.
tools/with-apple-build-lease.sh plozz/lifecycle -- \
  python3 -B tools/plozz-build-lifecycle.py reconcile

# A deliberately narrow unit below a registered, retired external DerivedData root.
# Without --output the default is JSON on stdout.
python3 -B tools/plozz-build-lifecycle.py propose \
  --target /physical/retired-derived-data/Build/Intermediates.noindex/objects \
  --output /private/review/manifest.json

python3 -B tools/apple-build-cleanup.py validate --manifest /private/review/manifest.json
```

Legacy missing owners without historical registration are shown as
**unattributed/protected**, never retroactively declared released. A path in an
old `info.plist` alone cannot establish shared references or needed evidence.
Previously unregistered nonempty external overrides are refused unless their
native DerivedData attribution can be verified. Dependency workspaces,
including uncommitted package edits, remain ineligible for external cleanup.
Containment is what retires their large private copies with the worktree.

The exact-manifest adapter is recovered from the reviewed cleanup lineage
ending at `3a133ffa85ff8f84259127c050f4156bc838034a`, not replaced by a second
destructive implementation. It only accepts recognized compiler outputs,
at least **seven days untouched across the whole tree** (birth/ctime/mtime),
bounded to 256 disjoint units and 4,096 total entries per approved manifest.
It rejects source/Git/dependency trees, protected bundles, hardlinks, symlinks,
unknown files, nested mounts, open inodes and changed identities. Manifests pin
registry bytes/epoch and inode-aware trees. Parent/leaf/owner/policy checks
repeat before each unlink. Interrupted work retains a fsynced partial journal;
there is no automatic resumption or overwrite of a previous journal.

For the adapter's new `retired-generated` target kind, the compatibility field
`session_id` carries the resource epoch UUID, **not** a Copilot session identity.
`release_record` pins the lifecycle registry; neither is a human attestation or
a substitute for the separate exact-scope maintenance approval.

**External automatic deletion is not enabled by this feature.** Production
`SUSPENDED`, installed tools and schedules are untouched. The unchanged
[v1 lease and attested maintenance-window contract](apple-maintenance-windows.md)
remains mandatory. Only after separately approved activation, with a complete
current writer inventory and exact approved manifest, may a maintenance owner run:

```bash
tools/with-apple-build-lease.sh --exclusive plozz/approved-maintenance -- \
  python3 -B tools/apple-build-cleanup.py apply \
  --manifest /private/review/manifest.json \
  --window-id APPROVED-WINDOW-UUID --journal /private/review/unique-journal.jsonl
```

Never call this exclusive operation inside a build's shared lease. The registry
is not an alternate approval, suspension bypass or stale-lease resolver.
Retired resources use their historical owner's common Git repository for
approved writer coverage; that repository and this entire executing bundle
must be fingerprinted. Any new registration invalidates a pinned preview.

Legacy `reclaim-disk.sh` and `prune-deriveddata.sh` no longer contain broad
deletion logic. Their sole `--dry-run` operation reports attribution; all
former apply modes fail before taking a lease or writing logs.

## Fixture validation

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  tools.tests.test_plozz_build_lifecycle tools.tests.test_apple_build_cleanup \
  tools.tests.test_apple_maintenance_policy tools.tests.test_package_storage
tools/tests/test-apple-build-interlock.sh
```

Fixtures use private temporary HOME/repos and separate lock namespaces, synthetic
approval evidence and tiny compiler files, never production cleanup or app
builds. Frozen-protocol tests cover competing writers/exclusive cleanup,
full-lane gaps, nested inheritance, crash holds and stale/forged capabilities.
Adapter tests cover nofollow TOCTOU, changed parents/trees, deadlines, open use,
partial recovery and exact real companion authorization. Lifecycle tests cover
real Git worktree removal, rename/restore/shared ownership, containment,
retention, bounded state, source/package/evidence protection and native Xcode
output-location semantics.
