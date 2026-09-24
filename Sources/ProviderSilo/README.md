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
ring and a visible match phrase. Profile selection uses the same avatar-row
component and scroll card as Plex server-user selection, including focus-aware
PIN indicators. These are Silo server profiles, not new Plozz household profiles.
On mobile, browser approval stays primary and manual/QR alternatives share one
disclosure instead of repeating the same instructions.

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
  Progress is read through the paged, library-scoped progress endpoint; Home's
  native next-up selections are corroborated before inclusion in a restricted
  library view. Versions use the original Silo file ID.
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
  The provider accepts original HTTP or HLS
  plans with a source-aligned seekable timeline; incompatible plans are released,
  not played with an incorrect clock. Progress samples are sequenced and stop
  requests carry an idempotent stop identifier.
- Watched state and the native Silo watchlist write back to Silo. Batched resume
  synchronization checks each result, not only HTTP success.

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
