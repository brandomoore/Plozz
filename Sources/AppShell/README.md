# AppShell

The composition root. Wires every other module into a single running app
and owns the top-level navigation, profile selection, and provider
registry.

## Responsibility

- `AppState` — the `@Observable @MainActor` aggregate root. Holds the
  `ProfilesModel`, the active `[ResolvedAccount]`, the `ProviderRegistry`,
  Trakt service, Top Shelf publisher, and the active settings models for
  the current profile. Orchestrates:
  - profile switching (`switchProfile`, `saveProfile`, `removeProfile`,
    `rebuildSettingsModels`),
  - Plex Home-user activation (`pendingPlexPINRequest`, `submitPlexPIN`,
    `cancelPlexPIN` — the PIN is never stored),
  - per-profile Trakt namespace swap (`updateTraktForActiveProfile`).
- `RootView` + `MainTabView` — the root SwiftUI hierarchy
  (Auth → ProfileSelection → MainTab). Lives here because it must depend
  on every feature module.
- `ProfileSelectionView` — hosts `FeatureProfiles.ProfilePickerView` and
  the create/edit sheet for both the launch picker and Settings.
- `SystemProfileBridge` — narrow seam onto the tvOS `TVUserManager` API
  (`shouldStorePreferencesForCurrentUser`) for the `user-management`
  entitlement.
- `AddAccountView` — first-run "add another server" flow that routes
  into `FeatureDiscovery` and `FeatureAuth`.
- `LibraryDiscoveryModel` — per-account "what libraries does this server
  expose?" coordination.
- `MediaItemActionCoordinator` — the cross-feature action bus (play,
  resume, mark watched, open detail) so any view can request an action
  without knowing the playback / detail routing.
- `PlaybackEngineComposition` — the **only** module that imports
  `EnginePlozzigen` (and any future engine packages). Builds the
  `EngineFactory` closure injected into `FeaturePlayback`, keeping the
  heavy on-device decode binaries out of every other module's dependency graph.
- `PlayerPresentation` handles Back only while preparing the initial playback
  version. Once it creates the player model, it removes that handler so the
  player's menus, controls, and video surface own their normal Back sequence.
- `AppInfo` — version / build / display-name helpers read from
  `Info.plist`.

## Invariants

- **Returning from Settings restores pinned-page focus.** Settings is hosted
  outside the navigation rail. Its Back action uses the same destination
  presentation fence and native content-focus request as selecting a rail
  destination, rather than relying on automatic focus after the overlay disappears.

- **Signing in does not change the starting page.** TV and mobile navigation
  availability uses the active profile's configured account metadata, not its
  credential-ready playback providers. A pending Plex Home identity or another
  unavailable credential must not make a media profile look Live-TV-only.
  Provider access remains credential-gated; excluded accounts and explicitly
  empty profile selections remain excluded from navigation availability too.

- **The TV startup expression survives a fast restore.** Smile leads into wink,
  delight, or surprise, rotating on each cold launch. The launch logo stays mounted
  until its first 0.7 seconds of active animation and session bootstrap both
  finish. Bootstrap runs independently; profile routing, covers and deferred
  incoming links wait for presentation. First-run diagnostic consent appears
  after the same intro, without starting bootstrap before consent. Reduce Motion
  skips the animation hold, and returning from the background does not repeat it.

- **Mobile Home keeps background folds out of scrolling.** Watchlist cache-load
  notifications use the same coalesced refresh as membership changes. Vertical
  scrolling and horizontal rail movement both extend the interaction settle
  window; cached Home rows still paint immediately on profile entry.
  Artwork prefetch task identity compares retained media and policy inputs,
  rather than constructing every item's metadata query during layout. Actual
  artwork lookup remains bounded to the existing nearby-card window. Changed
  items, artwork/provider preferences, spoilers and presentation restart that
  window; disabled prefetch performs no source preparation.

- **Preference sync is not a profile switch.** Mobile cloud apply rebuilds active
  settings and track/version preferences without restarting downloads, provider
  caches, identity indexing, or tracker/watchlist imports. Inactive-profile
  preferences and unchanged membership do not rebuild the active runtime.
  Changes to the active profile, namespace, membership, or local accounts still
  reconcile sources, after mandatory profile-lock checks. Retained downloads
  read current preferences from their original profile's stores when preparing
  new work.

- **Top Shelf actions retain their intent and owner.** Play opens the title then
  starts playback; More Info opens the same detail/episode-context destination
  without playback. Requests wait for signed-in admission and route through the
  active Home stack. Account-qualified links cannot fall back to another server,
  and cancellation or a superseding request rejects stale resolutions.

- **Missing sources are a recoverable route state.** Home, Watchlist, Search,
  library and series-context destinations show an unavailable state when their
  library provider no longer resolves. External Watchlist/Search details remain
  available without any enabled media server and keep their metadata/request
  behavior. An untagged library item may use the active primary
  provider; an explicit missing account never falls back to a different server.
  Classification and source selection use the same active-source snapshot so
  a stale index cannot send an external ID to a different server. Failed model
  construction is not cached; title, episode and season cache keys include their
  account and library origin inside the existing profile/credential scope.
  Player creation propagates missing-source failures into its visible error path.
  Online trailers bypass library version preparation and retain their dedicated
  provider even when no media-server account is enabled.

- **Mobile notification completion stays on the main actor.** The download
  notification delegate uses the explicit completion-handler entry point.
  Navigation is queued before completion; ignored and malformed notifications
  also complete exactly once on the main actor because UIKit may snapshot
  immediately afterward.

- **One root presentation at a time.** `RootPresentationCoordinator` retains the
  current native cover until its dismissal completes. Startup introductions,
  release notes, identity gates, synced-server prompts, and device setup wait
  rather than replacing one another. Automatic device offers wait for startup
  preparation; once visible, setup keeps confirmation, progress, errors, and
  success in that same cover until the user closes it. A profile authorization
  change stops credential transfer and leaves the error visible.

- **TV-to-phone setup QR.** The sender screen shows a three-minute
  `SyncSetupSourceInvite`. Scanning it opens the phone's existing receive flow,
  advertising the request UUID in Bonjour instead of broadcasting an iCloud
  offer. The TV matches that live request, then requires matching-code
  confirmation before sending credentials. This request has no
  credentials or public-key trust shortcut and cannot decode as the original
  receiver QR. Nearby-device labels inherit native button foregrounds so their
  codes remain readable when focus inverts the surface. The QR, nearby devices,
  and manual code entry stay on one page in distinct sections.

- **Bounded setup summaries.** Both sending and receiving use CoreUI's shared
  scrolling summary on TV and mobile. Group accounts by physical server, retain
  per-server transfer scope and pending sign-in state, and wrap full server and
  profile names. Headers scroll; Done/Continue remains reachable independently
  of the number of servers or profiles.

- **Visible pairing failures on both platforms.** Mobile automatic offers use
  one retained cover for confirmation, progress, retry and completion, waiting
  for existing root presentations. Sender authorization is rechecked during
  transfer; dismissing cancels the connection and any matching-code wait.
  Receivers stop advertising after failure and retain the error until an
  explicit retry. A failed TV-to-phone source QR requires a new scan.
  Sender retries keep the confirmed invitation pinned; a newly generated
  receiver code requires closing the old flow and accepting/scanning the new one.
  Matching-code confirmation is bounded to 60 seconds.

- **Device setup diagnostics.** Each attempt logs fixed role/route/stage/outcome
  categories and bounded elapsed time through `PlozzLog`, so manual diagnostics
  include pairing failures. With crash-reporting consent enabled, failures also
  reach Sentry automatically through `DeviceSetupDiagnostics`; no raw logs,
  device names, URLs, account IDs, codes, keys or credentials are uploaded.
  Failures are grouped by role/route/stage/reason and deduplicated to at most ten
  distinct reports per reporting session. Opt-out invalidates retained attempt
  callbacks. Explicit local cancellation/decline is not a failure report.

- **Composition root, not a feature.** This is the **only** module
  allowed to import all the others. Feature modules don't import
  `AppShell`.
- **Tokens stay in their stores.** `AppState` may *read* a session, but
  it never persists tokens itself — that's `FeatureAuth`'s job.
- **Provider-agnostic above the registry.** `AppState` resolves
  providers via `ProviderRegistry.provider(for:)`; nothing here
  switches on `ProviderKind` except for explicitly provider-specific UX
  (e.g. Plex Home-user PIN).
- **Profile-namespacing on switch.** Every per-user model must be
  rebuilt on profile change (`rebuildSettingsModels`) so settings,
  Trakt, and watched-state stay isolated.
  Tracker connection callbacks defer until every tracker is scoped and the
  watchlist reconciler matches the complete profile/identity/account scope.
  Authentication retries and native refreshes share the setup, PIN, and
  server-identity admission gates; callbacks never restart tracker scoping.

## Appearance onboarding

Apple TV first-run and new-profile setup share Theme, Navigation, and Home Layout
choices in that order. Each selection writes to the active profile's existing
settings model. Continue or Menu accepts the current selection; profile setup
is not complete until Home Layout is accepted.

Existing installations receive a device-local, one-time Home Layout chooser
after any pending navigation introduction and before release notes. The current
layout is preselected; dismissing does not reset it or change other profiles.
Finishing setup also completes these introductions, preventing a duplicate
prompt on first entry. iPhone and iPad retain their existing carousel layout.

`CoreUI.HomeLayoutOptionCard` supplies the same names and previews to onboarding
and Settings. Its illustrations omit navigation chrome, since Home layout and
navigation style are independent choices.

## Navigation planning

Settings is a normal destination in all three navigation shells. Its root keeps
app navigation visible and available; categories and nested pages hide it.
Root Back restores navigation focus, while child Back restores its Settings row.
The top-bar root reserves foreground clearance without moving subpage headers.
Chrome stays unavailable until a returning Settings page can receive focus.
Custom chrome fades over 220 ms with a 12-point exit toward its screen edge;
return uses the reverse motion. Reduce Motion keeps the fade without translation.
Native detail-transition snapshots keep owning their animation without a second
chrome transition. Pinned navigation moves its glass and controls together.
The native sidebar does not honor toolbar visibility for this custom page stack,
so its subpages use a full-screen presentation over the retained root.
Settings retains the mounted shell while its style picker saves the profile's
new preference immediately. Construct replacement chrome only after leaving
Settings: reparenting its pages resets native focus, even during a root return.
Ordinary Settings visits keep the mounted shell; Settings-first entry also
constructs usable navigation, including when Settings is hidden from the top bar.
Top-bar selection also prepares its nonpersistent library-navigation handoff
before a style change, so the first render cannot temporarily dismiss Settings.

Native tab builders capture the resolved selection and library entries before
constructing their children. The sidebar reuses that plan for content, labels,
and focus eligibility; lazy tab evaluations must not rebuild it per destination.
Recompute from current account visibility and profile layout when the shell
updates, rather than retaining a cache that could expose removed libraries.

Horizontal navigation offers individual libraries and All Libraries in the same
profile-scoped arranger as the sidebars. Newly discovered libraries appear
automatically; explicit Hide choices and saved order remain unchanged.
Top Bar is one glass surface using the pinned navigation's shared row style:
idle items have no background, and focus and selection use the same treatment.
Labels keep eight points between the icon and title, plus four points after the
title to balance the compact focus capsule.
Its scrolling list has no item cap and fades before the fixed profile area.
The 68-point-high panel fits its contents and stays centered, growing only to
75% of the page's title-safe width before scrolling. The Live TV guide and its loading
skeleton retain those page keylines even when the bar is narrow. A single shared
inner inset keeps the end focus capsule concentric with the panel instead of
doubling its end margin.
The profile icon sits inside the bar and is a button, not a destination: focus never opens the
picker, and Select opens the existing profile flow. Settings is fixed at the
right unless explicitly moved or hidden in the profile's arranger. Moving other
items does not unpin it; Reset restores its default position. Settings also remains
reachable through the picker's upper-right cog. Both vertical styles are unchanged.

Horizontal focus moves immediately without changing or constructing pages,
including after resting on a destination. Select opens the highlighted page and
enters its content. Down enters the already-open page, not an unselected
highlighted destination. There are no delayed page previews or native tab transitions.
Only the selected page and the visited Live TV guide
are mounted; walking twenty libraries must not retain twenty inactive grids.
The guide retains its filters while inactive playback is stopped. Account-qualified
destination IDs keep same-named libraries distinct. Content entry waits for
presentation through the existing shared focus owner; Back returns to the
selected navigation item. Detail pages hide the strip through `NavigationChromeModel`.
While Settings owns the shell, hidden navigation cancels focus handoffs and
cannot overwrite the selected Settings destination.
The focus owner's exit direction defaults to Right for pinned navigation and
is Down for the horizontal strip; Left/Right never trigger a page handoff there.
Initial focus resolves the selected destination, including a scrolled-off library,
before allowing neighboring controls. Live TV's first-use preview choice waits
for explicit content entry; its presentation owns focus until the choice finishes.
Full-bleed Live TV surfaces read the shared top-content inset for guide controls
and loading placeholders without shrinking expanded playback.
The common UIKit host propagates a real top safe area through nested stacks.
Foreground begins below the bar with a 16-point gap. The bar scrolls vertically
offscreen with Home, library grids, Showcase, Watchlist, Search, Music, and
Settings; foreground no longer fades beneath fixed navigation. The existing
root Back action resets the page to its top and focuses the selected destination,
discarding deep-row return focus. Subpage Back still returns one level first.
Showcase follows its native spring's painted viewport with a bounded display
observer that stops at rest or teardown. Hero artwork stays full bleed; Live TV's
bounded guide does not scroll the global bar.
The host's safe area stays stable across detail transitions so returning content
does not relayout under incoming remote input. Full-bleed detail surfaces ignore
that safe area. Scrolling the bar does not change the safe area or detail depth.

The profile-picker Settings request is a one-shot `ProfileFlowModel` intent,
scoped to the active profile. A cancellable picker returns to its already-admitted
profile; startup entry passes through the existing local, parental, and Plex
identity gates. Cancellation and ordinary profile switches clear the request.
`RootView` delivers it to `MainTabView`, which opens the existing Settings shell
before settling ordinary startup selection.

Home, Search, and Watchlist use shared, profile-scoped automatic visibility.
Live-only IPTV opens Live TV; IPTV movies and series expose Home and Search.
Search also remains available for configured Seerr discovery, and Plex keeps its
Home discovery surface. Library metadata comes from the existing bounded
navigation snapshot and library discovery, not a channel/title scan. Failed
accounts retain their last-known libraries; removed accounts cannot contribute.
Initial navigation discovery, Settings library refreshes, and account-selection
refreshes publish through one `LibraryDiscoveryModel` path to both navigation
and Settings. Cancelled or changed-profile/credential results cannot publish,
and an older request cannot overwrite a newer published answer. Cancelling a
Settings refresh does not invalidate a pending shell refresh; each request clears
only its own loading markers. Settings loading state stays observed only by its
library detail pages.

The iPhone/iPad shell (also used by the iPad app on Mac) includes discovered,
enabled video libraries as native tab/sidebar destinations. Its navigation
editor uses the same inventory and profile-scoped hide/order preferences.
Library routes keep account-qualified identity and use the existing library
browser; long lists use native overflow rather than dropping destinations.
Mobile Libraries settings and navigation refresh through the same scoped
discovery path, using `FeatureHomeCore.NavigationLibraryDiscovery` for the
same supersession/cancellation protection as Apple TV. Disabled or removed
accounts cannot contribute shortcuts, and refreshes preserve explicit hides.

An untouched Watchlist appears when the profile's hydrated local/native union
has items. Removing its last item does not evict its open page: it hides after
leaving, or on the next launch. Show and Hide are durable overrides; reordering
another row never converts automatic visibility into a manual preference.
Reset Navigation restores automatic defaults. Legacy hidden choices and
explicit whole-navigation arrangements are retained on decoding; an untouched
legacy default or library-only arrangement remains automatic. Runtime content
facts and the temporary open-page exception are never synced as preferences.

## Pinned sidebar remote navigation

At a visible pinned-navigation root, Back opens the menu on the current
destination. If already on Home, the next Back exits directly from the menu.
Otherwise, Back from the menu shows Home while keeping navigation open and focused
on its Home row; the following Back is left to tvOS to exit. Returning Home uses
the existing rendered-page handoff with a navigation focus target, so content never
takes focus and extra Back presses cannot exit before Home appears. Select or Right
still enters the page, where Back always opens navigation again. Leaving the active
scene releases menu focus so reopening starts in the content. Back
inside pushed pages and presentations still belongs to those surfaces. A hidden
Home destination is temporarily available for this explicit return without
changing the profile's hidden/order preferences. Native navigation and its
optional exit protection are unchanged.

`HomeTab` applies `NavigationRailRootContentInset` only to its root, before
registering destinations. Home, Watchlist and library roots retain their sidebar
clearance while details hide the rail; hiding chrome must not resize retained
rows or grids. Pushed pages still receive the shell's zero inset and remain
full-bleed. Native navigation roots keep their zero custom inset.

`SearchTab` likewise applies `NavigationRailSearchRootInset` only to its root,
before registering destinations. The native search field keeps room for the
page button while the surrounding navigation stack stays full-screen and fixed
during pushes and pops. Hiding pinned chrome must not change the stack's bounds
or move the retained search field; pushed details have no search-header padding.

`NavigationRailEdgeCatcher` passively observes arrow presses and indirect-touch
swipes. Left at an unresolved content edge opens the sidebar; Right at an
unresolved sidebar edge returns to the page. Both paths wait for native focus to
settle and do nothing if it moved or the sidebar's focus state changed. The Home
hero disables this fallback and requests entry at its own logical leading edge.
Unchanged focus is not sufficient evidence of unused input. Focus environments
conforming to `HorizontalNavigationInputOwning` keep horizontal adjustments,
and presented screens keep input away from the background rail. The native
Search controller remains eligible for its keyboard-edge handoff. Press, swipe,
and deferred Search callbacks recheck ownership before requesting navigation.

On tvOS, indirect touch-down and subsequent movement can use different coordinate
frames inside wide scrolling rows. `SwipeTravel` anchors at the first movement
sample, not touch-down; otherwise a left swipe from Continue Watching can look
like thousands of points to the right. The observer never recognizes, cancels,
or delays native touch gestures. Enable `PLZHFOCUS_STDOUT=1` for sidebar decisions
in the device console.

## Where to look first

- `AppState.swift` — the orchestration entry point.
- `RootView.swift` + `MainTabView.swift` — the root navigation.
- `PlaybackEngineComposition.swift` — how the Plozzigen (AetherEngine) engine
  is injected without leaking past this module.
