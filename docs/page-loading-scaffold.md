# Page loading scaffold

A recipe for any surface that loads content after its header — a detail page, a
rail, a browse section. It exists because these were each solved separately, and
the copies disagreed: some pages flashed a skeleton, some reserved nothing and
reflowed when cards arrived, some fetched the same row twice, and single-server and
multi-server installs rendered differently because each had its own fan-out.

If a new surface needs most of this, follow the steps; if it needs one piece, use
that piece. The primitives are shared, not copy-pasted.

## 1. Decide the load order once

A page is: **subject** → **children** → **the opening child's content**. The third
step is the slow one, and it must not wait for a view pass.

```swift
// CoreModels/DetailOpeningSelection
let openingSeason = DetailOpeningSelection.openingSeasonID(
    children: fetchedChildren,
    resumeSeasonID: serverResumeEpisode?.seasonID
)
```

`openingSeasonID` is the rule for **every** container kind (series, season, folder,
collection, leaf). Prefetch that child as soon as the children arrive, then let the
rail's own loader find the episodes already in hand instead of starting a second
request behind the first.

Store the task and cancel it with the page:

```swift
episodePrefetchTask = Task { [weak self] in await self?.loadEpisodes(for: seasonID) }

public func suspendEnrichment() {
    episodePrefetchTask?.cancel(); episodePrefetchTask = nil
    detailMetadataTask?.cancel(); detailMetadataTask = nil
    // …the rest of the page-local work
}
```

**Rule:** page-local Tasks are cancelled on disappear. Leaving them running is paid
for by the *next* screen — measured as hitching when scrolling Home right after a
detail page.

Independent round trips (cast/overview metadata) start at item resolution, in
parallel with children, not after them.

## 2. Fan out through one model

Reuse the surface's existing aggregation owner rather than creating a parallel
fetch path. Home remains owned by `HomeAggregator`, which handles row admission,
source identity, and partial failures. The `CoreModels/Fanout` utility is available
for ordered aggregation but has no production callers yet; it is not a replacement
for Home's provider and lifecycle contracts:

```swift
await Fanout.run(
    sources: accounts.map(\.id),
    publication: .progressive,        // or .completeOnly when a partial looks wrong
    fetch: { accountID in await service.value(for: accountID) },
    merge: { values in merge(values) },   // stable: same inputs → same result
    onProgress: { result in publish(result) }
)
```

- **One source is the fast path**, not a special case: single await, single
  publication, no merge delay. This is what keeps a one-server install from
  behaving like a degraded multi-server one.
- Merge in **source order**, never arrival order.
- `FanoutResult.isComplete` distinguishes "every one answered" from "nothing yet" —
  the distinction every cached-first surface needs.

## 3. Reserve geometry, then reveal

Use `CoreUI/PlozzReservedPlaceholder` (single view) or `PlozzPlaceholderRail`
(count-driven row):

```swift
PlozzReservedPlaceholder(isPending: episodes == nil, revealsPlaceholder: true) {
    EpisodeSkeletonRail()          // must be the real content height
} content: {
    EpisodeRail(episodes)
}
```

```swift
PlozzPlaceholderRail(isPending: loading, cardWidth: metrics.posterWidth, spacing: gap) { _ in
    PosterPlaceholder()
} content: {
    PosterRow(items)
}
```

- `isPending` decides whether the placeholder is **laid out** — so the page never
  jumps when content lands.
- `revealsPlaceholder` decides whether it is **painted** — a first load holds a
  shimmering placeholder, which is the affordance saying the row is coming.
- Placeholder **count comes from width** (`PlozzPlaceholderCapacity`), never a
  hardcoded 6 or 8.
- **Never gate these on elapsed time.** State only. `tools/ui-state-guard.py`
  rejects time-armed skeletons and bare-loading branches in CI.

### Revisit caches must be bounded and device-tiered

A revisit cache is only free if it is small. Two rules, both enforced here:

- **Restore only what the page will paint.** A detail snapshot can hold episodes for
  every season the viewer browsed; hydrating all of them to draw one rail is waste.
  `ItemDetailViewModel` restores just the opening season, capped at
  `maxRestoredEpisodesPerSeason` (80); the rail is lazy and the live fetch fills the
  rest on demand.
- **Size budgets by device.** `ArtworkMemoryBudget` and `DetailSnapshotCache.budget`
  both tier on `physicalMemory` (192 MB decoded artwork / 800 entries on ≥2.5 GB,
  96 MB / 300 entries below). Lower-memory devices use smaller budgets to limit
  prune-scan and decode work.

When adding a cache, ask: what is the largest thing a single page can put in it, and
what does that cost on the smallest device we support?

## 4. Sanitise provider text

Providers return prose as HTML. Convert at display with `CoreModels/HTMLText`:

```swift
ExpandableOverviewText(text: HTMLText.plainText(from: biography), …)
```

Do it where the text is shown so truncation measures visible characters, and so an
`@Observable` model keeps its property budget (see below).

## 5. Keep the observation budget honest

`tools/arch-guard.py` holds `@Observable` types to a **decreasing-only** property
budget. Rendering dependencies must remain observable: reading a flag in `body`
is a reason to track it, not to mark it `@ObservationIgnored`. Prefer deriving
loading presentation from the existing published load state. Keep optional cache
reads independent of visible loading feedback and available actions.

## 6. Measure, don't infer

- Traces are silent unless launched with `PLZXFAN_STDOUT=1`; timing lines carry
  monotonic `t=` (`DETAILVIEW`, `DETAILCARDS`, `DETAILCAST`, `DETAILRELATED`,
  `HOMEFRAME`, `HOMECAROUSEL`, `HEROARTREF`, `HOMECW`).
- Scrolling/enter-exit cost goes through the simulator lab, not opinion:
  `python3 tools/performance.py run --platform iOS --sim-id <uuid> --scenario related-detail-open-scroll`
  (counters include `maxMainActorGapMicroseconds`, `scrollCPUTimeMicroseconds`).
- See [agent-device-debugging.md](agent-device-debugging.md) for device capture and
  [state-management.md](state-management.md) for the retention rules these
  primitives implement.

## Checklist

- [ ] Load order is subject → children → opening child, with the child prefetched.
- [ ] Independent round trips start at item resolution, not after children.
- [ ] Every page-local Task is stored and cancelled on disappear.
- [ ] Multi-account reads reuse their aggregation owner; merge is source-ordered and stable.
- [ ] Geometry is reserved; placeholders are count-driven and state-gated.
- [ ] Provider HTML is sanitised at display.
- [ ] A trace line with `t=` covers the new stage; a perf scenario exists or was run.
- [ ] `tools/arch-guard.py`, `tools/test-hygiene.py` and `tools/ui-state-guard.py` pass.
