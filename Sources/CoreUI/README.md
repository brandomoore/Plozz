# CoreUI

Shared, **focusable** UI primitives, the app theme, and the artwork image
cache that every feature module reuses on tvOS and iOS/iPadOS — guarded behind
`#if canImport(SwiftUI)` so the package still compiles on Linux for tests.

## Responsibility

- **Unwatched episode counts** — a default-on profile preference replaces the
  top-right watch-status mark with a number on series/season cards.
  Watched mode uses an inset pearl count tile and a matching white completed
  circle with a dark check. Unwatched mode uses a white triangle for unnumbered
  titles and a flush white count tile with matching outer and bottom-left
  curves. Fine edges and soft shadows keep both legible on pale artwork; only
  the artwork clips the curved tile's shadow, never the tile's own bounds.
  Both count styles use bold system digits. At standard TV size the curved
  tile has 12pt side padding and is 52pt tall; Pearl spacing is unchanged.
  Floating marks have density-scaled clearance (16pt at standard TV size).
  Touch sizes and artwork radii remain proportionate. Episode cards and the
  watch-indicator Settings swatches reuse the same white check and flag.
  Positive exact library counts take priority; unknown counts retain the
  existing watched/unwatched style. Completed containers retain its completion
  behavior. Movies, episodes, ownership/request marks and spoiler protection
  are unchanged. Native and SwiftUI cards share the renderer and preference,
  including native hosting and accessibility.
  Counts use Plex leaf/viewed-leaf fields, Jellyfin/Emby unplayed-item counts,
  and existing local Share episode rollups. They never query episodes per card,
  use online episode totals, or sum duplicate servers. Cross-server counts
  follow the same source as watch state. Child mutations invalidate snapshots
  until the next batched refresh instead of guessing a decrement. Movie actions
  never invalidate unrelated episode counts. Count-only refreshes wait for
  confirmed server delivery so they cannot undo an optimistic watched action.
- **Discovery marks** — the requestable plus, requested clock, and unowned
  binoculars fit the same density-scaled square and corner clearance as the
  watched badge: 21pt on standard touch cards, 42pt on standard TV cards.
  Symbol bounds, not font point sizes, determine their footprint; mobile marks
  never inherit TV's 36pt minimum. Their existing grey/white treatment and
  ownership/request meanings are unchanged. In-player credits use the same
  renderer with their card-width-scaled size.
- **Theme** — `Theme`, `ThemeOption` (System / Dark / Pure Black / Light) and
  the per-profile theme model, observed at the app root.
  Gradient Backgrounds is a separate default-on profile preference, transferred
  with that profile. Turning it off restores the existing flat page/settings
  fills without changing the selected theme or music-player appearance.
  The static mesh layout is adapted from tresby's
  [Ambient proposal (#75)](https://github.com/brandomoore/Plozz/pull/75), with
  separate light, dark, and near-black treatments rather than another theme.
  Home and movie/show detail pages own their tint/cache locally on both platforms.
  They use the artwork actually displayed by their own hero; covered pages cannot
  replace another page's colours. Home sources publish only while frontmost.
  Palette extraction reuses cached artwork, runs
  off the main actor, waits 180ms for navigation to settle, and retains at most
  24 artwork-identity-keyed palettes. Replaced/cancelled sources cannot publish
  stale colours or clear another source. Only the background leaf observes the
  colour array; no full-screen clock, blur, or per-frame page invalidation runs.
  Reduce Motion disables the palette crossfade. Dark uses a softer wash and Black
  retains more visible colour while staying darker; Light's palette is unchanged.
  Fullscreen Hero Home uses half the artwork tint's saturation on both platforms,
  retaining its hue and brightness without desaturating the hero image. Showcase,
  detail pages, and untinted stock gradients retain their existing treatment.
  Tint saturation is page-scoped and shared with native card fills/textures.
  Settings panels, detail information cards, and PIN digit/delete keys share a
  5%-white wash in Dark and Black, or a 5%-black wash in Light, so they remain
  distinct without replacing the gradient's colour. SwiftUI surfaces keep their
  shadow and a matching hairline edge. Gradient Off or Reduce Transparency restores the original solid
  surface and border; unrelated raised cards and dialogs remain unchanged.
  PIN keys retain their existing focus, press, and hover treatment. Their resting
  gradient fill and edge also apply on systems before Liquid Glass.
  The detail information band retains its darker 40%-opaque surface.
  Compact mobile detail metadata and actions reveal the page gradient instead
  of covering it with a solid rectangle; Gradient Off and Reduce Transparency
  retain the original opaque base. The artwork's existing readability fade stays.
  Native tvOS cards display their local portion of a shared page-mesh texture,
  with the information band and wash precomposed because TVUIKit replaces fill
  alpha. The texture is created only when a card needs it, its longest edge is
  capped at 480 pixels, and it is rebuilt only for palette or viewport size
  changes. Scrolling updates each background's sampling rectangle, not its
  texture or foreground content. Native focus,
  clipping and text remain TVUIKit-owned.
  Text stays opaque and native focus geometry is unchanged. Gradient Off or
  Reduce Transparency restores both the solid band and solid card fills.
- **Focusable building blocks** — focus-aware buttons, cards, tab bars,
  parallax containers, brand QR code rendering, code-font numerals.
  Native card focus observation is separate from explicit focus requests.
  Caption, overlay and transition-anchor readers update without rebuilding
  the poster's artwork loader or context menu.
- **QR images** — `QRCodeView` renders on a worker actor, including Core Image
  initialization. Settings, account authorization and device pairing share it.
  Payload/correction/mask changes replace the request; cancelled work cannot
  publish an old code. Theme tint is applied to a transparent mask without
  rerendering. The memory-only cache retains at most 8 images and 16 MiB of
  pixels; payloads are never persisted or included in error logs.
- **Mobile content tabs** — `PlozzContentTabs` owns the touch-sized horizontal
  navigation shared by library modes and series seasons. Selected tabs use the
  existing glass capsule style; inactive tabs are secondary text without a
  capsule. Typography, spacing, 44pt minimum targets, selected accessibility
  traits, long-label fitting, and selected-tab reveal live in one component.
  It respects Reduce Motion when revealing a new selection and re-reveals after
  viewport, text-size, or option changes. Callers supply localized or verbatim
  labels and page keylines; native app tabs and tvOS focus controls are separate.
- **Mobile media corners** — posters and Continue Watching share a 12pt artwork
  radius at every display size and responsive width. Borderless cards use that
  radius directly; glass frames add their inset to remain concentric. Loaded
  artwork, missing-art placeholders, and skeletons agree. TV rounding is unchanged.
  Regular mobile artwork progress bars use an 8pt minimum height, leaving their
  length and the separate Continue Watching, hero, and TV bars unchanged.
  Mobile library, episode, and download artwork uses the same metric, keeping
  its caption clearance consistent with its actual corners. Mobile captions use
  a shared 4pt horizontal inset from the artwork edge, independently of their
  unchanged bottom corner clearance. Poster, landscape, music, download, and
  episode captions and skeletons share it; TV caption layout is unchanged.
  Home library names
  and server names share one leading-aligned text column beside the provider mark.
- **Provider marks** — IPTV uses coral-red while Media Share keeps teal.
  `ProviderBrandMark` owns their shared icon and badge tints, including deeper
  colors on white focus cards and brighter colors on black focus cards.
- **Media-row focus** — a dedicated modifier owns the row's `FocusState`
  and supplies its binding to tracked cards. Focus callbacks and prefetch
  bookkeeping must not invalidate the row that constructs all card inputs.
  Entry-gate state remains observable for episode rows; ordinary Home rows
  retain native column-aligned entry and cover/return behavior.
- **Grouped settings interactions** — `SettingsSectionGroup` uses explicit
  menu pickers on iOS. A visual group occupies one native List cell; automatic
  pickers can promote their menu to that whole cell and intercept neighboring
  navigation links or controls. Keep picker activation local without replacing
  the shared group surface, separators, or tvOS control styles.
- **Async artwork** — `FallbackAsyncImage` and `ArtworkImageCache`: an
  on-disk + in-memory image cache shared with `MetadataKit`'s URL cache,
  with profile-scoped source choices in Appearance > Artwork. Recommended uses
  metadata providers first for Home and library Showcase heroes, movie/show detail
  backgrounds and logos, and textless Continue Watching artwork. Ordinary rows,
  related-title posters, and episode thumbnails remain library-first. Detail hero
  placement is carried through resolution, cache identity, prewarming, and mobile
  reflections without changing the surrounding page's card policy.
  Shared hero/reflection first-paint results are qualified by source and provider
  policy so changing those settings cannot reuse a previous provider's winner.
  Library-first and metadata-provider-first
  presets initialize source choices for Home, Continue Watching, Browse,
  Search, Watchlist, Details, Episodes, Playback, Music, Top Shelf, and Downloads
  where available. Editing a view enters Custom mode; choosing any preset
  replaces the whole configuration. The shared editing and presentation contract
  lives in [FeatureSettings](../FeatureSettings/README.md#invariants). Cards retains
  card presentation controls, not app-wide artwork policy. Missing artwork can
  fall back to the other source. Provider-first waits for lookup and image decoding
  to finish, including time queued behind other requests; a short first-paint
  budget must not permanently select cached library artwork instead. Existing
  network/image-load deadlines still bound failures, and cancellation releases
  the view without painting a fallback for a cancelled request.
  Provider enablement/order is household-wide in Metadata Providers; changing
  appearance never enables a provider. The old library-artwork choice migrates to each profile,
  and the new preference transfers/syncs with that profile.
  Metadata Providers links directly to the active profile's Artwork preferences.
  Reciprocal links return to an existing page instead of stacking duplicate pages.
  Library-first heroes honor the server-selected backdrop or primary share
  sidecar rather than choosing a different image for Details or avoiding artwork
  on the focused card. Recommended retains varied library Details backgrounds as fallbacks;
  metadata-provider-first retains provider lookup and artwork variation. The
  choice applies equally to first paint, prewarming, mobile reflections, and
  later visits; alternative images remain fallbacks if the selected one fails.
  Continue Watching's recommended textless lookup is separate from source
  preference: explicit library-first uses supplied artwork without checking it
  online. A selected textless backdrop has priority over both ordinary provider
  and library images, including synchronous cache seeding. If that image fails,
  the normal source preference still orders the fallbacks. When textless artwork
  is unavailable, Recommended keeps a library background ahead of a metadata
  poster with baked-in lettering; episodes use only their series background.
  An explicit metadata-provider choice still gives providers priority. Missing
  or unreadable library backgrounds retain the metadata-poster fallback.
  Native tvOS and SwiftUI cards both settle cold textless lookups before
  selecting a background;
  the native poster and its focus owner remain mounted while waiting.
  `ContinueWatchingArtworkSource` is shared by rendering and lookahead on TV and
  mobile. It prepares the selected backdrop and processed logo, including
  metadata-provider fallbacks and SMB references, in the existing bounded caches.
  `ArtworkPrefetchWindow` retains only the current nine-card window, cancels work
  that leaves it, and reuses overlapping completed requests. Source or policy
  changes replace those requests; leaving the row cancels them. Background
  metadata has a separate one-request gate and image decoding uses the background
  lane. Neither focus callbacks nor touch scrolling await any preparation.
  Textless lookups coalesce per title; cancelling speculative work cannot cancel
  a visible consumer or turn an unfinished lookup into a cached miss.
  SMB selections retain local and online candidates in the shared
  catalog, including typed network-file references and their access gate.
  SwiftUI, native Browse cells, detached hosts, and prewarmers use the same
  effective policy. Cache identities include source and provider policy; a
  settings change replaces the image selection, not ordinary focus movement.
  A fallback is stable for that appearance, not a promise that an online source
  has no image. Playback system art receives an explicit snapshot.
  Top Shelf exports resolved images into its shared container. Downloads capture
  the selected artwork when queued; existing offline artwork is not re-fetched
  after a settings change. Clip-specific extra thumbnails, people, channel
  branding, and spoiler protection retain their separate semantics.
  When card captions are hidden, folder and missing-art placeholders carry the
  existing spoiler-safe title inside the artwork slot. Loaded art remains
  label-free, visible captions are not duplicated, and loading/failure never
  changes card height. Spoiler blur applies to images, not fallback names.
- **Content state** — `ContentStateView` renders the `LoadState`
  loading / loaded / empty / failed states identically across features.
- **Mobile settings surfaces** — `SettingsPageSurface` keeps the native scroll
  viewport full-width so the title's scroll-edge blur reaches both navigation
  edges. Horizontal safe-area padding insets the content without narrowing that
  viewport; both list rows and grouped scrolling panels retain their spacing.
  Settings subpages default to the system's centered inline navigation title on
  both iPhone and iPad, including the iPad detail column. Root destinations keep
  their leading large titles; only the Settings root overrides the shared surface
  title mode. Modal utility pages also use inline titles without custom fonts.
  The compact Settings drawer keeps its title leading beside a native close
  button at the top, switching to a centered inline title only after scrolling.
  Both Settings roots use a 16pt content inset matching the native leading title;
  subpages retain 24pt insets. Alignment never narrows the scroll viewport.
  Its first section uses a tighter 8pt content margin.
  Profile/PIN resealing observes the page, not a zero-height row that adds spacing.
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
  Continue Watching cards and focus-driven hero titles keep their text fallback
  invisible during logo lookup and decoding, preserving its layout space.
  Text appears only after resolution finds no usable logo (or there are no logo
  sources); cached logos still paint immediately. Completion is request-scoped,
  so a cancelled or missing logo for one title cannot reveal text for the next.
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
