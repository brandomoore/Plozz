# Native Silo provider

Plozz connects to Silo's native `/api/v2` API, not its separate Jellyfin
compatibility listener. Enter the web application's base URL, approve the
device code in Silo, then select the household profile. PIN-protected profiles
require server verification. Each connection retains that server profile's
library restrictions and watch history; Plozz profiles choose which connections
they use.

Nearby-server search probes Silo's standard HTTP port 8090 on directly connected
private IPv4 LANs. It validates the native v2 system identity and pairing
capability before displaying a result. The scan is bounded and stops when the
picker closes; it never signs in automatically. Saved servers remain one-tap
choices. Custom ports, remote/Tailscale addresses, IPv6-only hosts and reverse
proxy paths remain available through manual URL entry.
Discovery URL identities and authenticated installation IDs collapse into one
picker row when their provider, origin, and base path match, including root URLs
with or without a trailing slash. Different ports, schemes, and proxy paths stay
separate. New sign-ins preserve the selected server name rather than replacing
it with an IP address; existing account records are not migrated by discovery.

Silo uses the shared server picker, authentication handoff and library/profile
setup, not a separate onboarding flow. Pairing shows the selected server, a
phone-scannable code on TV and an "Open Silo to approve" action on iPhone/iPad.
Approval continues automatically to the profile picker. PIN entry can return to
that picker without repeating approval; retrying a failed profile lookup reuses
the approved login while it remains valid. Expired codes have an explicit renewal
action. Leaving the flow cancels pending work and clears in-memory PINs/tokens.
TV approval follows the shared Plex-style QR/manual-code layout with one expiry
ring and the same sign-in code shown by current Silo versions. Profile selection uses the same avatar-row
component and scroll card as Plex server-user selection, including focus-aware
PIN indicators. These are Silo server profiles, not new Plozz household profiles.
On mobile, browser approval stays primary and manual/QR alternatives share one
disclosure instead of repeating the same instructions.

If Silo advertises a configured public alias, Plozz keeps approval on the selected
server's documented `/activate` page, including its reverse-proxy base path.
It builds the link from the public user code, never forwards a foreign query or
follows an authentication redirect. Inconsistent/unrecognized approval links are
rejected with an address-specific message. Pending polls honor Silo's extended
expiry; canceled/consumed requests offer a fresh code. A failed start can be
retried in place, while a failed profile lookup retains successful approval.

Connection failures during polling retain the same code and approval link.
Scheduled polling backs off after a transport failure, never below the server's
interval, with at most three consecutive failed polls and no work past the
current deadline or cancellation. A successful pending response resets the
failure count. Authentication, malformed responses, rate limits and terminal
statuses are not retried. Device-start and other credential exchanges are never
automatically replayed.

The server consumes approval while minting its login session. If an approved
response is lost after that commit, a subsequent `consumed` response still
requires a fresh code; the client cannot recover tokens it never received.
Recovered transport interruptions are logged locally; only the terminal failure
enters the existing consent-gated setup diagnostic path.

Setup errors identify validation, code creation, polling, profile loading, PIN
verification, or session completion. With crash-reporting consent, at most ten
distinct failures per reporter lifetime are sent using fixed stage/reason/response
categories and an HTTP status only. No server address, response body, profile
identity, PIN, pairing code, token, or error description is included. Opt-out
invalidates retained attempts, including across later opt-in.

## Alternate connection addresses

Settings can approve another address through native device pairing, matching the
authenticated installation/account/profile before saving the alias. Only the
temporary verification login is revoked; the original rotating credential and
account identity stay intact. This does not depend on newer Silo pinned-LAN
discovery, and does not infer trust from a self-asserted public server ID.

API requests choose among explicitly approved routes with credential-free v2
reachability probes. A refresh whose route selection fails before transmission
retains its original token; an ambiguous transmitted refresh is never replayed.
Relative resource URLs use the selected API base. Server-issued signed media
URLs remain byte-for-byte on their issued origin, with the bearer added only for
approved server/session URLs. Foreign media nodes do not receive that bearer.
If Silo issues a public absolute media URL, selecting a local API address does
not silently rewrite it or move an already-playing stream.
Address-only edits preserve the existing provider's login-revision-bound playback
and subtitle grants while updating its API routes. They do not invalidate other
accounts' providers; a new credential revision still receives a new session store.

## Server Home

Match Server imports Silo's profile-scoped native Home row IDs, headings, order
and contents, including custom rows. The lightweight `/home/layout` endpoint
falls back to `/home/sections` only when unavailable; actual authentication,
network and malformed-response failures remain failures. A row refresh shares
one fresh sections response instead of caching content across watch changes.
Single-row requests use `/home/sections/{id}/items` with the same older-server
fallback. Servers lacking both Home endpoints retain ordinary provider defaults.

Only video cards are displayed. Disabled Plozz libraries require exact membership
in an enabled library; title matches alone never establish membership. Continue
Watching and Next Up resolve the server-selected playable episode and retain
resume state and verified parent artwork. Shared Home composition still owns
multi-server merging and explicit Plozz profile customizations.
These Home and device-login contracts were checked at upstream revision
`6144c45cd65ae0f49f9f3397bbc20f7e4d60a20e`.

## Contracts

- Native device-pairing protocol 2 and playback protocol 3. Check capability
  documents rather than guessing from a server version or its emulated Jellyfin
  identity. Silo is pre-release; contracts were checked against server revision
  `cbc13de10f4af28762be6777cab2f75403eade58`.
- Access tokens, rotating refresh tokens and profile-verification proofs live in
  the account Keychain entry. The raw PIN is never persisted. Refresh is
  single-flight and compare-and-set against the original login revision.
  An uncertain refresh requires sign-in rather than replaying a possibly spent
  token. A refresh proven by transport metrics not to have been transmitted
  restores the original credential for a later retry after an outage; missing
  evidence is never treated as proof. Library errors retain their real cause,
  so expired authentication offers sign-in rather than an endless offline retry.
  Silo logins are not cloned through device-to-device credential transfer
  or iCloud Keychain; another device pairs independently. Device setup still
  imports the server descriptor and shows it as needing sign-in rather than
  omitting it from the summary. Settings > iCloud Sync keeps that entry
  available and opens Silo's native sign-in flow.
- Catalog requests use native cursor pagination and explicit `seek` windows.
  Lightweight cards inherit missing external identities from Silo's frozen
  provider-anchored content-ID scheme, so the identity index can match owned
  copies before a detail page is opened. Explicit detail fields win; an
  episode's embedded series anchor is never treated as its own episode ID.
  Those anchors are partial identity, not a complete set of provider IDs. Library
  indexing and on-demand ownership searches hydrate native item details with
  bounded concurrency to join TVDB-anchored titles to TMDB/IMDb watchlist entries.
  Episode file resolution and coarse HDR/SDR fields fill missing track-level
  metadata for hero badges; detailed track facts take precedence. An explicit
  file-level `hdr: false` means SDR even when no video tracks are supplied;
  an absent or null HDR value stays unknown. Unknown audio
  channels never imply stereo or surround. Detail heroes observe source-scoped
  episode metadata separately from the rail, so a later sparse season/resume
  result cannot erase badges or restore stale progress.
  Explicit Dolby Vision/HDR10+ combinations survive profile mapping. Native
  `dv_bl_compat_id` and its presence flag distinguish HDR10, HLG, SDR, and no
  compatible base; an omitted zero with a true presence flag means no compatible
  base, while a false flag does not authorize use of a legacy numeric value.
  Profile 8 alone does not imply HDR10. The selected audio track's profile/title
  retains declared Atmos/JOC and DTS:X hints without borrowing other tracks.
  These facts reuse the detail response; no new media probes or card hydration
  requests are added.
  Progress is read through the paged, library-scoped progress endpoint; Home's
  native next-up selections are corroborated before inclusion in a restricted
  library view. Versions use the original Silo file ID.
  Parent series cards already present in the Home response fill missing episode
  logos and `Series*` identities, including episodes also returned by progress.
  The exact series relationship is checked; resume state and playable episode
  IDs are not replaced. This reuses existing responses rather than adding a
  parent lookup per card. Series-detail resume uses the same inheritance.
- Playback requests a fixed file when the server advertises that optional
  extension. Older protocol-3 servers remain supported, but a returned plan
  naming a different file is always rejected and released. Signed stream and
  subtitle URLs stay behind in-memory,
  account/revision-bound locators. A signed `st` reference is not account
  authentication: the current login bearer is added through Silo's documented
  media-element `token` query fallback only at I/O resolution, only for the
  configured origin and the exact issued native session path. Signed query
  bytes are preserved and foreign origins never receive the account bearer.
  Original-file delivery advertises Plozzigen's software codecs (including VP9),
  separately from hardware decode and native remote-HLS capabilities.
  Its delivery-scoped claims let the local player manage HDR presentation and
  select source audio tracks without requesting server conversion. They do not
  claim native HDR10+ output or apply to server-packaged streams. HLS delivery
  includes Silo's `hls` stream-container token, not only segment containers.
  The provider accepts original HTTP or HLS
  plans with a source-aligned seekable timeline; incompatible plans are released,
  not played with an incorrect clock. Refusals explain the rejected timeline,
  missing seek support, source mismatch, or unsupported delivery/authentication,
  including ordinary TV playback without explicit quality options. Raw server
  text and signed addresses are never user-facing explanations.
  Next-episode playback resolves on demand, not during the previous episode:
  protocol-3 sessions without playback activity can expire independently of
  their signed URL's expiry. Progress samples are sequenced and stop
  requests carry an idempotent stop identifier.
- Watched state and the native Silo watchlist write back to Silo. Batched resume
  synchronization checks each result, not only HTTP success.
  Watched writes use `POST /api/v2/watched/{id}`; unwatched writes use `DELETE`.
  Both accept the native `204 No Content` response and retain the selected
  server-profile headers. This contract is pinned in the
  [native API specification](https://github.com/Silo-Server/silo-server/blob/3bc9e58c51970f261d41848ff411713894d53243/contracts/api/v2/openapi.json).
  Failed outbox targets retain their watch intent and use the shared persisted
  retry cooldown rather than retrying on every index or configuration update.
  HTTP 429 honors both numeric and HTTP-date `Retry-After` values.

### Watch indicators

The shared mapper retains `user_state.played` and maps detail/season
`user_data.unplayed_count` into episode-count badges. That count already includes
in-progress episodes. Container progress uses watched / (watched + unplayed);
missing counts stay unknown rather than becoming zero. Leaf progress uses the
supplied position and duration, including a saved rewatch position. Existing
Continue Watching and Home responses update position and percentage together.
No extra requests, per-card detail hydration, or catalog scans are added.

At upstream revision `dd3f7a604ade38bb537d9c6cc63d149ff3f484b5`, native catalog
and Home cards expose completion through `user_state`, but do not expose the
detail/season `user_data` rollup. Browse `sort_metrics.progress_ratio` is
sort-dependent; Home Continue Watching cards can carry position/duration.
The native browse query has no watch-rollup expansion option. Consequently,
cards without those values cannot show an accurate remaining-episode count.
Supporting `user_data` on Silo's existing card responses would let this mapper
consume the same rollup without additional client requests.

## Search

TV and mobile use the shared federated search through `MediaProvider.search`.
Silo searches the native `/catalog` endpoint with `q`, scoped to each enabled
video library and the authenticated server profile. Results preserve the server's
order within each library, original content IDs, account/library attribution and
episode relationships; duplicate content IDs appear once. Disabled Plozz
libraries are not queried. Authentication and server failures remain errors,
not empty successful searches.

Catalog cursor sequences keep their initial page size (at most 200), including
after a short nonterminal page. Silo binds `limit` into the cursor scope, so a
smaller final request is invalid; the client trims the final results locally.
Missing or repeated continuation cursors fail rather than looping.
This contract was checked against the
[native catalog handler](https://github.com/Silo-Server/silo-server/blob/9b77105e5870b0cdea8148b26194f026d275167d/internal/apiv2/catalog_items.go)
and is covered by `SiloSearchTests.swift` in `ProviderSiloTests`.

Opted-in manual search diagnostics distinguish library-listing, catalog and token
refresh HTTP/decode failures. The bounded source record includes available,
excluded and attempted library counts, page sizes, returned row counts,
continuation presence and missing/repeated/empty-page failures. Library references
are request-local ordinals, never server IDs; cursor values and queries are
excluded. HTTP status, transport errors and allowlisted decoding fields survive
in the report even if another provider makes the overall search appear successful.
See [search diagnostic retention and consent](../FeatureSearch/README.md#diagnostic-submissions).

## Collections

Library collections and personal collections have separate native contracts.
`collections(in:page:)` retains `/library/{id}/collections` and
`source=library_collection`. `personalCollections(page:)` reads `/collections`,
including the acting viewer's own collections and collections shared with them,
even when they are not published in a library's Collections tab. It slices the
native unpaginated list without discarding the server's viewer order.

Personal IDs use a distinct provider-local namespace. Item lookup, children and
paged members route consistently to that namespace, with members fetched through
`/catalog?source=user_collection&collection_id=...`; no arbitrary library or sort
is imposed. Server profile authorization applies to every request. Missing
artwork is valid; unsupported endpoints and revoked credentials remain errors.
Personal catalog cards do not declare library ownership, so the provider leaves
it unknown rather than mislabeling the whole collection as one library.
These contracts were checked against native v2 revision
`bbef279723ddc17cd3798b22decf58e5791765c7`.

## Detail ratings

Native v2 detail ratings use the server-selected `ratings` list, preserving its
order, plain-text source marks and preformatted values (including plugin
sources). TMDB may use its approved mark. An explicit empty list stays empty:
external rating lookups, cached ratings and duplicate-title merges must not
restore a source the administrator excluded. Raw `rating_*` values remain
sorting facts, not a substitute display list. Older responses without `ratings`
retain ordinary external enrichment. Invalid scores and duplicate entries are
logged and omitted without losing the rest of the title.

## Streaming quality

The mobile quality controls use Silo's native protocol-3 preferences and video
bandwidth cap; they never rewrite a session's signed media URL. Resolution is
a height ceiling. Compound preferences preserve the requested height under a
lower bitrate cap, while smaller sources stay at their original dimensions.
The total bitrate reserves 192 Kbps for stereo AAC, and the HLS capability caps
audio at two channels. The returned effective recipe must satisfy the limits;
normalized preferences, ignored limits, or substituted files are refused and
their sessions released.

The published API currently supports 480p, 720p, 1080p and 4K conversion with
H.264 output. The UI disables unsupported 240p/1440p and HEVC conversion choices.
A saved HEVC preference can use the shared explicit H.264 retry without raising
the limit. Maximum retains the original negotiation path unless conversion is
forced; force uses a genuine bitrate reduction rather than inventing decoder
capabilities. Session cleanup sends an idempotent stop without fabricating a
resume position.
The quality contract was verified against Silo server revision
`8e5ae2f469d36109e28cab3959693236cb503833`; unsupported growing/non-source-aligned
timelines remain an explicit refusal rather than an incorrect resume clock.
Original-player claims and HLS container matching were checked against
`c78d233918ec7297d519fb2702f5473f5109eb9d`. An unspecified negotiation refusal
does not imply transcoding was requested; diagnostics retain the requested
quality, encoding requirement, and server refusal code.

## Subtitle search and download

Silo uses the shared TV/iOS subtitle search, accessibility preference ranking,
automatic download policy and hot-load pipeline. Search and download are scoped
to the exact playing file and session, never the item's first/default version.
Provider availability is checked at runtime; unconfigured/unauthorized sources
produce actionable errors rather than an empty successful search.

Search results are opaque, session-bound handles for the complete native result.
The server's match score is not a community rating or a verified file-hash match.
SDH is preserved; Silo does not report a forced flag, so none is invented and
forced-only automatic download does not select an unconfirmed full subtitle.

The download receipt identifies the exact stored sidecar, including one already
present, so it can be added without guessing from mutable track indices or opening
another playback session. Native delivery pins `file_id` and
`downloaded_subtitle_id` to the authorized session. Supported text formats are
served as WebVTT through the existing authenticated resource resolver and subtitle
overlay. Bearers and signed reconstruction references never enter track locators.
Uncertain download POSTs are not automatically replayed. Newly downloaded
sidecars use the configured native API even when a distributed node serves the
movie; account credentials are never attached to that node's URL.

## Offline downloads

On iOS/iPadOS, downloads use Silo's managed device registry, native capability
checks, revision guards and authenticated file delivery. They do not reuse a
playback grant or open a player session. Original quality keeps the source when
the server can deliver it; Silo may prepare a compatibility artifact. Reduced
qualities choose an advertised bitrate preset no higher than the requested cap.
Reduced Silo copies use the server-selected audio track; Original preserves
embedded tracks.

Prepared download IDs and revisions are persisted before byte transfer, so
retry/relaunch reconciles the server registry before creating anything. Background
and speed-limited transfers attach current bearer/profile/device headers and
reject cross-origin credential redirects. Offline manifests and supported text
sidecars are pinned beside the media. Completed files remain playable without a
server connection. Completion reports and server-registry removals survive
temporary disconnection in the durable local download state.

The Silo server icon is the SVG supplied by the maintainer, used only to identify
the compatible server. Plozz remains independently branded.

Upstream contract references:
- [Authentication](https://github.com/Silo-Server/silo-server/blob/cbc13de10f4af28762be6777cab2f75403eade58/docs/auth-api.md)
- [Playback](https://github.com/Silo-Server/silo-server/blob/cbc13de10f4af28762be6777cab2f75403eade58/docs/playback-api.md)
- [Downloads](https://github.com/Silo-Server/silo-server/blob/cbc13de10f4af28762be6777cab2f75403eade58/docs/downloads-api.md)

Tests: `ProviderSiloTests`, `SiloCredentialRotationTests`,
`ManagedDownloadLifecycleTests`, and the existing shared playback/download suites.
