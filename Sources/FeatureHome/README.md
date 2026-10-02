# FeatureHome

Home rows, item detail, series/season experience, and the online-trailer
fallback when the user's server has no attached trailer.

## Responsibility

- **Home** — `HomeView` + `HomeViewModel` render the focused tvOS rows:
  Continue Watching, Latest, Recently Added (per library). `HomeLayout`
  centralises sizing/spacing so all rows feel uniform.
- **Multi-account aggregation** — `HomeAggregator` fans out across the
  active account set (`[ResolvedAccount]`) so Home is a merged view
  across multiple servers / profiles. Uses the `MediaProvider`
  abstraction; never imports a specific provider module.
- **Item detail** — `ItemDetailView` + `ItemDetailViewModel` and
  `DetailHeroView` / `DetailExtrasView` render the cinematic full-bleed
  backdrop, logo, overview, ratings, cast, and Play/Resume button. Works
  for movies, episodes, and people.
  Page ownership is identity-based, not an appearance-callback counter: repeated
  appearances and late departures cannot hide a different detail or give it the
  previous movie's trailer. A confirmed cancelled cinematic Back restores the page that
  remains on the real navigation stack, removes its cover/input guard, and keeps
  its controls focusable. Older transition completions cannot finish a newer pop.
  The bounded debug handoff journal records page membership, return outcomes,
  and hashed trailer ownership so an intermittent failure can be inspected
  without restarting the affected app.
- **Series** — `SeriesDetailView` + `SeriesResume` provide one stable
  series backdrop with focus-driven season tabs and an episode rail; the
  hero text updates as focus moves without distracting backdrop swaps.
  The compact logo above Seasons fits wholly inside its 200pt slot, including
  tall wordmarks; it does not use the full hero's flexible height allowance.
  This changes only artwork sizing, not season/episode focus geometry.
  While the browser reveals, only the outer page's native scrolling is held:
  horizontal episode focus stays live without provoking a second vertical
  scroll that lifts the logo. The page restores normal scrolling when the
  reveal finishes or is cancelled. Season pills, resting episode artwork,
  loading cards, and About share the same leading keyline; card spacing stays
  on the trailing side rather than indenting the artwork.
  The shared hero/browser motion uses a finite 0.9-second curve with an earlier
  slowdown and gentle landing, including logo and backdrop parallax.
  A spring's logical completion leaves
  several points of upward travel after the apparent landing, even when the
  outer page never scrolls.
  When pinned navigation hides on detail pages, horizontal rows draw through
  the empty side gutter to the screen edge, including focused episode artwork.
  The sidebar's mask changes without replacing the scroll view, preserving
  browse position and restoring the normal feather when navigation returns.
- **Library browsing** — `LibraryBrowseView` + `LibraryBrowseViewModel`
  for the per-library grid behind a Home row. Video libraries can switch
  among Browse, Collections, and Playlists when their provider advertises
  those capabilities. Plex, Jellyfin, and Emby discover existing video
  playlists by actual member/library intersection; a mixed playlist appears
  in each matching library but opens with its full authored order. Music
  playlists remain in `MusicProvider`. Unsupported sources (including Silo)
  do not advertise a video-playlist mode. Snapshots are bound to the provider
  account and refreshed on the first page, not during poster scrolling.
- **Trailers** — `OnlineTrailerSource` and `TrailerResolutionCache`
  handle the TMDb → YouTube fallback when the server has no attached
  trailer, by routing through `ProviderTrailers.YouTubeTrailerProvider`
  to surface a real `PlaybackRequest`.
  Background hero trailers use one shared player. Detail departure stops its
  trailer unless the router is returning directly to a rendered, unreceded Home
  hero showing the same title with trailers enabled. Library, Watchlist, pushed
  grids, and covered detail pages cannot retain background audio. A cancelled
  or no-longer-frontmost detail resolver cannot start a trailer after departure.

## Home loading

Home gives inventory, each global feed, and per-library rows independent queues
of at most five operations each. Slow resume feeds cannot occupy the slots
needed to start other row types. Each global row arrives
once its own sources are complete, preserving cross-server deduplication and
ordering. A slow Continue Watching feed therefore retains its own skeleton
without holding up Watchlist, Recently Added, or per-library rows.

Enabled library rows start as soon as their inventory is known. Recently Added
and recommendation requests complete independently, in stable library/row slots.
Both shells use the same loading/error state; failed rows can be retried without
removing successful rows. Cancellation stops queued requests. Parent-series
identity lookups are coalesced per account and load, and incomplete Home content
does not overwrite the durable snapshot.

Showcase keeps its first-row anchor while that row loads; a lower row finishing
does not choose focus or scroll the page. Its leading loading card has a visible
progress indicator and can hold focus without making the other skeletons
interactive. The waiting card uses the loaded cards' shared focus treatment:
native TVUIKit for System, lighting/lift for Highlight, and glass for Outline.
Borderless effects belong to the artwork, not its wider layout/caption slot;
framed cards use the same concentric card surface as loaded content.
After the viewer navigates, it keeps the focused card when an earlier row finishes.
Classic Home preserves loaded cards' focus-binding hierarchy when an empty
earlier row disappears, so the new first row does not recreate its focused card.
Carousel rows share a native focus
section so Down can cross a loading row to reach usable content. Placeholder and
resolved heroes use the same row-recede geometry. The `PLZBOOT` row-ready events distinguish first usable
data from completion of the entire Home load.

## Showcase

`FocusHeroHomeView` keeps focus-driven movement and hero updates outside the
row-building view. Posters use the profile's full normal poster dimensions.
Preview headings have a 16pt inter-row spacer above them and more room below
before their cards. Only the active heading lifts, preserving its focus
clearance. That movement is a title-only drawing offset, not a rail
relayout. Native card/shadow drawing bounds remain intact.
Vertical movement uses a real `ScrollView` with additive native springs,
not a main-thread display link advancing the content offset. Each press adds
only its destination adjustment; existing springs keep running with their
original clocks and velocity. Stopping and recreating a spring on every press
makes held-remote navigation pulse between rows.
Springs and height keyframes start at the actual Core Animation commit, not an
earlier wall-clock timestamp. Otherwise a busy focus/layout update can skip
most of the first visible movement. Retargeting reads the native resolved clocks;
hosted coverage checks 90ms retargets and a deliberately delayed 150ms commit.
The mask and hero-column height follow the
viewport's presentation trajectory through the measured row anchors, not a
separate spring started by the destination change. Rapid Up can target Continue
Watching while the viewport still traverses taller rows; the height remains
unchanged until that viewport reaches the shorter-row interval. Smooth height
interpolation has zero slope at each anchor, avoiding a velocity jump on entering
or leaving the interval. Native keyframes are calculated once per retarget and
run on the compositor, without per-frame SwiftUI updates. Late row measurements
refresh that path from its painted position even if the destination is unchanged.
The lifted heading retains the same nonbouncing spring timing.
Focus still chooses the row and its
measured bottom edge determines the exact destination, preserving the hero,
heading positions and next-row peek. Only the outer viewport's automatic
scrolling is disabled to avoid a second competing focus-reveal animation;
horizontal rows stay native and retain their focus and scroll state. The rows
remain SwiftUI content in stable native hosts, including navigation and accessibility.
Each row retains its intrinsic vertical size rather than filling a host's height
proposal, including the custom-focus horizontal scroll views.
Hosts forward the public profile, styling and media-action environment values;
copying the entire SwiftUI environment also copies internal accessibility state
from the parent hosting tree and hides the hosted content from accessibility.
The media-item router retains a comparable identity within its navigation scope.
Refreshing its callback uses the latest route without invalidating every realized
card's context menu; enabling or disabling navigation still updates the menus.
Native-host coverage changes the route callback during upward navigation and
asserts that already-realized cards do not rebuild their action lists.
Vertical row owners remain in a `VStack`: the native model offset reaches its
destination before the presentation viewport does. A `LazyVStack` would recycle
rows that are still visibly passing through the viewport, especially during
repeated presses and reversals. Individual horizontal rails keep their normal
card windowing; preserving vertical owners does not realize every library item.
Repeated updates to an unchanged destination never cancel an in-flight scroll,
and Reduce Motion moves directly to the same anchor.
The first row rests at native scroll offset zero. Its measured height is
subtracted equally from the leading spacer and every scroll destination, keeping
the pinned geometry unchanged while letting the system sidebar button recognize
the top of Home. Native chrome still auto-hides farther down and returns at the
first row. The UI regression checks actual painted chrome, not just its
accessibility presence, including sidebar and detail returns.
The schedule badge sits 16pt above the logo slot; Showcase
constrains even tall logos to that slot rather than letting artwork grow into
the badge. The outgoing row tucks upward by up to 110pt behind the 24pt mask fade so no
bottom strip remains above the next row. This offset has its own native spring:
deriving it from the scroll view's logical geometry makes the returning row
release all 110pt immediately, ahead of the moving presentation viewport.
Earlier rows retain native Up eligibility;
making their entire mask transparent would break that navigation. Showcase's
backdrop uses wider leading and bottom gradients without lengthening its crossfade.
Crossfade is the only Showcase backdrop transition. The retired slide preference
is ignored when reading older settings without resetting the remaining choices.
Showcase's optional titles under cards remain in Customize Home > Home Layout;
they do not control title visibility elsewhere in the app.

Native poster layout slots use artwork size on both axes, rounding fractional
heights up so SwiftUI cannot round artwork down into its caption. TVUIKit's focus
margins settle after realization and draw outside that slot; feeding their
changing height into a lazy row shifts both the pinned row and hero during deep
horizontal scrolling. Hosted native-poster coverage checks this before and
after layout, and the Home UI regression traverses all 75 fixture cards.
Native poster overlays cache their logo/badge/progress composite at the current
display scale. Only that hosted overlay is rasterized; native artwork and focus
effects remain live, and changes to overlay content invalidate the cached image.

Discover hydrates and displays its saved candidates with the same featured-only
configuration used by Showcase's live curation. Without eligible cached content,
its stable row slot shows loading posters until curation completes, rather than
inserting a new row during navigation. A completed empty result removes the slot;
disabling Discover does not reserve it. Lower loading rows never take focus.

Metadata belongs to the current Home view-model identity (profile, account set,
and credential generation), never a process-global cache. Cached details only
fill presentation gaps in the current row record: watched/resume state, source
identity, availability, and the selected series remain current. Background
enrichment publishes batches of at most four, and focus-driven loads share the
same deduplication. Each title observes only its own metadata entry, so unrelated
enrichment does not rebuild the active hero. `FocusHeroMetadataTests` covers freshness and ownership;
`ShowcaseNavigationTests` covers geometry and native presented-frame hitches.
For existing-library coverage, the guarded physical driver supports
`--run-showcase-mixed`: it verifies on-screen Continue Watching, deep mixed-speed
paging, rapid reversals, sustained deep holds, stable vertical anchors, and
slow/fast tours through multiple real rows.
Its functional result is separate from `--measure-right` and
`--measure-vertical-burst` native hitch measurements. The driver accepts an
explicitly confirmed `PLOZZ_HOME_APP_CONFIGURATION=Debug-optimized` candidate
as well as Release; it never rebuilds or replaces the app under measurement.
Use optimized physical-device measurements for performance acceptance, not
simulator timing or passing navigation assertions alone.

## Detail watch-state updates

The shared `ItemDetailViewModel` applies account-scoped watch mutations to both
the displayed item and its separate source-picker records. Playing an SMB copy
must update a Plex-backed merged detail even when cross-server synchronization
is disabled, without changing the Plex copy's state. The next Play/Resume target
uses those same updated records rather than a stale pre-play position.

Local edits remain authoritative for the open page across delayed source
enrichment, snapshot restoration, and source switches while provider writes
converge. Metadata-only enrichment must not copy unified progress into an
untargeted physical source. Regressions cover the production stop notification,
source selection, completion, unwatch, and unrelated-account ID collisions.

## Invariants

- **Provider-agnostic.** All data flows through `MediaProvider`. No
  Jellyfin- or Plex-specific code paths above the provider seam.
- **Server art first.** External art (`MetadataKit`) is used as a
  fallback via `CoreUI.FallbackAsyncImage`, never as the default — the
  server's own backdrop/logo is always tried first.
  Shared logo views pair fallback lookups with the source item/account and
  metadata query. Memoized logos and in-flight tasks also distinguish artwork
  preference, so a missing server logo never gives unrelated titles a shared
  cache entry. A reused view rejects the previous title's image immediately.
- **`LoadState` everywhere.** Loading / empty / failure rendering uses
  `CoreUI.ContentStateView` so all surfaces feel identical.
- **No tokens in logs.** Provider calls log only opaque ids — never
  authorisation headers.

## Where to look first

- `HomeView.swift` + `HomeViewModel.swift` — the row composition.
- `HomeAggregator.swift` — multi-account fan-out.
- `ItemDetailViewModel.swift` + `SeriesDetailView.swift` — detail/series
  state coordination.
- `OnlineTrailerSource.swift` — the TMDb-keyless → YouTube fallback.
