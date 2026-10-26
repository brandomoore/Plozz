# WeTrakr

Optional, profile-scoped movie/episode scrobbling and bidirectional planning-list
sync. All media backends use the same tracker boundary. Live channels and media
without an identifiable movie or episode are not scrobbled.

## Release availability

Both platforms use `RuntimeFeatureFlags.buildDefault` for tracker setup,
watchlist links, runtime integration, and resolved configuration. Debug and
Release builds, including TestFlight and App Store archives, use the same
`RuntimeFeatureFlags.productionDefault`, with WeTrakr enabled. A configured
client ID and the viewer's connected account are still required for tracking.

An explicit feature-flag override can disable the integration without erasing
saved connections. Disabled configuration prevents status, watchlist and playback
requests even when a client ID and saved connection exist.

## Registration

Set `WETRAKR_CLIENT_ID` in the ignored `Config/Secrets.local.xcconfig`.
Only the public client ID is needed; do not ship a client secret. The registered
redirect is `https://plozz.app/auth/wetrakr/callback`.

Apple TV uses device authorization. Canonical iPhone/iPad builds use S256 PKCE
with `ASWebAuthenticationSession` and the existing `webcredentials:plozz.app`
association. Branded builds without the association use device authorization.
The callback fallback is maintained in `web/pairing-links`.

## Authorization and privacy

`CoreTrackerAuth` owns Keychain persistence, single-flight token refresh and
the encrypted CloudKit conditional-write protocol shared with Trakt. WeTrakr
uses a separate `wetrakr.oauth` account and coordinated cloud-record prefix;
existing Trakt storage names remain unchanged. Refresh-token rotation preserves
the connection identity. A new sign-in creates a new grant identity.

Credentials and API response bodies are never logged. Only the username needed
by Settings is decoded from account information. Requests carrying credentials
cannot redirect to another origin. Disconnect writes the coordinated tombstone,
discards local watchlist caches, and attempts remote session revocation. A failed
revocation is reported explicitly.
An HTTP 403 is reported as a blocked request, not an expired user sign-in or
proof that the client ID is invalid; the API's edge protection can reject a
request before it reaches authorization.
Browser failures, rejected callback addresses/state/codes, and failed token
exchanges have distinct Settings errors. Diagnostics contain only fixed failure
categories and numeric browser/HTTP error codes, never callback URLs, OAuth
codes, state values, credentials, or response bodies. Callback validation still
fails closed; these diagnostics do not bypass a failed sign-in.
Google sign-in can append a bare `#` to the callback. This empty fragment is
accepted without relaxing callback-address, state, or authorization-code checks.

## Playback and watchlists

- Start/resume/pause/stop events use the realtime API; progress ticks do not.
  The completion threshold is 90 percent. Realtime failures never stop playback.
- Durable completed watches retain the original capture time, connection
  identity and stable retry key. A later sign-in cannot receive an earlier
  connection's queued watch. Normal rewatches use `allow_rewatch: true`; known
  server duplicate responses are accepted, other per-item failures are not.
  Completion checkpoints and the final stop share one key within the existing
  live playback session. Successful delivery is persisted in the outbox ledger;
  later viewing sessions use new keys, including rewatches on the same day.
- Episode scrobbles use explicit series catalog IDs and episode coordinates,
  including season zero. Completed-watch writes can also use episode catalog
  IDs directly. Provider-local identifiers are never sent as WeTrakr IDs.
- WeTrakr's `planning` list participates in Plozz's universal watchlist. Reads
  have a minute-long memory cache, then check activities and consume the
  incremental journal. The visible journal watermark, overlap and event IDs
  prevent recent events from being lost. Expired journals require a full resync.
  Pagination must finish before a replacement list is published.
  Successful planning writes still invalidate the baseline: a lagging journal
  must not make a just-added title look like a confirmed native removal.
- The universal-watchlist runtime persists the last complete, identity-scoped
  view. Journal cursors remain in memory; a new process establishes a new full
  baseline. Imported entries are evidence, not permanent Plozz watchlist intent.
- Native entries retain canonical WeTrakr links through deduplication and
  library resolution. Detail pages expose the link directly (QR on Apple TV);
  mobile poster menus also offer it. Disconnect retracts native attribution.
- Native WeTrakr IDs provide stable, media-kind-scoped watchlist identity even
  without external catalog IDs. These entries remain removable; other trackers
  receive only catalog IDs they support, never WeTrakr IDs.

API contract: <https://api.wetrakr.com/>.

## Reviewed server-history comparison

The connected account page on both platforms offers **Compare with server
history**. Connecting or opening Settings does not import anything. The shared
review session owns exact server-user selection, explicit per-title approval,
fresh-state checks and the existing watch-mutation outbox.

The read-only adapter walks compact movie and episode play-history and playing
lists with opaque `X-Pagination-Next` cursors, never page numbers. Each list must
exhaust its cursor and match a stable `X-Pagination-Item-Count`; missing totals,
repeated records/cursors, changed activity or incomplete pages reject the whole
comparison. Reads are bounded to 5,000 rows and 8 MiB per response, 100 requests
and 100,000 records per list. All requests use the existing quota gate and check
the captured profile/grant before dispatch and after response. Token refresh
uses the shared coordinator, not a separate credential path.

An in-memory watched baseline is reused only for the same connection and an
unchanged activity stamp. Current playing lists are always refreshed. Changed
activity requires another complete compact walk; this is an explicit comparison,
not a polling task or permission for ongoing sync.

Individual play IDs preserve rewatches; `watched_at_unknown` remains an unknown
date rather than importing its placeholder. Episodes require their own and their
parent's matching catalog IDs plus exact coordinates; missing parent IDs never
become an inferred episode match. Paused progress with a supplied runtime uses
the documented percentage/runtime conversion, and the shared importer requires
the server runtime to match within one second. Active playback, missing runtimes
and zero/100-percent boundaries remain informational percentages, never clears
or completion events. A deleted or missing play does not unwatch server media.

After comparison, a separate **Ongoing sync** enrollment can authorize new watched
state and compatible paused progress for selected server users. It uses the same
reader, refresh-stable grant identity, guarded outbox and independent readback;
it never backfills the baseline or silently resolves a conflicting server resume.
Disconnect revokes local history permission before coordinated credential removal.
See the [shared consent lifecycle](../FeatureSettings/README.md).

## Request budget and diagnostics

Account-status reads are single-flight and cache a successful result for five
minutes. Reapplying the same profile does not cancel authorization or clear the
planning cache. Profile switches, disconnects, new grants and token rotation
remain separate scopes; refreshed credentials notify the runtime so blocked
authentication work can resume. An unchanged successful status does not trigger
another connection-change refresh.

The shared request gate serializes dispatches and persists cooldown deadlines
locally. Daily quota responses use `X-Quota-Reset` as seconds until reset, falling
back to the next midnight UTC using the response's server date. App-wide limits
block every credential of that app; credential limits do not block another
credential. A successful response with zero daily allowance also stops subsequent
requests. Per-minute/concurrency responses use `Retry-After` or `RateLimit-Reset`.
The gate never waits and retries a request automatically.

Secret-safe diagnostic counters distinguish status, authorization, realtime
events, history writes, planning writes, activity checks and journal/full reads.
They count transport dispatch attempts, not local cooldown rejections. Counts
are cumulative within a randomly identified process/gate lifetime and accompany
numeric HTTP outcomes in `PlozzLog` and the existing bounded development playback
journal. No credentials, credential fingerprints, media IDs, titles, request
bodies or arbitrary paths enter these diagnostic lines. These counters are for
attributing a future controlled run; they cannot reconstruct past API usage.

### Watchlist writes

The shared reconciler groups up to 50 pending WeTrakr changes with the same
profile, account scope and desired state into one request. Movies and shows may
share a batch; adds and removals use separate endpoints. Other destinations keep
their existing single-item transport unless they explicitly support batching.
The 50-title limit is a conservative client bound, not a documented server limit.

Before writing, WeTrakr checks its complete planning snapshot and skips titles
already in the requested state. A cold snapshot still needs activity and
paginated list reads; an unchanged list needs no writes. Complete same-identity
native observations also settle matching durable mutations without writing,
unless a newer intent superseded the read.
Missing or ambiguous remote identifiers cannot prove absence; those removals
still go to the service for resolution.

Each durable mutation has a persisted delivery identity. The batch retry key
includes those identities and the exact submitted body. An unchanged retry reuses
the key and deterministic body bytes; a changed intent or payload cannot reuse
the old response.
Every submitted title needs positive evidence: exact per-kind planning counts
for successes, and unambiguous identifiers for individual failures. Unresolved
titles wait for new identity evidence; rejected titles remain failed. Malformed
or ambiguous replies never acknowledge a whole batch.

The corrected writer uses write-policy version 1. When current watchlist intent
re-offers a mutation left permanently failed by an older policy, the queue grants
one recovery attempt through the normal bounded batch path. The policy marker
and new delivery identity are saved atomically before dispatch. Repeated refreshes
and process restarts cannot reopen a failure from the same policy; existing
cooldowns, attempt counts and other destinations remain untouched. This recovers
legacy queue state, but does not turn an unresolved or rejected title into a
successful sync without fresh evidence from WeTrakr.

Any attempted write invalidates the planning cache, including a lost response.
The next pass re-establishes the full baseline rather than trusting a lagging
journal. Aggregate batch diagnostics report unchanged, confirmed, unresolved
and failed counts without title IDs or request bodies. Destination cooldowns
also control the next scheduler wake, including queued work not yet attempted.
