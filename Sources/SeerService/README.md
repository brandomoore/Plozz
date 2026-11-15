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
- Setup automatically checks a compatible Jellyfin plugin for an address, then
  runs bounded local discovery if none is supplied. Its administrator key is never
  imported. A single result fills the address; multiple results remain explicit
  choices. Late discovery never replaces user input or crosses profiles.
  Generated local probes normalize Plex's IPv4 certificate hostname to its
  embedded address before deduplicating against the subnet sweep, so that one
  host appears once. Other hostnames and configured server URLs are unchanged.
  Discovery uses the shared named server row, with its address as secondary
  text and scan status in the section header. Manual address entry is separate.
- Sign-in has one primary action, favoring the profile's authorized media account.
  **Sign in as [name]** reuses that identity; **Use another Jellyfin/Plex account**
  starts a separate sign-in rather than competing with the saved-account action.
  Supported alternatives, including API-key entry, appear directly as full-width
  secondary buttons rather than in a menu. Password forms name the account type.
  Finding a server never authenticates or saves an account. The authenticated
  identity is shown for confirmation before saving.
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
