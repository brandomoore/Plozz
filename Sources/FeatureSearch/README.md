# FeatureSearch

The federated search view: one search box that queries every active
provider (including Jellyfin, Plex, and Silo) in parallel, deduplicates results, and
ranks them with a shared policy.

## Responsibility

- `SearchView` + `SearchViewModel` — focusable tvOS search UI with
  debounced input, per-section results, and `LoadState`-driven
  loading/empty/failure rendering.
- `SearchSection` — section model (movies / shows / episodes / people /
  music / collections) so results are grouped consistently across
  backends.
- `SearchDeduplicator` — collapses items that appear on multiple servers
  / accounts (same title + year + content type → one card with merged
  ids) so the federated view never shows obvious duplicates.
- `SearchPolicy` — the shared sorting/ranking rules (exact-match first,
  watched bias, recency, etc.). Pulled out so it's unit-testable
  independent of the view-model.

## Invariants

- **Provider-agnostic.** Search calls go through `MediaProvider`; nothing
  here imports a specific provider.
- **Federated across active accounts.** Fans out over the active
  `[ResolvedAccount]` set from `AppState`, the same way `FeatureHome`
  does.
- **`LoadState` everywhere.** Loading/empty/failure rendering uses
  `CoreUI.ContentStateView`.
- **Compiles without UI.** `SearchPolicy` and `SearchDeduplicator` are
  plain Swift, Linux-portable, and unit-tested in
  `Tests/FeatureSearchTests`.

## Diagnostic submissions

The shared search model records each active account's library-search outcome in
`CoreModels/SearchDiagnosticJournal` while Share Crash Reports is enabled.
Results, empty responses, failures and cancellation remain distinct even when
another account supplies results. Source ordinals and report-local search aliases
correlate concurrent requests without exporting account IDs. Silo adds numeric
library-filtering and cursor-page evidence; other providers retain their shared
outcome and available HTTP/decode evidence, without invented library counts.
This does not change search results or send automatic failure events.

Manual submissions include the latest 32 completed source attempts and up to 32
active attempts, independently of the short general-performance ring. Each source
retains its last eight requests/pages, total request/page counts, and up to four
HTTP, transport and decoding failures each. The in-memory history is cleared on
opt-out or app restart; completed entries expire after 48 hours. Enable reporting
before reproducing and submit before restarting. No search text, media titles,
server addresses, profile names, credentials or cursor values are collected.

## Where to look first

The mobile presentation lives in `AppShelliOS/PlozziOSSearchView.swift`. Its input
uses a flat theme-aware capsule at rest, crossfading to native Liquid Glass
while focused or holding a nonempty query on iOS 26 and later. Both background
layers stay mounted so editing never replaces the text field. Reduce Transparency
and older systems retain the flat surface; Reduce Motion skips the crossfade.
Results start below the transparent header but draw beyond their scroll viewport
behind its individual glass controls, without a full-width background. The
header stays above the results for drawing and hit testing.
The resting input reuses `settingsGroupSurface` with a capsule shape, including
its gradient-aware wash, theme borders/shadows, and Reduce Transparency fallback.
Section headings, visible poster edges, and captions share the input's 16-point
leading margin. Grid padding accounts for each card style's internal artwork
inset rather than aligning the invisible card slot.
Section-heading taps dismiss the keyboard without activating a nearby result.
Search results use a standard navigation push rather than an artwork zoom, so
interactive Back does not scale the Search page into an inset background.
The title/profile row collapses as search activates, moving that same field up
and revealing a separate native Cancel button. Cancel clears the query and
dismisses the keyboard; ending an empty search restores the title and profile.
Native More navigation keeps its own Back/title row instead of duplicating it.
Theme text colors keep it legible in light, dark, and black appearances. The native
Settings navigation entry displays the active profile avatar. Search keeps a
local avatar only when that navigation entry is not visible, including compact
layouts where Settings is under More.

On iPhone and iPad, the mobile screen owns the input's native SwiftUI focus.
Tapping the content below the header dismisses the keyboard without clearing the
query or consuming result/retry actions; scrolling results dismisses it
interactively. The full input capsule takes focus, and its clear button keeps
editing available. Unlike an overlaid search bar, results remain below this
header, so scrolling alone does not activate glass.

- `SearchViewModel.swift` — the debounced fan-out / merge loop.
- `SearchDeduplicator.swift` + `SearchPolicy.swift` — the pure logic
  pieces (test these without a simulator).
