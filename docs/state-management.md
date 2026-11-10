# State management and cross-platform coordination

Plozz runs the same feature code on tvOS and iOS/iPadOS, but the platform
lifecycle and user expectations differ. Stateful coordination must be a named
model in a core/runtime module, not a collection of `.task` and `.onChange`
blocks scattered through views.

## Layer ownership

| Layer | Owns |
| --- | --- |
| `CoreModels` | Pure values, policies, protocols. No UI or lifecycle decisions. |
| `Feature*Core` | Observable state models, coordinators, decision logic, platform profiles, harness-facing seams. |
| `AppRuntime` | Process-scoped services, lifecycle aggregation, other runtime seams. |
| `CoreUI` | Shared presentation and environment injection only. |
| `Feature*` / `AppShelliOS` | SwiftUI wiring, surface registration, view-only state. |
| `AppShell` / `AppShelliOS` roots | Composition, coordinator injection, platform lifecycle adapters. |

Views may own ephemeral presentation state. They may not own cross-screen timing,
platform thresholds, or provider refresh policy.

## Required scaffold for a stateful cross-platform feature

1. **Name the invariant and its owner.** Write down what must remain true and
   which module owns it.
2. **Define a pure policy/profile.** Platform differences (timing, action choice,
   availability) are data, not `#if os` branches in views.
3. **Define a named coordinator or state machine.** It exposes typed events and
   commands and uses a monotonic generation so stale work is rejected.
4. **Inject at the root.** Use `@State` ownership in the app root and
   `@Environment` for shared access.
5. **Register the visible surface.** Only the top/visible surface receives work.
   The view supplies its stable identity, not its timing.
6. **Build a deterministic harness.** Use a fake clock and synthetic lifecycle
   transitions. Do not rely on UI timing or wall-clock sleeps.
7. **Test every platform profile.** The same scenario matrix should run for
   tvOS and iOS behavior.
8. **Update the owning module README and this document** when behavior or
   invariants change.

## Content refresh coordinator

`ContentRefreshCoordinator` in `FeatureHomeCore` is the reference implementation.

- `ContentRefreshProfile` owns the tvOS/iOS timing and action mapping.
- `ContentRefreshSurfaceID` keeps profiles, accounts, and detail pages apart.
- Views call `.contentRefreshSurface(...)` with a stable identity and visibility.
- `ContentRefreshLifecycleReader` translates app activation into coordinator
  events. UIKit notifications are used instead of relying on a coalesced
  SwiftUI `scenePhase` change across suspend/resume.
- The coordinator emits an action only for the top surface.

### Refresh behavior

- **Home**: silent, staleness-gated reload.
- **Series detail**: re-fetch the item, seasons, and server resume episode. The
  series page may re-resolve its opening season when the viewer did not
  explicitly choose one.
- **Episode detail**: update watch state only. Do not reload children, change
  seasons, or navigate. The parent series page refreshes when it is revealed.
- **Explicit season choice**: preserve a season the viewer deliberately chose.

Do not add a second foreground-refresh mechanism beside the coordinator.

## Test constants and fixtures

Repeated test values belong in constants or shared fixtures:

- lifecycle durations (`shortAway`, `longAway`, thresholds),
- surface identities and expected actions,
- item/account IDs and season/episode numbers,
- shared expected labels.

Shared fixtures and harnesses live in `Tests/TestSupport*` so multiple suites can
reuse them. A formatted value's owner test owns the literal assertion; other
tests use the formatter or the fixture constant. Use an independent test
constant when the production behavior is what the test is verifying.

## Comments and single-source-of-truth values

Comments explain why and what must remain true. They do not restate the current
formatted output. When the exact text matters, name the owner (for example
`MediaItem.seasonEpisodeLabel`) or the owner's test.

A shared format change should edit the owner and its test, not every call site
comment or unrelated test that happens to quote an example. If a small format
change expands into dozens of files, fix ownership before changing the format.

## Pull-request scope

- One owner change plus call-site substitutions.
- Do not update unrelated comments merely to restate a new value.
- Split rules/documentation work from feature work.
- Keep generated Xcode projects and unrelated files out of the diff.
