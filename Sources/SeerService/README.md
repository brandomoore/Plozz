# Seerr connections

`SeerService` owns the active profile's saved connections, selected browsing
server, request destination, and credential lifecycle. Both app shells use the
same `SeerConnectionsView` and authentication implementation.

## Sign-in

- Existing authorized Jellyfin accounts can approve Seerr Quick Connect.
  Existing authorized Plex identities can exchange their Plex account token.
  Seerr 3.5.2 rejects Plex managed Home users without an email address; these
  identities must use another supported sign-in method. Never substitute the
  household owner's token to get around that server limitation.
  `AppRuntime.SeerProfileAuthentication` checks profile membership, credential
  revision, and the returned media-user identity.
  Jellyfin requests use the current `Authorization` header, including discovery
  and Quick Connect approval. If an older Seerr lacks Quick Connect, setup asks
  for the selected Jellyfin user's password instead of repeating a broken login.
- Manual Plex linking, Jellyfin/Emby username and password, and local Seerr
  email and password are offered according to the server's public capabilities.
  Media-server password fields allow an empty value for passwordless accounts;
  the server still validates the submitted credentials.
  Silo and other providers can use a supported Seerr login or an API key.
- `SeerSetupDiscovery`, owned by `SeerService`, prepares public server capabilities
  during the preceding first-run/new-profile onboarding steps on both platforms.
  The flow-level `prepareSeerrSetup` adapter observes approved account routes and
  profile identity, not a particular page transition. A five-minute in-memory
  successful result is reused on Seerr page entry; failed/empty preparation is
  retried, and explicit rescanning bypasses the cache. Reordering unchanged
  approved routes does not restart preparation.
  Known routes and the compatible Jellyfin plugin are checked concurrently.
  The first compatible ready response is usable immediately and cancels remaining
  discovery. A slow plugin or unfinished subnet scan does not block Continue.
  If no suitable known endpoint responds, discovery uses a bounded local sweep.
  Plugin lookups import only the URL, never an administrator key.
  Checks retain HTTPS, custom ports and base paths on known URLs, also trying
  their origin (including the standard web port) and the conventional `/seerr`,
  `/jellyseerr` and `/overseerr` paths.
  The conventional co-hosted port is 5055; local hosts can use HTTP on that
  separate endpoint, while public HTTPS hosts keep HTTPS. No arbitrary remote
  port scan or sibling-domain guessing occurs. Unknown custom addresses still
  need manual entry or a plugin-supplied URL. Discovery sends no media credentials
  to candidate servers, does not follow cross-origin redirects, and does not
  downgrade an HTTPS request. Only the existing Jellyfin plugin lookup uses
  that account's credentials against its own authorized media-server origin.
  Status and capabilities are checked within each concurrent probe. Discovery
  requests have a three-second resource budget, separate from interactive login.
  Jellyfin setup also checks the read-only Quick Connect status route without a
  secret. Its validation response confirms support without creating a login
  challenge or contacting Jellyfin; a missing route identifies password-only
  setup. This is shared by discovered, remembered, plugin-provided and manually
  entered addresses, including servers with backported support. Other HTTP or
  transport failures remain errors, not an inferred older-server capability.
  The shared `ServerDiscoveryRow` and bundled Seerr logo present the detected
  server in both suggested and manual setup, without a navigation chevron.
  Discovery labels use **Detected server** for one displayed result and
  **Detected servers** for several. Restored address summaries remain **Server**;
  an empty search remains **Servers**. Editable fields use **Seerr server address**.
  Scan progress uses the standard section-header indicator, not a second
  account panel or button spinner. The stable setup offers
  **Continue as [name]** for one matching profile account, and otherwise names
  the supported sign-in method. **Set up manually** and **Not now** remain available.
  Background discovery never opens forms. Manual scans retain all discovered
  choices; multiple matching accounts still require an explicit account action.
  Late results cannot replace user input or cross profile/account-route scopes.
  Leaving onboarding cancels unfinished work; cached data never grants sign-in.
  Generated local probes normalize Plex's IPv4 certificate hostname to its
  embedded address before deduplicating against the subnet sweep, so that one
  host appears once. Other hostnames and configured server URLs are unchanged.
  Discovery uses the shared named server row, with its address as secondary
  text and scan status in the section header. Manual address entry is separate.
  Selecting Seerr updates the current form, so its rows have no navigation
  chevron. An unfinished setup remembers its selected address per profile on
  this device and rechecks that server on relaunch instead of rediscovering a
  different one. This draft contains no sign-in session, does not configure
  requests, is excluded from pairing transfers, and clears after connection.
  Authorized Plex account choices refresh when the profile's resolved identity
  changes; pending authorization never substitutes the owner's credential.
  Continuing with a named, authorized Plex/Jellyfin account verifies that
  identity and saves it without a second confirmation. Emby has no equivalent
  session exchange: a single profile-scoped Emby username can be suggested,
  but Continue opens an editable Emby username/password form. Local Seerr
  credentials are separate and never inherit the Emby username.
  Explicit Plex browser sign-in opens directly on iPhone/iPad, with a button to
  reopen it if needed. Only Apple TV shows a QR code and asks the user to scan
  with another device.
- When account reuse is supported, sign-in offers **Continue as [name]** for one authorized media account or
  **Choose existing account** for several, never an arbitrary first account.
  The native chooser shows usernames with their media-server names and addresses
  and resolves the selected ID against the current profile's available accounts.
  Media sign-in buttons use the shared provider logo before their action label,
  without a second line or standalone heading beside the Seerr address.
  The provider name remains available to VoiceOver.
  Local-account and API-key actions do not carry media-provider branding. Jellyfin's secondary
  action is **Enter username and password**; Plex retains its separate browser flow.
  Older Seerr instances without Jellyfin Quick Connect instead offer **Sign in
  with Jellyfin** and explain that a password is needed until Seerr is updated.
  A single authorized Jellyfin username is still prefilled in the password form;
  multiple accounts never select an arbitrary username. A missing Quick Connect
  route during explicit account reuse also switches to this explained password
  flow. Released Seerr versions before 3.4.0 do not support that exchange.
  Supported alternatives, including API-key entry, appear directly as full-width
  secondary buttons rather than in a menu. Password forms name the account type.
  On iPhone/iPad, credential rows use the shared sign-in field style: native
  placeholders, persistent accessible names, and no duplicate small top labels.
  The server address remains a native editable URL field, without a Change button.
  Editing cancels discovery and discards old capabilities, credentials and account
  choices. It never probes or authenticates until an explicit submit; password
  sign-in returns to checking the new server, while API-key entry clears its key.
  Finding a server never authenticates or saves an account. Manual sign-ins
  show the authenticated identity for confirmation before saving.
- First-run and new-profile setup use a focused, optional onboarding page, not
  the saved-account Settings page. Saving the confirmed account advances setup;
  existing connections keep their request identity and show a simple Continue.
  Account lists and request-choice preferences remain in Settings.
- Every login uses isolated cookies, same-origin redirects, and an authenticated
  `/auth/me` check. Passwords are discarded. Sessions are stored in the device's
  secure store; expiration requires sign-in, never fallback to an administrator key.
  Uninitialized servers must be configured in Seerr itself.

## Defaults and authorization

The secure ledger is keyed by Plozz profile ID. Legacy API-key settings migrate
once for profiles that already exist, preserving their server-bound request user.
Later profiles do not inherit the household key. An unverified old user mapping
remains blocked until explicitly relinked, including after replacing its API key.

Only explicitly saved connections are choices, not users returned by Seerr's
directory. One connection requests directly unless **Ask each time** is enabled.
Multiple connections show a native destination choice, with the selected account
first. **Use last account** remembers only a successful request. Removing a
connection repairs the default; a network/authentication failure never selects
another destination.

Ordinary sessions always act as their authenticated user. Only explicitly
authorized API-key connections expose **Request as**. Kids restrictions and
live identity are rechecked before a request is sent. Profile or credential
changes invalidate pending authentication, selection, and request results.
Results from another destination must not become availability overrides for
the server currently being browsed.

## Device transfer

The additive `SyncSecretsBundle.seerrProfiles` field transfers profile-bound
API-key connections through the existing approved secret-transfer paths.
Imports are restricted to incoming/known profiles and never overwrite a locally
configured profile, including an intentional disconnect. Cookie sessions are
not transferred; sign in separately on another device. Legacy payloads can still
be imported. Older peers cannot read the new profile-bound field and require
manual Seerr setup; exporting a household-wide key would expand authorization.

Core regressions live in `Tests/SeerServiceTests/SeerAccountConnectionsTests.swift`;
mobile layout and presentation coverage lives in
`Tests/iOSPresentationTests/ProfileSeerrSetupPresentationTests.swift`.
