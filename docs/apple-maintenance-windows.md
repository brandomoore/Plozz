# Attested Apple maintenance windows

This policy tooling is not authorization to reclaim storage. It does not
remove `SUSPENDED`, write `rollout-policy-v1`, resolve lease records, change
schedules, stop writers, or delete build resources. A feature merge does not
enable global cleanup.

[Plozz build-data lifecycle](disk-reclaim.md) owns worktree containment,
registration/reconciliation and the exact-manifest adapter. Its minimum age is
seven days. It does not change this v1 lease or activate a maintenance window.

## Compatibility and rollout

Build clients use the unchanged v1 namespace and lease protocol from commit
`b1d24c0def3e980a9487d9042420a149298db867`. Vendor these four paths byte-for-byte,
preserving relative layout:

| File | SHA-256 |
| --- | --- |
| `tools/lib/apple_build_lease.py` | `56a54b71f9a642ddd5e10a51128bc59610cbe6e3f9600cc7f6799c3b196bdca2` |
| `tools/lib/apple-build-lease.sh` | `bcb0a687d32ffa740953a687c812515d2516bd0ba90ea824c01c21fc6303c705` |
| `tools/lib/apple_build_lease.rb` | `c7726eaf3470da9dacbacbdf65d86ce353770f47da15882624be4455b7008372` |
| `tools/with-apple-build-lease.sh` | `dc3d932b08b8056704bd37920694952effca451abb155cce1cf8e356752f1b99` |

`tools/apple-maintenance-policy.py protocol` reports the same manifest. New
policy tooling additionally needs `tools/apple-maintenance-policy.py` and
`tools/lib/apple_maintenance_policy.py` from the reviewed policy feature commit.
The two companion files must travel together.

Public build entrypoint:

```bash
tools/with-apple-build-lease.sh app/whole-release-lane -- command arguments
```

The wrapper changes working directory to its bundle's repository root. Use an
absolute command or explicitly change directory *inside* the protected command.
It must wrap the whole lane, including generation, package resolution, signing,
both platform builds, upload/processing/distribution, tagging, and queued gaps.
Wrapping each command separately does not protect the gaps between agent turns.
Python launchers must authenticate and explicitly pass the lease descriptors;
see `tools/run-bounded.py`. Never use `close_fds=False`.

The frozen `rollout-policy-v1` has no Hozz tokens. Adding tokens would break its
exact-match old readers, so this feature does **not** modify that schema. Instead,
enhanced global cleanup must require the companion
`apple-build-interlock-v1/maintenance-window-v1.json` as well as the existing v1
exclusive lease. Every old v1-only or broad cleanup entrypoint must be disabled
or upgraded before any activation. Otherwise an old reader could ignore Hozz,
expiry, owner holds, and target scope. Installing the companion alone does not
close this bypass.

## Operator workflow

1. Inventory every registered root, unregistered clone, raw/manual writer, and
   cleanup entrypoint on this machine. Include current **and** legacy Plozz,
   Mozz, Twozz, and Hozz. Account for active and queued work, not just processes.
2. Obtain actual owner attestations and durable evidence for that exact scope.
   Unwrapped owners may explicitly hold their work for a bounded window; this
   tool does not request such holds or manufacture agreement.
3. Obtain explicit human approval of the complete window package and the exact
   owner-released manifest, including provenance/evidence. Approval must be
   issued during the window, after its owner attestations.
4. Validate, then install the companion using compare-and-swap. This does not
   activate cleanup. Separately approved activation of existing suspension and
   legacy gates still requires their conflicting policy lock.
5. Enhanced cleanup acquires the v1 exclusive lease, checks the companion before
   each destructive step, and also enforces target eligibility, per-path open-use
   checks, process safety checks, age, and release evidence. All remain required.

There are no `--all-clear`, owner-generation, auto-approval, resume, or
stale-record-resolution options.

```bash
# Read-only identity aids. Namespace must already exist.
/usr/bin/python3 tools/apple-maintenance-policy.py host
/usr/bin/python3 tools/apple-maintenance-policy.py worktree-snapshot /physical/repo

# Review a supplied package without installing it.
/usr/bin/python3 tools/apple-maintenance-policy.py validate \
  --request /private/window-request.json --manifest /private/manifest.json

# Future explicitly authorized companion installation, NOT performed by this change.
/usr/bin/python3 tools/apple-maintenance-policy.py install \
  --request /private/window-request.json --manifest /private/manifest.json \
  --expect-current absent
```

For replacement, `--expect-current` is the current companion's raw SHA-256, not
`absent`. Install takes `policy.lock` exclusively and nonblocking **before**
reading/validating its request. Concurrent maintenance or an updater denies the
operation. Publication is mode-0600, fsynced, atomic, and compare-and-swap guarded.
A failure never fabricates a successful approval. A failed fsync may leave the
new companion present; it still does not activate anything. Inspect before retry.

Runtime contract, called by the installed adapter with inherited exclusive FDs:

```bash
/usr/bin/python3 /reviewed/bundle/tools/apple-maintenance-policy.py check \
  --manifest /private/manifest.json --window-id 00000000-0000-0000-0000-000000000000
```

The UUID above is a placeholder, not an approval. Exit 0 returns `window_id`,
`scope_sha256`, `expires_at` (UTC/RFC3339), and `policy_sha256`. Exit 75 refuses.
Missing, stale, malformed, forged, or closed inherited capabilities never fall
back to a new lease. The frozen protocol authenticates the capabilities and
retains the policy's shared lock throughout maintenance. Companion checks repeat
lease/suspension validation after evidence inspection.

Adapters must check the deadline before **every unlink**, not just each root.
Expiry/cancellation stops further deletion without signalling another process.
A partly processed target or quarantine and its journal remain protected for
owner review, not automatic resumption. A filesystem operation already in
progress at the deadline cannot be undone or forcibly interrupted safely.

## Document contract (schema 1)

All paths are absolute physical paths: no symlink aliases. Evidence, manifests,
requests, approvals, attestations, and installed companion files must be owned
by the effective UID and mode 0600 (or stricter). Writer sources may be readable
by others, but not writable by others. JSON duplicate fields and nonfinite
numbers fail closed.

Manifest top-level contract:

```json
{
  "schema": 1,
  "scope": "apple-owner-released-build-outputs-only",
  "targets": ["ADAPTER-VALIDATED EXACT TARGET RECORDS"]
}
```

This illustrative placeholder is **not** a valid adapter deletion target. The
adapter owns the target schema/validator: exact physical path and kind
(`worktree-apple-build` or `xcode-derived-data`), owner worktree/session, root
device/inode, release evidence, timestamps, whole-tree age of at least seven days,
and an inode-aware tree digest. This companion checks the nonempty schema/scope
and approval binding, not destructive eligibility. It must never be used alone
as a deletion implementation.

The manifest digest includes **all** parsed fields, including provenance and
release evidence, using:

```python
hashlib.sha256(json.dumps(
    manifest, sort_keys=True, separators=(",", ":"), ensure_ascii=False
).encode("utf-8")).hexdigest()
```

The same canonical encoding is used for `scope_sha256`. Other document
references use SHA-256 of their exact file bytes. A reference is exactly
`{"path": "/physical/private/file", "sha256": "<64 lowercase hex>"}`.

Window request fields (exact, no unknown fields):

| Field | Value |
| --- | --- |
| `schema` | Integer `1` |
| `host` | Exact `host` command result: effective UID, physical home/namespace identities, coordination device/inode |
| `window` | `id` UUID, UTC `not_before`/`expires_at`, exact `scope` above, canonical `manifest_sha256` |
| `cohorts` | One `{"name": "...", "roots": [...]}` for each required cohort |
| `registries` | `{"app": "plozz\|mozz\|twozz\|hozz", "root": "/physical/repo", "sha256": "..."}` entries |
| `approval` | Private SHA-bound reference to a supplied human approval document |

The window must be open now, positive, and no longer than two hours. Each root
is `{"identity": {"path": "...", "device": 1, "inode": 2}, "writers": [...]}`.
`writers` is a nonempty list of path/SHA-256 references covering the actual
entrypoints reviewed by its owner. Paths must be inside that root. These are
not proof that every entrypoint was discovered; owner review must provide that.

Required cohorts (exact set):

```text
global-cleanup-entrypoints
manual-xcode-writers-disabled-or-wrapped
mozz-current-writers
mozz-legacy-writers
plozz-current-writers
plozz-legacy-writers
twozz-current-writers
twozz-legacy-writers
hozz-current-writers
hozz-legacy-writers
```

Registry digests cover the exact bytes of
`git -C ROOT worktree list --porcelain -z`. The read-only `worktree-snapshot`
command supplies them. Every registered root must appear in that app's combined
current/legacy inventories; every declared app root must be registered. New
roots, removed roots, or HEAD/branch changes require renewed review and approval.
Multiple repositories/clones may be listed per app. Unregistered/unrecognized
repositories are **not** magically discovered: exhaustive host inventory remains
an explicit owner/human responsibility, including raw writers outside Git.

Compute `scope_sha256` over the request with just `approval` omitted. Each
supplied owner attestation has exactly:

```json
{
  "schema": 1,
  "scope_sha256": "<canonical scope digest>",
  "cohort": "<one required cohort>",
  "owner": "<real responsible owner>",
  "session_id": "<actual owner session UUID>",
  "attested_at": "<UTC within the window>",
  "disposition": "<wrapped|held|disabled|absent|enhanced>",
  "active_queued": "<none|protected-by-full-lane-shared-leases>",
  "evidence": [{"path": "<actual durable evidence>", "sha256": "<exact digest>"}]
}
```

`wrapped` requires the frozen four protocol files in every root, in addition to
owner-reviewed writer fingerprints. It permits active/queued work only when
protected by a **whole-lane** shared lease. `held` and `disabled` require explicit
owner evidence covering the entire approved window and no active/queued work;
neither can be inferred from an empty `ps`. `absent` is allowed only for an empty
app cohort, with owner evidence, never for manual/global writers. `enhanced` is
required only for the cleanup cohort: its evidence must confirm every path uses
the companion or has been disabled. A self-labelled v1-only wrapper is rejected.

The human approval document has exactly:

```json
{
  "schema": 1,
  "scope_sha256": "<same exact scope digest>",
  "approved_by": "<actual human approver>",
  "approved_at": "<UTC within window, after every owner attestation>",
  "evidence": {"path": "<actual approval evidence>", "sha256": "<exact digest>"},
  "attestations": ["ONE SHA-BOUND DOCUMENT REFERENCE PER COHORT"]
}
```

Again, placeholders are not real approvals. SHA-bound files prove consistency
with the reviewed package; they do not authenticate a human against another
process running as the same UID. The responsible operator must verify identity,
authority, inventory completeness, and the meaning of approval evidence. A
script cannot police a manual/raw writer that ignores an agreed hold. If those
conditions cannot be established, cleanup remains blocked.

## Evidence retention and tests

Install never inspects away, clears, or resolves failed lease records. Runtime
cleanup still refuses every unresolved record through v1. Owner attestation for
a finished failed lane must name the exact record ID and durable lane evidence;
it is input to a **later separately authorized** resolution, not permission for
this tool to delete it. Archives, IPAs, dSYMs, xcresults, session/release evidence,
Git/worktrees/source, shared dependencies, SDKs, simulators, VMs, Cargo/npm
resources, and Trash remain ineligible regardless of window approval.

Fixture-only validation, no app build:

```bash
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest \
  tools.tests.test_apple_maintenance_policy tools.tests.test_run_bounded
```

Tests create synthetic attestations exclusively under private temporary HOME
fixtures; no production owner assertions are generated. They cover missing
Hozz, scope/manifest/evidence/identity changes, expiry, raw queued owners,
wrapped-client bytes, registered-root snapshots, exclusive policy-update races,
compare-and-swap, real inherited exclusive checking, suspension, orphan evidence
retention, fixture confinement, and malformed JSON.
