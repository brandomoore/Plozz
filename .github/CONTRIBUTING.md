# Contributing to Plozz

Plozz is a free, open source media client for Apple TV, iPhone, and iPad.
**One PR, one focused change:** make it easy to understand, reproduce, and verify.

## Development pipeline

- Discuss substantial features or architectural changes before implementation.
- Submit one bug fix, feature, or refactor with its tests and documentation.
  Split independently useful changes; leave unrelated cleanup, formatting,
  dependency upgrades, and features for separate PRs.
- Follow [coding norms](#coding-norms) and reuse shared behavior rather than
  copying it between providers or platforms.
- Add regression tests that fail without the fix, including relevant failure
  and cancellation paths. Build and test affected platforms and sources using
  the [smallest meaningful checks](#tests).

### Design and UX

Design and UX are my favorite parts of building Plozz, and I care a lot about
helping shape their direction. Thoughtful improvements are very welcome, and
there's plenty still to refine. I'm happy to embrace a better solution, but not
every design will be the right fit. For bigger redesigns, sharing an idea or
mockup early can help avoid spending time on an approach I might take in a
different direction.

For settings changes, see [Settings copy and placement](../docs/swiftui-guidelines.md#settings-copy-and-placement)
for examples of plain rows, group footers, and explanations that belong with a choice.

Hero and tab-navigation continuity rules are part of the UX contract: read the
[SwiftUI guidelines](../docs/swiftui-guidelines.md#hero-continuity) before
changing hero artwork, wordmark reveals, action rows, or tab root requests.
Those changes need rendered/hosted coverage and a device check, not only a
compile.

### Before opening a PR

Review the final diff yourself. **Independent agent review before submission
is strongly recommended**, including for human-written code. Check correctness,
regressions, provider/platform assumptions, and test gaps; resolve or explain
findings. No specific tool/model is required. Agent review does not replace
tests or author responsibility. See [agent guidance](../AGENTS.md).

Complete the [PR template](pull_request_template.md): explain the outcome,
affected sources/platforms, [verification](#tests), and review status. Include
screenshots or recordings for visible changes. Keep evidence current and
address CI failures before requesting merge.

Keep defects from active, unreleased work in its current task or existing issue.
Do not open a new bug issue merely to fix or commit them. A branch push, main
merge, or local installation is **not delivery**.

## Supported sources

Plozz has [seven provider kinds](../Sources/CoreModels/ProviderKind.swift),
not just Jellyfin and Plex. Shares and IPTV each group several protocols:

| Source family | Supported sources |
| --- | --- |
| Media servers | Jellyfin, Plex, Emby, Silo |
| Music server | Navidrome / Subsonic / OpenSubsonic (music-only; development/TestFlight) |
| Network shares | SMB, WebDAV, NFS, SFTP, FTP |
| IPTV | M3U playlists and Xtream accounts; XMLTV guides |

**Jellyfin and Plex are co-equal backends.** Use `MediaProvider` above the provider
layer and respect capability differences. Emby shares Jellyfin's implementation
but still needs compatibility coverage.

For shared auth, browsing, metadata, playback, or watch-state changes, cover
Plex/Jellyfin and every other affected provider, including mixed sources where
relevant. Use deterministic fixtures and authorized live-server checks when
server behavior matters. Disclose unavailable combinations and request
maintainer validation. One server's success does not prove another works;
a tvOS pass does not establish iPhone/iPad behavior.

## Reporting bugs & requesting features

Search [open and closed issues](https://github.com/brandomoore/Plozz/issues?q=is%3Aissue)
and discussions before [filing a report](https://github.com/brandomoore/Plozz/issues/new/choose).
Reuse matching issues; distinguish related problems and post-release regressions.

- **Bug report:** describe expected and actual behavior, reproduction steps when
  known, affected media source, app version/build, and device/OS.
- **Feature request:** explain the problem and intended outcome.
- **Translation correction:** include the language, screen, current wording, and
  suggested correction.

Never include passwords, tokens, or credentialed URLs in reports or attachments.
New bug issues are for problems affecting distributed builds (including
TestFlight), unless a maintainer requests one; feature requests can precede code.

## Commit issue references

Reference existing issues in the fixing commit itself with `Refs #123`
(`Refs owner/repo#123` across repositories), not just in the PR.
For app changes, never use closing keywords (`Fixes`, `Closes`, `Resolves`).
The watcher closes a declared complete fix when it reaches `main` and tells
reporters it is coming in the next TestFlight. Closure does not mean delivery.
When the whole report is implemented, add one trailer per issue:

```text
Fix episode detail entry

Refs #177

TestFlight-Issue: 177 [tvOS]
```

Platforms: `tvOS`, `iOS`, or `tvOS,iOS` (`iOS` includes iPad). Partial fixes use
only `Refs`; reopened issues need a new declaration. Never use
`TestFlight-Fix: #...`: GitHub treats it as an immediate closing reference.
Branch pushes, pull requests to `main`, and the local main-landing hook check
incoming declarations without API access. Run the same check locally with
`python3 tools/testflight-resolutions.py --lint origin/main HEAD`. An existing
quarantine does not block unrelated changes. If two branches declare the same
issue independently, integrate both and declare the complete fix on that history.

The [delivery watcher](../docs/discord-bridge.md#delivery-gated-issue-resolution)
posts the build number on the closed GitHub issue and archives linked Discord
reports only after verifying external availability on every affected platform.
Non-app issue closure remains maintainer-managed.

### Preserving contribution credit

When adopting another person's work, preserve the original human author and
co-author attribution, source PR/issue references, and copyright/license notices.
Keep attribution with the change, not only in a PR comment or the README:

- Preserve authorship when merging or cherry-picking; use `git cherry-pick -x`
  to retain the original commit reference.
- For an adaptation or squash, carry forward the relevant `Refs #N` lines,
  identify the original author and source commit, and retain applicable human
  `Co-authored-by` trailers. State which part was adopted; do not imply that an
  entire PR was accepted when it was not.
- If a published commit omitted attribution, add a follow-up record linking
  the original contribution and its integration. Do not silently rewrite
  published history to repair credit.

Update [CONTRIBUTORS.md](../CONTRIBUTORS.md) for newly credited contributors and
adapted work. Its persistent source references complement Git history; they
do not replace it. The app-delivery issue rules above still apply.

## Building & running

### Requirements

- macOS and [CI's Xcode/SDK](workflows/ci.yml): currently Xcode 27
  (`xcode-27` runner). Deployment targets are iOS/tvOS 18.0.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.

### Generate the project and run

```bash
tools/generate-project.sh
open Plozz.xcodeproj
```

Run **Plozz** (tvOS) or **PlozziOS** (iOS/iPadOS) on an installed simulator.
`project.yml` and `Package.swift` are authoritative: use the wrapper, not bare
XcodeGen; never commit the generated project. Regenerate after source-file moves,
additions, or removals.

Normal builds need no Java disc runtime. See
[disc navigation](../docs/playback-engines.md#native-only-distribution-and-experimental-local-builds)
for experimental local-only builds.

Optional credentials go in gitignored `Config/Secrets.local.xcconfig`;
[defaults](../Config/Secrets.xcconfig) describe the keys. Missing registrations
disable those integrations, not the basic build. Never commit signing material.

### Build and deploy to a device

Use your own signing team and device; read deployment scripts' `--help` and
override maintainer-specific device IDs. [Isolated branch builds](../docs/per-branch-builds.md)
have no cloud sync and need fresh sign-in. Respect the
[build lease](../docs/apple-maintenance-windows.md); never disrupt another build
or clear shared caches to recover a failure.

### Unsigned self-build IPAs

```bash
tools/build-unsigned-ipa.sh ios   # iPhone and iPad
tools/build-unsigned-ipa.sh tvos  # Apple TV
```

Stage new source files first: these commands snapshot tracked working-tree files.
Outputs and provenance stay under `.build/unsigned-ipa/<platform>/run-*`;
the commands do not sign, install, upload, or release. Alternatively, run
[Unsigned IPA](workflows/unsigned-ipa.yml) in your fork with an available
Xcode 27+ macOS runner; the default `xcode-27` image may be unavailable.

**Unsigned IPAs need signing**, including embedded frameworks and the tvOS
extension. The separate **Plozz Self-build** app omits private metadata/OAuth
registrations, crash reporting, iCloud, push, associated domains, shared Top
Shelf data, and tvOS household-keychain access. Expect fresh sign-in and local
settings. Playback and license notices remain intact; packaging does not
establish licensing or patent clearance.

### Tests

Start with changed behavior; expand for shared-code risk or failures:

```bash
tools/run-tests.sh CoreModelsTests ProviderPlexTests  # selected package suites
tools/run-focus-tests.sh -only-testing:PlozzFocusTests/DetailPrimaryFocusHostedTests
```

The package runner takes test target names; omitting them runs its full matrix.
Both examples target tvOS simulators. iOS presentation coverage is separate;
see the [testing policy](../docs/testing-policy.md) for runners and selection.
Do not use desktop `swift test` for this Apple-platform package.

Changes to hero first paint, shared animation, or cross-tab navigation state
need a regression that exercises the surface (rendered/hosted fixture or an
app-hosted interaction), plus a manual device/simulator recipe. A guard that
only scans source text is not behavior coverage.

Report exact commands and pass/fail/skip results, plus a short manual recipe:
source, OS/device or simulator, settings, steps, and expected/actual behavior.
List untested combinations. Distinguish fixtures from live servers, simulators
from hardware, and compilation from behavior. Docs-only changes need no app build.

### Screenshots

See [screenshots](../docs/screenshots.md) for fixtures and capture commands.

### Performance debugging

Use the [performance lab](../docs/performance-lab.md) and
[profiling guide](../docs/performance-debugging.md). Measure the same workload
before and after; test duration alone is not app-performance evidence.

### Localization

Finalize UI and source wording with the maintainer before translation work.
Follow [source-string rules](../docs/localization.md) and the
[reviewed translation pipeline](../docs/translations.md). Do not hand-edit
translations or advance the source snapshot before checks finish.

### Releasing to TestFlight

Maintainer-authorized only, with approved notes for the exact candidate. Follow
[release identity and delivery](../docs/release-versioning.md); merging is not
releasing, and uploading is not external tester availability.

## Architecture

The [Swift package](../Package.swift) owns shared libraries and UI; app shells
stay thin. Start with the relevant owner:

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

## Coding norms

Follow the [Swift/SwiftUI guidelines](../docs/swiftui-guidelines.md) and existing
module ownership. Preserve profile/account boundaries, native accessibility,
and platform availability gates. Keep credentials out of code, logs, and test
fixtures. Update the documentation that owns the changed behavior.
