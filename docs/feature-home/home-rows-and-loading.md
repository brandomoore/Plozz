# Home rows and loading

[Home task map](../../Sources/FeatureHome/README.md#where-to-look-first)

## History diagnostics

Home history completion records returned, curated and visible item counts plus
failed-account counts in the existing bounded recent-activity log. This separates
an empty provider feed from local curation without recording media or account IDs.

## Mobile Home loading geometry

Idle, preparing, and progressively loaded Home share one scroll/presentation tree.
The initial frame uses the same configured row plan as the first publication,
including custom ordering, hidden rows, and permitted server/collection sections;
there is no separate fixed three-rail loading screen. Unknown library inventory
is not invented. An eligible durable hero paints immediately even without a row
snapshot; otherwise the configured hero reserves its normal placeholder.
Curation waits for preparation and its selected Home sources, not unrelated
rows. A pending empty source is not a completed empty hero. Source readiness is
part of the curation task identity so a genuinely empty response still finishes
curation and removes its placeholder. Existing profile, visibility, and
resume-snapshot restrictions continue to govern cached heroes.

Home shares its measured viewport width with loaded and skeleton rails.
`PlozziOSHomeRowSlot` reserves each row's footprint using the real card sizing
primitives, heading, captions, and current layout settings. Loading, populated,
and failed content occupy that space rather than determining its height. The
invisible sizing content does not shimmer or enter the accessibility tree.
Long status messages can scroll inside the reserved row instead of expanding
the page. Browse headings reserve chevron space before their action is available;
only actionable headings are buttons, with the native 44-point touch target.
Library, featured, Continue Watching, and Live TV rows use their own geometry.

On iPad, landscape Continue Watching fits complete cards and matches the next
poster card's visible peek at the same viewport width. Standard density uses
four cards in wide windows, three at intermediate widths, and two in narrow
windows. Density and larger text can change that count to retain readable cards.
Series-artwork and episode-thumbnail modes share this width policy, including
their loading and reserved footprints. Poster-layout Continue Watching, other
poster and landscape rails, iPhone sizing, and Mac's existing fitting policy are
unchanged.

Mobile landscape playback chips give up the play glyph before compressing their
progress gauge. Narrow cards retain a readable shorter gauge alongside episode
and time text; text remains the final fallback when neither fits. Portrait cards
and TV keep their existing fitting policies, and hidden progress stays hidden.
The card's text-only fallback retains both episode and time, wrapping when needed;
duration-only fitting remains limited to the player's fixed-height artwork.

Hero previews are retained under their own resolution keys as soon as they paint,
before full-quality decoding completes. This lets a newly mounted idle backdrop
reuse the incoming slide's image without a loading-background frame. Sliding,
idle, and reflected hero layers use the same artwork preference and resolution
identity; the full-quality image can still replace its preview when ready.

On iPadOS 26 and later, Home observes the native tab controller's
`contentLayoutGuide` from inside the Home destination. Its laid-out frame supplies
the sidebar's actual covered width, including after visibility and window-size
changes; no fixed sidebar width or replacement sidebar delegate is used. Home's
landscape artwork fits its 16:9 picture beside the sidebar, with reflected artwork
under the sidebar and below the picture where needed. Idle and sliding artwork
share that framing. Top navigation restores the existing full-width treatment.
Mac's artwork sizing and foreground placement remain unchanged.

The first progressive Home publication includes configured server and collection
rows before provider responses arrive. Planning and fetching share the same
active-account, server-user, enabled-library, and row-visibility filters.
Matching cached content remains usable while refreshing; an unavailable response
is not treated as an empty row. A failed global row with no usable cards regains
its loading reservation when an interrupted load resumes or an explicit retry
starts. Only content surviving library/tile visibility and the Recently Added
watched filter counts as usable. Successfully empty rows stay absent; retained
cards stay visible.

The vertical stack remains eager to avoid estimated-height changes. Loading-rail
geometry is retained offscreen; its horizontal stack is lazy, like the loaded
rail, so clipped placeholder cards are not all constructed at startup.
The mobile rail's native scroll
visibility controls its shared shimmer animation. Only visible loading rows
animate; scrolling a row into view resumes its shimmer without delaying loading.
Server/library/collection rows have a scoped, equatable presentation boundary,
so another server's response does not reconstruct their unchanged content and
browse closures. Each library boundary stores one `HomeRowChoice` and one
complete `HomeLibrarySectionGroup.Row`, not a presentation plus a second copy
of its embedded row. Equality compares the complete row once, including deep
metadata, alongside the choice, Home model and controller identities, and
featured playback activity. Browse actions reconstruct `HomePresentationRow`
from those same inputs. Profile settings and
environment changes remain observable inside the row; browsing/customization
bindings retain the owning Home's presentation state.
Scrolling is native: there is no per-row frame tracking, anchor preservation, or
compensating scroll command. Confirmed-empty rows follow the existing empty-message
and dismissal policy; removing one is a real document change. Newly discovered
inventory, hero availability, viewport/settings changes, and an Auto collection
cover shape resolved from new metadata can also change the document. Reserving
known row layouts does not promise immutable whole-page geometry or prove
physical-device frame pacing.

### Opt-in live-data row verification

`HomeLoadingLayoutTests.testLiveJellyfinLibraryRows`,
`testLivePlexLibraryRows`, and `testLiveCombinedLibraryRows` run in the
`PlozziOSPresentationTests` hosted target. They load real provider Home data,
resolve and mount the production library-row/slot/scroll components, browse up
to three shelves through the production browse model, and refresh the loaded
rows. The mounted sample is bounded to eight nonempty library rows; it is not
a full-library scan or the complete signed-in app shell.

The checks cover independently decoded equivalent inputs, deep metadata
invalidation, account attribution, native horizontal/vertical scrolling,
caption observation, and loading/error/recovery geometry. Metadata edits and
failure transitions are local controls over real rows, not server mutations or
simulated network outages. Persistence decoding normalizes some fields and omits
transient selection state, so equivalence compares two independent decodes,
not a persisted snapshot against every live in-memory field.

Without `PLOZZ_LIVE_HOME_ROWS_BROKER`, these tests explicitly skip. An authorized
local broker supplies an in-memory configuration from `GET <broker>/jellyfin`
and `GET <broker>/plex`: `baseURL`, `serverID`, `userID`, `username`, `deviceID`,
and `token`. The broker must use `http://127.0.0.1:<port>/<unguessable-route>`;
the tests reject URL credentials, queries and fragments. Pass only that loopback
address into the hosted test environment. Keep real credentials, authenticated
responses, and account inventories out of source, arguments, logs and attachments.
Use dedicated internal accounts, not personal owner or external review identities.
The test HTTP adapter rejects non-GET, Plex action, playback-info, session and
transcoding requests. No playback or watched/resume writes are required.

Use the existing leased, bounded simulator build/test procedure with these
three explicit selectors and inspect structured results: all three must pass,
with zero skips, on each selected device. A shelf that fits in the viewport
does not require vertical scrolling; horizontal movement is always required
and completed target counts are reported. This verifies row behavior, not
physical-device FPS, actual playback, artwork fidelity, or a button-driven
browse-navigation journey.

## Recently Added watched filtering

Screens & Navigation > Home > Filtering offers **Recently Added** under
**Hide watched content**, off by default and saved per profile. The shared presentation policy covers combined,
per-library, and typed server-authored Recently Added rows on TV and mobile. It leaves
Continue Watching, Next Up, Watchlist, collections, hero, and Top Shelf unchanged.
Movies/episodes use current completion (rewatches remain resumable). Series and
seasons stay visible with unfinished episodes; unknown completion is not inferred
from progress percentages. A selected alternate copy with unfinished episodes
keeps a merged show visible.

Enabled loads request a bounded 100-candidate window instead of the normal 20,
then filter before taking 20 cards. This is not a full-library scan or a promise
to fill every row: a server's shorter native feed, or an entirely watched window,
can still leave a short/empty row. Raw candidates are retained for live mutations,
toggle reversal, and credential-sanitized launch snapshots; hero/Top Shelf retain
their original feed. Server row batching remains shared, with non-Recent results
trimmed to their original budget.

Plex, Jellyfin/Emby, and Silo supply mapped server watch state. SMB, WebDAV, NFS,
SFTP, and FTP use the same ShareProvider/account/profile watch store; Home rolls
up share series from indexed logical episodes, counting alternate files once,
without walking the remote filesystem. Account/profile changes and the existing
post-write refresh path remain authoritative.

Emby's native `latestmedia` sections are classified using the machine-readable
contract verified against an Emby 4.10.2 server, including custom-named rows.
Unknown native sections remain unchanged; display titles and sort order are
never used to guess a row's purpose. Server-side watch filters remain authoritative
even when this additional client-side filter is off.

`JellyfinRecentlyAddedLiveTests` exercises the native Emby contract and mapped
watch policy against an explicitly approved passwordless test account. Set
`TEST_RUNNER_PLOZZ_TEST_EMBY_URL` and `TEST_RUNNER_PLOZZ_TEST_EMBY_USER` when
invoking Xcode tests; without them it skips. The check reads bounded native/latest
feeds and simulates watch changes only on in-memory copies, never server history.
Provider fixtures cover the other mappings; shared policy and Home model tests
cover candidate replenishment, identity reenrichment, and profile persistence.

## History scope

Global Continue Watching and account-wide server Next Up are the active accounts'
viewing history, independent of library/catalog visibility. This applies to
combined and individual-row layouts, detail resume hints, and Top Shelf. Hiding
catalogs must not empty history or fan it out into catalog-scoped requests.
Library-specific rows, discovery, account selection, server-user permissions,
and parental authorization retain their existing boundaries. A catalog-load
failure does not replace a successful history response with that failure.

## History failures

Home Continue Watching failures use the existing Details / Try Again actions on
TV (including focus-following layouts), iPhone and iPad. The report follows the
same failed source as the visible error and retains bounded, task-scoped HTTP,
decoding, paging and transport evidence. Retry/success clears stale reports;
cancelled or superseded requests cannot publish diagnostics into another load.
Reports contain provider and route categories, never account identifiers,
server addresses, credentials, media IDs/titles or response bodies.

## Row customization

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
  **Continue Watching action** chooses **Open details** (the default) or **Play**
  for movie/episode cards on Home, including merged Next Up entries and every TV
  Home layout. Existing saved choices are preserved; profiles without a saved
  action open details. The choice persists and transfers with the profile.
  Opening an episode from Continue Watching uses the normal series detail page,
  with that specific episode's information and playback target in the hero and
  its season selected. Only the explicit **Go to Episode** action opens the
  standalone episode page.
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
  Continue Watching admits ordinary resume positions at 5% of duration, bounded
  between 5 and 60 seconds (60 seconds when duration is unknown). Saving resume
  progress is independent of this visibility threshold. Detail and card progress
  indicators use the same minimum, so brief plays still look unstarted. A
  percentage-only item uses its runtime when available; without either a position
  or duration, its reported progress is retained. Unstarted Next Up episodes
  remain eligible; trailers never enter the row or propagate watch state to their
  parent title. The same policy covers optimistic updates, queued-write overlays,
  cached content, library/server rows, and their browse grids. Grid filtering
  preserves raw provider continuation offsets.
  Native Continue Watching reads the feed through bounded pages, applying
  eligibility and library exclusions before a presentation limit. Retained native rows immediately
  honor current library visibility while discovery is pending or offline.
  Connection failures identify the affected server. The Home row arranger names
  each failed server, distinguishing offline, sign-in, and Home-loading problems
  instead of showing a blanket warning about server arrangements. Recovery clears
  that server's status; failures never reset saved row choices.
  Enabled sections with failed or unavailable content retain a compact warning
  on Home with source, Details, and Retry. Confirmed-empty sections instead show
  a centered, icon-free empty state with source attribution and vertical padding
  sized near a normal media row, without error details or retry controls.
  A native secondary Customize Home button opens the active profile's existing
  Home editor so viewers can keep or hide the row. It uses the shared secondary
  button surface, not a bare text link. Its text uses the theme's
  neutral primary ink, not an inherited system accent. The editor's own empty-state
  previews omit this action, and opening it does not change row preferences.
  Empty-state actions sit side by side, falling back to a vertical layout only
  when the available width or accessibility text size requires it.
  Dismiss hides only that row's confirmed-empty Home message, persisted per
  profile without disabling or reordering the row. Titles appear automatically
  when available; loading placeholders and real failures remain visible. New
  row identities retain their messages, and the row's editor can restore a
  dismissed message. tvOS Showcase omits confirmed-empty rows automatically,
  without saving dismissals or changing other Home layouts.
  Customize Home shares the same completed-load
  evidence, distinguishing typed failures, empty results, and saved sections
  absent from the latest refresh. Missing sections do not prove a server error:
  dynamic recommendations may be empty or changed. Normal empty default library
  feeds remain quiet unless explicitly added. Existing usable cached/partial
  cards remain visible, with any load warning available in the editor.
  Empty and failed Home rows use the same header and keyline as populated rows,
  including pinned-navigation clearance. Status/source and native recovery
  actions for failures stay compact; empty states reserve a modest minimum
  height rather than an empty poster wall and grow for larger text. Mobile uses
  its ordinary media-section heading and insets.
  Warnings are runtime-only, scoped to the current profile, accounts, server
  users, credentials, and settings; cancellation is not a failure and successful
  recovery clears the warning. Details expose safe error categories, not URLs,
  credentials, or response bodies.
  Mobile library discovery follows the effective credential and Plex Home viewer,
  and cancelled lookups cannot restore another viewer's library choices.
  The section catalog enumerates optional recommendations only while the editor
  is open. Authored custom rows have independent stable section identities,
  names and poster, landscape or Featured presentation. `CollectionSection`
  migrates its former singular collection reference to an ordered array of
  `HomeContentSource` values. Sources can be collections, video playlists, video
  libraries, recommendations, or shared Home feeds. Server sources retain their
  account and exact viewer; provider requests always use native IDs.
  `HomeContentPager` interleaves source order across uneven pages and merges
  duplicates through `MediaItemMerger`. It serializes competing browse advances,
  bounds provider fan-out to three, adapts page sizes for overlap, and caps scans
  instead of draining a library to fill a default preview. Cancellation commits no cursor
  changes; partial source failures retain usable cards and remain retryable.
  Custom Home rows share one three-request lane and reuse identical preview
  pages during a Home load. Their work does not occupy native Home feed lanes.
  **See all** uses the same composition in the poster grid. Recently Added
  retains native full-feed paging rather than stopping at the Home preview;
  Watchlist and Continue Watching use profile-curated runtime snapshots.
  Custom rows persist a shared `HomeContentQuery`: Source order (the default),
  Name, Date Added, Release Date or Runtime with a direction, plus movie/show and
  Unwatched/In Progress filters. Preview, Home and the initial grid use the same
  query. Source order preserves curated playlists; the TV Shows filter includes
  seasons and episodes in feeds that admit them. A Watchlist-only row uses its
  saved-added dates rather than library-added dates.
  Explicit queries read complete membership before projecting results, not just
  the first page. Large sources consequently cost more network I/O and memory.
  Full traversal uses bounded pages and at most three source requests, merges
  once after collection, supports cancellation and fails visibly if any source
  cannot complete. Changing queries in one editor reuses its scoped inventory;
  Retry or changing credentials, sources or visibility starts a new traversal.
  Recently Added queries expand the native feed beyond the Home preview.
  Watch mutations reproject retained candidates and collection refreshes retain
  full membership for queried rows. Durable Home snapshots keep only the
  already-projected preview, never a truncated inventory posing as complete.
  Grid changes remain temporary and do not overwrite the saved row query.
  Browse watch-mutation projection, like ordinary sorting, runs off the main
  actor and fences publication by scope, query generation and mutation revision.
  Raw candidates stay unchanged so later filters can restore excluded titles.
  Local query sorting normalizes names once and sorts indices rather than
  repeatedly moving whole media records. Empty filters avoid building library
  query records; filtering and ordinary sorting periodically check cancellation.
  A traversal pins snapshots to prevent offset shifts, while Home presentation
  reflects current shared-feed membership. All card styles open title details.
  Recommendations from the same account/library/kind share one bounded discovery
  response per traversal, including concurrent requests. Its shelves remain in
  memory until the traversal ends; there is no cross-profile or global cache.
  Failed or cancelled discovery is not cached, and unrelated libraries retain
  independent request lanes.
  Jellyfin additionally reuses exact recommendation responses across Home,
  Settings discovery, previews, and browsing for up to one minute within the
  same Home/profile owner. The authenticated provider bounds this transient
  cache to 16 entries and 2,000 item records. Home reloads and watched/watchlist
  mutations advance its generation; profile retirement invalidates it. Pausing
  Home behind Settings does not retire authorized snapshot access. Detached Home
  aggregation explicitly installs the scope, while previews and browse sessions
  capture it. Missing-shelf and explicit editor Retry request fresh discovery
  without replacing already pinned healthy shelves. This does not change
  recommendation limits, cold server latency, or Emby's fixed-snapshot behavior.
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
  configured collections, including those inside mixed-source rows. Refreshing
  one collection preserves the other sources' contents, failures and continuation.
  Read-only reconciliation, unchanged confirmations,
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
  On tvOS, Classic rows retain these large cards with or without the Home hero.
  Showcase and Hero + Showcase instead render standard poster cards, leaving
  the focused title's artwork and metadata to Showcase. This presentation-only
  adaptation preserves the saved Featured preference, row order, and contents;
  iPhone and iPad continue to use large Featured cards.
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
  Live TV contributes typed cached channel cards only to its own optional row,
  never to Continue Watching, including Classic and Showcase layouts. Recent
  channel history remains available on the Live TV page. Cache bounds,
  authorization and managed tuning are documented in
  [Live TV](../live-tv-prototype.md).

## Home loading

On iPhone and iPad, the loading and loaded Home layouts share the hero visibility
gate. Disabling the hero or deselecting all its sources removes both the carousel
and its placeholder, including the reserved height. Only an active hero extends
under the top safe area; a rows-only Home keeps its first row below navigation.
The Home artwork, legibility scrim, and dissolve mask share window-wide bounds,
including behind native side chrome. The title, actions, paging, and touch targets
retain their safe-area layout; extending the artwork does not extend hit testing.
On devices using a native vertical toolbar, root pages keep the profile/settings
avatar in that rail, including Search and Live TV. The system's toolbar-edge
environment selects this layout; ordinary iPhone and iPad placement is unchanged.
The titleless Home hero explicitly keeps that native rail visible.

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
The Home Libraries row has a card-label override, like Continue Watching: Use default
inherits Home's label setting (including Showcase), while On or Off affects only
library cards and their loading placeholders. Hiding them removes the caption space
but preserves accessible library and server names. Library directories continue to
follow the global label preset. The Home Libraries row follows the profile's navigation order,
including its discovery-order fallback, without inheriting navigation visibility:
Home's own library visibility still decides which tiles appear.
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
Native TV library covers use the same opaque rectangular artwork surface as media
cards, including UIKit's moving edge highlight, enlargement, tilt, and small internal
crop. Transparent server reflections fade onto the shared dark card backing rather
than into the page. Cached source artwork retains its alpha for mobile and custom
focus styles; only the native TV presentation is flattened.
Transport marks stack the complete drive symbol above their label with balanced
vertical padding.
The decoded cache is capped at 16 MiB; the bounded disk derivative cache at 8 MiB.
Collage keys use a stable profile identity, not the app container's absolute path,
so installing another build does not invalidate them. Returning cards seed their
first frame synchronously from decoded memory; disk reads, decoding and composition
remain asynchronous and off the main thread.
Keys include the Home profile scope, account, effective server user, library and
credential revision. No authenticated artwork URLs are persisted by this cache.
Focus changes do not reload or compose artwork. Native TV posters prepare their
opaque presentation from the same cached source bitmap used by mobile/custom cards.
Captions and provider marks remain outside the focused artwork.

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

Mobile Home measures every configured row's exact footprint eagerly, while a
native lazy vertical stack mounts its rail content near the viewport. Offscreen
responses update the model without constructing all of their card views. The
sizing template receives only geometry and caption inputs, not changing media
payloads. Lazy content never determines the reserved height; native scrolling
still owns the offset. This changes presentation work, not provider concurrency,
request ordering, cancellation, or how much content is loaded.

If SwiftUI replaces Home's view task during library-settings preparation, a
coalesced replacement request retries the cancelled preparation once. The rows
must not wait for another trip away from Home and back. Cancellation without a
replacement does not start background loading; an already-running aggregation
still completes without a duplicate fetch.

Explicit owner suspension is different from view-task cancellation. Mobile Home
and Watchlist defer Home aggregation while Settings is presented, profile setup
is unfinished, or the active profile is unauthorized. A suspended load cancels
aggregation and its collection-refresh/reenrichment work; resumption uses the
final library choices. If the loaded content is still fresh, queued collection
previews and identity enrichment resume without refetching all Home feeds.
If loading was incomplete, resumption keeps already-published global, library,
server and collection cards visible and interactive while replacement results
arrive. Only unresolved rows show skeletons. Loading/failure evidence remains
on the source rows and in section diagnostics, not over usable retained cards.
Successful empty responses still remove old content. Live global-row readiness
is scoped to the viewer's library intent; it does not relax cold-launch snapshot
freshness or carry across changed choices.
Replacing an account/profile-scoped Home model on either
platform permanently invalidates it before creating the next one. Late results
and queued reloads from that retired model cannot publish or restart work; do
not rely on `deinit` while an outstanding load retains its model.

Identity verification does not imply a membership change. `IdentityIndex` compares
completed account rebuilds on its own actor and keeps its cached snapshot when
membership and source metadata are unchanged. Scan freshness and persistence
still advance. The shared runtime publishes only newer membership revisions,
after pruning the active account set, and retains profile/generation fences.
Home reenrichment and watchlist reconciliation therefore run for real changes,
not every unchanged server completion; live source lookup closures remain live.

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
