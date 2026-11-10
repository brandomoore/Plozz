# Incremental architecture and efficiency roadmap

Status: proposed; implementation batches require selection.
Research snapshot: November 10, 2026, source commit `31a2be726`.

## Recommendation

Keep Plozz's current feature/core/provider/platform boundaries. Improve the
ownership and discoverability of behavior inside them, one bounded change at a
time. Do not start with a new folder hierarchy, a new architecture framework, or
a wholesale rewrite.

The goals are to reduce the context needed to make a correct change, make
maintenance safer, and preserve or measurably improve performance. These are
related but distinct: smaller files do not automatically mean fewer agent
tokens, faster builds, or a faster app.

The first investment should be a better route into existing code and docs,
followed by a detail-source-selection pilot. Later work earns its priority
through measured benefit. Each completed batch should leave the app usable;
there is no requirement to finish the entire roadmap.

## What the evidence says

This is a targeted assessment, not an exhaustive audit or a fresh performance
baseline. File lengths include comments and blank lines. Recent-change counts
are appearances in the checked-out Git history over 30 days, not measures of
defect rate or independent user changes.

| Observation at the research snapshot | Implication |
| --- | --- |
| `Sources` contains 1,817 Swift files, about 500,000 lines, and 54 immediate directories. | A repository-wide reshuffle would have substantial cost. Scope by behavior, not by a global style rule. |
| Mobile detail is 4,206 lines; `ItemDetailViewModel` is 3,480. They appear in 60 and 20 recent commits respectively. | Detail is a practical ownership pilot: important, frequently touched, and now covered by return-refresh regressions. |
| Mobile Home is 3,761 lines; `HomeViewModel` is 2,926. Mobile Home appears in 72 recent commits. | Home is a candidate for dependency and update-cost work, but needs profiling before choosing an optimization. |
| `PlozziOSAppModel` is 3,929 lines; `PlayerViewModel` is 3,572. | These are discovery candidates, not instructions to split them immediately. Both own sensitive lifetimes and already delegate some work. |
| Home and playback module READMEs are 1,850 and 2,383 lines. Their "Where to look first" sections are near the end. | Improve navigation and move detailed topic material out of the default reading path without losing invariants. |
| The refresh investigation found a stale view-owned source snapshot overwriting current movie progress. | Removing duplicate authority can reduce both bugs and the amount of code a maintainer must reason about. |
| The repository already has architecture checks, test-impact selection, deterministic harnesses, and a substantial performance lab. | Extend these only where a specific gap exists; do not build a parallel framework. |

Evidence anchors:
[module map](../.github/CONTRIBUTING.md#architecture),
[package boundaries](../Package.swift),
[detail model](../Sources/FeatureHomeCore/ItemDetailViewModel.swift),
[mobile detail](../Sources/AppShelliOS/PlozziOSItemDetailView.swift),
[Home model](../Sources/FeatureHomeCore/HomeViewModel.swift),
[mobile app model](../Sources/AppShelliOS/PlozziOSAppModel.swift),
[player model](../Sources/FeaturePlayback/PlayerViewModel.swift).

## Research translated into decisions

| Guidance | Plozz application |
| --- | --- |
| Apple: measure a symptom, attribute it, change the cause, then remeasure. [1][2] | A structural cleanup can be successful without a speedup, but cannot be called a performance improvement without comparable evidence. |
| Apple: narrow view dependencies and avoid expensive work during `body`; extracting a view can help when it changes those dependencies. [1][2] | Extract real presentation boundaries, not merely computed fragments into extra files. Preserve identity, focus, and task lifetime. |
| Observation tracks properties read during evaluation, including reads through computed properties. [3] | A large observable type is not automatically a broad-invalidation bug. Inspect actual reads and update traces before changing observation. |
| Swift: clarity at the point of use matters more than brevity. [4] | Use behavior-specific names and small interfaces. Do not replace explicit dependencies with a generic service locator just to shorten initializers. |
| Apple: structured concurrency makes lifetime relationships clearer; cancellation remains cooperative. [5] | Extract asynchronous ownership only with explicit cancellation, identity fencing, and teardown tests. Do not mechanically replace every retained task. |
| Apple: build speed depends on dependency edges and the critical path. [6] | Do not assume more SwiftPM targets are faster. Measure incremental builds before changing the package graph. |
| GitHub supports repository-wide and path-specific guidance, with client-dependent support. [7] | Keep entry guidance short and link to topic owners. Add scoped instructions only if supported and useful, not copies of existing policy. |

The expected token benefit from clearer ownership is a hypothesis to measure,
not a published percentage established by these sources.

## Ordered work queue

### A. Navigation and measurement baseline — first

**A1: Make Home easy to enter.** Put a concise ownership/task/test map at the
top of `Sources/FeatureHome/README.md`. Move detailed topic sections into
behavior-named companion documents only where that shortens typical reading.
Retain an index and old heading destinations where existing links depend on
them. Keep authoritative rules in their existing owner, not in this roadmap.

Start with Home only. Apply the pattern to playback, CoreUI, or settings after
the pilot demonstrably helps. Do not mass-rewrite prose or delete hard-won
failure-mode documentation.

**A2: Record a small baseline.** Use representative tasks such as tracing a
detail Play target, finding a Home refresh rule, and locating a settings
preference's persistence and UI owners. Record the necessary files, source/doc
bytes read, search/read calls, relevant test command, and elapsed investigation
time. Use actual token usage if available; byte/line counts are only proxies.
No application behavior changes in this batch.

**Done when:** a reader can identify the owner and covering checks from the
entry map without reading the whole module guide; moved links resolve; a
baseline record exists. Do not claim token savings from document size alone.

**Pilot status:** A1 is complete: the [Home entry map](../Sources/FeatureHome/README.md#where-to-look-first)
links code owners, behavior sections, and regression files. Detailed contracts
are retained in six topic guides, with the old README heading destinations
preserved. A2 has a [reproducible bounded-retrieval baseline](feature-home/navigation-baseline.md)
for all three discovery tasks. The entry is smaller, but total documentation is
slightly larger; token savings and end-to-end investigation time remain
unmeasured. Capture those during the code pilot before extending the pattern
to other modules. This batch changes no application behavior.

### B. Detail source selection and Play target — first code pilot

**B1: Characterize the current contract.** Trace and document the division
between `DetailOpenEnvironment`, `DetailPlaybackSelection`,
`ItemDetailViewModel.playbackSources`, `MediaItem` routing, and
`AppRuntime/PlaybackSourceSelection`. Reuse their existing tests. Add missing
cases only: same item ID on different accounts, same-account editions,
unavailable sources, clearing progress, source changes during async work, and
series-to-episode targeting.

**B2: Reduce duplicate orchestration.** Give detail source state one explicit
owner in the existing feature-core boundary and let TV/mobile consume its
typed result. Reuse existing selectors rather than inventing a second routing
engine. If the owner already exists, consolidate callers instead of adding a
new object. Keep identity-index/account availability adaptation in its current
runtime layer; do not create an upward dependency from feature core.

Separate source-selection policy from unrelated ratings, trailers, downloads,
and view layout. Preserve provider-native playback IDs and intentional
cross-source resume semantics. A later extraction of series resume ownership
is a separate batch, not part of this first change.

**Pilot implementation:** the trace found existing state ownership and shared
selection primitives, not a need for another coordinator. The bounded change
consolidates the repeated source/version/Play composition in
`DetailPlaybackSelection.resolve`, consumed by TV item detail and mobile detail.
The [selection ownership map](feature-home/detail-and-playback.md#selection-ownership)
records the boundaries and the intentional series/platform differences.
No provider, runtime admission, asynchronous source-switch, or series-resume
policy moves. Regression coverage characterizes the composed result as well as
the existing primitive rules. Fewer duplicated decisions are a maintenance
improvement; runtime speed and actual agent-token savings are not established.

**Verification:** full TV and mobile simulator app builds passed; independent
review found no significant issues. The two selected package suites recorded
1,601 passes, two failures, and one opt-in skip. Both failures also reproduced
before this change: `HomeRowBrowseTests.testCompleteHistoryAndFailedRowsDoNotOfferBrowse`
and `HomePresentationRowTests.testRetainedNativeRowsImmediatelyHonorDisabledLibraryAndItemVisibility`.
The baseline had 1,596 passes with those same two failures and one skip.
The selection cases passed, but this is not a clean Home-suite or physical-device
playback result. The unrelated failures are not changed by this pilot.

**Done when:** the selected behavior has fewer independently mutable authorities
and a smaller required reading set; TV/mobile use the same policy; account,
edition, watch-state, and cancellation regressions pass. Exercise real mounted
detail views on affected platforms. Use `source-menu-version-presentation` for
covered picker costs; add a focused probe if the changed path is not represented.
Do not treat that picker benchmark as a whole-detail startup measurement.

### C. Home publication and rendering — profile before changing

**C1: Locate an actual cost.** Use the existing `home-row-metadata-updates`,
`home-artwork-layout`, and mobile startup/scroll scenarios as applicable.
Attribute unnecessary work with SwiftUI Instruments and Time Profiler.
Choose one reproducible issue: excessive publication, repeated row derivation,
unnecessarily broad dependencies, or redundant provider work.

**C2: Change just that owner.** Examples include a narrow presentation input,
reusing an unchanged derived row, or coalescing equivalent work. These are
options, not preselected fixes. Avoid another copy of watch state, an unbounded
cache, or a global observation workaround.

**Done when:** the same workload finishes with identical required content and
no identity/focus regressions; relevant CPU, memory, I/O, network, and latency
results are reported separately. A smaller source file is not the performance
acceptance criterion.

### D. Mobile shell and settings boundaries — one feature at a time

Use the existing app-model and settings owners to select one cohesive
responsibility. Prefer a low-risk presentation or preference-wiring slice
before authentication/profile switching. Extract meaningful typed inputs and
actions instead of passing the whole app model everywhere.

Keep genuinely local view state local. Share policy, not necessarily native
TV/mobile navigation. Inspect existing coordinators first. Do not bundle
profile changes, CloudKit lifecycle, navigation, and settings into one refactor.

**Done when:** the selected screen can be understood and mounted with a narrow
dependency set; profile persistence and native interaction behavior are
unchanged. Use the existing settings hosted/interaction coverage and, if
relevant, `mobile-preference-sync` or `mobile-profile-selection`.

### E. Playback lifecycle — later, higher risk

Start with one measured or repeatedly confusing boundary in `PlayerViewModel`.
It already delegates to engine handoff, subtitle, and next-episode owners;
extend or clarify those before introducing another coordinator. Keep playback
attempt identity, progress reporting, stream cleanup, and task teardown
explicit. Do not refactor all engine paths together.

**Done when:** targeted engine/provider tests and mounted playback transitions
pass, with before/after resource-lifetime evidence. Use the relevant
`player-controls-*` scenarios for UI costs; they do not prove decoder, seek,
or real-stream correctness. Live-provider checks are required when transport
or session behavior changes. Physical-device checks require separate approval.

### F. Package graph and build turnaround — only if measured

Capture a no-op build and repeated incremental builds after a representative
leaf implementation change. Inspect Xcode's build timeline and affected
targets. Consider moving a responsibility across module boundaries only when
it improves ownership or a demonstrated build dependency problem.

**Done when:** relevant rebuild scope/time improves or a justified ownership
benefit is documented without unacceptable build cost. Preserve supported
platforms, resource/localization ownership, and dependency direction.
No target-per-file split, automatic module proliferation, or toolchain upgrade.

## Measurement and acceptance

| Goal | Evidence to keep | What does not count |
| --- | --- | --- |
| Less agent context | Matched task prompts, files and bytes read, tool calls, available input/cache token usage; same model/settings and comparable starting context | Total repository lines, one lucky run, or cached-token counts presented as equivalent billing savings |
| Easier maintenance | Clear state owner, smaller interface, fewer files needed for a representative change, focused tests and reviewable diff | Moving all methods into extensions while preserving the same shared mutable state |
| Runtime performance | Existing lab comparison with equal work counts, latency distribution, CPU, peak/retained memory and I/O/request counts | Debug build duration, simulator wake-up gaps described as device FPS, or benchmarks that did less work |
| Build efficiency | Same machine/toolchain/configuration, repeated comparable incremental builds, dependency timeline | A warmed candidate compared with a cold baseline |
| Correctness | Relevant providers/platforms, identity/profile fencing, error and cancellation cases, hosted tests where needed | A compiler pass alone or treating skipped live checks as passes |

Use [the performance lab](performance-lab.md) and its existing comparison
budgets, repetitions, environment checks, and work-count invariants. If no
appropriate workload exists, add the smallest one before optimizing.
Do not invent a blanket percentage threshold or relax a guard after seeing a
failure. An inconclusive result stays inconclusive.

For context savings, compare multiple representative tasks where practical and
report the range, not a universal savings claim. Do not spend more tokens on a
large measurement campaign than a small navigation change can plausibly save.
Human completion and correctness matter as much as smaller prompts.

No new timing baselines or token-savings measurements were collected for this
planning document. Earlier refresh tests provide correctness evidence only.

## How to execute incrementally

Select one batch at a time. Before editing, state the behavior owner, invariants,
non-goals, expected benefit, covering checks, and rollback boundary. Prefer one
ownership change plus caller updates. If the work needs unrelated feature
edits, narrower scope or a different boundary is needed.

Separate behavior changes from structural cleanup. Keep commits independently
revertible and retain baseline/candidate evidence outside source files.
Update this roadmap's status and the affected module guide after a batch is
accepted. Use normal release policy; completing a refactor does not authorize
merging, device deployment, or distribution.

If a batch grows the reading surface, introduces broad host protocols, adds
more independently mutable copies, or has no demonstrated benefit, simplify
or stop that batch rather than extending it into a framework.

The next recommended batch is **A1/A2, Home navigation and baseline**, then
**B1/B2, detail source ownership**. C through F remain candidates to reassess
after the pilot; no recurring automation or large migration is implied.

## Sources

Primary guidance reviewed for this proposal:

1. Apple, [Demystify SwiftUI performance](https://developer.apple.com/videos/play/wwdc2023/10160/):
   dependency scoping, identity, cheap updates, measure/fix/remeasure.
2. Apple, [Optimize SwiftUI performance with Instruments](https://developer.apple.com/videos/play/wwdc2025/306/):
   long body updates, causes/effects, Time Profiler attribution.
3. Apple, [Discover Observation in SwiftUI](https://developer.apple.com/videos/play/wwdc2023/10149/):
   property-access tracking and state ownership wrappers.
4. Swift, [API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/):
   clarity at use sites and concise API summaries.
5. Apple, [Beyond the basics of structured concurrency](https://developer.apple.com/videos/play/wwdc2023/10170/):
   task hierarchy, cooperative cancellation, bounded resource usage.
6. Apple, [Demystify parallelization in Xcode builds](https://developer.apple.com/videos/play/wwdc2022/110364/):
   dependency graph, incremental work, build critical path.
7. GitHub, [Repository custom instructions](https://docs.github.com/en/copilot/how-tos/copilot-on-github/customize-copilot/add-custom-instructions/add-repository-instructions):
   repository/path-scoped guidance; support varies by client and surface.

Existing repository policies remain authoritative:
[state management](state-management.md),
[Swift/SwiftUI conventions](swiftui-guidelines.md),
[test selection](testing-policy.md), and
[performance investigation](performance-debugging.md).
