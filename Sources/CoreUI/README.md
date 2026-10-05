# CoreUI

Shared, **focusable** UI primitives, the app theme, and the artwork image
cache that every feature module reuses. tvOS-only — guarded behind
`#if canImport(SwiftUI)` so the package still compiles on Linux for tests.

## Responsibility

- **Theme** — `Theme`, `ThemeOption` (System / Dark / Pure Black / Light) and
  the per-profile theme model, observed at the app root.
  Gradient Backgrounds is a separate default-on profile preference, transferred
  with that profile. Turning it off restores the existing flat page/settings
  fills without changing the selected theme or music-player appearance.
  The static mesh layout is adapted from tresby's
  [Ambient proposal (#75)](https://github.com/brandomoore/Plozz/pull/75), with
  separate light, dark, and near-black treatments rather than another theme.
  Home owns its tint/cache locally: classic hero, Showcase, and mobile sources
  publish only while frontmost. Palette extraction reuses cached artwork, runs
  off the main actor, waits 180ms for navigation to settle, and retains at most
  24 artwork-identity-keyed palettes. Replaced/cancelled sources cannot publish
  stale colours or clear another source. Only the background leaf observes the
  colour array; no full-screen clock, blur, or per-frame Home invalidation runs.
  Reduce Motion disables the palette crossfade. Dark uses a softer wash and Black
  retains more visible colour while staying darker; Light's palette is unchanged.
  Settings groups blend their existing surface colour at 20% opacity over an
  enabled gradient, keeping their shadow and opaque content. Dark and Black use
  a shared 5%-white edge. Gradient Off or Reduce Transparency restores the
  original solid surface and border. Light, other raised cards, and overlays
  keep their existing border treatment.
  The detail information band keeps its subdued surface at 60% opacity over
  enabled gradients; its cards and text remain opaque. Gradient Off or Reduce
  Transparency restores the solid band.
- **Focusable building blocks** — focus-aware buttons, cards, tab bars,
  parallax containers, brand QR code rendering, code-font numerals.
  Native card focus observation is separate from explicit focus requests.
  Caption, overlay and transition-anchor readers update without rebuilding
  the poster's artwork loader or context menu.
- **Media-row focus** — a dedicated modifier owns the row's `FocusState`
  and supplies its binding to tracked cards. Focus callbacks and prefetch
  bookkeeping must not invalidate the row that constructs all card inputs.
  Entry-gate state remains observable for episode rows; ordinary Home rows
  retain native column-aligned entry and cover/return behavior.
- **Async artwork** — `FallbackAsyncImage` and `ArtworkImageCache`: an
  on-disk + in-memory image cache shared with `MetadataKit`'s URL cache,
  with an `asyncFallbackURL` slot so server art is always tried first and
  the `MetadataKit` fallback only runs when needed.
- **Content state** — `ContentStateView` renders the `LoadState`
  loading / loaded / empty / failed states identically across features.
- **Subtitle appearance** — editing the live subtitle look now happens in
  the player (`FeaturePlayback`'s in-player Style screen), not via a shared
  Settings card.
- **Cast & metadata cards** — `CastRowView` and friends, used by Home /
  detail. Common Sense marks keep a transparent background in every theme;
  the palette selects dark checkmark ink in Light and white ink in dark themes,
  preserving the green ring and the existing optical size.
- **Detail information focus** — the tvOS About/Ratings/Information band uses
  native focus with at most 2% growth and 6pt of expansion per edge, leaving
  clearance in its 18pt gutters. Focused read-only cards and card buttons draw
  above their peers. This policy does not change ordinary media-card growth,
  custom focus styles, or touch layouts.
- **Continue Watching logo contrast** — logo-overlay cards use a 40% base
  artwork dim, reduced for dark artwork and increased by up to 25 percentage
  points when the logo blends into its background (65% maximum). The dim sits
  behind the logo. Their logo subtree always uses the on-dark-artwork treatment,
  independent of the page theme; coloured logos retain their palette. Home/detail
  and Spotlight heroes still adapt monochrome ink to their own background, so
  Light keeps dark hero logos.
- **Series artwork identity** — episode-backed cards normalize through
  `MetadataQuery.seriesScoped` before creating a series artwork subject. Child
  IDs and Plex episode GUIDs must not become show IDs. Explicit series IDs,
  show-scoped anime IDs, account scope, and title-matching restrictions survive.
  Corrected logo queries share the series metadata-cache key and do not reuse
  misses stored under an episode ID; the image/memo caches remain shared.
  The textless-backdrop index also qualifies its account and series lookup, so
  a legacy ID-only miss cannot keep suppressing a newly resolvable logo.
  Providers applying parent enrichment to episodes/seasons must publish the
  inherited identifiers under `Series*` namespaces; unqualified IDs may identify
  the child. Share catalog read projection adds these scopes before an episode's
  local NFO overlays its own IDs, so persisted enrichment needs no rescan.
- **Circadian Mode** — profile-scoped warmth/dimming still uses the window-wide
  multiply tint while active. Disabled, daytime, and zero-strength states remove
  the view and its filter rather than leave an opaque white layer above video.
  Fading back to neutral removes it on completion; reactivation or a profile
  change invalidates the old completion. The observer remains alive so schedules
  and previews can reinstall the tint. Hosted tests cover both off and active
  behavior; layer removal alone is not proof of HDR10+ HDMI passthrough.

## Invariants

- **No Jellyfin/Plex specifics.** Components take `CoreModels` value
  types only.
- **No persistence other than caches.** Settings live in feature modules
  (`FeatureSettings`, `CoreModels.ProfileStore`).
- **Compiles without UI.** Files are guarded by `#if canImport(SwiftUI)`
  / `#if canImport(UIKit)` so the package still builds on Linux.

## Where to look first

- `ContentStateView.swift` — the unified load-state renderer.
- `ArtworkImageCache.swift` + `FallbackAsyncImage` — shared image cache &
  the server-first / fallback rendering pattern.
- `Theme.swift` — color/themes used everywhere.
