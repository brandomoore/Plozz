# Hero sources, trailers, and theme music

[Home task map](../../Sources/FeatureHome/README.md#where-to-look-first)

## Trailer source policy

Trailer discovery and playback honor the active profile's `trailerSources`
policy in `HeroBackgroundSettings`. Off skips trailer-specific provider and
metadata lookups; Server only also excludes server-supplied and cached YouTube
links. Ordinary metadata and non-trailer extras remain independent. Allowed
manual trailers are prepared during detail loading, not on button press.
Policy changes filter visible actions immediately, fence pending results, and
refresh allowed sources without caching disabled lookups as missing trailers.
Home and detail autoplay use the effective settings rather than the stored
surface choices, so turning trailers off preserves those choices and does not
disable detail theme music.

## Theme music

Theme audio is owned by `FeatureHomeCore.ThemeMusicController` and the shared
`themeMusicScope` / `themeMusicPlayback` modifiers on both TV and mobile.
Only the frontmost active detail owns playback. Full video, Live TV, hero trailers,
and full music playback take precedence. Volume changes update the same player
without re-resolving or restarting a source. Leaving a detail for Home or a library
fades its current volume to silence over 750ms before releasing the player.
App inactivity uses the same bounded fade before pausing, then resumes the retained
timeline with a fade-in on return. Rapid returns cancel the outgoing fade without
discarding the item. Forced termination cannot guarantee a fade. Playback
suppression, authorization changes, and audio interruptions still stop or pause
immediately. Settings previews instead stop and
require a new adjustment or Play action. Late resolution cannot revive a stopped
preview, switch profiles, or bypass current playback suppression.
Each detail instance owns a separate theme-playback token, even when a repeated
title has the same account/item ID. Covered pages cannot release another page's
audio. Both shells re-resolve themes through the currently authorized provider,
not a provider retained by an old detail model. Profile/account/effective
credential changes invalidate playback; live authorization is rechecked after
theme and authenticated-URL resolution, including for public theme URLs.
Audio-interruption changes cancel pending resolution and retry the still-current
foreground detail when the interruption ends.
On iPhone and iPad, active detail theme music uses the trailer mute button's
trailing toolbar position. Mute changes the existing player's audio without
changing the saved volume, restarting playback, or interrupting its fade.
It survives temporary app inactivity but resets when that detail playback ends;
settings previews and another profile do not inherit it. The control is absent
for a covered page, another item's theme, or a settings preview.

## Kids Discovery

- **Kids Discovery policy** — both shells consume the live profile's effective
  Hero settings, not a destructive rewrite of saved preferences. Kids profiles
  exclude external Discovery, including Showcase, cached attributed titles, and
  delayed network results. The shared runtime checks authorization before and
  after awaits; curation and final display reconciliation apply the same restriction.
  Cache configuration includes the policy even when Discovery was already switched
  off. Public provider caches stay profile-independent; server-owned library titles
  continue to follow the selected server user's access rather than an invented
  app-wide maturity threshold.

## Home composition and hero behavior

- **Home** — `HomeView` + `HomeViewModel` render the focused tvOS rows:
  Continue Watching, Latest, Recently Added (per library). `HomeLayout`
  centralises sizing/spacing so all rows feel uniform.
  Share polling and scan-triggered row reloads only run while Home is frontmost
  and the scene is active, never behind playback or a pushed page. The shared
  content coordinator separately handles foreground/retained-page returns.
  Hidden catalog changes coalesce until Home returns; overdue polls resume once
  rather than catching up in a burst. Ordinary catalog
  changes still respect the trailer and navigation-idle guards. This does not
  disable background synchronization or discard pending library updates.
  On mobile, a root-owned `LazyViewState` retains the shared Home/Watchlist
  model by profile, credentials and active accounts. Rebuilding the tab shell
  for settings/theme changes must not construct and rehydrate throwaway models.
  The full Watchlist grid filters All, Movies, or TV Shows and sorts by Date
  Added, Release Date, or Name, in either direction. Its choices are retained
  with that profile's Home model and persisted separately from library queries.
  Synced choices and resets refresh that retained model without writing back;
  local edits preserve other choices received before a change notification.
  Home's Watchlist row and the canonical union order are unchanged. Filtering
  never fetches another list or changes membership; controls remain available
  during loading, errors, and empty results.
  On TV, navigation enters the available cards rather than the query controls.
  The outer Watchlist scroll view owns Top Bar scrolling; Back restores both
  the header and navigation to the top.
  Date Added uses the Watchlist add time, never a library/catalog add date or
  import time. Local actions and available Plex, Trakt, and Simkl dates survive
  publication and native caching. Undated/tied entries retain source order after
  dated entries in either direction; duplicate native entries use the earliest
  known add across enabled sources. Release dates survive alias presentation and
  owned-copy retargeting; missing exact dates use the shared library comparator.
  Queries apply to resolved titles from every provider, including mixed-server
  and network-share lists. Existing Jellyfin, Emby, or Silo entries without a
  Watchlist-add timestamp keep their source order; Plozz's own add actions retain
  their actual action dates for every provider.
  Watchlist artwork rehydration shares URL sanitization and signing only within
  one synchronous publication batch, including repeated cast images. Cache keys
  preserve artwork ownership, playback fallback account and requested size;
  no signed result survives into another profile or credential publication.
  Mobile cards defer identity-index source resolution until direct-play activation
  or the detail destination's body. Browsing and metadata updates do not resolve
  every visible card. Activation reads current accounts/index contents while
  preserving explicit detail editions and folder/collection routing.
  Both platforms recheck hero Watchlist membership immediately, but memoize
  supporting-source identity tokens by the full current row values. No
  supporting index is built without exclusions; source-scope changes clear it.
  Mobile and TV share the Hero slot policy: pending curation reserves a placeholder,
  available items render the Hero, and a completed empty result removes the slot
  and its spacing. Mobile also skips the placeholder immediately when Collections
  has no selections or Discovery has no enabled providers and no other source is
  configured. Completion belongs to the current curation inputs and profile;
  cancelled work cannot settle a replacement request. This never changes saved
  preferences or treats a failed fetch as authority to erase cached candidates.
  New profiles enable Continue Watching, Recently Added, Random from Library,
  and Watchlist; Collections is opt-in. They include Discovery in the carousel
  only while Seerr is configured.
  Explicitly toggling Discovery saves that profile's choice, independent of later
  connections or disconnections. Other Hero edits retain the automatic default,
  and temporary Seerr reachability failures do not change it. Existing saved
  source lists retain their selection; Kids restrictions still take precedence.
  The developer first-run reset preserves saved Hero preferences, including the
  default profile's unsuffixed settings. Repeating onboarding through that reset
  is not a fresh-settings test; use a new profile namespace to verify defaults.
  Showcase's separate Discovery row remains opt-in.
  On iPhone and iPad, tapping the Home hero artwork, logo or metadata opens its
  item/provider detail page instead of a separate More Info button. The artwork
  link sits behind the non-interactive metadata and foreground actions, so Play,
  Watchlist and requests stay independent. Horizontal paging and vertical scrolling
  do not open details; in-flight page transitions disable the artwork link.
  VoiceOver exposes the artwork as More Info with the current title.
  Mobile Home stays stationary beneath a pushed detail page. A transition-scoped,
  non-interactive snapshot covers the outgoing page's native parallax and is
  removed on completion or cancellation; destination animation and native Back
  gestures remain owned by the navigation stack.
  Opening an episode/season's parent show keeps the known hero artwork and title
  visible while the provider resolves the series, on both iPhone and iPad.
  This read-only preview does not start trailers or expose playback actions;
  lookup failures still show the existing error and retry action.
  The tvOS More Info button is unchanged.
  Mobile Home and detail hero actions share native Liquid Glass buttons on iOS 26+.
  Primary actions use the prominent style with their existing monochrome theme
  tint and contrasting label; secondary actions use untinted glass. The existing
  solid styles remain on older systems and when transparency/panel glass is reduced.
  Native controls own the glass and press treatment; tvOS and multiview are unchanged.
  Request Seasons is a primary button, not a dropdown. Home and request-only
  detail heroes open the same Seasons sheet with per-season status, Request All
  Missing, refresh/retry and the active request identity. Unknown/loading status
  still opens that sheet; failures never enable a whole-series request.
  Home pauses hero navigation/auto-advance while the sheet is open, dismisses it
  when the request profile/server changes, and presents confirmations/errors in
  the sheet without bypassing the existing request-context checks.
  Closing the sheet starts a fresh carousel dwell interval. Status polling
  continues for the selected series while the sheet is open; a lookup superseded
  by a sheet/manual refresh is not treated as a server failure.

## Discovery ownership

- **Discovery ownership refresh** — Home carousel and Showcase reverify Featured
  titles when the active library identity index publishes, independently of Hide
  Watched. This cannot use the watch-history-only fast path: an external title
  needs a freshly verified, enabled-library copy before it can offer Play.
  Existing slides remain visible and keep their identity while verified routing
  arrives. Mobile uses the same discovery-verification policy. Shared Home/detail
  movie actions never offer Request for Seerr's Available or Partially Available
  status without local playback proof; the title remains navigable instead.
  Series retain their season picker for requesting genuinely missing seasons.
  Public discovery refreshes preserve the current slide's Seerr status when local
  verification remains inconclusive; only live status updates may reset that
  state to Unknown or Deleted. Failed or disabled local copies never gain Play.
  Status survives library-visibility resets only within the same request context.
  Changing the profile/Seerr connection clears old status and optimistic request
  overrides; a different server cannot inherit Available or download progress.
  If a curated movie or show has strong catalog identity but no index entry,
  shared TV/mobile metadata enrichment uses the existing cross-server search to
  recover its library copy. Only the final carousel candidates are probed, with
  four titles in flight and a cooperative four-second search/verification budget
  per account and title; the full Discovery feed is never searched this way.
  Accounts search and verify independently, so a timed-out account cannot erase
  another account's verified match. Searches honor disabled libraries and retain
  enabled-library provenance even when detail records omit it. Search hits
  still require a live, identity-matching record in an enabled library. An
  existing index-verification rejection is not retried as a missing entry.
  Policy or library-visibility changes and cancellation discard late results.
  Recovered shows resolve a real episode and use the library's metadata/ratings;
  Watched roots retain their evidence instead of being replaced by an unwatched
  episode. Both shells update the visible set and launch candidate pool with that
  evidence before applying Hide Watched, including to an already pinned slide.
  Showcase retains its existing stable-lineup policy. Optional external and
  server-plugin ratings remain cache-only on Home.

## Collections hero source

- **Collections hero source** — an opt-in source mixes individual movies and
  shows from multiple account-qualified collections across libraries, not collection cards. TV and
  mobile use the same `MediaProvider.collectionMembers` loader and existing
  watched-title, artwork, freshness and source-mixing rules. A session-seeded,
  bounded window per collection gives large collections coverage beyond their first page
  without enumerating entire collections on Home. Loads are serial within this
  source, each sampling at most 48 members. Round-robin sampling retains alternate
  copies through eligibility checks. After applying current watch mutations,
  Hide Watched excludes a title if any matching selected copy has been watched,
  even before the identity index is warm. All sampled selections participate in
  filtering and freshness ranking before the candidate cap, which counts distinct
  title groups without dropping their alternate artwork. Bounded artwork checks
  choose the first usable copy per group, preserving its provider routing and
  artwork while carrying the group's identity aliases and per-copy watch history.
  Cached slides therefore recognize later account-scoped watch mutations without
  a warm identity index, and final source mixing still shows each title once. Short pages
  follow the reported total, while duplicate/non-progressing pages fail the
  whole load. Cancellation and fetch failures are distinct from a confirmed
  empty collection. Selection changes invalidate the cached lineup; account
  and library availability are rechecked for live and persisted candidates.
  A failed or cancelled collection does not turn a partial aggregate into
  authoritative success. The cached collection bucket has no individual
  collection-membership attribution, so losing access to any saved selection
  requires fresh sampling instead of reusing that bucket.
  Personal collections are account/server-viewer scoped with no invented library;
  mixed movie/show members retain their own known library attribution and the
  existing Home visibility rules. Legacy single selections and cache keys migrate;
  an explicitly empty selection array never restores the old single choice.

## Trailer playback and handoff

- **Trailers** — Server-owned trailer files retain in-app playback and take
  priority across the title's server copies. Server-supplied YouTube links and
  TMDB's documented videos API supply external trailer actions. Hero trailer
  buttons are always icon-only, using the shared cutout-arrow `TrailerActionIcon`
  for external links. "Watch on YouTube" is a VoiceOver label, not visible button
  text; overflow menus use "Trailer" with an external-opening symbol.
  `YouTubeTrailerOpening` opens the YouTube app, with browser fallback on mobile
  and a visible failure on TV when no handler is available. Returning to Plozz
  is manual; no completion callback or QR fallback is implied.
  App links retain the complete `www.youtube.com/watch?v=…` host/path/query with
  the `youtube` scheme; an abbreviated link may launch the TV app without
  navigating to the requested video.
  No YouTube scraping, stream extraction, embed probing, or media caching runs
  during browsing or playback. Household metadata settings and the active TMDB
  credential apply; unavailable external metadata never removes server trailers.
  `TrailerResolutionCache` stores link decisions, not media/playability claims.
  Its new namespace does not reuse old extracted/scraped decisions.
  Background hero trailers use one shared player. Detail departure stops its
  trailer unless the router is returning directly to a rendered, unreceded Home
  hero showing the same title with trailers enabled. Library, Watchlist, pushed
  grids, and covered detail pages cannot retain background audio. A cancelled
  or no-longer-frontmost detail resolver cannot start a trailer after departure.
  The shared handoff renderer initializes Core Image only when a decoded trailer
  frame needs a snapshot, on its own actor rather than Home's main thread.
  Idle Home does not initialize Metal for unused handoff snapshots; subsequent
  frames reuse the context. A completed snapshot cannot replace a newer trailer.
  Immediate live-surface moves retain a separate synchronous renderer, also
  initialized only after a decoded frame is available.
  Home transfers the matching trailer to detail before navigation starts (when
  detail trailers are enabled). Home disappearance and late scroll/recede
  callbacks cannot stop or pause that player; its item, position and live mute
  choice survive the handoff on TV and mobile. Leaving for another destination
  or backgrounding the app still stops ambient playback.
  Home, detail and featured cards share one persistent video layer, moved only
  into the owning surface's mounted host. Offscreen navigation hosts cannot take
  it, and there is no second invisible layer competing for decoded frames.
  Hero + Showcase uses the same round-trip contract: covering Home retains its
  same-title return receiver and suspends carousel advancement. Returning restores
  the trailer's elapsed timeline rather than restarting or immediately paging.
  Scoped detail cleanup requires an exact handler owner, including while a
  pre-navigation transfer has no handler; delayed featured focus cannot take
  a trailer already owned by detail.
  A trailer handoff bypasses artwork covers in both navigation directions;
  cached or late artwork cannot cover live video. Home renders trailer visibility
  from the shared controller on its first returning frame, and the outgoing video
  host holds a decoded frame while the persistent layer moves.
  Routers register the exact source ID selected for the destination alongside
  the Home ID. This is a playback-scoped alias, not a title/name match: it retains
  the original player through source selection and is cleared when playback stops
  or changes to another item.
  On tvOS, Up from the hero action row opens an already-playing trailer with
  Plozz's regular full-screen play/pause and seeking controls. Home enables this only with
  Pinned Sidebar: Top Bar and native Sidebar retain their Up navigation. Detail
  pages allow it with every navigation style and briefly show "Up for playback
  controls" above the hero after two seconds of eligible focus. The hint reuses
  Showcase's upward chevron and never adds a focus stop. The Trailer button uses
  the same presentation when that title's ambient trailer is already playing;
  otherwise its existing provider/external-link route remains available.
  The same player, item and decoded video layer are lent to Plozz's shared
  transport UI, with a cross-dissolve instead of a sliding modal. Reduced Motion
  removes the dissolve. There are no competing video renderers or source reloads.
  Full-screen playback enables sound
  temporarily, freezes Home's carousel, and retains the finished item for seeking
  or replay. Back returns to the same page at the current position, restores the
  ambient mute choice, and resumes the hero. An actual stop/profile departure
  invalidates the presentation so dismissing it cannot revive old playback.
  On Back, a retained trailer frame covers the outgoing player while the live
  layer returns to the hero before the dissolve begins. Carousel and focus
  callbacks remain suspended until dismissal completes; the hero is never
  revealed while its video surface is still in the full-screen player.
  The session weakly remembers the actual entry host so transient SwiftUI
  registrations cannot displace a still-mounted return destination. If that
  host leaves the window or changes owner/role, the current registered host
  remains the fallback; ending or stopping the session clears the reference.
  A pending or failed Home trailer keeps the normal artwork dwell, not the
  advertised trailer duration. Preparation is bounded to eight seconds and
  abandoned when its item is replaced. Only ready playback extends the timeline;
  a later failure clears that extension so the carousel can continue.
