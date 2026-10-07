# Per-branch builds (`--branded`)

Install a branch's build on a real device **side-by-side with the canonical app**,
so you can test it without losing the app you actually use.

```sh
tools/deploy-tv.sh  --branded          # Apple TV
tools/deploy-ios.sh --ipad --branded   # iPad
tools/deploy-ios.sh --iphone --branded # iPhone
```

That's the whole workflow. The scripts handle project regeneration, signing,
install, launch, and restoring the canonical project state on exit.

## What you get

The app is named and identified from the current git branch:

| branch | app name | bundle id |
| --- | --- | --- |
| `thatcube-localization` | Plozz localization | `com.thatcube.Plozz.localization` |
| `thatcube-new-player` | Plozz new-player | `com.thatcube.Plozz.new-player` |

The `thatcube-` prefix is stripped and the rest is slugified (lowercased,
non-alphanumerics to `-`, capped at 24 characters).

## What a branded build deliberately gives up

A per-branch build uses a **brand-new App ID**, and a new App ID cannot
auto-provision the canonical app's special capabilities. So branded builds sign
against stripped entitlements:

- `App/Resources/Plozz.branded.entitlements` (tvOS)
- `App/PlozziOS/PlozziOS.branded.entitlements` (iOS)

Both are empty. The practical consequences:

| Capability | Effect on a branded build |
| --- | --- |
| iCloud / CloudKit | **No cloud sync.** Config stays device-local. |
| Push notifications | No silent CloudKit wake-ups (tvOS already ships this way). |
| Associated Domains (iOS) | `applinks:plozz.app` routes to the canonical app. |
| App Group (tvOS) | Top Shelf stays empty. |
| User Management (tvOS) | Falls back to the normal per-user keychain. |

**The most visible consequence: a branded build will not inherit your servers or
profiles, so you will sign in again.** That is intended isolation — the branded
app has its own container and cannot disturb your real setup — not a bug.

Everything above degrades rather than fails. For isolated onboarding with real
iCloud, use a first-user case instead of `--branded`.

## Cloud-enabled first-user cases

`tools/first-run.sh` builds the normal app with a separate development identity.
It does not reset, uninstall, back up, or modify an existing installation.

```sh
# First-ever user: new local storage, Keychain access group, and cloud household.
tools/first-run.sh --new --platform tvos --device "$TV_CORE_DEVICE_ID"

# New device in that same TEST household: reuse the UUID printed above.
tools/first-run.sh --case <case-uuid> --platform ios --device "$PHONE_CORE_DEVICE_ID"

# Omit --device to build and verify without installing.
```

The default uses the Apple Developer account signed into Xcode. Alternatively,
`--provisioning api` uses the existing local `ASC_KEY_PATH`, `ASC_KEY_ID`, and
`ASC_ISSUER_ID` configuration. Apple must provision the new App IDs and the
dedicated `iCloud.com.thatcube.Plozz.FirstRun` container. A signing failure is
not worked around by dropping iCloud, sharing normal Plozz's container, or
deleting provisioning profiles.

Each `--new` creates a UUID-labelled app, **Plozz First Run xxxx**, with:

- A distinct app container, default Keychain access group, and iCloud key-value
  store. Uninstalling is not used as a substitute for clearing surviving secrets.
- Case-specific zones for every sync channel in the dedicated test CloudKit
  Development container. Record formats, encrypted fields, and the sync engine
  remain the same; fetches are restricted to the case's zones.
- Isolated Bonjour pairing and QR/deep links. Normal Plozz cannot discover the
  test's pairing listener, and current clients reject invites from another case.
- The normal tvOS household Keychain capability. Top Shelf and production
  universal links are deliberately absent; this is not a Top Shelf test.

The tool verifies signed capabilities before installation, preserves exact app
artifacts under `.build/first-run/<case-uuid>/`, and restores generated project
configuration without discarding pre-existing plist edits. Case manifests must
match before `--case` can reuse them. Reusing a case is **not** a fresh-user test;
it is a continuation or restoration test. Starting a new case leaves previous
test apps and data intact.

For a first-time IPTV walkthrough, start only one device. Leave the welcome
screen and setup choices unchanged, choose **IPTV**, connect the provider,
and check import, guide, and first playback. Do not seed media-server accounts
or generated Plozz Channels into this case. Afterward, use the same case on
another device to test cloud restoration. Use a separate case for a large
generated-channel sync/performance workload.

A signature check is not proof of working iCloud. Following the first successful
foreground cloud fetch, the test app writes a nonsecret `first-run-cloud.json`
receipt beside its sync ledger (`Library/Application Support/PlozzSync/` or the
tvOS Caches fallback). Verify the case/container, `fetchSucceeded`, and
`recordsBeforeInitialPublish == 0` on the first device before calling it an empty
cloud test. A second device restoring that case may correctly receive records.
No receipt means live cloud validation remains incomplete.

## Troubleshooting

### `0xe8008012` — "This provisioning profile cannot be installed on this device"

The profile doesn't include your device's UDID. `tools/deploy-ios.sh` now catches
this **before** installing and prints which UDID is missing, because the raw
error names neither the device nor the profile.

Usual cause is a stale cached profile. In order:

1. Connect and unlock the device, then re-run. The script builds against the
   concrete target device, which is normally enough to make Xcode refresh.
2. `rm -rf ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles`
3. Confirm the device is registered on the developer portal.

Root cause, for the curious: with a *generic* destination (`generic/platform=iOS`)
xcodebuild has no target device to provision for, so `-allowProvisioningUpdates`
could hand back a wildcard profile containing the wrong device set. For the
canonical app id an all-devices profile already existed, so this never showed up;
a fresh per-branch App ID exposed it immediately.

### The app crashes instantly on launch

Should be fixed — but the shape is worth recognising, because more than one API
behaves this way. `CKContainer(identifier:)` does **not** return an error when the
iCloud entitlement is missing; it **traps** (`EXC_BREAKPOINT`/`SIGTRAP`). A
`do/catch` around a later call never runs, because the crash happens earlier, on
container construction.

`CloudConfigSyncService` now checks the entitlement (read from the embedded
provisioning profile) before touching CloudKit. If you add code that consumes a
stripped capability, guard it the same way — assume the API traps rather than
throws until proven otherwise.

### It builds but doesn't install

`--build-only` skips installing. Both device deployment wrappers use
`install-verified.sh`: up to three 180-second install attempts, bounded version
queries, and short backoff. A stale availability probe never gates installation.
There is no shorter outer timeout truncating the retry budget.

The installer preserves a signed-app check, all command logs, structured replies,
and a receipt under `.build/device-installs/`. It verifies after an error before
retrying: a newly observed target build confirms a completed install, but an
unchanged build number does **not** prove a `--force` replacement. A clean install
completion remains success if a follow-up connection or optional launch fails.
Package/signature rejection remains a failure, not device unavailability.
Recovery never resets shared device services, changes pairing, or deletes caches;
cancellation terminates only the installer’s current owned command.

`PLOZZ_INSTALL_TIMEOUT` (1–600 seconds) and `PLOZZ_INSTALL_ATTEMPTS` (1–5) override
the defaults. `PLOZZ_DEPLOY_INSTALL_DEADLINE`, if explicitly set, is an overall
deadline owned by the installer, not a second independently timed wrapper.

## Cleaning up

Delete the branded app from the device like any other app. Nothing else to undo —
the scripts restore the canonical project and `Info.plist`s on exit (including
after a failure), so `git status` stays clean.
