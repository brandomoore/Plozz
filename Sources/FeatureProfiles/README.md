# FeatureProfiles

The "Who's watching?" launch picker and the profile editor — Plozz's
household multi-user UI on top of `CoreModels.ProfileStore`.

## Responsibility

- `ProfilePickerView` — the launch / "Switch Profile" picker. Shows the
  household's profile tiles (avatar + name), focusable, with an "add
  profile" tile that opens the editor. `AppShell.ProfileSelectionView`
  hosts this for both the launch flow and Settings → Switch Profile.
  Its upper-right Settings cog uses the shared native glass button, including
  the reduced-transparency fallback. A full-width focus section lets Up from
  the profile tiles reach it. The shell owns authentication and profile-scoped
  routing; the picker never bypasses a PIN or activates another profile itself.
  Initial native focus selects the active profile, falling back to the first
  available profile. A presentation anchor waits for visible layout in the
  active scene's key window, then crosses the presentation commit before handing
  off focus. Background mounting and disabled input do not consume the request.
  Entry does not depend on a timed focus assignment.
  Other tiles, Cancel, and the Settings cog become focusable after the entry
  profile receives native focus. They cannot win entry, but normal navigation
  is available afterward, including Up to Settings. An empty picker leaves its
  available actions enabled.
  Mobile uses `AppShelliOS.PlozziOSProfileSelectionView` and its touch picker.
- `ProfileEditorView` — create / rename / restyle a profile (name,
  `avatarSymbol` SF Symbol, color from `ProfileTileColor` palette,
  account subset, Plex Home-user mapping).
- `ProfileAvatarView` — renders a profile's photo, emoji, or SF Symbol.
  Native navigation labels use `rendersAsImage` so the circular crop, point
  size, and original colors survive native image extraction. This includes
  iOS toolbar buttons when the iPad app runs on Mac; framing a resizable photo
  alone does not constrain the extracted image. Keep the native button style
  and hit target. Palette resolution lives here, not in Foundation-only `CoreModels`.
- `ProfileTileColor` — the colour palette and the deterministic
  `colorIndex → Color` resolution used by avatar / tile / picker.
  Avatar choices reuse CoreUI's `ColorSwatchButton`, also used by watch-indicator
  settings. The 40-color avatar palette, TV grid, mobile compact row/full palette
  sheet, and neutral emoji option remain independent of the watch-mark palette.
- `ProfileNameLabel` — shared picker and summary name with an inline lock
  for a Plozz Profile Lock or a configured PIN-protected Plex Home binding.
  The indicator and VoiceOver value describe configured protection, not temporary
  unlock state, source enablement, or Kids restrictions. It does not add a local
  PIN gate; live Plex checks still decide whether authorization is required.
- `ProfilePhotoCandidate` — value type for profile photos borrowed from
  connected accounts and Plex Home users.
- `ProfileActionsList` — shared profile management actions. Settings pages use
  separate native groups for appearance/locks/Kids, device-wide automatic sign-in,
  and deletion; mobile groups own row insets rather than wrapping padded rows.
  Locked or parentally sealed actions remain gated, including automatic sign-in.
  Picker dialogs retain their ungrouped layout and do not offer startup trust.
- `AutomaticSignInSettings` — one binding and shared control for the device's
  startup preference, exposed in individual profile settings and Everyone → Profiles.
  The description carries device scope without an extra section heading.

## Invariants

- **tvOS profile selection on return.** Automatically Sign In is the only
  device-wide access preference. When it is on, warm returns keep the current
  profile authorized. When it is off, `CoreModels.ProfileReturnPolicy` derives
  the return timing from the current profiles: immediate selection when any
  profile has a configured local or Plex PIN, five minutes away for multiple
  unprotected profiles, and no return prompt for one unprotected profile.
  There is no configurable timeout or persisted override; profile and PIN
  changes take effect without another setting to update.
  Elapsed time is measured only while away, using a continuous clock (including
  sleep), not a background timer or browsing inactivity. Returning before the
  threshold starts a new grace period for the next departure. Expiry requires
  profile selection and fresh authorization for whichever profile is selected.
  Retaining the current authorization never skips manual switching gates.
  Cold launches keep the existing Automatically Sign In policy.
  Control Center and other inactive-only interruptions do not lock. Open video
  players (including paused/buffering sessions), visible Live TV players, Now
  Playing, actively playing music, and the current external-player handoff are
  exempt; ambient hero trailers and an empty Live TV guide are not.
  A scene-owned opaque window covers browsing and any presented Settings page,
  removing their input/accessibility access without destroying their navigation.
  Selecting the same profile restores that context after successful PIN entry;
  choosing another profile uses normal identity/settings rescoping. Cancellation
  stays at the mandatory picker, including when leaving from a previously
  cancelable profile picker or in-app account setup. The picker's Settings
  shortcut also requires fresh authorization on return, and another departure
  clears any unconsumed Settings request. Top Shelf links wait for
  authorization, and a late async result cannot start a new player behind the
  gate. Pending PIN attempts are revoked on another departure even within the
  return delay. Configured Plex PINs affect the return default, but disabled
  sources still do not ask for PINs. This policy does not change iOS.
- **Non-secret only.** Profiles are non-secret metadata; tokens belong
  to `FeatureAuth.AccountStore`.
- **Default profile is special.** Stable id
  `ProfileStore.defaultProfileID` (`com.plozz.profile.default`); `nil`
  settings namespace; cannot be removed. Don't break the upgrade path.
- **Plex Home onboarding is opt-in.** After linking Plex, the shared page offers
  Add all profiles or Just me. Add all commits the missing profiles first, confirms
  Profiles added (or Profiles ready when already present), then offers Choose your
  profile using those same Home identities. Just me offers Choose your Plex user
  and binds only the current profile. Confirmation advances without another Continue
  button; only the uncommitted Just me choice offers Back. Transitions use a short
  lift/fade; Reduce Motion uses only a fade.
  Import preserves existing profiles and their customization. New profiles have
  explicit membership in that login's selected
  Plex servers, their own Home-user bindings/photos, and the normal setup gate.
  Import is metadata-only: no other user's PIN or session is requested, and
  each user's current Plex protection is checked when they enter their profile.
  Choosing an imported profile uses the normal parental/local-lock gates before
  changing persona, then scopes settings and library choices to that profile.
  The selected viewer authenticates before library selection, including during
  first run. The library-selection surface owns verification and any required
  Plex PIN, then loads libraries using the resolved viewer credentials. Missing
  providers are failures, not an empty inventory, and credential/profile changes
  restart discovery. Other imported users remain unauthenticated. A
  just-entered linked local PIN is spent immediately rather than held across setup;
  only the selected viewer's setup gate is cleared. The default owner's identity
  and other imported profiles remain intact when a different viewer is selected.
  If account setup began inside another profile's unfinished setup, choosing an
  imported viewer retargets the setup identity and navigation to that viewer,
  without completing the previous profile. The mobile chooser owns its local
  and parental PIN surface, including when it sits above Settings.
  Extra imported profiles cannot skip the remaining onboarding pages; once the
  viewer finishes, a synced household still avoids repeating first-run elsewhere.
  Short choice pages center vertically; overflowing viewer lists start at the
  top so initial native focus stays visible and remote navigation scrolls normally.
  The import preview and confirmation show every household avatar in centered,
  wrapping rows. Viewer names have their own line; owner/PIN metadata sits below
  rather than competing with the name for horizontal space.
- **Photo fallback.** Borrowed photos fall back to the profile's emoji or
  symbol if loading fails; preserve symbol-only profiles on both platforms.
- **Profile-aware everywhere.** Any feature reading per-user state
  (settings, watched, recommendations) must scope through the active
  profile id from `CoreModels.ProfilesModel`.
- **Continuous mobile selection.** Launch and Settings keep the picker and
  parental/profile/Plex PIN steps on one opaque surface until authorization
  finishes.
  A pending PIN never opens automatically when the picker appears: only a
  profile tap starts authorization, including when a restored profile is locked.
  The modal owner sits outside the profile-scoped shell identity;
  launch keeps that identity stable through PIN entry and cancellation.
  Cancelling a PIN returns to the retained picker, not Home. Authorization
  still belongs to the existing profile/Plex models.
  Selection carries the Plozz profile's own avatar and name into authorization
  using native matched geometry while the other tiles fade away. PIN type is
  secondary copy, not a replacement server-user identity. Live Plex verification
  keeps that identity in place without an avatar spinner; only a longer check
  shows loading feedback below it. Confirmed PIN keys reveal progressively;
  unprotected users never mount a keypad. Errors retain the identity and expose
  Retry/Cancel. Cancelling returns to the retained tile order, while profile
  details still reflect live edits. Reduce Motion removes the movement and
  reveal delays. Existing parental and separate-PIN steps remain explicit.
  A verified local PIN stays visible, with input disabled, while chained Plex
  authentication finishes. Only a confirmed additional PIN replaces it with a
  fresh keypad; failures remain retryable. Completion retains the outgoing PIN
  surface through dismissal rather than clearing it before Home appears.
  Local PIN verification does not block the UI executor, and cancellation or a
  changed profile/lock invalidates an in-flight result. Switching away expires
  local unlock proof on both platforms; returning requires the PIN again.
  Picker lock badges and accessibility values use each profile's enabled Plex
  sources, with the same stale-account fallback as activation. A saved binding
  to a disabled or removed source does not advertise a PIN gate. A separate
  local Profile Lock remains visible regardless of source enablement. Setup
  transfer summaries describe configured protection rather than local admission.
- Mobile Plex identity selection explains playback and watchlist ownership in
  its scrolling content. Whole-row buttons show pending work immediately;
  verification, Retry/Cancel, and confirmed PIN entry stay in that chooser.
  Its exact pending request is excluded from app-level PIN presenters, and the
  root identity sheet survives Plex identity-generation changes. Settings retains
  its same-profile presentation until dismissal before rebuilding covered content;
  a different active profile still invalidates that presentation. A proposed
  binding is still saved only after authentication succeeds.
- **Visible mobile entrance.** Launch waits for native presentation to finish;
  the cancellable in-app switcher starts during presentation instead of adding
  another pause afterward. Overlapping 450 ms native smooth springs use a subtle
  lift and 90 ms between profiles for households of up to six. Larger households
  shorten every interval so the last profile starts within 450 ms; Add tiles
  continue the same cadence. All visual starts share one presentation transaction,
  rather than waiting on separate task wake-ups; tasks only admit input when
  each tile starts appearing. Sixteen profiles should settle within one second.
  Never clamp later delays into a batch. Reduce Motion reveals everything
  immediately; newly realized offscreen cells do not wait through earlier slots.
- **Native editor controls.** On tvOS, the scrollable editor keeps its title
  separate from one center-aligned row of Back, Delete, and save/revert actions.
  The navigation owner still supplies Back and its focus-restoration behavior.
  Actions use native glass, with the shared reduced-transparency/older-OS fallback;
  Delete is an icon-only destructive button and still requires confirmation.
  Both platforms share a native name field without custom fills or focus colors.
  Mobile uses `SettingsSectionGroup`; tvOS keeps its system field surface without
  a second container. Mobile actions stay in the native toolbar.

## Where to look first

- `ProfilePickerView.swift` + `ProfileEditorView.swift` — the two UI
  surfaces.
- `ProfileTileColor.swift` — color palette resolution.
- `CoreModels/ProfileStore.swift` — the persistence layer this UI edits.
