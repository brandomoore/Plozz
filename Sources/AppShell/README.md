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
- `AppInfo` — version / build / display-name helpers read from
  `Info.plist`.

## Invariants

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

## Pinned sidebar remote navigation

At a visible pinned-navigation root, Back opens the menu on the current
destination. If already on Home, the next Back exits directly from the menu.
Otherwise, Back from the menu returns focus to Home; the following Back is left
to tvOS to exit. Returning Home uses the existing rendered-page focus handoff, and
extra Back presses during that handoff cannot exit early. Explicit navigation,
opening a detail page, or leaving the active scene resets the sequence. Leaving
the active scene also releases menu focus so reopening starts in the content. Back
inside pushed pages and presentations still belongs to those surfaces. A hidden
Home destination is temporarily available for this explicit return without
changing the profile's hidden/order preferences. Native navigation and its
optional exit protection are unchanged.

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
