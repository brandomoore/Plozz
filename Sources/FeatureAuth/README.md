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
  Plex Link codes as scannable QR. `ConnectionCodeView` supplies the shared
  readable code panel for Quick Connect, Plex Link, Silo, and device setup.
  `ServerAddressesView` uses the shared provider logo and Settings surfaces to
  separate server/sign-in identity, saved addresses, and address entry. Full
  addresses wrap without truncation, with the protocol labeled separately;
  mobile Copy preserves the complete URL, and accessibility reads it intact.
  Routing and device-scope explanations remain secondary to native add/remove actions;
  removal still requires confirmation, and the original address cannot be removed.
  The add action uses a native title-and-icon label so the group's muted row-icon
  color cannot override the prominent button's contrasting foreground.

## Invariants

- **Managed-server recovery does not require removal.** Plex, Jellyfin, Emby,
  and Silo expose Sign In Again from server settings and rejected library loads.
  Recovery uses the provider's existing link, password, Quick Connect, or pairing
  flow and requires the original server/user (and Silo profile). It preserves
  the exact account ID and selections, refuses stale or removed accounts, and
  rechecks profile authorization before saving. An unsuccessful save stays in
  sign-in with Retry/Cancel instead of claiming success or dismissing.
  IPTV authentication failures open its existing connection editor. Network
  failures retain Retry and do not discard credentials or send file shares
  through a media-server sign-in flow.
- **Recovery uses the shared screen treatment.** Plex gate failures and managed
  account sign-in errors use `RecoveryScreen`, also used by playback failures,
  with `ProviderBrandMark` and native `plozzActionButton` controls. The provider
  heading, affected name and error remain distinct. Account recovery inherits
  the browsing theme rather than playback's dark-only policy. Actions adapt to
  width, stacked mobile actions fill the card's content width, all content
  scrolls at large text sizes, and TV entry focuses Sign In
  Again (or Retry when a sign-in attempt failed).
  On TV, managed account recovery owns the shared opaque dialog surface through
  the link-code phase too; the covered Settings error must not show through
  behind the QR code or instructions.
- **Plex account recovery stays inside the profile gate.** A rejected Home-user
  list request means the saved account needs sign-in, not that the server is
  offline or the user's Home PIN is wrong. Failed activations offer Sign In Again
  on both platforms, using Plex's hosted link flow (including MFA). Recovery
  accepts only the original Plex login and server and replaces that exact saved
  account under a compare-and-swap. Account IDs, selections, alternate addresses,
  profile bindings, and library preferences survive. Removed/replaced accounts,
  cancelled linking, and superseded profile activations cannot commit credentials.
  Linking does not unlock a Home user: current PIN protection is checked again.
  Cancelling returns to the unresolved gate without exposing the owner's content.
- **Repeat sign-ins reuse the exact server/user connection.** Authentication
  matches provider, backend server ID, and authenticated user ID under the account
  store's mutation lock. Existing account IDs, creation order, approved alternate
  addresses, and enabled/disabled selections survive reconnecting, including older
  randomly identified accounts. Fresh credentials replace the existing credential;
  unchanged credentials keep their revision. Server names, addresses, and library
  overlap are not identities. Different users on the same server remain separate,
  and Plex Home bindings remain attached to their existing Plozz profiles.
  Already-saved duplicates are not silently deleted or merged.
- **Public discovery retains the canonical API address.** Jellyfin/Emby may
  upgrade HTTP to HTTPS on the same hostname or redirect within the same origin,
  preserving the final reverse-proxy prefix. Public requests carry no credentials;
  authenticated redirects remain same-origin only. Sign-in retains the resolved
  address and uses it for the user avatar. The launch metadata refresher repairs
  older saved addresses only when the public server ID matches. Its metadata-only
  compare-and-swap cannot revive a removed account or overwrite a concurrent
  credential/address change. Account IDs, credential revisions, alternate
  addresses and active selection remain unchanged. Connection-scope updates
  refresh retained providers and trigger library/Home reloads on both platforms.
- **Alternate addresses belong to one local sign-in.** `ServerAddressesModel`
  verifies Jellyfin/Emby public server IDs and Plex machine identifiers without
  sending saved credentials. Silo uses fresh native device pairing and matches
  the authenticated installation, account, profile, and device; it revokes that
  verification login without replacing the original credential. Cancellation
  also disposes of any unfinished verification login already received.
  A public identity is a consistency check, not proof of transport trust:
  users must explicitly approve trusted addresses, with an HTTP warning.
  `AccountStore.updateServerAddresses` compares the original account snapshot
  before writing metadata; profile authorization and cancellation are checked
  again after asynchronous work. Account IDs, credential revisions, active
  selection, and watch state do not change. Aliases are excluded from sync and
  device-transfer descriptors. Address-only reloads update existing providers
  through `ServerAddressUpdating`, including retained music consumers, rather
  than invalidating every provider and losing active Silo grants.
- **Tokens NEVER leave the Keychain.** Never written to `UserDefaults`,
  never logged. `AccountStore` is split-storage by design.
- **One Plex Home authorization across servers.** During one profile activation,
  a successful Home-user PIN authenticates that Plex login/user once. Other enabled
  servers with the same Plex account user ID and Home-user UUID reuse its in-memory
  cloud token and resolve their own server access tokens. No PIN is retained or
  replayed. Sharing is limited to the account credentials, bindings, and source
  generations captured for that activation; cancellation, manual activation,
  disabled sources, credential replacement, and changed identities cannot reuse
  stale proof. Distinct Plex logins or different Home users remain independent.
  Opt-in automatic startup reconstructs sharing only for the saved session's
  validated accounts. Re-enabling a sibling server can reuse an enabled user's
  authorization; disabling the last authorized source still removes that proof.
- **IPTV cache cleanup uses the complete household inventory.** Background
  maintenance runs at startup and after account mutations on both platforms.
  It preserves disabled/profile-unselected accounts and fails closed on missing,
  malformed, or unreadable credentials or a missing household account record.
  An explicitly persisted empty list is distinct from a record that has not yet
  been promoted from the per-user Keychain. tvOS maintenance does not use a per-user
  Keychain fallback to authorize deletion. Removed/replaced catalogues are reclaimed
  only after their final SQLite connection closes and a fresh inventory confirms
  that no saved account references them. Unowned legacy cache files need a 24-hour
  grace period; recent setup files remain protected until sign-in is persisted.
  Maintenance only scans the IPTV cache directory, never imported playlist
  snapshots in Application Support, watch state, or sync data. Saved journals are
  recovered through SQLite off the main thread, with busy readers left intact;
  failed/cancelled imports also reclaim journals after rollback.
- **Pure state machine.** `SessionStateMachine` has no I/O — all side
  effects live in the services it produces events for.
- **Provider-appropriate sign-in.** Jellyfin uses Quick Connect or password,
  Emby uses password, and Plex uses Link.
- **Always cancellable.** Every flow must be Cancel-able from the remote
  without leaking polling tasks.
- **Connection reports distinguish validation from sign-in.** Password sign-in
  and Quick Connect add bounded `ServerConnectionDiagnostics` records to the
  existing explicit diagnostic submission. Quick Connect records begin/approval
  stages rather than one journal entry per poll. Cancelled work is excluded;
  usernames, passwords, codes, tokens, server addresses, and response bodies
  are never retained by this journal.
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
- **IPTV setup discovers guides automatically.** The basic form exposes one
  optional EPG URL; leaving it empty uses the provider's guide. Custom guide URLs
  keep priority and are never overwritten by automatic discovery. There is no
  separate discovery toggle, including when reconnecting an old account.
  Playlist authentication, additional guides, and request headers live under
  Advanced options; required Xtream credentials stay in Connection. Existing
  advanced settings start expanded, and collapsing never clears or disables them. The HTTP warning
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

Individual profile settings and Everyone → Profiles expose the same
off-by-default, device-only startup preference on
tvOS and iOS/iPadOS. When enabled from an authenticated profile, the next launch
opens the last successfully used profile without the profile picker or PIN.
This is the only startup control. When disabled, households with multiple
profiles see the picker and protected profiles require their PIN as usual.
The retired ask-on-startup preference is ignored, not converted into consent
to bypass a PIN. The description explains that it signs in to the last-used
profile automatically on this device; this is not a per-profile or synced preference.

On mobile, applying configuration sync refreshes the unchanged active profile
without starting a new explicit activation. Cosmetic updates preserve a successful
or in-flight Plex PIN entry. Synced profile changes and locks still pass the
profile gates, and source membership/credential changes still reconcile or revoke
Plex access. Deliberate selection, even of the current profile, remains a fresh
authorization boundary.
Automatic sign-in applies to Plozz profiles regardless of their providers,
including profiles without server accounts. Plex Home token restoration is the
provider-specific part, not a restriction on who can use the setting.

Plex authorization follows the profile's enabled sources, not individual library
visibility. Disabling an entire Plex source preserves its saved Home-user binding
but clears its live credentials, PIN proof, and pending authorization. It no longer
prompts when entering the profile or participates in automatic sign-in. Re-enabling
the source verifies current protection and requires its PIN before content access;
neither old credentials nor an in-flight response can authorize it. Hiding libraries
within an enabled source does not waive authentication. Separate Plozz Profile Locks
and Kids Profile exit gates are unchanged.
Both profile pickers use this same source membership for their lock indicators,
including before a profile is selected; a disabled Plex source alone does not
mark a Silo, Jellyfin, or other non-Plex profile as locked.

`AppRuntime.AutomaticSignInStore` retains one session in a non-synchronizable,
ThisDeviceOnly Keychain item (per Apple TV system user). It stores authenticated
Plex server and Discover tokens, never a PIN. The preference and session are not
part of profile sync, device pairing, or credential export. Restoration requires
the same profile, lock revision, account credential revisions, and Plex bindings;
missing or changed state returns to the normal gates, never the owner's identity.
Protected Plex credentials also require a device-local record of successful,
nonempty PIN authentication. Enabling the preference alone never grants this
proof. Older startup sessions without it must authenticate again on that device.
Resolved credentials and PIN proof also belong to the originating account
credential revision, server identity, and server user. Replacing that source
cannot reuse old proof or save old tokens under a new automatic-sign-in session.

Only the startup entry point can restore this session, once per process. Manual
profile activation discards startup unlock credit and Plex overrides, so switching
back to a protected Plex Home user still requires their PIN, including two Plozz
profiles mapped to the same Plex user. Local Profile Locks and Kids Profile exit
gates remain in force for manual switching. Local unlock proof expires on every
active-profile change, not just process exit; async verification must still match
the original request, selection generation and lock before granting entry.
On tvOS, Automatically Sign In also bypasses the return picker. With it off,
selection is required on every return if any profile has a local or Plex PIN,
after five minutes away for multiple unprotected profiles, and not on warm
returns for one unprotected profile. This timing is derived, not configurable.
Expiry revokes live PIN proof. Foreground reauthorization retains the same
viewer's credentials behind an opaque input-blocking gate so unchanged tokens do
not reset browsing identity. It still checks current Plex protection, never
replays old PIN proof, and retains the gate on cancellation or network failure.
Different-profile selection continues to clear credentials normally. Player
exemptions and navigation retention are described in `FeatureProfiles/README.md`.
Disabling automatic sign-in removes the stored session without changing any PIN;
sign-out invalidates it.
Every unresolved Plex binding verifies current Home-user protection before entry,
even if its last saved status said no PIN. Removing and later re-adding a Plex PIN
must therefore prompt on the next manual switch. Old unprotected token-cache
entries are purged, not replayed. Until authorization completes, neither server
nor Discover access may substitute the owner's credentials. Only an already
authorized in-memory identity may repair a missing Discover credential; that
repair cannot authorize a new profile activation.

Before clearing a protected Plex Home binding's PIN requirement, Plozz requires
current Home-user metadata explicitly reporting no PIN and a successful PIN-less
switch for the same profile, user and account credential. A successful switch
using the owner's credential alone is not proof of PIN removal or PIN knowledge.
Legacy bindings without a verified protection marker cannot restore unprotected
cached tokens or automatic-sign-in sessions until they are revalidated.
Verification is not PIN entry: both shells show a neutral loading state while
checking and a retryable error when protection cannot be determined. The
Plex PIN heading and keypad are instantiated only after Plex explicitly confirms
that the selected Home user is protected. A local Plozz PIN already entered
remains visible and disabled during chained verification, rather than disappearing
while its matching PIN authenticates with Plex. An unprotected Plex-only user
never passes through a PIN screen, including while its authorization cover dismisses.
Plex's account-password flag (`hasPassword`) is not Home PIN protection; only
the explicit `protected` field establishes that requirement.
Plex rejecting a PIN-less switch leaves a retryable authentication error, not a
PIN prompt for an unprotected user. A supplied PIN goes directly to the switch endpoint;
stale, missing or unavailable Home-user metadata cannot block authentication or
discard the entered PIN. A rejected entered PIN also permits one authenticated
PIN-less attempt only after metadata confirms the Plex PIN was removed, including when a separate
Plozz lock supplied its former matching PIN. Network errors and rejected switches
never unlock the profile. Cancellation and superseded profile/account/lock state invalidate the
attempt. A successful switch cannot dismiss another account's PIN prompt,
and cancelling retains the gate unless an authorized fallback profile activates.
That activation gate is distinct from editing an existing profile's Plex user.
A requested "watching as" change remains an in-memory proposal: the saved
binding, current server/Discover credentials, and other accounts stay unchanged
through verification, wrong PINs, and connection errors. Successful authentication
publishes the new binding and credentials together; Cancel discards the proposal.
Stale completions after another selection, profile/lock change, credential
replacement, or account removal cannot commit it. Account owners use the same
verification path as other Home users, not an unauthenticated clear-binding row.
The shared keypad cancels its final-digit display delay before cancellation or
disappearance, so an abandoned entry cannot submit afterward. Mobile PIN sheets
also block interactive dismissal while the gate remains unresolved.
This does not create, remove or change a separate Plozz Profile Lock, even when
the person chose the same digits for both locks.

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
