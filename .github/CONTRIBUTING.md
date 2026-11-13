# Contributing to Plozz

Plozz is a free, open source media client for Apple TV, iPhone, and iPad.
Bug reports, translation corrections, documentation, and focused code
contributions are welcome.

Agent-assisted contributions are welcome too. Follow the [agent guidance](../AGENTS.md)
and review and understand everything you submit; no particular assistant or
model is required.

## Reporting bugs & requesting features

Search [open and closed issues](https://github.com/brandomoore/Plozz/issues?q=is%3Aissue)
and their discussions before [choosing a report template](https://github.com/brandomoore/Plozz/issues/new/choose).
Reuse the existing issue for the same report; link related problems without
conflating them. A regression after a delivered fix still needs investigation.

- **Bug report:** describe expected and actual behavior, reproduction steps when
  known, affected media source, app version/build, and device/OS.
- **Feature request:** explain the problem and intended outcome.
- **Translation correction:** include the language, screen, current wording, and
  suggested correction.

Never include passwords, tokens, or credentialed URLs in reports or attachments.
For Discord mirroring and the generated website roadmap, see the
[Discord bridge](../docs/discord-bridge.md) and [roadmap guide](../docs/website-roadmap.md).

## Development pipeline

Discuss substantial features before investing in an implementation. Keep changes
focused, follow the surrounding conventions, and submit a pull request describing
the behavior changed, affected platforms/providers, checks run, and known gaps.
Include screenshots for visible changes.

Keep defects and review findings from active, unreleased work in its current task
or existing feature issue; do not create a new bug issue just to fix or commit
them. New bug issues are for problems affecting users of distributed builds
(including TestFlight), unless a maintainer explicitly requests one. Feature
requests can precede implementation.

A branch push, merge to `main`, or local installation is **not delivery**. Keep
issue status accurate and distinguish implemented work from released fixes.

### Commit issue references

Reference an existing issue in the fixing commit itself, using `Refs #123`
(or `Refs owner/repo#123` across repositories). A PR reference or separate comment
does not replace the commit reference.

For app fixes and features, do not use closing keywords (`Fixes`, `Closes`,
`Resolves`) in commits or PR descriptions. Reports stay open until the affected
platforms are available to external TestFlight testers.

When the whole report is implemented, add one trailer per resolved issue:

```text
Fix episode detail entry

Refs #177

TestFlight-Issue: 177 [tvOS]
```

Allowed platform values are exactly `tvOS`, `iOS`, or `tvOS,iOS`; `iOS` includes
iPhone and iPad. Partial fixes use only `Refs`. A reopened issue needs a new
fixing-commit declaration. Never use the old `TestFlight-Fix: #...` spelling:
GitHub treats it as an immediate closing reference.

The delivery watcher verifies tagged source and external availability before
posting build-specific comments and closing GitHub and linked Discord reports.
See [delivery-gated issue resolution](../docs/discord-bridge.md#delivery-gated-issue-resolution)
for activation and recovery. Non-app issue closure remains maintainer-managed.

## Building & running

### Requirements

- macOS and the Xcode/SDK configuration used by [CI](workflows/ci.yml):
  currently Xcode 27 on the `xcode-27` runner image. The pinned playback engine
  requires this toolchain; app deployment targets are iOS/tvOS 18.0.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.

### Generate the project and run

```bash
tools/generate-project.sh
open Plozz.xcodeproj
```

Choose **Plozz** for tvOS or **PlozziOS** for iOS/iPadOS, select an installed
simulator, and Run. `project.yml` and `Package.swift` are the source of truth;
use the generation wrapper, not bare XcodeGen, and do not commit the generated
project. Regenerate after adding, removing, or renaming source files.

**Normal builds do not need a separate Java disc runtime.** Experimental local
Debug builds have a separate opt-in procedure in
[disc navigation](../docs/playback-engines.md#native-only-distribution-and-experimental-local-builds);
they are not for TestFlight distribution.

Optional integration credentials belong in the gitignored
`Config/Secrets.local.xcconfig`; [committed defaults](../Config/Secrets.xcconfig)
describe the keys. Missing registrations disable those integrations, not the
basic build. Never commit credentials or signing material.

### Build and deploy to a device

Configure your own signing team and provisioning in Xcode and choose your paired
device. The deployment scripts are maintainer-oriented: inspect their `--help`
and override device identifiers rather than using their machine-specific defaults
(`PLOZZ_TV_ID`, `PLOZZ_IPHONE_CORE_ID`, `PLOZZ_IPAD_CORE_ID`).

`--build-only` compiles without installation; `--iphone` and `--ipad` select mobile
targets. Device builds use optimized Debug (`-O`); use `--unoptimized` for
debugger-oriented builds. The tvOS `--sim-build` path remains unoptimized.

`--branded` creates a separate branch app with stripped entitlements, no cloud
sync, and fresh sign-in instead of replacing the canonical app. See
[per-branch builds](../docs/per-branch-builds.md) for signing and isolation details.
Build scripts use the [shared build lease](../docs/apple-maintenance-windows.md);
do not clear shared caches or disrupt another build to recover a failure.

### Unsigned self-build IPAs

```bash
tools/build-unsigned-ipa.sh ios   # iPhone and iPad
tools/build-unsigned-ipa.sh tvos  # Apple TV
```

These commands snapshot tracked working-tree files; stage new source files first.
They retain the source, logs, products, IPA, and provenance receipt under
`.build/unsigned-ipa/<platform>/run-*` without changing the checkout's project,
plists, or private configuration. They do not sign, install, upload, or release.

Alternatively, enable Actions in your fork and run [Unsigned IPA](workflows/unsigned-ipa.yml)
from its default branch. Select an available macOS runner with Xcode 27 or later;
the default `xcode-27` image is not available to every fork. No signing or App Store
Connect secrets are required. Artifacts are retained for seven days.

**Unsigned IPAs are not directly installable.** Sign the app, embedded frameworks,
and tvOS Top Shelf extension with compatible provisioning. Device availability and
expiration depend on your signing tool and Apple account. The separate app is
**Plozz Self-build** (`com.thatcube.Plozz.selfbuild`).

Self-builds omit private metadata/OAuth registrations and crash reporting, and
disable iCloud sync, push, associated domains, shared Top Shelf data, and tvOS
household-keychain access. Provider artwork and keyless enrichment remain;
expect fresh sign-in and local settings. Playback configuration and license
notices remain intact; unsigned packaging is not licensing or patent clearance.

### Tests

Choose checks for the changed behavior, not an automatic full sweep:

```bash
tools/run-tests.sh CoreModelsTests ProviderPlexTests  # selected package suites
tools/run-focus-tests.sh -only-testing:PlozzFocusTests/DetailPrimaryFocusHostedTests
```

The package runner takes test target names; omitting them runs its full matrix.
Both examples target tvOS simulators. iOS presentation coverage is separate;
see the [testing policy](../docs/testing-policy.md) for runners, selection, and
evidence reuse. Do not use desktop `swift test` for this Apple-platform package.
Report failures, skips, and untested platforms explicitly.

### Screenshots

See [screenshots](../docs/screenshots.md) for simulator fixtures and capture commands,
including `tools/capture-shots.sh` and `tools/readme-shots.sh`.

### Performance debugging

Use the [performance lab](../docs/performance-lab.md) for reproducible simulator
measurements and [performance debugging](../docs/performance-debugging.md) for
device profiling. Compare equivalent workloads; test duration alone is not an
app-performance measurement.

### Localization

Finalize UI and source wording with the maintainer before translation work.
Shared UI strings live in the app-owned catalog, not per-module catalogs.
Follow [source-string rules](../docs/localization.md) and the
[reviewed translation pipeline](../docs/translations.md) for extraction,
permission prompts, independent review, import, and source-snapshot updates.
Do not hand-edit translations or advance the snapshot before checks finish.

### Releasing to TestFlight

Distribution requires explicit authorization and approved notes for the exact
candidate. [Release identity and delivery](../docs/release-versioning.md) owns
version/build selection, fastlane commands, and partial-upload recovery.
Local credentials use the gitignored `.env.fastlane` described by
[`.env.fastlane.example`](../.env.fastlane.example).

A main merge is not a release, and an upload is not external tester availability.
Preserve release evidence and inspect both platforms before retrying an
interrupted distribution.

## Architecture

The [Swift package](../Package.swift) supplies shared libraries and platform UI
to thin XcodeGen app targets. Start with the relevant module or guide:

| Area | Owners |
| --- | --- |
| Models, provider contracts, networking | [CoreModels](../Sources/CoreModels/README.md), [CoreNetworking](../Sources/CoreNetworking/README.md) |
| Shared behavior and runtime composition | `Feature*Core` modules, [AppRuntime](../Sources/AppRuntime), [state management](../docs/state-management.md) |
| Platform UI and shared components | [AppShell](../Sources/AppShell/README.md) (TV), [AppShelliOS](../Sources/AppShelliOS), [CoreUI](../Sources/CoreUI/README.md) |
| Providers | [Jellyfin/Emby](../Sources/ProviderJellyfin/README.md), [Plex](../Sources/ProviderPlex/README.md), [Silo](../Sources/ProviderSilo/README.md), [Subsonic](../Sources/ProviderSubsonic/README.md), [shares](../Sources/ProviderShare) |
| Home, playback, music, Live TV | [FeatureHome](../Sources/FeatureHome/README.md), [FeaturePlayback](../Sources/FeaturePlayback/README.md), [FeatureMusic](../Sources/FeatureMusic/README.md), [FeatureLiveTV](../Sources/FeatureLiveTV) |
| Discovery, accounts, profiles | [FeatureDiscovery](../Sources/FeatureDiscovery/README.md), [FeatureAuth](../Sources/FeatureAuth/README.md), [FeatureProfiles](../Sources/FeatureProfiles/README.md) |
| Search and settings | [FeatureSearch](../Sources/FeatureSearch/README.md), [FeatureSettings](../Sources/FeatureSettings/README.md) |
| Metadata, ratings, tracking | [MetadataKit](../Sources/MetadataKit/README.md), [RatingsService](../Sources/RatingsService/README.md), [TraktService](../Sources/TraktService/README.md), [WetrakrService](../Sources/WetrakrService/README.md), [CoreTrackerAuth](../Sources/CoreTrackerAuth/README.md) |
| Downloads and Top Shelf | [MediaDownloads](../Sources/MediaDownloads/README.md), [TopShelfKit](../Sources/TopShelfKit/README.md) |

Keep cross-view/platform state in core or runtime modules, not app shells.
See the [architecture roadmap](../docs/architecture-roadmap.md) for proposed work.

## The dual-provider invariant

**Jellyfin and Plex are co-equal backends.** Changes to data, playback, auth,
metadata, search, or navigation must account for both while preserving other
supported providers. Use `MediaProvider` above the provider layer; disclose
intentional capability differences. Jellyfin and Emby share a provider
implementation; Subsonic support is music-only and currently development/TestFlight-only.

## Coding norms

Follow the [Swift/SwiftUI guidelines](../docs/swiftui-guidelines.md) and existing
module ownership. Keep changes focused, add relevant regression coverage, and
update the documentation that owns the changed behavior.
