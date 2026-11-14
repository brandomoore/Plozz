# Presentation and Showcase

[Home task map](../../Sources/FeatureHome/README.md#where-to-look-first)

## Typography

Home playback pills keep Play, Resume and Start watching as localized resources
until the UIKit presentation boundary resolves the active app locale. Episode
suffixes remain separate content, and progress/remaining-time pills keep their
existing layout. `HeroPlaybackLocalizationHostedTests` checks the shipped German
catalog across playback states and locale changes on a retained pill.

Home text sizing applies to both SwiftUI and persistent UIKit foregrounds.
Detail Page, Showcase, and library Recommended have independent profile-scoped sizes.
Title fallbacks, descriptions, metadata, and badge details scale together;
artwork sizing and action controls remain independent. On Apple TV, Detail Page
text sizing also scales the episode titles and three-line synopses below episode
artwork, including loading placeholders; other row/card labels remain independent.
Compact mobile detail badges use their natural height when fully visible, with
8-point padding above and below in addition to the normal metadata and action-stack gaps.
Overflow disclosures retain their 44-point tap target.
Episode synopses use the same font size and line spacing as hero descriptions at
every adjustment, while episode titles stay larger and semibold.
TV episode descriptions are visible on every labeled card by default. The
profile-scoped **Only show descriptions on focus** toggle in the detail-page label settings
restores the delayed focus-only reveal. Hidden labels and spoiler protection
still apply; label visibility presets do not reset this independent preference.
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
[`CoreUI/PlozzTypography`](../../Sources/CoreUI/README.md#responsibility), not individual heroes.

## Mobile posters

- **Mobile Home posters** — portrait rails fit two full posters below 375pt,
  three on larger phones, and a 28% preview at standard density. Wider windows add columns;
  per-profile display-size choices scale the result. Loaded cards and placeholders
  share `PlozziOSHomeRailLayout`, and their artwork starts on the heading keyline
  after subtracting each card style's internal inset. Smaller mobile artwork uses
  proportionate corners and a 20pt minimum watched badge, without shrinking folder
  navigation badges. Continue Watching geometry and library grid columns are unchanged.

## Artwork lookahead

- **Showcase artwork lookahead** — A separate observer warms the policy-selected
  preview and logo for up to five nearby titles plus the leading title of either
  adjacent row. It shares the bounded background queue and artwork caches with
  Continue Watching, without observing focus in the view that builds the rows.
  Changing focus, rows, source references, or provider settings replaces only
  obsolete preparation; leaving Home cancels it. The native navigation and
  row/hero motion never await artwork or metadata.

## Card labels

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
  focus style, including System; the synopsis uses a delayed reveal only when
  **Only show descriptions on focus** is enabled.
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

## Mobile library icons

- Mobile library provider icons align with the thumbnail's leading edge; the
  library name and server name share the adjacent text column.

## Mobile row spacing

- **Shared mobile row rhythm** — Home, library recommendations, search groups,
  related titles, extras (including loading/failure), and cast use
  `PlozziOSMediaSection`: native Dynamic Type `title3` semibold headings, a 12pt
  heading-to-artwork layout gap, and 32pt between sections. Mobile media surfaces
  sit 12pt apart; framed cards retain their interior artwork insets. Scroll shadow
  clearance does not add invisible vertical padding, and framed artwork shares
  the same vertical keylines as borderless posters. Normal-size headings truncate
  at the tail; accessibility sizes wrap. Card sizing, caption preferences, native
  page titles and tvOS typography remain separate from this shared section style.

## Showcase

The default **Hero + Showcase** Home presentation keeps the featured carousel above
the same Showcase rows. Its native stage preserves the three hosting trees:
the featured hero, Showcase details/artwork, and the row viewport. Down admits
the first row before animating its viewport into place; Up from that row restores
the existing hero action and slide, without a separate arrow-button focus stop.
Each hosted root anchors its content at the top leading edge. The featured host
uses symmetric horizontal viewport insets so its screen-wide backdrop stays
centered on the display, including under pinned navigation's asymmetric row
viewport. The Showcase host extends to the physical right edge while preserving
its leading details inset. The row host retains its original bounds.
Showcase bridges empty row gutters with native focus guides targeting the nearest
visible edge card. Up and Down enter the adjacent row without skipping short rows:
entering from beyond its right edge selects its last card, not an arbitrary first
or remembered card. Within the cards, native column-aligned entry is unchanged.
Guides are disabled while focus is inside their row or outside Showcase rows,
preserving horizontal scrolling, sidebar entry, hero handoff, and detail return.
Focus ownership includes SwiftUI virtual items and nested native controls,
not only UIView-backed controls.
While featured content loads, its full-size skeleton remains a native focus
target so Down can still enter already-loaded rows and Up can return.
The peeking rows are not eligible for focus while the featured hero is active,
so first entry cannot collapse it. Boundary-only press and indirect-swipe
recognizers request the other host even when its hidden content provides no
geometric focus candidate; deeper-row and horizontal navigation remain native.
The swipe fallback cannot prevent or be prevented by native focus panning, and
does not cancel or delay touches. Both touchpad swipes and arrow presses use the
same boundary handoff; hidden rows must not require a physical Down click.
When touch input crosses that boundary, further focus proposals in the same
vertical direction are rejected for that input sequence, including momentum
after lift. A passive observer releases this guard on the next contact or button
press, without a timed cooldown. Cancellation, leaving the stage, and explicit
return-to-top clear it. Ordinary row swipes, horizontal movement, and physical
arrow repeats remain native; both geometric and fallback boundary crossings
share this guard.
While a boundary handoff waits for the current focus transaction to finish,
further proposals in that direction remain blocked. They must not focus
navigation before the deferred request can restore the hero or enter the rows.
With Top Bar navigation, the featured stage contributes to the navigation scroll
offset: entering even the first Showcase row moves the bar offscreen and removes
it from focus, and returning to the hero reveals it. Back's return-to-top resets
both the rows and featured stage. With the native Sidebar, the first Showcase row
also includes the hidden hero's distance in its real scroll offset, balanced by
matching content padding so card placement does not change. Native Home chrome
therefore disappears on the first Down, not the second row, and reappears only
when returning to the hero. Selecting the already-active native Home destination
resets both the Showcase rows and the featured stage before content focus returns;
resetting the row offset alone leaves the hero hidden. Right from the sidebar and
returning from another destination do not issue this explicit reset. With Hero
disabled, reselection returns to the first row instead.
Back from native-Sidebar Showcase rows smoothly returns to the featured hero,
or the first row when Hero is disabled, without opening navigation. Showcase
handles this through its own row/stage motion because its native offset guard
rejects UIKit's independent scroll-to-top. Once at the top, Back is left to the
native sidebar. Left, sidebar reselection, and detail-page Back retain their
existing behavior; reduced motion uses the same nonanimated fallback as row navigation.
This padding is a coordinate origin, separate from
the row destination and height stops. Changing it rebases the native scroll
target without adding a spring or restarting the in-flight viewport-height
path, including when Up reaches the hero before the first row settles.
For an animated native-Sidebar boundary, focus and compositor motion are admitted
before changing that scroll origin. A one-shot display-link observer applies the
padding/offset pair after it observes motion, rather than making native chrome
layout block the first frame. It publishes once, not on every animation frame,
and is bounded by the spring's settling duration. Reversal uses the latest
destination; reset, disappearance, teardown and nonanimated updates synchronize
immediately. This reorders the native layout work; it does not remove its CPU
cost or replace the native Home control.
The boundary handoff keeps Up directed at the hero
instead of the native Home control. Standalone Showcase keeps its existing
first-row behavior, and the Pinned Sidebar is unchanged.
The bar travels only far enough to clear the screen and receives an additive
native translation in the stage's own animation transaction, including reversals.
Top Bar has no display-link-to-SwiftUI follower or independent SwiftUI animation.
Using the full stage distance would hide it early and reveal it late.
Detach and reduced-motion updates clear owned animations. The return chevron sits 48 points from the top in all navigation styles,
without reserving space for the now-hidden Top Bar.
Top Bar Back still reveals navigation immediately, cancelling its remaining translations.
The row scroll bridge retains its requested stage motion across temporary detach
and reattachment, rebinding only while mounted; it does not depend on a later
SwiftUI update to restore navigation. Featured and Showcase artwork reporters
take ownership only while their respective stage is active, so returning to
the featured hero republishes its displayed-image palette.
The navigation fixture samples the bar's rendered position against stage
progress through full transitions and rapid reversals, as well as checking
focus ownership, final visibility, and the chevron's screen position. It requires
less than one point of phase error and at most one navigation-state target change
per transition, so a frame-following implementation cannot pass merely by reaching
the correct final position.
The same probe supports native Sidebar with `--native-sidebar-home` and
`--held-home-artwork`: a controlled dark backdrop lets it check painted Home
chrome, not just accessibility presence. It verifies repeated first-row/hero
returns, rapid reversals, actual native focus and stable card placement.
The outgoing hero foreground, incoming Showcase details, and rows share one
native scroll distance, easing, and start time. Their relative positions remain
fixed throughout the move and rapid reversals; only their opacity changes as
the old details give way to the new. Both artwork planes travel at 37.5% of
the foreground speed (about 120 points at the standard peek distance): the
featured image rises out while the first Showcase image rises into place from
below, reversing together on return. Their nested foregrounds compensate for
that parent movement so their total travel still matches the rows. The
transition uses the same zero-bounce spring as ordinary Showcase rows
(0.4-second perceptual duration, running through its settling duration).
Foregrounds, artwork, navigation, and crossfade share those spring parameters
and the transaction's commit time. Additive movement retains running springs
through rapid reversals instead of restarting from rest. Ordinary Showcase row
transitions are unchanged and keep their artwork pinned. The return chevron lives outside the
moving hosts and stays stationary.
The incoming image includes top overscan equal to its travel, keeping its upper
edge offscreen throughout the transition. This adds a modest aspect-fill crop
only to the hybrid's Showcase backdrop; standalone layouts and Reduce Motion
retain the original image bounds.
Two stable foreground hosts let the compositor move them without per-frame
SwiftUI state updates; artwork drift reuses the existing scene hosts rather
than adding another renderer or loading another image. The other Home layouts
do not create these hosts. Scroll and crossfade animations use the shared
transaction's default start time, not a wall-clock timestamp captured before
layout and focus work. Cold first-entry work therefore cannot use up their
duration before that transaction is submitted.
Reduce Motion omits foreground and artwork travel and snaps the rows.
A shallow, text-free up chevron sits at the screen's horizontal center, 48 points
from the top. It fades in only after two seconds on the first row when arriving
upward from a deeper row. Coming down from the hero never shows it, and leaving
before the delay ends cancels it. It fades away after three seconds of visibility;
ordinary updates within the row do not restart it. Leaving Home, returning to the
hero, or detaching the cue clears its arrival history.
It is informational, never an additional focus stop. Deeper rows retain ordinary navigation.
Row translation uses additive compositor animations so reversing direction retains
the in-flight motion. Artwork planes crossfade; Reduce Motion uses the same
destinations without animation. Carousel dwell and trailers suspend while rows
are active. Settings exposes Hero independently from Classic/Showcase row
style. Fresh profiles use both Hero and Showcase; saved styles and disabled
heroes retain their previous behavior. Blobs without a style field keep the old
carousel layout rather than adopting the new-profile default.

The production Home fixture's `--hero-showcase-focus-probe` records initial
native focus and invokes the same boundary handoff used by remote input. It
checks the actual `UIFocusSystem.focusedItem` in the running app scene, not only
the requested destination. This is separate from physical press/swipe delivery
and presented-frame measurements in the remote test suite.
`--hero-showcase-latency-probe` waits for native navigation to admit the hero,
then measures ten boundary handoffs. When `PLOZZ_HERO_BOUNDARY_START` names a
Darwin notification, the fixture registers it before reporting `ready`; the
driver signals it only after hero focus is confirmed, so setup cannot race
the measured navigation. It records queue, preparation, layout and
focus-request durations plus the first observed moving presentation layer and
destination focus. `ShowcaseNavigationTests.testHeroBoundaryLatencyAcrossNavigationStyles`
retains the same measurements for Pinned, Top Bar and native Sidebar. Build it
with `PlozzHomeFixtureTests` so the driver and fixture are both current.
The 16 ms observation interval quantizes the latter two measurements; these
exclude physical input delivery and are not display-photon latency or FPS.
Keep first-entry and warm samples separate when comparing captures.
The native first-motion callback is also recorded: subsequent chrome layout can
delay the polling task even when compositor motion is already underway. Every
sample requires native origin synchronization as well as focus and motion.
`--hero-showcase-navigation-probe` first changes destinations and returns Home
through pinned or top-bar navigation, then supplies presses to the boundary
recognizer and checks actual focus while rejecting escape during each queued
handoff. It covers focus ordering, not physical remote delivery or geometry.
The separate `--hero-showcase-geometry-probe` directly changes presentation
without requesting focus and verifies the artwork's physical screen edges.
Use it with `--pinned-home`, `--native-sidebar-home`, and `--top-bar-home` to
capture initial hero, Showcase, and returned hero geometry. Its pass is not a
remote-input or focus pass.
Add `--hero-showcase-delayed-commit` to either probe to hold the first
transition's outer transaction for half a second, then require intermediate
scroll and opacity values after submission. This controlled regression
reproduces the early-clock skip; it does not measure the cause or duration of
physical-device first-entry work.

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
Detail pages install their optional override with
`mediaItemNavigator(_:preservingInherited: true)`, retaining the inherited route
when no override is supplied. Do not construct a fresh `MediaItemNavigator`
inside an environment transform: its new identity rebuilds unchanged episode
menus whenever the page's callback refreshes. Hosted detail coverage counts
episode action-list builds across callback changes; shared-router coverage
checks fresh callbacks, inheritance, explicit removal, and released captures.
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
Showcase artwork fits its full image into the top-trailing backdrop slot, including
non-16:9 sources. Hero + Showcase transition overscan extends the image's top edge
above that slot instead of enlarging and lifting the resting image. Standalone
Showcase and Reduce Motion preserve the same uncropped framing; carousel artwork
keeps its existing fill treatment.
Landscape heroes check usable library and online backdrops before accepting a
portrait or square fallback. Source preference still chooses between landscape
images; a cached online miss and its poster fallback cannot hide a server backdrop.
Poster-only titles retain artwork, and mobile's explicitly compact portrait heroes
keep their existing selection policy. Preview, handoff, and resolved-image memo
identities preserve that distinction.
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
