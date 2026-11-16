# Signing an unsigned self-build IPA

`tools/build-unsigned-ipa.sh` produces an installable-after-re-signing app, not a
signed one. This note records exactly what the artifact contains, what a
third-party signer replaces, and which runtime capability a re-signed install can
lose. It is the reference for "the re-signed build installs but cannot play".

## What the artifact contains

The build snapshots tracked files, blanks integration keys, builds with
`CODE_SIGNING_ALLOWED=NO`, and strips the signature from the app and extension
executables only. It never writes a provisioning profile.

| Item | State in the unsigned IPA |
| --- | --- |
| `Info.plist` | Complete, including `NSLocalNetworkUsageDescription`, `NSBonjourServices`, `NSAppTransportSecurity` and `UIBackgroundModes` |
| App / extension executable | Unsigned (`codesign -dv` reports "not signed at all") |
| `AetherEngine.framework` (built from source) | Unsigned |
| Prebuilt FFmpeg / Sentry / freetype frameworks | Their original linker ad-hoc signatures, preserved on purpose |
| `embedded.mobileprovision` | Absent |
| App entitlements | None |

The script now rejects a package that lost a playback key
(`PLAYBACK_INFO_KEYS` in `tools/build-unsigned-ipa.py`), because nothing after
that point rewrites the plist: a signer only adds a signature and profile.

## Entitlements: what signing actually changes

The working, Xcode-signed self-build
(`.build/deploy-selfbuild-derived-data/Build/Products/Debug-iphoneos/Plozz.app`)
claims only:

```
application-identifier      = 23M9Z58332.com.thatcube.Plozz.selfbuild
com.apple.developer.team-identifier = 23M9Z58332
get-task-allow              = true
```

There is no multicast entitlement, no App Group, no keychain group and no
network extension. Those three claims are written into the signature from the
provisioning profile; the canonical entitlements file contributes nothing else
to the working build. That is the first useful negative result: **entitlements
are not the reason playback differs**, because the build that plays has no
playback entitlement to lose.

`App/PlozziOS/PlozziOS.entitlements` (the canonical file) also asks for:

| Claim | Runtime effect when a profile cannot grant it |
| --- | --- |
| `aps-environment`, `com.apple.developer.aps-environment` | CloudKit silent pushes stop; sync falls back to foreground |
| `com.apple.developer.ubiquity-kvstore-identifier` | Sync & Setup presence beacon stops |
| `com.apple.developer.icloud-container-identifiers` / `-services` | Device-local only; `CloudConfigSyncService` checks entitlement proof first and never traps |
| `com.apple.developer.associated-domains` | `applinks:plozz.app` / QR pairing into the app stops |
| `com.apple.security.application-groups` (tvOS) | Top Shelf stays empty; `TopShelfStore` guards the nil container |
| `com.apple.developer.user-management` (tvOS) | Household keychain falls back per system user |

None of these are in the playback path. A free Personal Team profile cannot
grant iCloud, push, App Groups or Associated Domains; those features are simply
absent and the code paths above degrade as listed.

## What Feather does

This describes Feather `main` as inspected on 2026-11-14
(`Feather/Utilities/Handlers/SigningHandler.swift` and its `Zsign` submodule;
zsign is the signer Feather drives). Re-check it if a later release changes the
options.

Feather's `SigningHandler` reads entitlements **from the app binary** before it
re-signs. The unsigned artifact has no such blob, so the merge step has nothing
to read. Its `mergeEntitlements` option is also off by default. The result is
that zsign signs the app with the provisioning profile's `Entitlements`
dictionary verbatim — concrete for an explicit App ID, still wildcarded for a
wildcard profile.

Consequences for this app:

- Every entitlement the profile does not grant is gone. Per the table above that
  is acceptable for playback.
- A **wildcard** profile (`TEAM.*`) is supported and is what a normal sideload
  uses. zsign writes the profile's wildcard `application-identifier`; the app still
  installs, launches, reads its credentials and loads Home/library rows from servers
  — observed on a real install. What a wildcard cannot carry is the capability set:
  App Groups, iCloud/CloudKit, push, Associated Domains, and the Top Shelf's shared
  container. Those degrade as listed above; the viewer's library, playback and
  progress do not.
- An **explicit App ID** is only required if you need one of those capabilities.
  If you use one, its bundle id must be exactly `com.thatcube.Plozz.selfbuild`.
- Do not change the bundle id in the signer. `BGTaskSchedulerPermittedIdentifiers`
  and the external-player callback scheme are baked from it at build time, so a
  rename silently breaks background handoff and callbacks. If a rename is
  unavoidable, rebuild with `PLOZZ_ID_SUFFIX` instead of editing the plist.

## Local Network: the capability that does not degrade

Local Network is a privacy grant, not an entitlement. The system records it
against the **signed identity**, so a re-signed install (new team prefix) starts
undecided while the previous install's grant belongs to the old identity.

Per [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy):

- outgoing TCP to a local-network address requires the grant;
- accepting incoming connections does not;
- loopback (`127.0.0.1`) is not a local-network address.

So the loopback HLS server and `ExternalPlaybackByteServer` are unaffected, while
playing a stream from a server on the LAN needs the grant. If the grant is
missing, network requests can fail or time out. A timeout alone does not establish
that permission is denied; an unavailable server can produce the same symptom.

The operating system manages the permission prompt when the app accesses the
local network. Plozz does not infer a permanent permission state from Bonjour
discovery or claim to expose that state in Developer Mode.

If the alert was dismissed, or the grant belongs to the old signature:

1. Settings ▸ Privacy & Security ▸ Local Network.
2. Enable "Plozz Self-build".
3. Retry playback.

tvOS has no Local Network privacy gate, so this does not apply there.

## Verifying a build

```bash
tools/build-unsigned-ipa.sh ios
IP=$(ls -dt .build/unsigned-ipa/ios/run-* | head -1)
python3 - "$IP/receipt.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["playbackInfoKeys"])
PY
codesign -dv "$IP/Payload/Plozz.app" 2>&1 | head -1          # not signed at all
plutil -p "$IP/Payload/Plozz.app/Info.plist" | grep -E \
  'NSLocalNetworkUsageDescription|NSBonjourServices|NSAllowsArbitraryLoads|UIBackgroundModes'
```
After signing, the same checks on the installed app are
`codesign -d --entitlements :- <app>` (expect profile identity claims only) and
the Developer Mode panel above.

## Residual risk

- A free Personal Team profile expires after 7 days and cannot grant iCloud,
  push, App Groups or Associated Domains; sync, notifications, universal links
  and Top Shelf are unavailable by design.
- If Apple revokes the certificate, previously installed apps stop launching.
- Whether a specific server advertises a LAN stream URL while the app connected
  over the internet (the common case for a public Jellyfin/Emby address) decides
  whether playback needs the grant at all. Both paths now ask for it up front.
- A physical-device test with Feather is still the acceptance test for a given
  certificate/profile pair; this repository cannot prove a third-party signer's
  output.
