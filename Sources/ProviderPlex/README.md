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

- Manually verified alternate addresses supplement, rather than replace, Plex's
  advertised local/remote/relay candidates. Discovery refresh retains the manual
  set, and removed aliases cannot be resurrected by a last-reachable seed.
  Public `/identity` validation carries no token; subsequent server probes and
  API calls restrict redirects to the approved origin. Playback resolution asks
  the existing Plex resolver for the current route. Address edits preserve
  discovered candidates separately from manual aliases and retire superseded
  probe sweeps before they can authenticate to a removed alias.
  Playback locators strip the matching source base's encoded proxy prefix and
  resolve relative to the newly selected base, preserving encoded media-path bytes.
- **No UI imports.** Pure logic + DTOs.
- **Tokens never logged.** `X-Plex-Token` flows through `CoreNetworking`
  redaction; PIN values are never persisted (see `PlexPinFlow`).
- **All errors become `AppError`.**
- **Co-equal with `ProviderJellyfin`.** Any new `MediaProvider` capability
  must ship for Plex whenever it ships for Jellyfin (and vice versa).
- Home-user identity changes happen **in-memory only** — Plozz never
  rewrites the stored admin account's token; per-user tokens live in a
  short-lived override map.
- An empty Home user's library access is not an expired login. After a server
  rejects section discovery, a successful Plex cloud resources response that
  omits that server confirms an empty video/music library inventory for this user.
  A present grant, rejected cloud credential, malformed response, network failure,
  or cancellation is never converted to an empty result. Resource-token lookup
  reads the server grant directly, without requiring advertised connection URLs
  or probing servers just to resolve credentials.
  Browsing providers receive a live cloud-credential reader fenced to their
  account and effective credential revision. Sharing verification uses that
  Home-user token, never the server-scoped token, and rechecks identity after
  the cloud response before publishing an empty inventory.

## Format badges

Detail and version badges preserve the same source's Dolby Vision compatibility
and HDR10+ hints together. A base compatibility ID of 1 does not downgrade
confirmed HDR10+ to HDR10. HLG/SDR/none compatibility remains authoritative;
profile 8 alone and false DoVi flags do not establish an HDR10 base layer.
Selected audio profile/title hints use the shared normalization, including
E-AC-3 JOC, without changing playback negotiation or adding metadata requests.

## Playback chapters

Playback detail requests opt into `includeChapters=1` and carry the server's
item-level chapter starts, titles, and optional images in `PlaybackRequest`.
Millisecond offsets become seconds; missing and invalid starts are omitted.
Ordinary browsing requests do not add this chapter query.

## Episode identity and order

Full item metadata requests include GUIDs and preferences. The series'
`Preferences.Setting` entry named `episodeOrdering` supplies the explicit
TVDB aired/DVD/absolute or TMDB aired numbering system. Unrecognized values
stay unknown, and an absent/inherited order is not guessed from the library
agent or title. Episode `Guid` TVDB IDs remain episode IDs, separate from
the parent's TVDB identity; community markers can pin that exact episode.
Preference retrieval follows
[PlexAPI's advanced-settings contract](https://github.com/pushingkarmaorg/python-plexapi/blob/master/plexapi/mixins/advanced_settings.py);
Plex's [metadata-provider schema](https://developer.plex.tv/pms/) documents
the `SeasonType` identifiers.

## Home recommendations

`homeHubs` reads `/hubs/promoted` for the current user's Home-promoted rows,
scoped to the requested library. It does not substitute the full
`/hubs/sections/{id}` recommendation menu for Home. The shared arranger may
enumerate that menu as optional rows; promotion eligibility and legacy
eligibility stay separate from the row's title and stable hub identifier.
Subject-driven rows (similar titles and people) retain a family/slot identity
when the suggested movie or person changes; ordinary genre/collection IDs remain
server-authored. The shared library key scopes both forms to their account.
Explicit row choices can include person or sparse shelves that legacy Home
excluded. The library Recommended view retains `libraryHubs` behavior.
Home continues to use the canonical Continue Watching feed rather than
duplicating a resume/on-deck hub inside each library.

Home and library Continue Watching share the same endpoint selection: items hub,
plain hub, then legacy on-deck only after an initial unsupported, invalid-response,
or decode failure. An empty successful hub is authoritative. Authentication,
rate-limit, cancellation, transport, and failures after a decoded page do not
switch feeds or publish partial results. Home still applies its video and
hidden-library filtering after the complete feed is available.

Exhaustive feed pagination detects repeated server items using namespaced
`ratingKey` and metadata `key` aliases. A global Plex GUID is only a fallback
when both local identifiers are absent: copies or editions in different
libraries can legitimately share it. Size, total, offset, and forward-progress
validation remain strict.
Failed reads also record the failing endpoint category and paging invariant for
the shared Details sheet. These opt-in diagnostics preserve error/fallback
behavior and never export item identities or response bodies.

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
`/library/collections/{ratingKey}/children`, with no type or sort override. That same
endpoint serves static and smart collections and preserves their server order.
Do not substitute `/library/metadata/{ratingKey}/children`: a populated smart
collection can return HTTP 200 with `size: 0`, `totalSize: 0`, and no `Metadata`
through that alias. This was reproduced with a real Dolby Vision smart collection;
its collection endpoint returned all 588 members across six bounded pages.
Ordinary show/season children continue to use the metadata namespace.
Membership requests use `includeOptionalElements=Stream`, never the
`includeElements=Stream` whitelist, so optional stream enrichment does not
filter out membership records. Discovery and
membership both reject nonempty envelopes with missing metadata rather than
presenting them as empty collections. Genuine empty collections and exhausted
pages remain valid.
Series/season members missing episode aggregates receive exact metadata in
batches of at most 50 IDs, using the same authenticated client. Only watch state
is applied; membership order, artwork and identity remain from the collection
response. Complementary aggregate fields retain the collection's known counts;
unresolved or invalid totals fail the page rather than publishing guessed watch
state. Complete aggregates require no extra request. Failed or missing metadata
also fails the page rather than publishing a false unwatched state.
Both platforms browse members in the existing vertical library grid, fetching
bounded pages on demand rather than loading a whole collection before first paint.
Failures remain separate from empty results and expose retry.

Protocol references: [Plex's official API and response customization](https://developer.plex.tv/pms/)
documents the dedicated collection endpoint and `MediaContainer.Metadata` JSON
envelope. python-plexapi uses the alternative `/all?type=18` discovery query:
[`LibrarySection.collections` / `search`](https://github.com/pushingkarmaorg/python-plexapi/blob/master/plexapi/library.py),
[`SEARCHTYPES`](https://github.com/pushingkarmaorg/python-plexapi/blob/master/plexapi/utils.py),
and [`Collection._items`](https://github.com/pushingkarmaorg/python-plexapi/blob/master/plexapi/collection.py)
uses the server-issued collection key's children path for static and smart membership.

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
MP4: the profile declares an explicit HLS `subtitleProfile` target alongside
the video target. Text tracks use automatic delivery instead of forced burn-in;
bitmap tracks still require burn-in for a server transcode, and Off remains explicit.
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

Bounded video encoding reserves the quality policy's audio budget. Plex receives
the documented `audioChannelCount` parameter and a `videoAudioCodec` /
`audio.bitrate` profile limitation, rather than relying on `audioChannels` or
an audio-bitrate query alone. Bitmap burn-in disables audio copy for bounded
renditions: copying a 640 kbps soundtrack beside video encoded against a 128 kbps
audio reservation would exceed the selected total. Original quality can retain
compatible audio, and an already-under-limit remux is not forced to downmix.

Stopping a streaming rendition runs outside its caller's cancellation state and
is awaited, so canceling negotiation or replacement does not cancel the cleanup
request too. Decision, materialized start, and stop retain the owned session ID;
credential-free locators still omit the session query fields restored at playback.
`StreamingSessionMaintaining` sends an authenticated, cancellation-aware
`/video/:/transcode/universal/ping` for that exact streaming session. Direct files
are not pinged. Every server rendition carries its owned session ID, including
ordinary compatibility conversion and forced fallback without quality options.
The playback owner controls the maintenance lifetime and drains
it before releasing the session; the provider creates no timer. This follows
[Plex's own paused-transcoder maintenance](https://github.com/plexinc/plex-home-theater-public/blob/f2f1d63f2d48ad0d2935f7002ee1168ebcd5bb3d/plex/Client/PlexTimelineManager.cpp#L232-L259)
and [session-scoped ping endpoint](https://github.com/plexinc/plex-home-theater-public/blob/f2f1d63f2d48ad0d2935f7002ee1168ebcd5bb3d/plex/Client/PlexMediaServerClient.cpp#L267-L272);
neither establishes a universal server-expiry timeout.
VOD retains the full-title HLS timeline and in-band seeking; no offset prewarming
or speculative buffering constants are added.

Protocol references: [Plex's official API and profile augmentations](https://developer.plex.tv/pms/),
the [revision-pinned profile grammar](https://github.com/LukasParke/plex-api-spec/blob/0a34b2513263f433756d98b5c6d12f984c7efa33/description.md#profile-augmentations),
and [Plezy's independent HLS targets](https://github.com/edde746/plezy/blob/8ef7c2cd9a35fd208403d0577d063d4143375fd9/lib/services/plex_client.dart#L95-L165).
Its [offset-prewarming regression](https://github.com/edde746/plezy/commit/3a704a2b9b37a177959cdd06027c326502a30541)
is a reason to test player-specific seek behavior, not assume that extra requests
improve startup. [Apple's HLS specification](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices)
requires fMP4 for HEVC and separate WebVTT text files.

Tests: `PlexStreamingQualityTests` and `StreamingPlaybackTests`.

## Original-file playback versus downloads

Aether-enabled direct-play negotiation uses `PlozzigenMediaFormats`, including
linked software-decoded video/audio families rather than only native formats.
The selected rendition still controls playback; an original-file descriptor is
not permission to bypass conversion or quality limits.

Original-file playback and scrub-frame extraction use
the original `/library/parts/...` URL without `download=1`. Only the explicit
offline-download source includes that flag. Reusing the download URL for player
buffering can make Plex's activity dashboard show transient download tasks.
Both variants retain the same selected media part, credential-free locator,
original bytes, and current-account authentication. This does not change engine
selection, quality limits, or server-transcode negotiation.

Tests: `ProviderPlexTests` covers MKV and MP4 original-file playback, scrubbing,
selected media versions, and the separately preserved offline-download URL.

## Playback session reporting

Each VOD playback request owns a unique `playSessionID`, even for repeated plays
of the same library item. For server renditions, it is the same identity used by
the universal decision, materialized stream, ping, and stop. Every timeline event,
including the outgoing rendition's stopped report during replacement, forwards
that request's identity as `X-Plex-Session-Identifier`. `ratingKey` and `key`
continue to identify the library item for watch state, not the playback session.
There is no provider-wide "current session" lookup.

Timeline reports include the known playback duration in milliseconds; unknown,
non-finite, nonpositive, or unrepresentable durations are omitted, not replaced
with zero. End reporting retains the final position and duration captured before
engine teardown. Plozz's optimistic watched flag and queued `/:/scrobble` write
are separate from Plex's playback history: neither a local checkmark nor a
successful timeline response proves that a history entry was recorded.

Direct files also own a reporting identity but do not acquire a transcoder
session or receive transcoder ping/stop calls. Callers without a playback identity,
including the current music reporter, still omit the optional header rather than
inventing or borrowing one. Live TV retains its separate lease-owned reporting.

The [PMS timeline specification](https://github.com/LukasParke/plex-api-spec/blob/0a34b2513263f433756d98b5c6d12f984c7efa33/plex-api-spec.yaml#L1204-L1208)
defines the header as unique per client playback session.
[Plezy's progress implementation](https://github.com/edde746/plezy/blob/8ef7c2cd9a35fd208403d0577d063d4143375fd9/lib/services/plex_client.dart#L2152-L2180)
also forwards the stream's session identifier to associate dashboard reports with
the actual stream decision. This correlation does not prove delivered resolution
or explain a player stall; those require separate stream and playback evidence.

Tests: `PlexStreamingQualityTests` and `PlexProviderMappingTests`.

## Where to look first

- `PlexProvider.swift` / `PlexClient.swift` — the `MediaProvider` entry.
- `PlexAuthClient.swift` + `PlexPinFlow.swift` — sign-in & Home-user PIN.
- `PlexConnectionResolver.swift` — how a usable base URL is chosen.
- `PlexDeviceProfile.swift` — what the server is told this device can play.
