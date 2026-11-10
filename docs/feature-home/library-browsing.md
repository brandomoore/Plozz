# Library and row browsing

[Home task map](../../Sources/FeatureHome/README.md#where-to-look-first)

## Inline library collections

Movie Browse follows the server's collection presentation automatically under
All + Name sorting, without a new setting or toolbar control. The shared
`PageRequest.collectionPresentation` opts only library title browsing into this
behavior; background indexing, recommendations, filtered/sorted inventories and
collection members continue to request individual items. Provider adapters own
their native policy; unsupported sources do not infer collections from titles.
Existing collection cards open the same paged member route on TV and mobile.

Combined libraries merge each source's native mixed result. Collection identity
stays account-scoped, even for two users on one physical server, and title-index
membership cannot combine curated collections. A hidden member in one source
does not hide an independently returned movie from another. Aggregate buffers
include collection presentation in their query identity. Grouped A-Z targets
use actual page positions, not individual-movie counts; no eager member scan or
library scan is added to ordinary paging.

## Browsing Home rows

Media rows have a title-chevron action on iPhone/iPad and a trailing **See all**
card on Apple TV. The TV action is a separate native control, not a synthetic
media item, and follows the rail's poster, landscape, or featured geometry.
All TV Home layouts retain the complete `HomePresentationRow` source when
opening the shared browser. Libraries and Live TV keep their existing navigation.
Expanded grids of collection covers retain the resolved Auto, Posters, or
Landscape cover layout on TV and mobile. Movie, show, episode, and mixed-content
grids use normal posters; they do not inherit Continue Watching's special layout
or a custom collection-member row's Landscape/Featured presentation.
Landscape collection-cover grids use wider columns; sorting, filtering, and
paging do not change their shape or the saved library-browser layout.
TV row browsers use Home's navigation path, hiding top-level navigation as soon
as they open. Opening a title adds another level; Back returns to the browser
before returning to the original Home action. Browser scrolling does not move
Home's retained top navigation. See all uses native page push/pop animations;
the retained Home rail keeps its own scroll position throughout the transition
and restores focus to the original action.
Browse actions appear only when the feed confirms additional eligible titles
beyond the Home preview, not merely because the preview reaches its limit.
Home requests one lookahead item in the existing bounded fetch; it does not
probe every shelf again. Complete rows, including single-item shelves and
uncapped Continue Watching snapshots, have no redundant browse action.
On Mac, successfully loaded media rows with more than ten titles offer the
title-chevron action even when the entire row is already loaded. This threshold
changes only the heading action; it does not shorten the rail or change its fetch
limit. Rows with ten or fewer titles, loading/failed rows, Libraries, and Live TV
have no new action. Mac Related headings follow the same threshold and open all
currently resolved related titles in the same grid, preserving their order,
continuation cues, detail navigation, and profile/account scope.
Watchlist previews the first 20 titles in its existing Home order. When there
are more, TV pushes the existing Watchlist view beneath Home rather than switching
top-level destinations. Mobile retains its existing Watchlist destination handoff,
temporarily admitting a hidden navigation entry without changing the saved layout.
Both reuse the full profile-scoped Watchlist and its saved sorting/filtering
preferences instead of creating a separate row browser.
On TV, browser entry keeps query controls and later cards out of focus until
the first grid item actually receives native focus. This also covers delayed
loads and nested Watchlist; empty and failed loads release the controls. Once
entered, ordinary directional navigation and detail-return focus stay native.
The shared row browser's sort and filter menus sit at the trailing end of the
TV heading and in the top-right navigation toolbar on iPhone/iPad. Mobile uses
a native inline navigation title rather than a second large content heading;
long titles truncate to fit alongside Back and the menus. Watchlist
and library grids use that same mobile toolbar placement, keeping supported
query actions available while the content scrolls without adding a pinned
content header.

Mobile row-browser destinations capture only the app model and resolved layout
inputs. Capturing the entire Home view causes a navigation update loop on iOS 18
inside the production tab shell; standalone Home navigation does not reproduce
it. Keep the shell-backed Films heading regression when changing this boundary.

`HomeRowBrowseModel` preserves source order by default and loads additional
bounded pages as the grid advances. Library and collection rows use their existing
container APIs. Provider Home feeds continue the exact feed: Plex uses its
same-origin shelf key where available, while limit-only feeds extend their
requested prefix. Recommendation membership is separate from arranger slot
identity; a missing or changed source is an error, not permission to browse an
unrelated library. Server previews carry the continuation from their content
response through aggregation and presentation, separately from saved layout
discovery. This preserves Plex curated shuffle seeds across every browser page.
Fixed server shelves end when the source has no continuation.
Combined Recently Added also enforces its non-music library scope on returned
items when a provider cannot scope the feed, without changing raw page offsets.
Its hide-watched policy is reapplied after watch mutations for combined,
per-library, and server rows; retained candidates can reappear when marked unwatched.

Sorting and filtering first complete the shelf, then publish the whole-row
result. Pending or failed queries never display a partially sorted page as a
complete answer. This can require more requests and memory than opening the
default-order grid, especially for large collections. Work is cancelled on
navigation/supersession, and profile/source visibility is checked again after
asynchronous work. Watchlist reuses Home's full retained data in its existing tab;
the preview does not reinterpret its account-wide membership. Browse controls
are destination-local and do not change the Home row's settings or order.

## Browse failures

- **Library browse failures** — Browse, Collections, Playlists and their member
  pages use the shared Details / Try Again actions on mobile and TV, including
  nonfatal later-page failures. `LibraryLoadDiagnostic` identifies the requested
  section and retains safe response/paging evidence. Retry and mode changes clear
  stale reports; cancelled or superseded requests cannot publish one.
  Jellyfin/Emby Collections uses the native server-defined list without a
  library/member scan. A dedicated Collections library entry coexists with the
  movie/TV library shortcut. Synthesized directory entries stay in navigation,
  but never enter scoped playable-media feed requests or per-library Home rows.
  Confirmed-empty collection directories stay out of Home's Libraries row until
  populated or explicitly enabled in the profile's Libraries checklist. The
  shared row resolver applies this on both platforms without hiding discovery.
  Providers with intermediate discovery can display confirmed cards while remaining candidates
  are checked. Both platforms show native progress and retain the stable card
  slots. Partial failures retain those cards with an explicit incomplete-list
  message and Details / Try Again; interrupted discovery restarts on return.
  Reappearance must not restart an already-running first page, and sparse-page
  prefetch waits until discovery is complete. Aggregated libraries retain their
  existing complete-source merge rather than leaking unmerged source progress.
  Browse network errors do not assume a local-network server. Task-local
  diagnostics preserve the failing route and numeric URL error (for example,
  timeout versus connection loss), without addresses or raw error text.

## Recommendation failures

- **Library recommendation failures** — Continue Watching, server recommendations,
  and Recently Added resolve independently. Partial and complete failures offer
  the shared native Details / Try Again actions on mobile and TV. Details name
  every failed section and reuse the existing shareable diagnostic sheet, without
  server addresses, account names, library IDs, titles, or response bodies.
  Decode failures retain bounded structured response evidence rather than only
  `AppError.decoding`; provider error types and strict decoding are unchanged.
  Refreshing preserves each failed family's previously loaded rows until that
  family succeeds, including an authoritative empty result. Cancellation never
  publishes a partial success or replaces the last completed diagnostic.

## Multi-account browsing

- **Multi-account aggregation** — `HomeAggregator` fans out across the
  active account set (`[ResolvedAccount]`) so Home is a merged view
  across multiple servers / profiles. Uses the `MediaProvider`
  abstraction; never imports a specific provider module.
  All Libraries keeps reachable sources when capability preparation, query facets,
  inventory discovery, or duplicate-card hydration encounters an unavailable source.
  Its provider and query implementation live in `FeatureHomeCore` and are shared
  by tvOS and iPhone/iPad. Mobile uses the existing native library grid, sort and
  filter controls, with a separate profile-scoped browse preference key. Combined
  cards use unified detail routing, not a synthetic provider as their playback
  source. Profile/account changes or a changed library source set replace retained
  browse state; ordinary discovery reordering does not.
  Inventory membership stays fixed per attempt. Before publishing a first page,
  a source lost during inventory or card hydration causes one bounded rebuild
  without that source; concurrent callers share recovery. Published pages keep
  their offsets and retry feedback rather than silently shifting existing cards.
  Refresh rediscovers sources. All-source failures
  remain retryable errors, and cancellation never becomes partial success.
  Navigation retains offline library destinations: the native sidebar includes
  Offline in its single tab title (native tabs discard separate sibling labels),
  while the pinned rail also adds a contrasting wifi-slash badge
  that stays legible when the row is focused. Compact top navigation has no
  individual library destinations.
  Failed library pages identify the affected server with its provider logo and
  saved name in a non-focusable identity chip on both platforms, alongside Retry.
  It reuses library-discovery failures and actual share-root scan results, never
  a new polling loop or cached-catalog reads as proof that a share is online.

## Library modes and queries

- **Library browsing** — `LibraryBrowseView` + `LibraryBrowseViewModel`
  distinguish navigation roots from pushed pages with `isNavigationRoot`.
  Individual library and All Libraries roots preserve automatic native-sidebar
  visibility. The custom Top Bar owns its own chrome and content-focus gate,
  so loading content cannot remove its focused destination. Pushed
  library/collection pages retain their hidden native tab bar. They
  own a bounded, directional `ArtworkPrefetchWindow`. Its URL/variant requests
  preserve overlapping work across reversals and cancel obsolete queued work.
  Admission rechecks decoded residency; content, density, lifecycle and background
  generation changes cannot keep stale warming alive or suppress a later pass.
  They initially show the first supported tab in the profile's shared library
  arrangement (Recommended by default for server-backed video libraries), with
  library-scoped Continue Watching and Recently Added plus native Plex hubs
  or Jellyfin/Emby movie recommendation categories. TV uses Showcase, showing
  its mode tabs only while the first row is active; mobile uses touch-sized rows.
  iPhone and iPad keep Recommended, Browse, Collections, and Playlists in a
  horizontally scrolling tab strip, limited to the provider's capabilities.
  `LibraryPresentationSettings` shares tab order/visibility and TV logo size
  across libraries, independently of Home and detail pages. Recommended row
  order/visibility is account-and-library-qualified within that profile.
  Presentation edits resolve the already-loaded rows without refetching them;
  unavailable rows and unsupported tabs retain saved intent. Browse remains
  accessible when no preferred tab is supported. Collection/playlist member
  routes remain plain Browse destinations.
  Mobile Home's no-account and connected-but-empty states share
  `PlozziOSHomeEmptyState`: the small blue Plozz mascot without its wordmark, a state-specific explanation,
  and one native **Add Source** action. Only the no-account state also offers
  device transfer. Both remain scrollable at large text sizes and in landscape;
  empty-state presentation does not alter provider loading or profile inclusion.
  Library modes and series seasons both use CoreUI's `PlozzContentTabs`, with
  the same selected glass pill, inactive text, touch sizing, and reveal behavior.
  Tabs retain their identity through loading, empty, and failure states and
  reveal the selected mode without compressing every label into a segmented
  control. At accessibility sizes, an individual tab still fits the viewport.
  Mobile controls scroll with the page; Filter and the current Sort occupy a
  separate line instead of competing with the tabs. Row headings, artwork, grids,
  and scan banners share the mobile page keyline (22pt compact, 36pt regular).
  Mode changes reset to the padded page's true top, keeping both the tabs and
  native navigation-bar scroll-edge appearance consistent across all four modes.
  Recommendation rails remain horizontally lazy and share touch card appearance
  and the same heading, visible spacing, and artwork keylines as mobile Home.
  Library Continue Watching uses Home's profile-selected series artwork and
  resume progress treatment, including profile spoiler protection on mobile.
  Merged libraries validate Continue Watching against every account-qualified
  source, merge duplicate titles with their source references, and order by
  watch recency before limiting the row. Watch changes
  refresh recommendations on return (or while visible), retaining the current
  rows during the request and rejecting snapshots predating another watch change.
  On tvOS, changing tabs keeps the focused mode control
  mounted while replacing content below it. A stable layout container owns the
  top inset across Recommended, Browse, Collections, and Playlists (a transparent
  `Group` would attach the inset to each replaceable content branch).
  Library pages discard the native container's top-bar inset and reserve only
  screen-safe spacing plus clearance for the native sidebar's visible page button.
  The outer focus host and Recommended content both break out at the trailing
  edge so artwork reaches the screen edge; headers and grids retain their safe
  margins, including the custom pinned rail's foreground inset. Home is unchanged.
  The mode container, Showcase details and row headings, scan banner, and visible
  grid-card surfaces share one keyline across Recommended, Browse, Collections,
  and Playlists. There is no grid-only sidebar offset. Both grid implementations
  use `cardRowLeadingPadding`, as Home rows do, to compensate for invisible
  borderless-card margins rather than aligning padded slots. Framed cards align
  their outer surface. Switching pages must not move or resize the navigation.
  Focus changes a tab's contrast, not its size, preserving the container's even
  6pt inner padding. Pressed feedback remains unchanged.
  Sort sits on that same top navigation line alongside Filter and file browsing.
  Filter and Sort form a compact pair. Alphabet navigation stays on the
  scrolling rail; there is no separate Jump to letter button.
  Without mode tabs, the library/share display name occupies the left of the
  same header, with controls on the right; it does not add a focus target.
  A persistent tvOS focus owner encloses the header and grid, preserving
  the selected tab's focus identity as content changes. The content slot stays full-height
  during loading, keeping the header in place and query progress vertically
  centered below it. Scan progress remains in the grid. Its hosting view is
  constrained to the collection's supplementary header, which alone owns the
  placed size. Do not pre-size that view and then autoresize it when the header
  grows: a live scan update would apply the size delta twice, overlapping posters
  until another focus/layout pass. Banner height and artwork alignment must be
  correct while unfocused, through focus changes, and when progress reappears.
  Library Showcase measures its navigation clearance and reserves one native
  badge's height for schedule/availability-capable items before the line loads.
  The visible badge hugs the fitted logo, not unused space in its sizing slot;
  late schedule arrival cannot resize it. Default sizing trims description lines
  before constraining the logo. Custom sizing fits the logo and text together
  within the fixed details footprint, retaining their proportions. Row motion
  translates that block without resizing it or borrowing navigation space.
  A cold logo is adopted
  when it finishes for the still-current title, without requiring a focus round trip.
  Its title slot stays visually empty while the logo resolves; text appears only
  after no usable logo is found, never as a temporary title before the wordmark.
  Home hero and Showcase use independent `HeroSettings` logo sizes; full detail
  heroes use `DetailPageSettings.logoSize`. Both Home foreground renderers apply
  the same sizing math without reloading artwork. Defaults preserve existing sizes,
  while text fallback fonts follow the separate text preference. The compact
  series-browser logo remains unchanged.
  Dark coloured Showcase logos can select CoreUI's cached contrast lift against
  the leading page colour, preserving hue, saturation, white highlights, and
  the logo's geometry rather than whitening the lettering.
  Showcase gates lower rows only until the first row actually receives native
  focus, so an already-ready Discover row cannot win cold-start entry while
  Continue Watching is still realizing. Once entered, normal navigation and
  later data updates do not reclaim focus from another row.
  Navigation eligibility follows the current row order when a refresh removes
  or inserts a row, without requiring focus to move. Hub identities are scoped
  by their source and content, not by their position among other rows.
  The scrolling header forwards public styling and enabled state to its hosted
  SwiftUI content, not another hosting tree's private accessibility state.
  Returning to the first row re-enables the same controls after Showcase hides them.
  Filter joins the same header line. Quick filters intersect genre and year;
  its label names the selected options while they fit, falling back to their
  count only when the available header space is too narrow. Tabs and Sort retain
  their room, and accessibility always announces the full selection.
  The compact count uses localized plural forms; format names such as Dolby
  Vision stay verbatim in both the menu and selection summary.
  App-authored recommendation headings retain localization resources through
  caching and source qualification, so language changes update existing rows
  without changing their identities. Provider-authored headings stay verbatim.
  On tvOS, library tabs, Filter, and Sort move with the grid instead of staying
  over the posters. Their native controls remain mounted during query changes
  so returning to the top and changing filters or modes preserves focus.
  The native grid's viewport spans the full screen vertically, with content
  insets preserving the header and bottom spacing. Disabling clipping alone
  does not prevent UIKit from hiding artwork at an inset viewport boundary;
  partly visible posters must keep rendering until they leave the screen.
  Offscreen rows still recycle normally.
  Sort/filter choices are remembered per library, account, mode, and profile.
  Genre/year options use each server's scoped facet endpoint; Jellyfin/Emby use
  `/Items/Filters`, whose response contains genre names and years. Empty successful
  responses are cached, cancellation is not a load error, and actual failures
  retain a retry action separate from the selected quick filter.
  Facet requests belong to the library model and are shared across menu mounts,
  so canceling a disappearing menu does not discard a replacement menu's options.
  Catalog changes reload facets and reject pre-refresh responses; watch-only
  changes retain the cached genre/year options.
  Native provider operations remain paged. Explicit non-native options prepare
  a cancellable utility-priority inventory of compact IDs/query facts, not a
  full-card Home cache. Ordinary Home, Browse, and facet menus never inventory.
  Inventory pages are bounded to 120, visible-card materialization to three
  concurrent reads, and estimated retained facts to 24 MiB; inconsistent or
  incomplete inventories fail explicitly instead of displaying partial totals.
  Cancelled inventory tasks are retired before reuse; a live coalesced caller
  retries when another caller cancels their shared task. Random filtering uses
  deterministic server traversal before locally ordering the collected records.
  Richer cached facts cover simpler subsequent sorts. Changing history sorts or
  watch state reuses file facts for up to two minutes without retaining stale
  history or repeating version hydration; catalog changes discard those facts.
  Watch/catalog changes invalidate query membership/history without scanning covered library views.
  A failed background refresh retains the grid and retries the refresh itself
  through Try Again, rather than only retrying failed paging requests.
  Series format/history queries roll up logical episodes, not alternate files.
  Merged query cards retain their verified inventory membership when loading
  full details. Duplicates includes distinct copies within one account and
  separate files for the same episode, but excludes out-of-scope index hints.
  Filtered alphabet offsets follow actual sorted positions, including non-Latin
  titles, rather than assuming the catch-all bucket comes first.
  Missing sort values stay last; original provider ratings remain distinct from
  externally enriched display ratings. Shares read existing catalog metadata
  without initiating per-item network enrichment or media probing.
  Share facets use the same representative movie/series metadata and local
  precedence as browse cards; filtered titles retain their native sort inputs,
  including exact local premiere dates. Shares do not offer critic/content-rating
  sorts without corresponding catalog metadata.
  Your Rating is offered only where the provider exposes a personal rating;
  Silo Rotten Tomatoes sorts require its authenticated ratings capability.
  Browse retains its paged grid,
  and video libraries can also switch to Collections and Playlists when their
  provider advertises those capabilities. File shares and collection/playlist
  members continue to open in Browse. Plex, Jellyfin, and Emby discover existing video
  playlists by actual member/library intersection; a mixed playlist appears
  in each matching library but opens with its full authored order. Music
  playlists remain in `MusicProvider`. Unsupported sources (including Silo)
  do not advertise a video-playlist mode. Snapshots are bound to the provider
  account and refreshed on the first page, not during poster scrolling.
