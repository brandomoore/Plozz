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

The shared detail model fetches bounded pages and distinguishes failed loads from
empty collections, with retry on tvOS and iOS. It never caches a failed partial
load as a complete collection.

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
