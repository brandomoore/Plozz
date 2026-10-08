# ProviderJellyfin

Shared Jellyfin/Emby implementation of `CoreModels.MediaProvider`. Both use the
MediaBrowser API lineage and intentionally share one implementation so every
supported capability remains at parity.

## Responsibility

- `JellyfinProvider` (the `MediaProvider` conformer) — libraries, items,
  continue-watching, latest, seasons/episodes, search, watched state,
  playback URL/streaming info, progress reporting, and Jellyfin Quick Connect.
- Emby compatibility — password authentication, Emby UDP discovery, chapter
  intro/credit markers, BIF trickplay, combined theme media, and Emby playback
  negotiation while preserving the shared feature surface.
- Delayed E-AC-3 JOC enrichment — when Emby omits Atmos from its API, Plozz
  performs a bounded one-frame decode after first paint, caches the confirmed
  result by source revision, and updates badges without delaying detail or Play.
- `JellyfinDTOs` — server JSON shapes, mapped into `CoreModels` value types
  at the seam (no DTO ever leaks above this module).
- `JellyfinDeviceProfile` + `JellyfinCapabilityProfile` — the
  direct-play / transcode capability matrix sent on `/PlaybackInfo`,
  parameterised by whether the on-device decode engine (Plozzigen) is linked
  so the server allows MKV / DTS / TrueHD / etc. to direct play when we can
  decode them locally.
- `JellyfinMusicProvider` — music-library queries (artists, albums, tracks)
  surfaced through the shared provider abstraction.

## Invariants

- **No UI imports.** Pure logic + DTOs. Compiles on Linux.
- **Never logs tokens.** All `Authorization` / `X-MediaBrowser-Token` headers
  flow through `CoreNetworking` redaction.
- **Maps every error to `AppError`.** Transport / decode / HTTP-status
  failures don't escape this module raw.
- **Jellyfin/Emby parity by construction.** Shared capabilities stay in one
  implementation; provider-specific branches are limited to API differences.
- **Co-equal with `ProviderPlex`.** Any new `MediaProvider` capability must be
  implemented here whenever it's implemented for Plex (and vice versa).

## Library recommendations

Watched- and liked-movie similarity rows share the concise localized heading
`More like [movie title]`. The server title remains unchanged apart from trimming
surrounding whitespace; absent or blank titles retain `Suggested movies`.

`/Movies/Recommendations` category IDs are strings on Jellyfin and nullable
64-bit integers on Emby. `MovieRecommendationDto` normalizes integers directly
to decimal strings without floating-point conversion, preserving exact stable
row IDs across refreshes. Existing string IDs are unchanged; null or absent IDs
retain the provider's recommendation-type/subject fallback. Malformed values
still fail decoding rather than silently removing recommendations or errors.

`JellyfinLibraryScopingTests` uses backend-specific recommendation fixtures and
covers full Int64 boundaries, exact IDs above 2^53, malformed IDs, library scope,
and stable category identity after rows are reordered.

## Music

Artist browse uses `/Artists` and artist album queries use `ArtistIds`, including
performers on compilations whose album artist differs. Album metadata still
retains its album artist.

Track loading resolves the container type first. Playlists use
`/Playlists/{id}/Items` directly, without album sorting or item-ID deduplication;
both playlists and albums load bounded 500-item pages until complete. Any failed
page fails the load rather than returning a playable partial playlist.

The native audio player's universal request restricts **both container and
codec** (`container|codec|codec,...`), independently of the video engine's broader
capabilities. `JellyfinMusicDirectPlayProfile` owns the request and local quality
prediction; unsupported pairs such as DTS-in-WAV request the AAC/HLS fallback.
Quality remains a prediction of negotiation, not a measurement of server output.

`JellyfinMusicProviderTests` covers performer relationships, playlist order,
duplicates, pagination/failure, and matching request/quality profiles for Jellyfin
and Emby. Universal-profile syntax is defined by released Jellyfin's
[`UniversalAudioController`](https://github.com/jellyfin/jellyfin/blob/v10.11.0/Jellyfin.Api/Controllers/UniversalAudioController.cs).

## Transcode dynamic range

Full H.264 video conversions request SDR independently of the eight-bit depth
limit. Forced-transcode negotiation adds a codec-scoped range constraint using
Emby's `VideoRange` or Jellyfin's `VideoRangeType`. The final server-issued
rendition also carries `h264-videorange=SDR` (Emby) or `h264-rangetype=SDR`
(Jellyfin), including automatic codec conversion and the HEVC-to-H.264 fallback.
Other codec options, selected tracks, sessions, and quality bounds are retained.

The ordinary capability profile is unchanged so direct play and video-copy
remuxes retain their original range. HEVC HDR capabilities are not reduced to SDR.
These are output requests, not measured facts: never overwrite source metadata
or label an active stream SDR from its URL. Transcode Info continues to use the
engine's measured output. A server without tone mapping can still return HDR;
keep playable output rather than introducing a subscription-dependent playback
block or silently raising the selected quality limit.

The Emby query contract was confirmed against 4.10.1.0 by comparing otherwise
identical PlaybackInfo requests with no range, SDR, and HDR constraints. Its
[official schema](https://github.com/MediaBrowser/Emby.SDK/blob/master/Resources/OpenApi/openapi_v3.json)
defines `VideoRange`; Jellyfin's
[`StreamInfo`](https://github.com/jellyfin/jellyfin/blob/v10.11.0/MediaBrowser.Model/Dlna/StreamInfo.cs)
reads the codec-specific `rangetype` option.

## Watch-state writes

Manual marking and playback completion both use the shared watch outbox.
`PlayedItems` writes watched state; the following session-less `UserData` write
clears or updates the resume position without stopping playback.

Emby's `UserData` endpoint is not a field-by-field patch for `Played`: omitting
that field saves `false`, even when the request succeeds. Before each Emby resume
write, read the same user's current item state and explicitly preserve `Played`.
Never cache or default that flag. A failed read, missing flag, or failed write
must throw so the durable outbox retains the update. Leave favorites and play
count out of the update. Jellyfin retains its partial update without the extra
read; its older-server stop fallback must never apply to Emby.

`EmbyWatchStateTests` models the behavior reproduced against Emby 4.10.0.40 and
checks persisted server state after marking, completion, rewatching, dismissal,
reload, and failed-read recovery, not just successful HTTP responses.

## Collections

Jellyfin and Emby retain native `boxsets` libraries and `BoxSet` items. Both also
advertise `.libraryCollections` for the shared Collections option inside a
movie/TV library. `MediaProvider.collections(in:page:)` returns only groups with
at least one direct member in the selected library's recursive item set.

Do not assume `ParentId=<movie-library>&IncludeItemTypes=BoxSet` scopes this query:
released Jellyfin 10.10.7/10.11.0 and the published Emby implementation explicitly
clear `ParentId` for BoxSet listing. Latest Jellyfin development source has newer
linked-ancestor handling, but relying on it would leak unrelated collections on
older servers.

The shared compatible strategy reads the global BoxSet list and the selected
library's IDs in bounded 200-item pages, then checks collection member IDs with
at most four concurrent probes, stopping each probe at its first intersection.
ID queries disable collection collapsing, images, and user data. A provider/session-bound, single-flight
snapshot (maximum four library/sort entries) supplies subsequent grid pages
without repeated per-poster requests; page zero refreshes it. Failed, repeated,
or truncated pages fail the load rather than silently exclude uncertain groups.
Each consumer owns its own cancellable wait: leaving one page does not cancel a
replacement page's shared work. Only the last consumer cancels the worker, and
late cleanup cannot remove a newer flight.

Filtering preserves the server's requested collection-list sort. Random order
is the exception: enumerate candidates in stable name order, scope the complete
set, then shuffle the snapshot once. Cached grid pages retain that order instead
of requesting independently shuffled server pages that could omit collections.

`MediaProvider.collectionMembers(of:page:)` pages direct members through
`/Users/{userID}/Items?ParentId={collectionID}&Recursive=false`. It deliberately
omits `IncludeItemTypes`, `SortBy`, and `SortOrder`: members can have mixed kinds,
and the server owns collection membership and display order. Library listing
remains a separate `items(in:kind:page:)` query; the member API is unchanged.

Both platforms browse members in the existing vertical library grid. The first
page paints without waiting for the rest of the collection; later pages load as
needed. Failed pages remain retryable and are never treated as authoritative
empty results.

Protocol references: released Jellyfin
[`ItemsController`](https://github.com/jellyfin/jellyfin/blob/v10.11.0/Jellyfin.Api/Controllers/ItemsController.cs#L274-L278),
published Emby
[`ItemsService`](https://github.com/MediaBrowser/Emby/blob/master/MediaBrowser.Api/UserLibrary/ItemsService.cs#L193-L202),
and [`BoxSet`](https://github.com/jellyfin/jellyfin/blob/master/MediaBrowser.Controller/Entities/Movies/BoxSet.cs).
Tests: `MediaBrowserScopedCollectionTests`, `MediaBrowserCollectionCacheTests`,
`MediaBrowserCollectionRandomTests`, `MediaBrowserCollectionBrowsingTests`
(both provider kinds), and shared `CollectionDetailBrowsingTests`.

## Where to look first

- `JellyfinClient.swift` — the `MediaProvider` impl.
- `JellyfinDeviceProfile.swift` + `JellyfinCapabilityProfile.swift` — what
  the server is told this device can direct-play.
- `JellyfinDTOs.swift` — server JSON shapes mapped to `CoreModels`.
