# FeatureAuth

Sign-in for Plex, Jellyfin, and Emby, an explicit session state machine that
keeps the UI free of ad-hoc boolean flags, and Keychain-backed account /
session persistence.

## Responsibility

- **Sign-in flows** — couch-friendly, no-password-typing-on-a-remote:
  - `QuickConnectService` + `QuickConnectViewModel` + `QuickConnectView` —
    Jellyfin **Quick Connect** (show a code on TV, approve elsewhere,
    poll until accepted; clean cancel / retry / expiry).
  - `PlexAuthService` + `PlexAuthViewModel` + `PlexLinkView` — Plex
    **Link** (`plex.tv/link`) PIN-code OAuth flow, polling for activation.
  - `PasswordSignInService` + `PasswordSignInViewModel` +
    `PasswordSignInView` — username/password sign-in for Emby and the
    fallback for Jellyfin servers without Quick Connect.
- **Session state machine** — `SessionStateMachine`. A pure `reduce`
  function over `(state, event) → state` (`launching → selectingServer →
  authenticating → authenticated → failed`). Unit-tested independently of
  any UI.
- **Persistence (split by sensitivity)** —
  - `SessionStore` (`SessionPersisting`) — Keychain for the access token,
    `UserDefaults` for non-secret metadata (server, user id/name, device
    id). Lets relaunch restore a session without re-login.
  - `AccountStore` — household-global, multi-account list (per-server
    logins). The single source of truth for "who can sign in" that
    `CoreModels.ProfileStore` subsets per profile.
  - `Keychain` — small wrapper around the Security framework used by
    both stores.
- **UI surfaces** — `AuthView` (root sign-in orchestrator) and the
  per-flow views above. `BrandQRCodeView` renders the Quick Connect /
  Plex Link codes as scannable QR + readable digits.

## Invariants

- **Tokens NEVER leave the Keychain.** Never written to `UserDefaults`,
  never logged. `AccountStore` is split-storage by design.
- **Pure state machine.** `SessionStateMachine` has no I/O — all side
  effects live in the services it produces events for.
- **Provider-appropriate sign-in.** Jellyfin uses Quick Connect or password,
  Emby uses password, and Plex uses Link.
- **Always cancellable.** Every flow must be Cancel-able from the remote
  without leaking polling tasks.
- **IPTV editor removal captures row identity first.** Guide/header removal
  actions capture the row's ID before mutating its collection. Reading a bound
  row from inside `removeAll` can overlap the collection's exclusive write
  access and crash Swift's runtime.
- **Valid empty IPTV playlists can be saved.** A playlist with an `#EXTM3U`
  header needs no current entries: event providers can publish channels later.
  URL and file imports retain these accounts, and authorized IPTV sources remain
  visible with zero channels. Refresh fetches the URL again instead of reusing
  the provider's 30-minute catalog cache; a successful empty response removes
  ended events without removing the source. Failed downloads retain the previous
  catalog. Blank/comment-only responses without a playlist header, invalid content
  such as a web page, and playlists containing only unusable entries still fail
  setup without creating an account. Imported files remain device-local snapshots.
- **IPTV setup keeps optional configuration behind a disclosure.** Playlist
  authentication, guides, and request headers live under Advanced options;
  required Xtream credentials stay in Connection. Existing advanced settings
  start expanded, and collapsing never clears or disables them. The HTTP warning
  appears only for an entered playlist/server or guide address using HTTP.
  Form controls share body typography and contained settings-row focus styling;
  only Connect and Cancel use the shared action-pill style. Section headings and
  essential helper text retain the shared settings typography.
  Disclosure, menu, and add/remove actions use `SettingsFormButtonStyle`, which
  places the shared TV row height and padding **inside** the focus fill. The
  section's outer spacing cannot substitute for clearance around text and icons.
- **IPTV import shows measured stages, not estimated completion.** Connecting,
  reading, and saving use one gradient-aware status card on both platforms.
  Parsed entries and committed records are distinct counts; cancellation remains
  available, stale callbacks cannot update a later attempt, and failed setup
  preserves the form and its disclosure state. Library discovery uses the same
  outlined surface and explicitly offers Choose later while it is working.
  Visible foreground imports temporarily suppress idle sleep on Apple TV and
  iPhone/iPad. Completion, failure, cancellation, backgrounding, and dismissal
  release only the import's wake lease; overlapping playback keeps its own lease.
  On iOS the loading card lives in a settings scroll surface, not a Form row
  whose native corner mask would clip its outline. The outline and fill use
  the same continuous corner shape.
  Count text interpolates toward confirmed totals without running ahead; a stage
  change resets it immediately. Reduce Motion shows exact counts without animation,
  and accessibility always exposes the latest confirmed total.
  Playlist sign-in validates and imports a single response. Automatic Live TV
  entry/enrollment reuses the current provider catalogue; only explicit source
  refresh bypasses its freshness policy. A current committed catalogue remains
  readable during replacement staging so library selection does not wait for
  another full download.
  Catalogue writes reuse a bounded set of prepared statements during staging.
  Repeated series/season parents are recognized before encoding and encrypting
  them again; their first record still wins. Statements and bound data are
  released with the temporary import, including failed replacements.
  Saving reports completed 500-record batches. Full-playlist replacement builds
  secondary indexes once inside the transaction instead of maintaining them for
  every inserted row; partial library refreshes retain their indexes. Cancellation
  or a write failure rolls back both rows and indexes. Storage diagnostics retain
  only numeric SQLite codes, never SQL, provider values, or database paths; only
  an actual disk-full result suggests checking available storage.
  Unexpected HTTP failures use plain-language provider errors rather than field
  validation advice; exact status codes stay in diagnostics. A 451 response
  explains blocked access without asserting that a trial has expired.
  Duplicate, incomplete, and conflicting custom headers have
  separate validation messages and cannot be inferred from a server response.
- **Channels-only IPTV needs no library selection.** Successful discovery with
  no on-demand libraries continues onboarding on both platforms; failed
  discovery still offers recovery. Adding an IPTV account includes it in the
  active profile's explicit server selection so Live TV can discover its channels.
  Reconnecting an existing account preserves its enabled/disabled choice, and
  other profiles' explicit selections are unchanged.
  Explicitly adding the same playlist again selects its existing account, without
  duplicating it; this also repairs accounts saved by older incomplete setup flows.
  Settings enrolls newly authorized IPTV sources, including empty event
  playlists, using the same guarded source registration as Live TV, so a source
  appears without first visiting the player. Removed or disabled sources stay
  removed or disabled.
- **In-app setup preserves its starting page.** tvOS keeps the signed-in
  navigation tree mounted underneath account setup, including Sources inside
  Live TV settings. Finishing or cancelling returns to that page. First-run
  setup remains separate, completes the profile/appearance steps, and uses the
  shared startup policy to enter Live TV for channels-only IPTV.

## Automatically Sign In

Settings → Profiles offers an off-by-default, device-only startup preference on
tvOS and iOS/iPadOS. When enabled from an authenticated profile, the next launch
opens the last successfully used profile without the profile picker or PIN.
This is the only startup control. When disabled, households with multiple
profiles see the picker and protected profiles require their PIN as usual.
The retired ask-on-startup preference is ignored, not converted into consent
to bypass a PIN. The toggle has no helper text; only errors appear beneath it.
Automatic sign-in applies to Plozz profiles regardless of their providers,
including profiles without server accounts. Plex Home token restoration is the
provider-specific part, not a restriction on who can use the setting.

`AppRuntime.AutomaticSignInStore` retains one session in a non-synchronizable,
ThisDeviceOnly Keychain item (per Apple TV system user). It stores authenticated
Plex server and Discover tokens, never a PIN. The preference and session are not
part of profile sync, device pairing, or credential export. Restoration requires
the same profile, lock revision, account credential revisions, and Plex bindings;
missing or changed state returns to the normal gates, never the owner's identity.

Only the startup entry point can restore this session, once per process. Manual
profile activation discards startup unlock credit and Plex overrides, so switching
back to a protected Plex Home user still requires their PIN, including two Plozz
profiles mapped to the same Plex user. Local Profile Locks and Kids Profile exit
gates remain in force for manual switching. Disabling automatic sign-in removes
the stored session without changing any PIN; sign-out invalidates it.

Foreground account or profile-membership credential recovery must leave a
launching session in `launching`. The shell's bootstrap owns profile/PIN gates
and automatic sign-in restoration before emitting `restored`; an early
`accountsChanged` must not skip that step while Home's cache is prewarming.

## Where to look first

- `SessionStateMachine.swift` — the pure auth-state reducer (start here
  to understand the auth lifecycle).
- `SessionStore.swift` + `AccountStore.swift` — what's persisted where.
- `QuickConnectService.swift` + `PlexAuthService.swift` — the two
  couch-friendly OAuth flows.
