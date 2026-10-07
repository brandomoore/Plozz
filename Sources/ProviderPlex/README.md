# ProviderPlex

Plex implementation of `CoreModels.MediaProvider`. One of Plozz's two
first-class backends; co-equal with `ProviderJellyfin`.

## Responsibility

- `PlexProvider` — the `MediaProvider` conformer (libraries / hubs,
  continue-watching, latest, seasons/episodes, search, watched state,
  playback info / direct-play / transcode, progress reporting).
- `PlexClient` — low-level Plex API wrapper built on the shared
  `CoreNetworking.HTTPClient`. Centralises Plex's quirky required headers
  (`X-Plex-Token`, `X-Plex-Client-Identifier`, product/version, …).
- `PlexAuthClient` + `PlexPinFlow` — Plex **Link** "show a code, poll for
  completion" OAuth-PIN flow, plus the Home-user activation path that lets
  a Plozz profile map onto a Plex Home user (with optional PIN gate).
- `PlexConnectionResolver` + `PlexConnectionSelector` — pick the best
  reachable server connection from `plex.tv` (LAN vs WAN vs relayed),
  prioritising local & direct over relayed.
- `PlexDeviceProfile` — the direct-play / transcode capability matrix sent
  to the server, parameterised by whether the on-device decode engine
  (Plozzigen) is linked.
- `PlexDTOs` — Plex JSON shapes, mapped into `CoreModels` at the seam.

## Invariants

- **No UI imports.** Pure logic + DTOs.
- **Tokens never logged.** `X-Plex-Token` flows through `CoreNetworking`
  redaction; PIN values are never persisted (see `PlexPinFlow`).
- **All errors become `AppError`.**
- **Co-equal with `ProviderJellyfin`.** Any new `MediaProvider` capability
  must ship for Plex whenever it ships for Jellyfin (and vice versa).
- Home-user identity changes happen **in-memory only** — Plozz never
  rewrites the stored admin account's token; per-user tokens live in a
  short-lived override map.

## Continue Watching artwork

The existing parent-series metadata batches (at most 50 referenced series per
request) provide both recency and artwork context. Episodes retain their own
playable IDs, external IDs, resume positions, and watched state; the parent fills
missing `clearLogo` URLs and `Series*` external IDs. Existing feed logos win.
This adds no requests and also works when the parent has no last-viewed date.
Unrequested or non-series records are rejected, and a failed parent lookup keeps
the original feed available.

## Collections

`libraries()` returns actual server sections only. Collection discovery is an
option inside a movie/TV library, exposed by `.libraryCollections` and
`MediaProvider.collections(in:page:)`. It pages the dedicated
`/library/sections/{sectionID}/collections` endpoint with the selected sort.
Discovery deliberately omits `includeElements=Stream`: Plex documents
`includeElements` as an element whitelist, not a request for additional streams.
Nonempty envelopes with missing metadata are failures, not empty libraries.

Previously persisted `plex:collections:<sectionID>` IDs still route to scoped
discovery, but new library lists never synthesize these shortcuts. Legacy
`MediaLibrary` Codable fields remain readable while navigation migrates caches.

Collection membership
uses `MediaProvider.collectionMembers(of:page:)`, backed by paged
`/library/metadata/{ratingKey}/children`, with no type or sort override. That same
endpoint serves static and smart collections and preserves their server order.
Membership requests use `includeOptionalElements=Stream`, never the
`includeElements=Stream` whitelist: smart-collection responses honoring that
whitelist can retain their counts while omitting the members. Discovery and
membership both reject nonempty envelopes with missing metadata rather than
presenting them as empty collections. Genuine empty collections and exhausted
pages remain valid.
Both platforms browse members in the existing vertical library grid, fetching
bounded pages on demand rather than loading a whole collection before first paint.
Failures remain separate from empty results and expose retry.

Protocol references: [Plex's official API and response customization](https://developer.plex.tv/pms/)
documents the dedicated collection endpoint and `MediaContainer.Metadata` JSON
envelope. python-plexapi uses the alternative `/all?type=18` discovery query:
[`LibrarySection.collections` / `search`](https://github.com/pkkid/python-plexapi/blob/master/plexapi/library.py),
[`SEARCHTYPES`](https://github.com/pkkid/python-plexapi/blob/master/plexapi/utils.py),
and [`Collection._items`](https://github.com/pkkid/python-plexapi/blob/master/plexapi/collection.py)
documents the shared static/smart membership path.

Tests: `PlexCollectionBrowsingTests` and shared `CollectionDetailBrowsingTests`.

## Family guidance

The server's item metadata supplies only the Common Sense age/score and short
summary. Full reviews and content topics use
`https://metadata.provider.plex.tv/library/metadata/{globalPlexID}/commonsensemedia`,
not the Discover/watchlist host. This follows
[`CommonSenseMedia._reload` in Python PlexAPI](https://github.com/pushingkarmaorg/python-plexapi/blob/8a9ade7f364582cabb6d5bc200994fddb2113d48/plexapi/media.py#L1393-L1403).

Requests use the active Plex Home user's account-level cloud credential, never
an owner fallback for a mapped Home user. Authorization failures, Plex Pass
restrictions, and missing guidance remain distinct; Retry makes a fresh request
using the current profile's credential. Only same-origin redirects are allowed.
If an unprotected Home user's cloud credential is missing, Retry repairs only
that credential through an authenticated Home-user switch. It does not resolve
or rotate the library's server token, change its credential revision, or rebuild
the detail page. Startup also repairs incomplete cached identities: a failed
server-token lookup retains the same user's working server credential without
discarding the newly authenticated cloud token. Both credential halves are
cleared when leaving that Home identity, even when only the cloud half exists.
Superseded profile, binding, activation, or account credentials cannot publish
the repair. Protected users still require their normal Plex PIN flow; a Plozz
profile PIN is not a Plex PIN.
The bounded debug journal records the request route and HTTP status without
credentials or review content.

## Streaming transcodes

Universal-transcoder requests advertise HLS with fragmented MP4 audio/video
segments, AAC audio, and WebVTT text subtitles for Automatic, H.264, and HEVC.
The explicit target replaces the Generic profile's defaults; codec preferences
and bitrate/resolution ceilings remain unchanged. Quality-controlled playback
validates the same profile through `/decision` before opening `start.m3u8` and
rejects an incompatible returned container or video codec.

WebVTT is a separate subtitle rendition, not a subtitle muxed into ordinary
MP4. Text tracks use automatic delivery instead of forced burn-in; bitmap
tracks still require burn-in for a server transcode, and Off remains explicit.
Existing fetchable text sidecars retain their original format and authenticated
delivery source for Plozz's styled overlay. Embedded HLS text is extracted from
the native player's legible rendition into that same overlay. Selecting a different
embedded track prepares a new server rendition while preserving position, pause,
speed, quality limits, and the selected media version. Off and a text rendition
already prepared by the current session can switch locally.

Player track identities remain container indexes. Only the outbound transcode
options translate selected audio/subtitle indexes to Plex's database stream
IDs, using the selected media version's stream inventory. Decision and playback
requests must carry identical selections and limits.

Tests: `PlexStreamingQualityTests` and `StreamingPlaybackTests`.

## Where to look first

- `PlexProvider.swift` / `PlexClient.swift` — the `MediaProvider` entry.
- `PlexAuthClient.swift` + `PlexPinFlow.swift` — sign-in & Home-user PIN.
- `PlexConnectionResolver.swift` — how a usable base URL is chosen.
- `PlexDeviceProfile.swift` — what the server is told this device can play.
