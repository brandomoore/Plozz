# FeatureSettings

The Settings screen and its detail pages. Profile-aware, integration-aware,
and the single place caption customization lives.

## Responsibility

- `SettingsView` — the root focused list (themes, profiles, servers &
  libraries, integrations, captions, about). `SettingsRowStyle` &
  `SettingsContext` provide the shared look + the environment needed by
  every detail page.
- `ProfileDetailView` — manage the active profile: rename, recolor,
  switch / sign out of accounts, configure the Plex Home-user mapping
  (`PlexLinkedUserDetailView`).
- `ServerDetailView` + `ServersAndLibrariesDetailView` — manage stored
  servers / accounts (`AccountStore`), pick which Jellyfin libraries the
  current profile includes, remove accounts.
- `IntegrationsDetailView` — "Trackers" page: connect/disconnect for Trakt,
  Simkl, AniList & MyAnimeList (delegates to each tracker service) plus the
  Watch Status across-servers sync toggle.
- `PreferenceDetailViews` — subtitle behaviour / spoiler / diagnostics /
  Home-customization preferences. Subtitle *behaviour* (mode, language,
  auto-download) lives here; the subtitle *look* is now adjusted in the
  player while watching.
- `SettingsAboutSection` — app identity / version / release notes.
- `SettingsCommunityLinks` — separate Discord-first and GitHub cards shared by
  About and mobile Settings. Apple TV shows them below the app identity.
  Mobile uses one shared Community section with full-wordmark direct links and
  expandable QR cards: directly above Support in compact iPhone Settings,
  and on the About page in regular-width layouts. The cards use
  official icon-and-wordmark lockups directly on their surfaces, without colored
  icon tiles or duplicate name labels. They follow the theme's primary text color
  and stay outside the codes' white scan margins. Narrow layouts stack without
  shrinking the codes. Public destinations are centralized in `CoreModels.AppLinks`.
  `SettingsCommunityLogo` balances both brands by visible ink area rather than
  equal height: Discord renders at 75% of GitHub's height, with each original
  aspect ratio preserved. A common layout height keeps caption baselines aligned
  on TV and mobile; hosted coverage compares the rendered areas at both sizes.
  Lockup sources are from [Discord](https://discord.com/branding) and
  [GitHub](https://brand.github.com/foundations/logo); original SVGs are in
  `docs/assets/{discord,github}-lockup.svg`. The marks and lockups live in
  `App/Resources/CommunityAssets.xcassets`, linked by both app targets and their
  presentation-test hosts; platform-only catalogs must not own shared logos.
  Their vector PDF exports use CairoSVG
  with `dpi=72` so source units map to PDF points without fractional-height
  rounding by the asset compiler:
  `python3 -c "import cairosvg; cairosvg.svg2pdf(url='docs/assets/discord-lockup.svg', dpi=72, write_to='App/Resources/CommunityAssets.xcassets/DiscordLockup.imageset/discord_lockup.pdf')"`
  (substitute `github` / `GitHubLockup` for the GitHub export).
  The Discord mark comes from [Simple Icons](https://simpleicons.org/) (CC0).
  Its original path is in `docs/assets/discord-mark.svg`; the asset catalog uses
  a vector PDF because Xcode's SVG renderer distorts this path's compact arcs.
  Regenerate it with
  `python3 -c "import cairosvg; cairosvg.svg2pdf(url='docs/assets/discord-mark.svg', write_to='App/Resources/CommunityAssets.xcassets/DiscordMark.imageset/discord_mark.pdf')"`.

## Invariants

- **Artwork and label presets.** Choosing any preset, including reselecting the
  previous one, replaces the whole configuration through `applyPreset`. Editing
  a view switches to Custom: no preset is selected, and a single badge appears on
  "Customize by view". `selectedPreset` derives this status from existing stored
  overrides; the backing preference retains unedited views' behavior, including
  mixed recommended rules. Settings remain in the existing profile store and sync
  payload; artwork's `scopeVersion` migrates earlier shared choices once.
  Matching a preset's value manually stays Custom until a preset is chosen.
  Rows have only a name and short value: Library / Providers, or On / Off. Select
  toggles the value directly, without an inheritance step, menus, chevrons, or
  per-row status. Mixed labels in Home and library Recommended retain their
  Showcase/title-artwork rules until edited. Explanations appear outside the rows
  when focused on TV, and as accessibility hints on both platforms. Accessibility
  text sizes can stack the name and value instead of shrinking or clipping them.
  Both lists group library tabs under "Libraries". Artwork separates Home's
  Showcase/hero from other Home rows, and library Recommended's hero (TV only)
  from its rows. Browse, Collections, and Playlists have independent choices;
  titles inside collections/playlists use Browse. Continue Watching rows share
  one choice across Home and libraries, independent of the series-artwork option.
  Watchlist means the standalone page, not Home's Watchlist row. Episode browser
  means detail-page episode cards; Video player artwork covers player menus,
  Up Next, and system Now Playing. Shared view components retain these scopes
  rather than treating a common layout as a shared preference.
  Labels retain equal-height visual presets: App default uses a single split illustration with
  caption bars on only one half. Show labels everywhere and Hide labels everywhere
  govern all media captions; App default owns Showcase and title-artwork exceptions.
  Explicit per-view choices, including Episodes, last until a preset replaces them.
  Library navigation names and on-artwork information are not captions.
- **Scoped TV detail navigation.** `SettingsDetailPages` and `SettingsDetailLink`
  in `SettingsDetailNavigation.swift` are reusable across settings, independent of
  artwork and labels. A `SettingsSplitRow` opts in with `SettingsDetailSubpage`;
  use `SettingsDetailLink` inside its root content to open that child. Outside a
  scoped pane, the link uses ordinary navigation. Both pages slide by the pane's
  full width: the root leaves toward the leading edge as the child enters from
  the trailing edge, and Back reverses both motions. The root stays mounted to
  preserve state and scroll position; it becomes ineligible for input while away.
  The sidebar stays stationary. Entry transfers native focus to the first row;
  Back restores the originating link after removal completes. Stale completions
  are invalidated when changing the selected sidebar page. Left remains available
  for sidebar navigation, RTL mirrors the motion, and Reduce Motion disables it.
  Child content chooses its initial native focus target and calls
  `SettingsDetailNavigation.focusArrived()` when that control receives focus.
  Customization lists and their inset contextual cards occupy separate regions.
  Larger 16:9 illustrations highlight only the affected artwork, beside one sentence
  of help; label settings reuse the card-style preview. Navigation follows the active
  profile, including native sidebar, pinned rail, and top-tab differences. Ordinary
  title rows use 2:3 posters; episode/player thumbnails use their landscape ratios.
  Home follows the active Fullscreen Hero/Showcase layout, including disabled heroes;
  Continue Watching uses its actual thumbnail or extended series-artwork shape.
  The shared title-detail choice shows separate movie and show layouts: show episodes
  stay muted because the episode choice owns those images. Extras and cast photos
  are not promised a title-level source replacement. Keep the card and viewport
  stable as focus or values change, with no extra focus stop or content behind
  the card. A smooth 40-point bottom fade and matching scroll clearance keep focused
  rows above the fade. Lists without help reserve no footer. Pane-level transition clipping
  remains. Artwork values use "Library" and "Metadata providers"; narrow/mobile
  and accessibility layouts stack the complete value rather than abbreviating it.
- **Mobile Settings is a presentation action.** Its tab or More entry opens
  the drawer over the current page without selecting a replacement destination.
  Keep the active content stack and overflow navigation intact on dismissal;
  destination normalization still retains the Settings-only recovery screen.
  The native tab delegate must reject the Settings transition before UIKit
  changes navigation insets; declining only the SwiftUI selection binding can
  move a scrolled page. Forward other delegate callbacks and restore the prior
  delegate when the action bridge is removed.
- **Automatic iCloud sync.** The main sync page does not show a separate Live TV
  explanation panel. Recovery lives in Troubleshooting, with a warning above
  Reload and Reset explaining that neither is normally needed. Both platforms
  use the shared transient-status presenter for progress and the actual result,
  and disable both actions while either is running. Reset still requires
  confirmation. Pending Live TV source repair rows remain in Troubleshooting.
- **Profile-namespaced settings.** Per-user prefs (theme, captions,
  diagnostics, spoiler) are namespaced by the active profile id; the
  default profile uses no suffix so an upgrading install keeps existing
  values (`migrateLegacyIfNeeded` in `ProfileStore`).
- **No tokens here.** Account & Trakt token management is delegated to
  `FeatureAuth.AccountStore` / `TraktService.TraktTokenStore`.
- **Dual-provider.** Server/library management must work for both Plex
  and Jellyfin accounts (Plex Home-user mapping is Plex-specific, but
  the UI must clearly say so).
- **No persistence schema duplication.** Persistence lives in
  `CoreModels` / `FeatureAuth` / `TraktService`; this module only
  **edits** what they store.

## Where to look first

- `SettingsView.swift` — the row composition (the tree of detail pages).
- `ProfileDetailView.swift` — profile-scoped editing.
- `PreferenceDetailViews.swift` — caption / spoiler / diagnostics prefs.
