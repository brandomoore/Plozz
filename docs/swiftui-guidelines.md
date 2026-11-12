# Swift and SwiftUI guidelines

This document is the repository-specific version of the usual Swift/SwiftUI
agent guidance. The source of truth for the supported OS versions and toolchain
is `Package.swift`, `project.yml`, and CI.

## Repository layout

```text
App/Plozz/              tvOS app shell
App/PlozziOS/           iOS app shell
Sources/CoreModels/     pure domain models, policies, protocols
Sources/CoreNetworking/ HTTP, endpoints, secret-safe logging
Sources/CoreUI/         shared presentation and environment keys
Sources/Provider*/      provider clients and MediaProvider conformers
Sources/Feature*Core/   feature state models, coordinators, pure logic
Sources/Feature*/       SwiftUI views for that feature
Sources/AppRuntime/     process-scoped services and lifecycle
Sources/AppShell/       tvOS composition root
Sources/AppShelliOS/    iOS composition root
Tests/<Module>Tests/    module tests
Tests/TestSupport*/     shared fixtures, harnesses, network doubles
docs/ tools/
```

- Shared behavior belongs in `CoreModels`, a `Feature*Core`, or `AppRuntime`.
  App shells stay thin.
- One primary model per new file. Tightly related value types that form a single
  vocabulary may share it; do not split unrelated legacy files just for style.
- Views belong in `Feature*`; view models, coordinators, and policies belong in
  `Feature*Core`.
- Tests mirror the module, and shared fixtures live in `TestSupport*`.
- `project.yml` and `Package.swift` are authoritative. Never commit the
  generated Xcode project.

## Swift

- Use `@Observable` for new shared state. New UI-facing observable models must be
  `@MainActor` unless they are intentionally background services or actors.
- Use `@State` for ownership, `@Bindable` for bindings, and `@Environment` for
  passing shared dependencies.
- Prefer Observation over new `ObservableObject`/`@Published` models. Retain
  framework-required Combine/ObservableObject bridges at the adapter boundary.
- Prefer async/await and structured concurrency. Own and cancel unstructured
  tasks; retain GCD only where an API or measured native ordering requires it.
  Use `Task.sleep(for:)`, and respect cancellation.
- Avoid force unwraps and force `try` except at documented unrecoverable
  boundaries.
- Use modern Foundation where it fits: `FormatStyle` for user-facing dates and
  numbers, `URL.documentsDirectory`, `appending(path:)`, and
  `localizedStandardContains` for user-entered filtering.
- Follow `docs/localization.md` for user-facing formatting, including localized
  plural/placeholder conventions. Technical encodings and diagnostics may use
  `String(format:)`.
- Do not introduce third-party frameworks without asking first.
- Never commit secrets.

## SwiftUI

- Prefer modern SwiftUI APIs within the supported availability gates; preserve
  established native navigation/focus wrappers instead of replacing them for style.
- Use the two-parameter `onChange` variant.
- Use `Button` instead of `onTapGesture` unless tap location/count is required.
- Use `scrollIndicators(.hidden)` and modern ScrollView positioning APIs where
  they fit.
- Do not use `UIScreen.main.bounds` or add new hard-coded font sizes, padding, or
  stack spacing. Use the shared theme and metrics.
- Prefer dedicated `View` structs for complex or reusable subviews. Small,
  single-use private computed fragments are acceptable.
- Avoid new `AnyView` unless a documented type-erasure/module boundary requires
  it.
- Use `ImageRenderer` for SwiftUI output and UIKit renderers for UIKit surfaces;
  select the renderer that preserves the actual platform rendering contract.
- Avoid `GeometryReader` when a newer layout primitive works. Do not refactor
  existing uses gratuitously.
- Add `#Preview` where the target is previewable and the view renders in
  isolation. tvOS-only or fixture-dependent views may document the hosted
  fixture instead.
- Move view logic into view models or coordinators. Views register, render, and
  call typed actions.

## State and lifecycle

For cross-screen state coordination, follow [state management](state-management.md):

- a pure policy/profile for platform differences,
- a named coordinator/state machine for decisions,
- root injection and surface registration,
- a deterministic harness with a fake clock,
- tests for each platform profile.

Do not add ad-hoc foreground/background refresh logic to view bodies.

## Tests

- Use named constants or shared fixtures for repeated test values, thresholds,
  surface IDs, item IDs, and expected actions.
- Keep shared fixtures in `TestSupport*`; do not copy them per target.
- Keep formatting assertions at the formatter's boundary, plus independent
  integration assertions where rendering the correct value is the contract.
- Do not derive an expected value from production code when the production
  behavior is what the test is verifying; use an independent named constant in
  that case.
- Unit tests cover decisions; hosted tests cover rendering, focus, lifecycle
  delivery, and SwiftUI task ownership that a pure harness cannot exercise.

## Comments

- Comments explain why, invariants, and tradeoffs.
- Do not duplicate current formatted output in comments. Name the owner instead,
  for example `MediaItem.seasonEpisodeLabel`.
- Keep literal examples in the owner's documentation or test.
- A shared format change should update the owner and its test, not dozens of
  unrelated comments/tests.

## Pull requests and tools

- Keep the diff focused. Do not update unrelated comments just to restate a new
  value.
- Use `tools/generate-project.sh`, and never commit `Plozz.xcodeproj`.
- Run the smallest covering checks with `tools/run-tests.sh` or
  `tools/test-fast.sh`; do not use `swift test` for this package.
- Run SwiftLint if it is configured for the checkout.
- Follow the issue-reference and TestFlight trailer rules in
  [CONTRIBUTING](../.github/CONTRIBUTING.md).

## Not imported from generic guidance

- A generic `Sources/Features/...` tree.
- SwiftData rules; this repository does not use SwiftData.
- “Every view file must include `#Preview`.”
- “Never use `String(format:)`.”
- “Never use UIKit.”
- “Never use computed properties for subviews.”
- Any change to deployment targets, package tools version, or language mode in
  feature work.
