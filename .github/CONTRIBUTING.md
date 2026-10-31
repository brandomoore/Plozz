# Contributing to Plozz

Thanks for your interest in Plozz — a free, open source client for Jellyfin,
Plex, Emby, Silo, and local shares, on Apple TV, iPhone, and iPad. It's a small,
solo-maintained project, so this guide stays lightweight.

Agent-assisted contributions are welcome. Read the repository's
[agent guidance](../AGENTS.md) for implementation, verification, and safety
expectations. You remain responsible for reviewing and understanding the changes
you submit; no particular assistant or model is required.

## Reporting bugs & requesting features

Use issues for problems in distributed builds and proposals that need their own
tracking. [**Open one**](https://github.com/thatcube/Plozz/issues/new/choose)
and pick a template:

- **🐞 Bug report** — captures what makes a bug fixable: steps to reproduce,
  expected vs actual, and your Plozz version/build and device/OS version.
  Selecting the affected media source (Jellyfin, Emby, Plex, Silo, SMB, or IPTV)
  is required. Select all that apply, or "Not applicable / not sure" for bugs
  before setup or when you don't know the source.
- **✨ Feature request** — a short form for problems worth solving.

Please search [existing issues](https://github.com/thatcube/Plozz/issues) first,
and never paste tokens, passwords, or credentialed server URLs.

Plozz's Discord support forums can also feed the same GitHub backlog once their
public-mirroring notice and bridge are activated. Forum guidelines explain what
is copied and how votes work. See [Discord bridge behavior and privacy
limits](../docs/discord-bridge.md); ordinary chat channels are not mirrored.

## Development pipeline

Fix defects, review findings, UI adjustments, and test failures introduced during
active unreleased work within that task or its existing feature issue. Do not
create a separate issue merely to fix something before users receive it. A
development branch or local test installation is not a distributed release.

Create an issue for a problem in a build delivered to users (including TestFlight),
work being deferred beyond the current task, independently actionable work, or an
explicit request to file one. Search for existing tracking first. Keep issue
status accurate and distinguish a branch fix from a fix delivered to users.

### Commit issue references

When work addresses a GitHub issue, include its reference in the fixing commit's
subject or body before committing. Use `Refs #123` for an issue in the same
repository, or `Refs owner/repo#123` when the fix lives in another repository.
Plain text such as `issue 123` is not a GitHub issue reference.

The pushed commit should create GitHub's built-in "added a commit that references
this issue" timeline entry. A PR reference alone is not a substitute. Do not post
a separate issue comment just to link the commit.

For app fixes and features, use the non-closing `Refs` form: merging a fix is not
delivery. Keep GitHub and linked Discord reports open until the affected
platforms are available to external TestFlight testers. Do not use GitHub's
`Fixes`, `Closes`, or `Resolves` keywords in commits or PR descriptions for these
reports.

When the entire report is resolved, add a final commit-trailer block declaring
the affected platforms (exactly `tvOS`, `iOS`, or `tvOS,iOS`):

```text
Fix episode detail entry

Refs #177

TestFlight-Issue: 177 [tvOS]
```

Use one trailer per fully resolved issue; partial work keeps only `Refs`.
The trailer deliberately uses a numeric issue ID without `#` and no closing
keyword. Do not use the old `TestFlight-Fix: #...` spelling: GitHub interprets
that as an immediate closing reference even though it is inside a trailer.
`iOS` includes iPhone and iPad. The hosted watcher records an `awaiting release`
status and, after verifying tagged source and external TestFlight availability,
publishes build-specific comments and closes both reports. It does not infer
resolution from commit subjects or ask an LLM. A reopened issue requires a new
fixing-commit declaration. See [delivery-gated issue resolution](../docs/discord-bridge.md#delivery-gated-issue-resolution)
for activation, retries, and limitations. Non-app work that does not ship through
TestFlight remains a maintainer-managed closure.

## Building & running

### Requirements

- macOS with the Xcode/SDK configuration supported by [CI](workflows/ci.yml)
  (currently Xcode 27 on the `xcode-27` runner image, matching the pinned playback
  engine's toolchain requirement). The app deployment targets remain iOS 18.0
  and tvOS 18.0.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

### Generate the project and run

The Xcode project is generated, not committed. Use the wrapper rather than
calling `xcodegen` directly — it also stamps the version and build number:

```bash
tools/generate-project.sh
open Plozz.xcodeproj
# Select the "Plozz" scheme (or "PlozziOS") and a simulator, then Run.
```

### Build and deploy to a device

```bash
tools/deploy-tv.sh --build-only   # compile, don't install
tools/deploy-tv.sh                # build, install, launch on an Apple TV
tools/deploy-ios.sh --ipad        # iPad
```

Device deployment builds use the Debug configuration with Swift optimization
enabled (`-O`), including package dependencies. This retains diagnostics without
making hot media-processing loops run at unoptimized debugger speed. Pass
`--unoptimized` when stepping through code or inspecting locals is more important
than playback performance. The tvOS `--sim-build` compile-check path remains
unoptimized.

To install a branch's build **alongside** the canonical app rather than
replacing it, add `--branded`:

```bash
tools/deploy-tv.sh  --branded
tools/deploy-ios.sh --ipad --branded
```

That installs `com.thatcube.Plozz.<branch-slug>` as a separate app. It signs
against stripped entitlements, so it has no cloud sync and won't inherit your
servers — see [`docs/per-branch-builds.md`](../docs/per-branch-builds.md).

### Tests

```bash
tools/run-tests.sh [SchemeName]
```

Tests run on a tvOS Simulator. Use the repository's Apple-platform test runners,
not desktop `swift test`: the package depends on platform frameworks and UIKit.
See the [testing policy](../docs/testing-policy.md) for affected-suite selection,
separate app-hosted coverage, and evidence reuse.

### Screenshots

Plozz photographs itself by driving a Simulator; there's no capture card and no
device to keep plugged in. The marketing and App Store shots, and the ones
embedded in the README, all come from that pipeline:

```bash
tools/capture-shots.sh            # Apple TV -> build/shots/
tools/readme-shots.sh             # web-sized README images
```

The full explanation, including the traps, is in
[`docs/screenshots.md`](../docs/screenshots.md).

### Performance debugging

If the app feels laggy, or you see blank artwork or memory crashes on device,
[`docs/performance-debugging.md`](../docs/performance-debugging.md) is an on-device
playbook using the watchdog and Instruments (`xctrace`).

### Localization

All UI copy is served from one app-owned String Catalog. Adding a string means
writing it in Swift, running `tools/l10n-sync.py`, and committing both. The
rules — and the traps — are in [`docs/localization.md`](../docs/localization.md).

Plozz ships complete UI and permission-prompt catalogs for **36 languages**,
including Arabic/Hebrew RTL layouts and full Slavic plural forms. How
translations are produced, reviewed, structurally gated, and corrected is in
[`docs/translations.md`](../docs/translations.md).

### Releasing to TestFlight

Distribution is automated with fastlane (App Store Connect API key auth). Drop a
gitignored `.env.fastlane` with `ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_KEY_PATH`
(see `.env.fastlane.example`), then:

```bash
PLOZZ_RELEASE_ID=release/NNN fastlane beta --env fastlane
fastlane build --env fastlane   # archive a signed .ipa locally, no upload
PLOZZ_RELEASE_ID=release/NNN fastlane release --env fastlane
```

**Versioning:** [release identity and delivery](../docs/release-versioning.md)
defines the public date, the separate Apple marketing version, and the selected
build number (including dotted hotfix builds). The committed
`App/Resources/ReleaseNotes.json` entry owns that identity. Obtain approval for
the exact rendered platform notes and candidate before running a distribution
lane.

**Package resolution:** Fastlane's supported `build_app` options carry the same
package paths and locked-version policy through dependency resolution, build
settings, and archive. Do not duplicate package flags in `xcargs` or bypass
resolution. `PLOZZ_FASTLANE_CLONED_SOURCE_PACKAGES` overrides the package workspace
**root**; each invocation and platform gets a private child directory. The
download cache remains shared (`PLOZZ_PACKAGE_CACHE_PATH`, defaulting to the
standard SwiftPM cache). The lane preserves the host's git configuration and
appends `safe.bareRepository=all`.

**TestFlight concurrency:** both signed archives finish and both exported IPAs
pass version/build/platform checks before either upload starts. Two isolated Ruby
processes then upload, wait for Apple processing, set their platform-specific
notes, and submit to **Plozz External**, with notifications enabled. No previous
builds are expired or rejected. Successful submission is not approval: the final
report includes Apple's observed internal/external state, which may still be
`WAITING_FOR_BETA_REVIEW`. The App Store `release` uploads remain serial.

The enclosing shared release lease stays held through both workers, descendant
cleanup, and tagging. Workers inherit its descriptors and receive the current
API key only through anonymous pipes. Each worker uses Fastlane's normal
altool/Java transporter rather than the shell transporter's shared key directory.
Results and separate platform logs remain under `.build/testflight-uploads/`.

**Partial failure or cancellation:** both workers are reaped; a platform failure
does not stop the other platform's processing. Cancellation terminates both owned
process groups, with a bounded grace period before forced termination. No tag or
GitHub release is created unless both workers succeed. Preserve the signed IPAs,
logs, and `summary.json`; inspect the exact platform/version/build in App Store
Connect before recovery. An interrupted upload may already have reached Apple.
Do not blindly rerun `beta`, increment the build, rebuild, or retry an upload.
There is no automatic retry or distribution-only lane.
Known validation failures report fixed safe codes (`external_group_missing`,
`uploaded_build_mismatch`); invalid worker output reports `invalid_worker_result`.
Arbitrary exception messages and credentials are not copied into the summary.

App icons, in-app logos, and tvOS **Brand Assets** are generated from
`App/Resources/Assets.xcassets/PlozzLogo.imageset/plozz_logo.svg` with
`python3 tools/generate_brand_assets.py`. The tvOS App Store and Top Shelf
assets live under `App/Resources/Assets.xcassets/…brandassets`.

## Architecture

Plozz is a Swift Package with one library per concern, consumed by thin app
targets generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen).

| Module | Responsibility |
| --- | --- |
| [`CoreModels`](../Sources/CoreModels/README.md) | Domain models, `AppError`, `LoadState`, caption settings, and the **`MediaProvider`** protocol (the provider abstraction). |
| [`CoreNetworking`](../Sources/CoreNetworking/README.md) | `HTTPClient`, `Endpoint`, URL normalization, and a secret-safe logger (`PlozzLog`). |
| [`CoreUI`](../Sources/CoreUI/README.md) | Shared focusable components, theme, image cache, content-state views. |
| [`ProviderJellyfin`](../Sources/ProviderJellyfin/README.md) | Shared Jellyfin/Emby MediaBrowser client, DTOs, compatibility shims, device profile, and `MediaProvider` implementation. |
| [`ProviderPlex`](../Sources/ProviderPlex/README.md) | Plex client, DTOs, PIN/auth, connection resolver/selector, and a `MediaProvider` implementation. |
| [`ProviderTrailers`](../Sources/ProviderTrailers/README.md) | Synthetic `MediaProvider` for online (YouTube) trailers, with stream extraction via YouTubeKit. |
| [`MetadataKit`](../Sources/MetadataKit/README.md) | Keyless-first artwork & metadata enrichment (AniList, Kitsu, TVmaze, Deezer, MusicBrainz/CAA, Wikidata/Wikipedia) routed by content type with a persistent on-disk cache. Bundled TheTVDB tier + optional maintainer-hosted TMDb tier. |
| [`RatingsService`](../Sources/RatingsService/README.md) | External ratings enrichment (OMDb optional key, keyless AniList) with on-disk cache. |
| [`TraktService`](../Sources/TraktService/README.md) | Optional Trakt OAuth, scrobbling, and watched/sync helpers. |
| [`TopShelfKit`](../Sources/TopShelfKit/README.md) | Domain-to-snapshot mapping for the Top Shelf extension; writes to the shared App Group container. |
| [`FeatureDiscovery`](../Sources/FeatureDiscovery/README.md) | LAN (UDP) discovery, server validation, server-picker UI, last-server persistence. |
| [`FeatureAuth`](../Sources/FeatureAuth/README.md) | Quick Connect, Plex Link, password sign-in, the explicit **session state machine**, Keychain-backed account/session stores. |
| [`FeatureHome`](../Sources/FeatureHome/README.md) | Home rows, item detail, series/season experience, online trailer fallback. |
| [`FeaturePlayback`](../Sources/FeaturePlayback/README.md) | `AVPlayer` view model/view, engine routing, resume reporting, caption style rules, idle-sleep handling, diagnostics overlay. |
| [`FeatureSearch`](../Sources/FeatureSearch/README.md) | Search view & view model, deduplication, search policy. |
| [`FeatureSettings`](../Sources/FeatureSettings/README.md) | Settings (profiles, integrations, server, caption customization, preference detail). |
| [`FeatureProfiles`](../Sources/FeatureProfiles/README.md) | Profile picker, editor, avatar/photo capture (household "Who's watching?"). |
| [`FeatureMusic`](../Sources/FeatureMusic/README.md) | Music browsing, mini-player, queue/now-playing, background audio. |
| [`AppShell`](../Sources/AppShell/README.md) | App state wiring, root navigation, profile selection, provider/registry composition. |

Each module's `README.md` documents its responsibility, public surface, and
invariants. Everything above the provider layer talks to the **`MediaProvider`**
abstraction rather than a specific backend. Jellyfin and Emby intentionally share
one conformer so their supported features remain in lockstep.

## The dual-provider invariant

Plozz treats **Jellyfin and Plex as co-equal, first-class backends**. Any
contribution that touches data, playback, auth, metadata, search, or navigation
must work for **both** — neither is a "phase 2" afterthought. Everything above
the provider layer talks to the `MediaProvider` protocol rather than a specific
backend; see [Architecture](#architecture). If a change can only work
for one backend, call that out explicitly in the issue/PR.

## Coding norms

Keep changes focused and match the surrounding style. That's about it — open an
issue if you're unsure whether something's a good fit before investing a lot of
time.
