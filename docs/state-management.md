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

- **Home**: silent revalidation on every app foreground return; in-app navigation
  retains a 15-second absence gate. See [refresh and watch state](feature-home/refresh-and-watch-state.md).
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

## Home first paint and refresh retention

Home renders from a persisted snapshot before the network answers, and the rules
that keep that first paint stable are part of the contract, not incidental
polish. Measured regressions these rules exist to prevent: a hero that paints
then blanks to its no-image cover, a carousel that collapses from eight slides
to three and reseats, and a Continue Watching row that empties under the viewer.

- **Skeleton only without a snapshot.** `PlozziOSHomeView` paints the full-page
  skeleton only when `HomeViewModel.hasPersistedSnapshot` is false. With a
  snapshot on disk the page paints it on the frame it appears. Never gate this on
  elapsed time.
- **A fold never takes the loud path.** A `reloadHome` that arrives at
  `.idle`/`.loading`/`.failed` against a page that has already shown content
  refreshes silently (`load(showLoadingState: false)`), so the settled rows and
  hero stay on screen until replacements are ready.
- **Empty results are not evidence.** A per-account aggregate, a hero curation,
  or a snapshot write that returns nothing cannot clear content that is already
  shown. The row keeps its cards until a completed load says otherwise, and
  `HomeSnapshotPersistence` preserves the previous Continue Watching row when the
  new one is empty because other rows succeeded (that write is not an empty
  aggregate, so nothing else would have stopped it).
- **Snapshots are not pruned on unknown state.** `HomeViewModel.init` only
  prunes for an empty account list once accounts have resolved *and* a live load
  has completed; before that, an empty list means "not loaded yet", and pruning
  there (including `scheduleSnapshotClear`) destroyed the snapshot the next launch
  paints from.
- **Hero stability.** `heroItems` is replaced only by a non-empty curation, the
  visible set keeps `.unrestricted` eligibility until `hasCompletedLiveLoad`, and
  the slide is reseated by title identity so a copy arriving with a new id does
  not move the viewer. A decoded image is applied synchronously on first paint and
  art is retained across a reference change.
- **Continue Watching is not gate-kept behind the aggregate.** Cached cards stay
  painted while the fresh multi-account result lands, and a row that already holds
  cards is never re-marked as loading: `HomeViewModel` seeds `loadingRows` in
  `init` and in every `receiveProgress` from the **data** each row currently has,
  not from the account list. Measured regression: a row with 48 cached cards
  rendered as placeholders on the first frame and again for ~2.4 s mid-load,
  which is what "starts blank, scroll shows the covers" looked like.

These paths carry opt-in telemetry (`HOMESEED`, `HOMEFRAME`, `HEROFRAME`,
`HOMECAROUSEL`, `HEROARTREF`, `HOMECW`, `DETAILVIEW`, `DETAILRAIL`,
`DETAILRETURN`). It is silent unless the process is launched with
`PLZXFAN_STDOUT=1`; the lines print counts, kinds and hashes, never titles, ids or
URLs.


## Detail opening pipeline

Every detail page uses the same three-stage load, and the third stage is what makes
an open feel slow:

1. **Subject** — `provider.item(id:)`.
2. **Children** — `provider.children(of:)` for container kinds.
3. **Chosen child's content** — e.g. a season's episodes.

The third stage must not wait for the view to publish a selection.
`DetailOpeningSelection.openingSeasonID(children:resumeSeasonID:)` (CoreModels)
decides which child opens first for **every** container kind — resume season when
the server still lists it, otherwise the first season; `nil` for a season page
(its children already are the rail) and for leaves. `ItemDetailViewModel` prefetches
that child as soon as the children arrive, and the rail's own `loadEpisodes` then
finds the episodes in hand instead of starting a second request behind the first.

Rendering follows the same rules as Home: geometry is reserved with
`PlozzReservedPlaceholder` (CoreUI) so the page never jumps when cards land, and
the placeholder is state-driven — never a timer. Latency is measured, not guessed:
`DETAILVIEW`/`DETAILRAIL`/`DETAILCARDS` carry monotonic `t=` timestamps under
`PLZXFAN_STDOUT=1`, so the open cost is visible end to end.

Surfaces that read from more than one account go through `Fanout` (CoreModels)
rather than their own loop: one source takes the fast path (single await, single
publication), several sources merge in source order with explicit completeness.
That is what keeps a one-server install from rendering differently than a
multi-server one.

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
