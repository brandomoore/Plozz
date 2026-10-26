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

The provider-neutral implementation now lives in `CoreTrackerAuth`; Trakt's
public names remain compatibility aliases. WeTrakr reuses that implementation
with separate token accounts and cloud-record prefixes, never Trakt credentials.

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

Playback reporting remains outbound; server resume state remains server-owned.
Settings also offers an explicit, one-time history comparison on TV and mobile.
It reads every page of `/users/me/history` and `/sync/playback`, requiring stable
pagination totals, exact page sizes and unique record IDs. The relevant
`/sync/last_activities` timestamps must remain unchanged across the read. Missing,
capped, malformed or changing results fail the comparison instead of becoming a
partial import. Reads reuse coordinated OAuth refresh and retain profile/grant
fences before and after each request.

The shared importer previews exact server users and requires selected-row
confirmation before writing through the existing watch outbox. It rechecks server
state and authorization, excludes current playback, and never enables ongoing
sync or creates a new tracker scrobble. Rewatches collapse to a watched-state
change; individual play dates/counts are not written to media servers.
Episode imports require matching episode and parent IDs in the same namespace,
with the episode ID distinct from the parent's and a single matching episode
coordinate. Trakt coordinates alone do not establish a server's episode order.
Unconfirmed identities remain unmatched. Trakt percentages remain visible,
non-importable observations: catalog runtimes do not establish the played file's
runtime, and neither 0% nor 100% implies an explicit clear or completed watch.

The separate **Ongoing sync** enrollment can authorize new watched-state imports
for selected server users; it does not backfill the reviewed history. Its
connection identity survives coordinated refresh/relaunch and changes on each
new sign-in, including identical returned tokens. Disconnect revokes device-local
permission before coordinated credential removal. Percentage-only resume remains
unavailable. See the [shared consent lifecycle](../FeatureSettings/README.md).

API shape references: Trakt's
[history client](https://github.com/trakt/trakt-rippple/blob/282a49fa049bcf325e126b4932e6c8d91d580860/Rippple/Trakt%20API/TraktAPIService.swift)
and [sync contracts](https://github.com/trakt/trakt-api/blob/dab7797de4e30bdd3fa0f98c0f8b5d8509845991/projects/api/src/contracts/sync/index.ts).
Playback pagination is explicitly requested; a headerless response is not a
complete snapshot. These contracts and fixture checks are not authenticated
round-trip acceptance evidence.

## Guarded historical export

**Export server history** uses the shared read-only preview, explicit server-user/
library selection and separate confirmation on TV, iPhone and iPad. It exports
only watched movies and individually identified episodes with a known server watch
date. Unknown dates remain unsupported until their readback semantics are verified;
an existing watch with an unavailable date still prevents duplicate export, but
cannot verify a dated write. No current-time substitute, repeat-play count,
scrobble backfill, show/season expansion, rating change or server write is made.

Public external-ID lookup and fresh canonical detail must agree with the source.
Episodes also require corroborated parent IDs and exact season/episode coordinates.
The immutable authenticated `user.ids.uuid`, native media ID and kind form the
receipt target; titles and mutable source metadata do not. Complete history,
watchlists, paused playback and current watching protect existing state.
Movie, show, season and episode watchlist entries are all protected; a planned
season protects only episodes in that season, not unrelated seasons.
Activity checks include `watchlist.updated_at` so removals invalidate cached
protection. Missing pagination, changing owners/activity and malformed evidence
fail closed.

An export-only serial gate leaves at least 1.01 seconds after each operation
before admitting the next. Full source/tracker authorization runs after that wait,
then coordinated access-token retrieval and the profile/grant guard run immediately
before dispatch. Reads do not enter this writer gate. A 429 stops delivery without
automatic retry; its bounded cooldown survives relaunch. This does not claim to
coordinate other applications or every existing realtime request.

Each `/sync/history` request contains exactly one native movie or episode and an
explicit UTC `watched_at`. The current OpenAPI acknowledgement requires HTTP 200,
with redirects left unfollowed to prevent automatic resubmission,
exactly one addition, zero updates and empty not-found buckets. Independent
item-history readback must confirm the same native identity and date. Known
non-delivery clears only the current attempt's receipt; ambiguous transport,
cancellation after dispatch or malformed acknowledgements retain the replay
fence. Presence after an uncertain reply does not establish authorship. Trakt
does not deduplicate item/date submissions, and local receipts are not remote
idempotency or distributed atomicity.

Contract: [Trakt API](https://trakt.docs.apiary.io/), external-ID lookup,
user settings/watching, activity and history endpoints. Synthetic service and
native fixtures do not replace authenticated account round-trip acceptance.

External-player callbacks use the same durable watch outbox as in-app playback.
Returning before completion sends `/scrobble/pause` with the reported percentage
for Trakt's paused playback data, as well as saving server resume state. This is
not a guarantee of an entry in Trakt's own Continue Watching UI: its
[documented presentation](https://forums.trakt.tv/t/new-trakt-feature-spotlight-continue-watching-start-watching/89875)
distinguishes next-episode suggestions for shows from paused movies.
Partial progress is separate from completed-watch mirrors: it does not
mark watched on Trakt or other trackers, and later returns update it even on the
same day. Completion still sends `/scrobble/stop` at 100%. No progress is inferred
without a supported callback, and already-consumed returns are not backfilled.
A connected movie/episode with insufficient identifiers is not
considered delivered: the outbox reloads the original server item (and its series
for episodes) under the same profile/server-user authorization before retrying.
It never guesses a title match. Still-unidentifiable watches remain pending,
with a safe diagnostic, without undoing successful server watched-state writes.
Disconnected integrations and unsupported container kinds remain no-ops.

With playback diagnostics enabled, `TRAKT_SCROBBLE` records the requested and
returned action, percentage, catalog IDs, and episode coordinates in `PlozzLog`
and the bounded playback journal included by Send to Developer. It excludes
titles, account identities, credentials, and raw response bodies; IMDb values
must match the catalog ID format. An unreadable acknowledgement is explicitly
logged but does not change delivery or retry an accepted write. These
diagnostics record Trakt's response, not an independent playback-data readback
or proof of its mobile UI state.

## Where to look first

- `TraktService.swift` — the public façade `AppShell` consumes.
- `TraktAuthService.swift` — sign-in / refresh flow.
- `TraktScrobbler.swift` — playback → Trakt event mapping.
