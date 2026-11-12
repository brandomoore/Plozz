# State management and cross-platform coordination

Plozz shares feature logic across tvOS and iOS/iPadOS, but lifecycle and
presentation differ. Give cross-screen coordination a named owner; keep
view-local presentation state local rather than introducing a coordinator for
every control.

## Layer ownership

| Layer | Owns |
| --- | --- |
| `CoreModels` | Domain values, policies, protocols and shared stores. |
| `Feature*Core` | Observable state models, coordinators, decision logic, platform profiles, harness-facing seams. |
| `AppRuntime` | Process-scoped services, lifecycle aggregation, other runtime seams. |
| `CoreUI` | Shared presentation and environment injection only. |
| `Feature*` / `AppShelliOS` | SwiftUI wiring, surface registration, view-only state. |
| `AppShell` / `AppShelliOS` roots | Composition, coordinator injection, platform lifecycle adapters. |

Views may own ephemeral presentation state. They may not own cross-screen timing,
platform thresholds, or provider refresh policy.

## Cross-platform coordination

1. **Name the invariant and its owner.** Write down what must remain true and
   which module owns it.
2. **Separate policy from adapters.** Share timing and action decisions; keep
   platform APIs and availability checks in their adapters.
3. **Define a named coordinator or state machine.** It exposes typed events and
   commands. Cancel superseded work and recheck captured profile/account/source
   identity after suspension. A generation counter alone does not fence results.
4. **Inject at the root.** Use `@State` ownership in the app root and
   `@Environment` for shared access.
5. **Register the visible surface.** Only the top/visible surface receives work.
   The view supplies its stable identity, not its timing.
6. **Build a deterministic harness.** Use a fake clock and synthetic lifecycle
   transitions. Do not rely on UI timing or wall-clock sleeps.
7. **Test every platform profile.** The same scenario matrix should run for
   tvOS and iOS behavior.
8. **Update the owning module README** when behavior or invariants change.

## Content refresh coordinator

`ContentRefreshCoordinator` in `FeatureHomeCore` is the reference implementation.

- `ContentRefreshProfile` owns the tvOS/iOS timing and action mapping.
- `ContentRefreshSurfaceID` identifies the content. Each mounted page owns a
  separate registration, so repeated pushes of the same title remain distinct.
- Profile changes invalidate pending requests and re-register retained pages.
  The root remains responsible for replacing profile-scoped feature models.
- Views call `.contentRefreshSurface(...)` with a stable identity and visibility.
- `ContentRefreshLifecycleReader` translates app activation into coordinator
  events. UIKit notifications are used instead of relying on a coalesced
  SwiftUI `scenePhase` change across suspend/resume.
- The coordinator emits only to the top visible surface. Its modifier uses a
  cancellable `.task(id:)`; hiding, replacing, backgrounding, or resetting a
  surface invalidates that task. Models also fence late provider responses.
- Home's existing model-owned aggregation remains coalesced across view-task
  cancellation; profile invalidation and its model generation still fence that
  work. Cancelling a surface request does not replace that ownership contract.
- Elapsed time uses a monotonic clock. Repeated lifecycle/visibility callbacks
  are idempotent, and hidden registrations live with their pages, not in an
  unbounded global history.

### Refresh behavior

- **Home**: silent, staleness-gated reload after at least 15 seconds away.
- **Series detail**: re-fetch the item, seasons, and server resume episode. The
  series page may re-resolve its opening season when the viewer did not
  explicitly choose one.
- **Episode/movie detail**: update watch state only. Do not reload children, change
  seasons, or navigate. The parent series page refreshes when it is revealed.
- **Explicit season choice**: preserve a season the viewer deliberately chose.
- Detail return refreshes use a five-minute absence threshold on both platforms.
  Brief interruptions and first appearance do not duplicate initial loading.
- Failed or cancelled series refreshes retain existing resume/season context.
  A successful empty resume response clears the old target. This is separate
  from playback-return and local watch-mutation handling.

Do not add a second foreground-refresh mechanism beside the coordinator.

## Test constants and fixtures

Use named constants for repeated behavioral boundaries and shared fixtures when
multiple suites need the same scenario:

- lifecycle durations (`shortAway`, `longAway`, thresholds),
- surface identities and expected actions,
- item/account IDs and season/episode numbers,
- shared expected labels.

Shared fixtures and harnesses live in `Tests/TestSupport*`; a single-suite helper
can stay in that suite. Keep expected behavior independent of the production
implementation. Boundary and integration tests may repeat a literal when that
literal is the contract under test; avoid circular assertions against the same
formatter being exercised.

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
