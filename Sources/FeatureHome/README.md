# FeatureHome

Home history completion records returned, curated and visible item counts plus
failed-account counts in the existing bounded recent-activity log. This separates
an empty provider feed from local curation without recording media or account IDs.

Home rows, item detail, series/season experience, and the online-trailer
fallback when the user's server has no attached trailer.

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

tvOS detail entry keeps the real primary action focusable while its play target
loads. An early press queues one activation, replacing the icon with a spinner
without resizing the button. Readiness consumes that intent once through the
normal playback callback; a pending series request opens the normal season
chooser, never a bulk request. A fresh Select during the cinematic entrance
queues only while the target is unavailable. A ready action finishes the
decorative entrance immediately rather than waiting for its animation or artwork;
the opening press, cancelled presses, and return-transition input are not replayed.
Leaving/covering the page, scene inactivity,
profile/request-identity changes, explicit source/version changes, or entering
the episode browser cancel the intent. Failed/empty resolution clears it and
retains the existing error/retry presentation. Late episode resolution must not move focus back from a
secondary action the user selected. Request/status actions retain the same
leading-entry preference, and returning from a child preserves source focus.

## Request status

Movie request statuses in Home and detail heroes use the same
`Requested · Unreleased` wording as season requests. This is an approved request
with a known future release day, not a prediction that downloading will start on
that day. Pending approval stays Requested; library availability and reported
queue activity take precedence, including queue items with no measurable progress.
Release days use the viewer's local calendar day, and missing dates are not guessed.
The UIKit and SwiftUI hero renderers share the localized status and calendar symbol.

## Responsibility

Global Continue Watching and account-wide server Next Up are the active accounts'
viewing history, independent of library/catalog visibility. This applies to
combined and individual-row layouts, detail resume hints, and Top Shelf. Hiding
catalogs must not empty history or fan it out into catalog-scoped requests.
Library-specific rows, discovery, account selection, server-user permissions,
and parental authorization retain their existing boundaries. A catalog-load
failure does not replace a successful history response with that failure.

Home text sizing applies to both SwiftUI and persistent UIKit foregrounds.
Detail Page, Showcase, and library Recommended have independent profile-scoped sizes.
Title fallbacks, descriptions, metadata, and badge details scale together;
artwork sizing and action controls remain independent. On Apple TV, Detail Page
text sizing also scales the episode titles and three-line synopses below episode
artwork, including loading placeholders; other row/card labels remain independent.
Home's text column can use the same wider budget as an enlarged logo, even at
default Text size. Smaller logos retain the original reading width; changing
Text size alone never widens it. Both TV foreground renderers share this rule,
and mobile Home remains capped by its available screen width. Apple TV Detail
descriptions can grow to the live facts/badges row's width, within the shared
reading-width limit and the space reserved for right-side credits. Showcase
and Recommended keep their existing column widths.
Apple TV descriptions default to 24pt with 3pt additional line spacing; the
slider spans 18–36pt. Detail descriptions stay capped at four lines, while Home
may gain a fourth line when enlarged. Mobile typography is unchanged. Their scrims
extend upward by the larger of the requested logo growth and description-height
growth, without weakening default coverage or resizing the artwork.
Showcase and Recommended keep their row positions and description budgets.
Custom sizes use the actual space above the active row, not a fixed worst-case
footprint. They fit the complete logo/metadata block down by one shared factor
only when that space is insufficient; the requested proportions stay intact.
Incoming titles use their destination size from the first frame, not a smaller
transitional size. The native motion owner adjusts placement and the row mask
together to protect the title while rows move, including reversals.
Recommended sizes against the destination's navigation clearance immediately,
but reserves the outgoing header's space until it fades. Custom Recommended
uses the logo's actual artwork height and the header's existing bottom padding
rather than reserving empty logo space or a second navigation gap.
Default Recommended sizing retains its existing constrained layout.

Shared typography and future app-wide scale composition are owned by
[`CoreUI/PlozzTypography`](../CoreUI/README.md#responsibility), not individual heroes.

Home Continue Watching failures use the existing Details / Try Again actions on
TV (including focus-following layouts), iPhone and iPad. The report follows the
same failed source as the visible error and retains bounded, task-scoped HTTP,
decoding, paging and transport evidence. Retry/success clears stale reports;
cancelled or superseded requests cannot publish diagnostics into another load.
Reports contain provider and route categories, never account identifiers,
server addresses, credentials, media IDs/titles or response bodies.

Playback inventory failures on automatically selected TV sources use the existing
untried-account failover before constructing a player. Every replacement still
loads authoritative inventory; explicit selections, cancellation and revoked
presentation scope never fail over. An unavailable unselected edition is logged
and omitted from the current picker rather than blocking a confirmed primary.

The shared version gate and detail/episode inventory enrichment emit bounded,
failure-only `plozz-preparation-1` records to Recent Activity. They identify the
request stage, elapsed time, HTTP/network failure, safe decode field/type, and
inventory validation reason. Identity checks name the mismatched dimension, not
the item/account values. The existing Send Recent Activity action includes these
records on both platforms; error dialogs, playback routing and timeouts are unchanged.

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

- **Explicit version inventory** — providers that advertise lazy file discovery
  expose Version regardless of the cached source count, but load it only after
  that action is opened. Home, detail dwell, returning to a page and passive
  episode badge enrichment use presentation metadata, never playback inventory.
  Publication is fenced by the current source and the picker task's cancellation;
  later sparse metadata cannot erase authoritative file choices. Same-account
  alternate files use the same sequential discovery as the Play gate.
  Failure keeps browsing available but never authorizes playback: Play runs its
  own strict gate. Providers with complete detail inventories incur no extra fetch.
  Series heroes enrich the playable episode's ordinary metadata. Explicit
  mobile source/version actions use that episode even while
  the hero shows the series' artwork and description, matching tvOS. Choosing a
  version therefore remembers the episode/series preference, not a container file.
  A confirmed no-stream result from explicit detail discovery replaces Play with
  `No streams found` on both platforms. It rechecks the selected source without
  starting playback; successful recovery restores Play. This page-local result is
  scoped to the active server and episode, not inferred from timeouts, missing
  metadata or generic source errors. Retry failures remain visible and secondary
  mobile actions continue to overflow before the primary label is squeezed.

- **Kids Discovery policy** — both shells consume the live profile's effective
  Hero settings, not a destructive rewrite of saved preferences. Kids profiles
  exclude external Discovery, including Showcase, cached attributed titles, and
  delayed network results. The shared runtime checks authorization before and
  after awaits; curation and final display reconciliation apply the same restriction.
  Cache configuration includes the policy even when Discovery was already switched
  off. Public provider caches stay profile-independent; server-owned library titles
  continue to follow the selected server user's access rather than an invented
  app-wide maturity threshold.
- **Home row customization** — Settings > Screens & Navigation > Customize Home > Rows
  uses the same arrangement editor on TV, iPhone and iPad. Tap a row to configure
  it, Edit to reorder or remove it, or Add row to choose a collection or another existing feed.
  Layout/Hero and Card labels have separate destinations. Rows from different
  libraries can be interleaved, reordered or hidden, including the Libraries
  tiles. `HomeRowCustomization` stores typed identity, order and explicit
  visibility inside the profile's existing Home settings blob; profile transfer
  carries it to other devices. Editing available rows preserves offline keys.
  `HomePresentationRow` resolves the one list consumed by standard, carousel,
  Showcase and mobile Home. Hiding every row retains an escapable TV notice.
  Fresh profiles select **Match server**: one server follows its available Home
  arrangement; multiple servers combine common rows while retaining their other
  native default rows. Unsupported sources keep their provider-style library rows.
  It adapts to source changes until a manual row edit freezes a **Custom arrangement**. Choosing Match server
  again resumes adaptation. **Combined rows** starts with cross-library rows
  regardless of source count. Existing legacy arrangements remain unchanged.
  Both presets put **Libraries** last among visible rows, after Live TV and any
  newly discovered default rows, even when the server lists Libraries first.
  Custom row positions and hidden Libraries choices remain unchanged.
  Global rows say **All libraries**; native server and library rows identify their
  source. All can be freely interleaved. Changing presets requires confirmation;
  selecting the already active preset does nothing.
  **Include Next Up** is a profile-scoped setting inside the **Continue Watching**
  section's configuration on every platform, alongside its artwork choice.
  **Continue Watching action** chooses **Play** (the unchanged default) or
  **Open details** for movie/episode cards on Home, including merged Next Up
  entries and every TV Home layout. It persists and transfers with the profile.
  Artwork, progress overlays, context menus and Live TV tuning are unchanged.
  Library Recommended rows retain their existing detail navigation.
  On Apple TV, the remote's center button follows this choice, while Play/Pause
  always starts the focused Continue Watching item through the normal playback
  path. Play/Pause never opens details, including when **Open details** is selected.
  Normal resume/restart and version-choice prompts still apply.
  It uses the provider's combined resume/next-episode feed without changing the
  preset, library exclusions, or other row choices. Separate Next Up rows are
  neither requested nor presented while merged; the arranger omits them rather
  than treating them as explicitly hidden. Their previous visibility and positions
  survive other row edits and return when merging is turned off. Hiding Continue
  Watching suspends the merge so Next Up does not disappear with it. Preset changes
  retain the merge preference, and older profiles keep their existing behavior.
  Providers whose native feed already combines next episodes retain that behavior
  when the override is off. This does not synthesize Next Up for network shares.
  Jellyfin uses its saved web Home preferences, Emby its native Home sections
  with an older-server fallback, and Plex its promoted hubs—not another client's
  private sidebar pins. Unsupported providers retain their normal default rows.
  Matching excludes music and reading. Derived layouts are cached locally by
  account/server/viewer (including the selected Plex Home user), separate from
  profile-synced arrangement intent. Effective credentials fence in-flight discovery
  without putting ephemeral revisions or tokens in the durable cache. A real
  refresh or opening the arranger can refresh them; there is no polling timer.
  Native content requests batch by account and library so several Plex rows
  reuse one promoted-hub response. Sharing lasts only for that refresh; it never
  leaves Next Up stale behind a cross-refresh item cache.
  Native Continue Watching keeps the complete feed through bounded pages, applying
  library exclusions before a presentation limit. Retained native rows immediately
  honor current library visibility while discovery is pending or offline.
  Connection failures identify the affected server. The Home row arranger names
  each failed server, distinguishing offline, sign-in, and Home-loading problems
  instead of showing a blanket warning about server arrangements. Recovery clears
  that server's status; failures never reset saved row choices.
  Enabled sections missing their content retain a compact warning on Home with
  source, Details, and Retry. Customize Home shares the same completed-load
  evidence, distinguishing typed failures, empty results, and saved sections
  absent from the latest refresh. Missing sections do not prove a server error:
  dynamic recommendations may be empty or changed. Normal empty default library
  feeds remain quiet unless explicitly added. Existing usable cached/partial
  cards remain visible, with any load warning available in the editor.
  Empty and failed Home rows use the same header and keyline as populated rows,
  including pinned-navigation clearance. Status/source and native recovery
  actions stay compact; they do not use a full-page error panel or reserve an
  empty poster wall. Mobile uses its ordinary media-section heading and insets.
  Warnings are runtime-only, scoped to the current profile, accounts, server
  users, credentials, and settings; cancellation is not a failure and successful
  recovery clears the warning. Details expose safe error categories, not URLs,
  credentials, or response bodies.
  Mobile library discovery follows the effective credential and Plex Home viewer,
  and cancelled lookups cannot restore another viewer's library choices.
  The section catalog enumerates optional recommendations only while the editor
  is open. Authored collection rows have independent stable section identities,
  names and poster, landscape or Featured presentation. Each references one account/viewer-qualified
  collection through `MediaProvider`; its bounded preview preserves server order
  and membership, showing supported movie and series cards without reconstructing
  library membership. **See all** opens the existing collection browser using
  the original provider ID. All card styles open title details.
  This member-row layout is separate from collection **covers**. Lists and Home
  or Recommended rows containing only collection containers use a uniform
  Auto/Posters/Landscape cover layout. Overrides are profile-scoped and keyed
  independently by Home row or account/library/browser/Recommended row. Browsers
  resolve Auto from the initial page and retain that shape through later pages.
  Cover layout controls live only in Settings: Customize Libraries owns each
  library's collection browser and Recommended rows; Customize Home owns Home
  rows. Browse headers contain query controls, not cover appearance controls.
  Landscape collection covers still open the collection, never direct playback.
  Collection definitions persist with the profile separately from arrangement:
  removing a row or choosing a preset retains its configuration in Add row.
  Disabled libraries and a different server viewer prevent collection requests;
  failures remain distinct from empty collections.
  Successful Watchlist server writes (add **and** remove, including retries or
  reconciliation that actually writes) quietly refresh the affected profile/viewer's
  configured collection rows. Read-only reconciliation, unchanged confirmations,
  optimistic local intent, and navigation do not schedule this extra pass; normal
  Home loads retain their existing behavior. Watchlist/Watch Later/My List-like
  names are prioritized, not used to exclude custom names. Changes coalesce for 750 ms; one utility task
  reads at most 20 members per collection, with 250 ms between previews and one
  follow-up after three seconds for server automation. Duplicate collection sources
  share a request. A new confirmation wakes a pending deadline without cancelling
  an active preview or skipping the pacing delay. Unrelated accounts/feeds, library inventories, artwork caches,
  and Top Shelf are untouched. Navigation postpones requests/publication; full Home
  loads cancel and supersede in-flight previews. Unchanged rows are not published,
  failures keep prior items with diagnostics, and snapshot writes are coalesced.
  This bounds client work by configured rows, not server size; external automation
  may still take longer than the follow-up window.
  Naming evidence includes Kometa's
  [My Watchlist example](https://kometa.wiki/en/latest/files/builders/plex/watchlist/),
  [community collection configurations](https://github.com/Kometa-Team/Community-Configs/blob/ca959423cd75f49397311eac865901096f7ac609/ladywhiskers/movies/movies_watchlist.yml),
  YouTube's [Watch Later](https://support.google.com/youtube/answer/56101?hl=en),
  and Netflix's [My List](https://help.netflix.com/en/node/10523).
  These are observed conventions, not a prevalence survey or an exhaustive
  multilingual dictionary. Names do not establish that a collection is a watchlist,
  and this does not add support for third-party plugins with separate watchlist storage.
  Featured is available only for authored collection rows. Large artwork cards
  place the title logo (or text fallback) and real metadata at the lower left.
  TV rows reuse the standard media-row heading and See all action, with the same
  pinned-navigation keyline, leading fade and card-slot parking as ordinary rows.
  System-focus Featured cards share the image-based native poster renderer.
  Physical comparisons reproduced the exposed edge with SwiftUI card buttons,
  including a flattened label, but not with the native image renderer. Do not
  restore that card surface or the generic hosted `TVCardView` bridge, which can
  retain enlarged artwork after held directional navigation. One artwork
  resolution supplies the native image and its live composition. Artwork,
  video, scrim and metadata use the public image overlay surface with its shared
  outer clip; do not add individual image/video clips or rasterize live video.
  Featured disables the ordinary overlay's additional rounded clip so its
  scrim covers bright backing artwork through the corners throughout focus
  transitions. The native image surface alone supplies the outer silhouette.
  The TV scrim extends 40pt beyond each edge without moving its fade stops or
  changing the image, video and metadata layout. This covers oversized
  aspect-fill pixels during native settling; the live composition must not
  apply a rectangular clip that would discard that extra coverage.
  Ordinary poster overlays retain rasterization. Non-system styles retain the
  shared focus fallback. TV widths round outward to multiples of four points,
  keeping both dimensions integral and the 4:5 ratio exact. Keep native clip geometry in
  whole points rather than rounding each dimension separately to physical
  pixels. Standalone previews and mobile cards keep their own outer rounded clip.
  Rails reserve the shared shadow clearance without increasing row spacing.
  Full-bleed Home artwork preserves the measured trailing title-safe inset for
  row actions. Remote-driven coverage checks resting painted sizes after rapid
  navigation; simulator rendering is not proof of physical remote-tilt behavior.
  The focused TV card or settled visible mobile card can play a supported
  local/server trailer, using the profile's Home trailer enable/mute preferences.
  A shared coordinator arbitrates visible rails and borrows the existing hero
  player; it never creates per-card players or performs online trailer extraction.
  Scrolling away, navigation, backgrounding, source changes and full playback
  cancel the preview. Reduce Motion keeps the cards static. Missing or failed
  trailers retain artwork. Mixed feeds, filters and library-page placement are
  not part of this slice. Home omits
  unselected row-family requests and stops a recommendation family after all its
  known rows are hidden. The separate library Recommended screen and Showcase's
  optional external Discover row are not redefined by these Home preferences.
  Live TV contributes typed cached channel cards to Continue Watching and its
  own optional row, never VOD items. Cache bounds, authorization and managed
  tuning are documented in [Live TV](../../docs/live-tv-prototype.md).

- **Home** — `HomeView` + `HomeViewModel` render the focused tvOS rows:
  Continue Watching, Latest, Recently Added (per library). `HomeLayout`
  centralises sizing/spacing so all rows feel uniform.
  Share polling and scan/foreground-triggered row reloads only run while Home
  is frontmost and the scene is active, never behind playback or a pushed page.
  Hidden catalog changes and app-foreground refreshes coalesce until Home returns;
  overdue polls resume once rather than catching up in a burst. Ordinary catalog
  changes still respect the trailer and navigation-idle guards. This does not
  disable background synchronization or discard pending library updates.
  On mobile, a root-owned `LazyViewState` retains the shared Home/Watchlist
  model by profile, credentials and active accounts. Rebuilding the tab shell
  for settings/theme changes must not construct and rehydrate throwaway models.
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
- **Multi-account aggregation** — `HomeAggregator` fans out across the
  active account set (`[ResolvedAccount]`) so Home is a merged view
  across multiple servers / profiles. Uses the `MediaProvider`
  abstraction; never imports a specific provider module.
  All Libraries keeps reachable sources when capability preparation, query facets,
  inventory discovery, or duplicate-card hydration encounters an unavailable source.
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
- **Mobile Home posters** — portrait rails fit two full posters below 375pt,
  three on larger phones, and a 28% preview at standard density. Wider windows add columns;
  per-profile display-size choices scale the result. Loaded cards and placeholders
  share `PlozziOSHomeRailLayout`, and their artwork starts on the heading keyline
  after subtracting each card style's internal inset. Smaller mobile artwork uses
  proportionate corners and a 20pt minimum watched badge, without shrinking folder
  navigation badges. Continue Watching geometry and library grid columns are unchanged.
- **Showcase artwork lookahead** — A separate observer warms the policy-selected
  preview and logo for up to five nearby titles plus the leading title of either
  adjacent row. It shares the bounded background queue and artwork caches with
  Continue Watching, without observing focus in the view that builds the rows.
  Changing focus, rows, source references, or provider settings replaces only
  obsolete preparation; leaving Home cancels it. The native navigation and
  row/hero motion never await artwork or metadata.
- **Card labels** — Appearance > Cards owns profile-scoped App default,
  Show labels everywhere, and Hide labels everywhere presets, with
  On / Off values edited directly in a flat list of experiences. Editing enters
  Custom mode; selecting any preset replaces all per-view choices.
  App default shows labels during ordinary browsing and on detail-page episodes;
  it hides them in Showcase and on Continue Watching cards that carry a title on
  their artwork. Manual presets apply to all media captions, including those cards.
  Existing explicit global and per-view choices survive migration.
  Showcase is presentation context within Home or library Recommended, not a new
  override scope; destination scopes clear that context and hosting boundaries forward it.
  Home, Recommended, Browse, Collections, Playlists, Search, Watchlist, related titles,
  episodes, extras, and filmography resolve the same policy on iOS and tvOS.
  Explicit episode overrides, including previously persisted ones, are honored.
  On TV, the episode title moves down on focus and back up on exit in every
  focus style, including System; the synopsis keeps its delayed reveal.
  Loading captions use the same motion without changing row geometry, and
  Reduce Motion keeps the caption stationary.
  Collection and playlist contents follow Browse across every library. Library
  navigation, cast names, essential list text, accessibility labels, and on-artwork
  playback information stay intact. Existing Home choices migrate once from
  `HeroSettings`; the card settings transfer with the profile. Native grids and
  loading placeholders remove the same caption space as loaded cards. Touch captions
  have a 4pt gap without TV focus travel; TV captions retain their focus clearance.
  Mobile poster titles use native Dynamic Type footnote (13pt normally), with
  caption1 subtitles (12pt). Compact density does not shrink them below those styles.
  Framed, borderless, and loading cards share these tokens; landscape and TV type stay unchanged.
  Mobile poster and series-artwork rails reserve the subtitle line when labels are
  shown, even when metadata is absent, matching
  loading placeholders and keeping adjacent captions and row heights aligned.
- Mobile library provider icons align with the thumbnail's leading edge; the
  library name and server name share the adjacent text column.
- **Shared mobile row rhythm** — Home, library recommendations, search groups,
  related titles, extras (including loading/failure), and cast use
  `PlozziOSMediaSection`: native Dynamic Type `title3` semibold headings, a 12pt
  heading-to-artwork layout gap, and 32pt between sections. Mobile media surfaces
  sit 12pt apart; framed cards retain their interior artwork insets. Scroll shadow
  clearance does not add invisible vertical padding, and framed artwork shares
  the same vertical keylines as borderless posters. Normal-size headings truncate
  at the tail; accessibility sizes wrap. Card sizing, caption preferences, native
  page titles and tvOS typography remain separate from this shared section style.
- **Item detail** — `ItemDetailView` + `ItemDetailViewModel` and
  `DetailHeroView` / `DetailExtrasView` render the cinematic full-bleed
  backdrop, logo, overview, ratings, cast, and Play/Resume button. Works
  for movies, episodes, and people.
  An episode's show breadcrumb is a single native button showing only the show
  title and chevron, without a background or border in either focus state.
  Play takes initial focus when available; Up then reaches
  the show, preserving its source account and season. Episodes without Play
  keep the breadcrumb immediately eligible for focus.
  Page ownership is identity-based, not an appearance-callback counter: repeated
  appearances and late departures cannot hide a different detail or give it the
  previous movie's trailer. A confirmed cancelled cinematic Back restores the page that
  remains on the real navigation stack, removes its cover/input guard, and keeps
  its controls focusable. Older transition completions cannot finish a newer pop.
  Returning to a retained page restores its cached artwork palette without a
  second crossfade after the cinematic cover lifts. Ordinary artwork changes
  still crossfade, and hidden pages still release their displayed-artwork owner.
  The bounded debug handoff journal records page membership, return outcomes,
  and hashed trailer ownership so an intermittent failure can be inspected
  without restarting the affected app.
- **Series** — `SeriesDetailView` + `SeriesResume` provide one stable
  series backdrop with focus-driven season tabs and an episode rail; the
  hero text updates as focus moves without distracting backdrop swaps.
  On tvOS, opening an individual episode from Home or Search starts at the hero
  with Play focused, just like opening the show. The episode's source, season,
  and prepared rail target are retained; the rail does not claim initial focus
  or bypass the cinematic entrance. Returning from a child page retains the
  existing focus-restoration behavior rather than claiming Play again.
  Episode-rail re-entry measures the remembered card before revealing it.
  An already-visible card keeps its horizontal position instead of snapping to
  the leading edge when focus moves to Seasons, the hero, or lower details.
  Ratings and Details count as leaving the browser, so returning restores its
  full vertical stage without replacing the browsed card with a loading slot.
  Direct returns from Related to an episode restore that stage inside UIKit's
  coordinated focus animation. A SwiftUI focus-entry scroll alone can be
  overwritten by the native card's reveal, leaving actual focus offscreen.
  The page return overrides the short native focus-effect timing with a
  0.6-second ease-in/ease-out animation, paced against the native downward
  reveal. It remains interruptible and applies its destination immediately
  with Reduce Motion. Leaving the browser releases its scroll guard during the
  native focus handoff, before UIKit reveals the next row; stale SwiftUI reveal
  state cannot relock the page during rapid Up/Down reversals.
  A populated Related rail owns a full-width native focus section, so Down from
  a horizontally distant episode reaches even a single Related card before
  Cast. Empty and loading Related rows add no focus stop.
  Leaving for lower details also re-arms the episode entry gate. Returning
  through a different Related column, even while rapidly passing through to
  the hero, preserves the last browsed episode instead of remembering a
  geometrically closer card encountered in transit.
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
  Reduce Motion keeps the same resting hero placement and browser geometry:
  the resting content offset is structural, not optional animation travel.
  Movie hero focus restoration likewise skips its animated scroll under
  Reduce Motion instead of changing the hero's dimensions or artwork crop.
  When pinned navigation hides on detail pages, horizontal rows draw through
  the empty side gutter to the screen edge, including focused episode artwork.
  The sidebar's mask changes without replacing the scroll view, preserving
  browse position and restoring the normal feather when navigation returns.
- **Library browsing** — `LibraryBrowseView` + `LibraryBrowseViewModel`
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

## Home loading

On iPhone and iPad, the loading and loaded Home layouts share the hero visibility
gate. Disabling the hero or deselecting all its sources removes both the carousel
and its placeholder, including the reserved height. Only an active hero extends
under the top safe area; a rows-only Home keeps its first row below navigation.

Library cards preserve server-supplied cover artwork. Missing covers use a stable,
locally composed poster collage from that exact library, with a provider-colored
fallback for empty or unavailable sources. All cards carry the shared provider
mark (including explicit SMB/WebDAV/NFS transport badges), while server/account
captions continue to distinguish same-provider servers.

`LibraryArtworkSource` requests at most 18 library items and selects six unique
poster candidates. `LibraryCollageCache` coalesces requests, admits at most two
libraries and three poster transfers at once, and composes a single 720x405 texture
on a serial utility queue. Visible covers use the foreground artwork lane rather
than waiting behind speculative prefetch. The raw Browse Files root uses the same
account's indexed latest media, never a recursive filesystem walk. Library names
are not drawn over artwork. Provider badges sit beside the library name in the caption below the
artwork on TV and mobile, never on the cover or collage; no logo scrim is applied.
They use `ProviderBrandMark`'s standard provider-tinted circular background and
optically balanced internal padding, including its existing Plex size adjustment.
Native captions center the badge and short title together, keep the badge fixed
while long names marquee, and move both together on focus without adding a focus target.
Native library, poster, and landscape captions share the same density-aware
artwork-to-caption gap, including loading placeholders. Native focus overflow
stays outside the artwork layout slot. Poster caption travel reserves at least
24 points for TVUIKit's enlargement, including compact densities, without
reflowing the row or changing animation timing. Native library grids use the
same resting gap and focus travel; playback-panel and circular-tile captions
retain their own geometry.
Transparent server covers retain their alpha but use the same rounded native
poster treatment as opaque covers, rather than alpha-shaped cutout focus.
This changes the native image-view treatment, not the cached artwork bitmap.
Transport marks stack the complete drive symbol above their label with balanced
vertical padding.
The decoded cache is capped at 16 MiB; the bounded disk derivative cache at 8 MiB.
Collage keys use a stable profile identity, not the app container's absolute path,
so installing another build does not invalidate them. Returning cards seed their
first frame synchronously from decoded memory; disk reads, decoding and composition
remain asynchronous and off the main thread.
Keys include the Home profile scope, account, effective server user, library and
credential revision. No authenticated artwork URLs are persisted by this cache.
Focus changes do not reload or compose artwork. Native TV posters receive the
same cached bitmap as mobile/custom cards; clipping and focus geometry stay unchanged.

Home gives inventory, each global feed, and per-library rows independent queues
of at most five operations each. Slow resume feeds cannot occupy the slots
needed to start other row types. Each global row arrives
once its own sources are complete, preserving cross-server deduplication and
ordering. A slow Continue Watching feed therefore retains its own skeleton
without holding up Watchlist, Recently Added, or per-library rows.
Progressive publication keeps failures, reconciled content, and loading state
together after pending watch-state reads finish. A partial server failure must
not replace Continue Watching's focusable loading slot with an error while
healthy cards are still reconciling. Usable cards retain focus; a settled empty
failed row still presents its error.
If library visibility changes while a load is in flight, the model replaces the
obsolete load even when Home's view-owned task is absent. Discarding stale
results must never strand a row on loading placeholders.

Adding an owned library title to Watchlist retains its verified source and full
presentation in memory, even when Search is the only place that loaded it.
Opening that entry does not depend on a native-watchlist refresh or a warm
identity index to recover Play, episodes, or the selected server artwork.
Both shells share this handoff. Retained items follow alias redirects, are
pruned with membership, and are discarded when the profile, active accounts,
credentials, or Plex Home identity changes. They are not persisted or synced as
ownership evidence; discovery items and synced identity hints remain unowned
until a local provider verifies a copy.

Watchlist publication uses the canonical alias resolver, including exact
account/item identities and alias redirects, to match current library candidates.
Sparse SMB titles do not need external IDs or a year to recover their library
presentation after relaunch. An alias alone is not playback proof: without a
current validated candidate, native owned source, or verified index match, the
entry remains unresolved. Native entries share ownership only through their
canonical alias, never through matching title/year text. Source and artwork
come from the same deterministically selected owned entry without moving its row.
The shared detail ownership search retains the seed's merge group even when a
richer library copy becomes the display representative, and keeps the opened
library source first. Discovery catalog IDs never become playable source refs.
Sharing one external ID does not override a conflicting ID in another namespace.
Search rejects contradictory hits before stopping its title-query sequence, and
the same rule guards item merging and index lookup. A populated index cannot
restore a rejected ownership match or traverse that match to unrelated sources;
missing IDs alone do not reject otherwise compatible library copies.
Canonical labels never reuse the shared ID for both conflicting groups. Episode matching
keeps explicit series IDs separate from episode IDs, including share payloads
that repeat a series ID in the ordinary provider field.
Exact-source recovery cannot add stale IDs that contradict the loaded item.
Sparse index lookups return no ownership when their candidates contradict each
other; they do not guess between groups. After search selects a compatible group,
cached sources are looked up with that group's combined IDs, not the original
sparse seed. The same ordering applies when enriching merged Home/Search cards.
Freshly inspected sources rejected from that group cannot return through sparse
cached entries that omit their conflicting IDs.
Compatible cached sources remain available when search returns no results.
Compatible sparse search hits recover exact indexed membership before grouping;
seeing an incomplete hit is not itself a rejection. Batch and incremental
browsing filter both cached and carried sources against the accepted group.
Incremental pages invalidate source-dependent cached cards when new loaded
evidence arrives, even without a shared merge key, without moving already exposed
card positions. Sparse members stay with their refined group; compatible cards
kept separate for paging stability are not treated as rejected matches.
Positive source rejections travel with cached items and detail snapshots.
Sparse reloads cannot clear them, and detail discovery distinguishes explicit
rejection from a missing search result. Successfully fetched alternate details
must pass the same identity checks before contributing versions or watch state.
Detail source discovery, seeded cards, and restored snapshots fill missing server,
provider, and user labels from the exact owning account or matching discovered
source. Existing display names, file versions, and per-account watch state survive
metadata-only repairs. Separate sign-ins to the same physical server remain
separately selectable; naming never changes the active playback source.
Rejecting an indexed bridge also removes membership supported only through that
bridge, including references already carried by an open detail page.
Watch actions preserve these exclusions through queued persistence, coalescing,
and later identity expansion; contradictory titles retain separate intents.
Durable, viewer-scoped clocks protect each physical target even when its metadata
or canonical ID changes. Seeded and expanded targets receive the same ordering
protection, rechecked after provider resolution before dispatching a write.
Filtered browsing revalidates hydrated groups and corrects source-level inventory
before publishing its first page, preserving unrelated peers and episode-derived
query facts. A change to already exposed paging requires an explicit restart
rather than silently shifting offsets.

Enabled library rows start as soon as their inventory is known. Recently Added
and recommendation requests complete independently, in stable library/row slots.
Both shells use the same loading/error state; failed rows can be retried without
removing successful rows. Cancellation stops queued requests. Parent-series
identity lookups are coalesced per account and load, and incomplete Home content
does not overwrite the durable snapshot.

Showcase keeps its first-row anchor while that row loads; a lower row finishing
does not choose focus or scroll the page. Its leading loading card has a visible
progress indicator and can hold focus without making the other skeletons
interactive. Its hero stays empty, even if cached Live TV cards are available
after the waiting slots; returning to that slot also cancels any delayed title
from the previous row. The waiting card uses the loaded cards' shared focus treatment:
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

Episode-backed Home heroes use a separately scoped `MediaSeriesSynopsis` fetched
from the authenticated parent-series record. The server's series tagline/synopsis
is shown without episode spoiler masking; episode prose is never substituted
when that series text is absent. The original episode overview, playback route,
and watch state remain intact. Detail pages retain episode-specific spoiler rules.
This description policy is shared by Showcase, the TV carousel, and mobile Home.

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
The schedule badge sits 16pt above the fitted, already-trimmed artwork inside
the logo slot. Showcase reuses the cached off-main crop and existing dwell-gated
schedule requests; it does not scan pixels or eagerly fetch schedules while browsing.
The outgoing row tucks upward by up to 110pt behind the 24pt mask fade so no
bottom strip remains above the next row. This offset has its own native spring:
deriving it from the scroll view's logical geometry makes the returning row
release all 110pt immediately, ahead of the moving presentation viewport.
Earlier rows retain native Up eligibility;
making their entire mask transparent would break that navigation. Showcase's
backdrop uses wider leading and bottom gradients without lengthening its crossfade.
Crossfade is the only Showcase backdrop transition. The retired slide preference
is ignored when reading older settings without resetting the remaining choices.
Showcase's optional titles under cards follow Appearance > Cards;
they do not control title visibility elsewhere in the app.

With pinned navigation, the carousel extends its leading fade to the top edge,
blending into the unchanged bottom shading through a variant of the existing
cached scrim, not an extra compositing pass. Detail pages have no pinned rail:
all navigation styles keep the softer top-left corner there. Detail shading
fades in as the artwork cover hands off, just before the logo and metadata,
without adding a mask or changing the artwork's position. Native Home navigation
retains the original shading; Showcase already fades its artwork into the
background along the full leading edge.

Native poster layout slots use artwork size on both axes, rounding fractional
heights up so SwiftUI cannot round artwork down into its caption. TVUIKit's focus
margins settle after realization and draw outside that slot; feeding their
changing height into a lazy row shifts both the pinned row and hero during deep
horizontal scrolling. Hosted native-poster coverage checks this before and
after layout, and the Home UI regression traverses all 75 fixture cards.
Native poster overlays cache their logo/badge/progress composite at the current
display scale. Only that hosted overlay is rasterized; native artwork and focus
effects remain live, and changes to overlay content invalidate the cached image.

Libraries uses the same unclipped horizontal viewport as media rows. Native
navigation lets focused artwork and scrolling cards draw through the page gutter
to the screen edge. Pinned navigation's shared feather retains 10% artwork
opacity beneath the icons through the physical leading edge, rising smoothly to
full opacity near the first card across a 48pt feather. The faint floor explicitly
overhangs the row because Showcase's nested native hosts suppress safe-area
propagation; relying on `ignoresSafeArea` alone clips it before the icons.
Extending that floor does not move or widen the feather, add a second mask, or
change scrolling, parking, or focus identity.

Discover hydrates and displays its saved candidates with the same featured-only
configuration used by Showcase's live curation. Without eligible cached content,
its stable row slot shows loading posters until curation completes, rather than
inserting a new row during navigation. An initially empty result removes the slot;
disabling Discover does not reserve it. Lower loading rows never take focus.

Once populated, Discover keeps its entire lineup for the app session, not just
the focused or currently visible cards. Opening details, changing tabs,
backgrounding, freshness ticks, and watched-state updates do not replace or
reorder titles. Matching status and verified routing still refresh in place.
An explicit configuration or profile/account-scope change resets the selection;
retention never overrides source authorization. Fullscreen Hero keeps its
existing carousel refresh policy.

Discover records exposure only after at least half a real card is visible for
two seconds while Home is frontmost and the scene active. A single native row
sampler respects horizontal/vertical clipping and the Showcase mask without
publishing SwiftUI state or treating lazy realization as an impression. The
profile-scoped history favors unseen cached titles on the next cold launch.
Background cache writes retain unexposed alternatives, clear unverified routing
from retained-only discoveries, and fill remaining capacity with refreshed
candidates; they never publish those replacements into the current lineup.

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
