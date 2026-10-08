# TraktService

Optional Trakt.tv integration: OAuth sign-in, scrobble (start / pause /
stop) while playing, and watched-state sync helpers. Disabled until the
user signs in.

## Responsibility

- `TraktConfig` — public client ID, HTTPS redirect and separate auth/API hosts for the
  Trakt app registration.
- `TraktClient` — low-level wrapper around the shared
  `CoreNetworking.HTTPClient` that centralises Trakt's required headers
  (`trakt-api-version`, `trakt-api-key`, bearer `Authorization`).
- `TraktAuthService` — device-code OAuth on TV, authorization-code exchange with
  S256 PKCE on mobile, and refresh-token rotation.
- `TraktTokenCoordinator` — shares single-use refreshes across Settings,
  watchlists, playback and outbox adapters; disconnect invalidates pending writes.
- `TraktTokenStore` — Keychain-backed persistence for access/refresh
  tokens. Per-profile namespaced from `AppShell` so each household profile
  has its own Trakt identity.
- `TraktScrobbler` — translates `FeaturePlayback` progress events into
  Trakt scrobble start/pause/stop calls, with thresholds, debouncing, and
  graceful no-op when disabled.
- `TraktModels` — Trakt API DTOs / response shapes, mapped onto domain
  types at the seam.

## Invariants

- **No UI imports.** PKCE uses Apple's CryptoKit.
- **Tokens stay in Keychain.** Never logged, never written to plists.
  `HTTPClient` redacts the bearer `Authorization` header.
- **Playback is not interrupted.** Realtime failures are logged; durable
  scrobbles throw so the outbox retains retryable work. Settings surfaces
  authentication and persistence failures rather than claiming a connection.
- **Pluggable / optional.** When the user isn't signed in to Trakt, the
  service short-circuits to no-ops — features must remain functional
  without it.

## Registration and sign-in

Create the registration at <https://developer.trakt.tv/apps>. Set the redirect
to `https://plozz.app/auth/trakt/callback` exactly and leave allowed origins
empty. Supply only `TRAKT_CLIENT_ID` in the ignored local xcconfig. Native apps
must neither require nor ship a client secret.

Canonical iPhone/iPad builds use `ASWebAuthenticationSession` with its verified
HTTPS callback and a fresh random verifier/state per attempt. Only the matching
callback/state can redeem the code, once. The app's `webcredentials:plozz.app`
entitlement and the AASA in `web/pairing-links` must be deployed together.
Branded builds without that domain association retain device-code sign-in.
Apple TV also retains device codes, respecting expiry, terminal rejections and
`Retry-After`.

OAuth calls use `auth.trakt.tv`; media/watchlist calls use `api.trakt.tv`.
Refresh sends the same registered redirect and persists both replacement tokens
before use. A failed Keychain write retains the rotated grant in memory for a
later persistence retry. An invalid grant requires reconnecting; older grants
from before Trakt's authentication migration may no longer refresh.

## Shared profile authorization

One sign-in per Plozz profile is shared across Apple TV, iPhone and iPad through
the existing private encrypted CloudKit tracker channel. Access and refresh
tokens remain in Keychain locally. A server-acknowledged conditional CloudKit
write claims each single-use refresh before contacting Trakt; other devices
read the resulting grant rather than exchanging the old token again.
Devices can use the same access token simultaneously. Its seven-day expiry
triggers automatic renewal, not another sign-in.

The device-local Keychain journal records the exchange boundary and successor
before publication. Cloud outages and failed persistence retain recoverable
work. Retry resumes synchronization, not a new OAuth sign-in. Sign-out is a
durable tombstone; reconnect starts a new epoch. Conditional writes, profile and
iCloud-account checks fence stale responses. These records reuse the deployed
encrypted tracker schema but are excluded from ordinary last-writer-wins sync.
Capture the authoritative connection baseline before starting either OAuth flow
and retain that context through publication; a delayed authorization must not
overwrite a later sign-out. Synchronization and refresh share one per-scope
in-flight owner so an older cloud read cannot erase an unpublished successor.
Install the coordinator before constructing Trakt services on both platforms,
even when ordinary configuration sync is disabled.

CloudKit availability does not depend on an App Store receipt. TestFlight's
iPhone/iPad sandbox installs can have no receipt before an in-app purchase,
which this free integration never requires. An embedded provisioning profile
remains authoritative; a missing or unreadable entitlement fails closed.
When Apple removes that profile for distribution, only the canonical app and
container on a physical device use the profileless fallback. Test hosts,
profileless simulators, and unentitled branded builds cannot construct CloudKit.
See Apple's [receipt availability documentation](https://developer.apple.com/documentation/foundation/bundle/appstorereceipturl).

The private tracker record type (`PlozzTrackerTokensV1Record`) and its encrypted
`value` field must be deployed to the container's **Production** schema before
TestFlight/App Store builds can use this channel. A Development schema alone is
not sufficient. Publishing the schema does not copy or reset users' records.
An enabled iCloud switch is not evidence that a cloud write succeeded: ordinary
sync retains individual zone/record failures until the affected operation
recovers, and incomplete zone fetches cannot finalize a full reload.

Connection errors do not claim credentials were saved before OAuth has run.
CloudKit rejections expose their numeric error code; transport diagnostics log
only the operation, error domain and code, never record names, account IDs,
payloads or unrestricted CloudKit error descriptions. Retry still resumes the
retained journal without another authorization or an uncoordinated refresh.

There is no expiring lock that can replay an already-consumed token. If a
response is irretrievably lost after Trakt consumes the grant, recovery requires
reconnecting the profile once; the replacement is then shared with all devices.
Both the renewing device and followers expose a confirmed shared reconnect.
Confirmed-undelivered requests can retry the existing claim; throttled attempts
retain their Retry-After deadline across relaunch.
Provider-supported idempotency would be needed to eliminate that failure window.
Older app versions must be upgraded to honor coordination.

History sync is outbound; server resume state remains server-owned.

## Where to look first

- `TraktService.swift` — the public façade `AppShell` consumes.
- `TraktAuthService.swift` — sign-in / refresh flow.
- `TraktScrobbler.swift` — playback → Trakt event mapping.
