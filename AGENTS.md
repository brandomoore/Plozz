# Agent guidance

Plozz welcomes agent-assisted development. Contributors are responsible for
understanding, reviewing, and validating their changes, regardless of the tool or
model used. An agent's confidence is not a substitute for evidence.

Start with [CONTRIBUTING](.github/CONTRIBUTING.md) for setup and contribution
workflow. These instructions apply across the repository; keep machine-specific
configuration and credentials out of committed guidance.

## Understand the change

- Read the relevant code and module README before editing. Check the working
  tree and preserve unrelated or uncommitted work.
- For Live TV changes, consult the [IPTV history](docs/iptv-history.md) for
  historical context, not a specification.
- Keep changes focused on the requested behavior. Reuse existing helpers,
  ownership boundaries, naming, and error handling instead of creating a
  parallel implementation.
- Put shared behavior in the appropriate `Feature*Core`, core, or runtime
  module; keep the app shells thin. See the
  [architecture map](.github/CONTRIBUTING.md#architecture).
- Use `MediaProvider` above the provider layer. Jellyfin and Plex are co-equal
  backends; preserve the other supported providers and report intentional
  capability differences rather than silently dropping support.
- Preserve profile, account, server-user, and parental-authorization boundaries,
  including after asynchronous work. Reuse the existing settings models and
  profile-scoped stores for preferences.
- Identify affected platforms and availability gates. Shared Swift source does
  not automatically mean identical behavior on tvOS and iOS/iPadOS.
- Follow the existing native controls, focus behavior, accessibility, and
  reduced-effects fallbacks. Finalize UI behavior and source copy with the
  maintainer before starting translation work.

## Where code goes

- Shared behavior belongs in `CoreModels`, the relevant `Feature*Core`, or
  `AppRuntime`. Keep app shells thin.
- Views live in `Feature*`; view models, coordinators, and policies live in
  `Feature*Core`.
- One primary model per new file. Tightly related value types that form a single
  vocabulary may share it; do not scatter one concept across many files.
- Tests mirror the module. Shared fixtures and harnesses live in
  `Tests/TestSupport*`.
- Follow the [Swift/SwiftUI guidelines](docs/swiftui-guidelines.md) and the
  [state-management scaffold](docs/state-management.md).
- Do not add ad-hoc foreground/background refresh decisions to view bodies; use
  the shared coordinator and platform profile.

## Swift/SwiftUI norms

- Use `@Observable` with `@MainActor` for new shared UI state. Use `@State` for
  ownership and `@Bindable`/`@Environment` for passing.
- Do not add new `ObservableObject`, `@Published`, `@StateObject`,
  `@ObservedObject`, or `@EnvironmentObject`.
- Prefer modern Swift concurrency and Foundation APIs; do not add GCD or legacy
  user-facing formatters.
- Use the shared theme and metrics. Do not add hard-coded font sizes, padding, or
  stack spacing without a design reason.
- Use the state/lifecycle coordinator instead of view-local refresh logic.
- Tests use named constants or shared fixtures. The owner of a formatted value
  owns the literal assertion; unrelated tests reference the owner.
- Comments explain why and invariants. Do not duplicate current formatted output
  in comments or tests; reference the owning symbol instead.
- Keep PRs focused. A shared format/helper change should touch the owner and call
  sites, not unrelated comments.

## Build and verify

Use `tools/generate-project.sh`, not bare XcodeGen. `project.yml` and
`Package.swift` are the source of truth; do not commit the generated Xcode project.
Use the supported toolchain and simulator runners described in
[CONTRIBUTING](.github/CONTRIBUTING.md#building--running) and
[CI](.github/workflows/ci.yml).

Select the smallest checks that cover the actual risk using
[the testing policy](docs/testing-policy.md). Add regression coverage for changed
behavior, check affected platforms and providers, and expand coverage when the
evidence requires it. Do not describe a focused run, skipped test, or missing
result as a full pass.

For performance work, measure the real workload before and after under comparable
conditions. Explain CPU, memory, I/O, and cancellation tradeoffs; a benchmark must
complete its intended work to count. Use the
[performance lab](docs/performance-lab.md) and
[debugging guide](docs/performance-debugging.md), not timing guesses or unbounded
background probes.

For localization, follow [source-string rules](docs/localization.md) and the
[reviewed translation pipeline](docs/translations.md). Do not hand-edit the string
catalog, skip independent translation review, or advance the source snapshot
before the required checks finish.

## Protect users and other work

- Keep secrets out of code, commits, logs, fixtures, and screenshots. Use the
  existing Keychain storage and secret-safe `PlozzLog` conventions.
- Surface errors through the existing typed errors, logging, and UI paths.
  Cancellation is not success; do not hide failures behind success-shaped defaults.
- Bound temporary servers, simulators, and profiling runs. Track resources you
  start and stop only those you own.
- Do not work around a blocked build by deleting unrelated outputs, purging
  shared developer caches, or resetting shared services. Preserve release evidence
  and follow the [build-lease protocol](docs/apple-maintenance-windows.md).
- A code change does not authorize device installation, credential/signing
  changes, merging, or distribution. Obtain explicit authorization for those
  actions. TestFlight/App Store delivery also requires approved notes for the
  exact candidate; follow [release identity and delivery](docs/release-versioning.md)
  and the existing release pipeline.

## Hand off clearly

Before committing issue-related work, follow the
[commit issue-reference requirements](.github/CONTRIBUTING.md#commit-issue-references):
the fixing commit itself must reference the issue, not a separate issue comment.

Follow the issue and pull-request workflow in CONTRIBUTING. Explain the behavior
changed, relevant tradeoffs, checks actually run, and remaining limitations.
Distinguish simulator evidence from physical-device results, uploads from tester
availability, and a suspected cause from a demonstrated fix.

Keep detailed procedures in their existing documents and link to them here
instead of duplicating them.
