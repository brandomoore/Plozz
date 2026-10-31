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
  Aether-enabled profiles use `PlozzigenMediaFormats` for linked container,
  video and audio families rather than native hardware-only restrictions.
  Native-only profiles and server conversion limits remain independent.
  On-demand Original quality sends explicit null bitrate limits to Jellyfin;
  omitting those profile keys would restore its 8 Mbps defaults. Emby requires
  numeric limits: Original sends its signed-64-bit protocol ceiling in both the
  request and device profile. Null/omitted limits cause unnecessary conversion
  on Emby 4.10.2.0, even for compatible low-bitrate originals. This does not restore
  the old 120 Mbps client cap. User-selected lower qualities retain their exact
  limits. Server/user policy, codec compatibility, Live TV and music negotiation
  remain independent.
  If Emby copies the unlimited ceiling into a required conversion's video target,
  bound that saturated target to the original video bitrate (or container bitrate
  when the video rate is unavailable). Preserve smaller server targets and all
  other rendition restrictions. Missing source bitrate fails explicitly rather
  than starting an effectively unbounded encode. Direct files are not capped.
  Optional playback diagnostics retain bounded server-decision facts: source
  bitrate, selected quality limit (nil for Original), direct-play/stream/transcode
  flags, subtitle burn-in, and allowlisted reasons from the response or its
  transcode URL. Addresses, tokens, paths, and unknown reason text are never
  included. These facts explain why conversion was selected; they do not prove
  why the resulting stream failed.
- `JellyfinMusicProvider` — music-library queries (artists, albums, tracks)
  surfaced through the shared provider abstraction.

## Invariants

- Approved alternate addresses share one resolver across ordinary and interactive
  API requests. Artwork and newly resolved playback resources use the selected
  origin, including its reverse-proxy prefix. Public identity probes carry no
  bearer. Single-address accounts retain their existing zero-probe behavior.
  Jellyfin and Emby use the same route selection and fallback policy.
- **No UI imports.** Pure logic + DTOs. Compiles on Linux.
- **Never logs tokens.** All `Authorization` / `X-MediaBrowser-Token` headers
  flow through `CoreNetworking` redaction.
- **Maps every error to `AppError`.** Transport / decode / HTTP-status
  failures don't escape this module raw.
- **Jellyfin/Emby parity by construction.** Shared capabilities stay in one
  implementation; provider-specific branches are limited to API differences.
- **Co-equal with `ProviderPlex`.** Any new `MediaProvider` capability must be
  implemented here whenever it's implemented for Plex (and vice versa).

## Home browsing

Home browse feeds and collection membership request `DateCreated` so client-side
Date added sorting uses library dates on both Jellyfin and Emby, without changing
the server-authored feed membership or default order.

## Format badges

Existing detail and per-version badges share the same source classifier.
Jellyfin's `DOVIWithHDR10Plus` and confirmed Emby compatibility survive mapping;
the UI groups Dolby Vision and its declared HDR10+/HDR10/HLG compatibility into
one badge. Selected audio stream profile, display title, and track title retain
explicit Atmos/JOC or DTS:X hints. No other track or filename supplies those
facts, and this does not add probes or requests.

## Playback chapters

Playback detail's `Chapters` array supplies chapter navigation on both backends.
Offsets use 100-nanosecond ticks; chapter image paths retain the original array
index even when invalid entries or Emby intro/credit markers are filtered out.
Only ordinary chapter entries become `PlaybackRequest.chapters`; the skip-marker
path remains separate. Missing chapter images never remove navigation entries.

## Server-provided ratings

Jellyfin item details display ratings supplied by the authenticated server.
Optional rating reads are presentation-only: required item loads and playback
inventory requests never make or await them. Details retain their native
metadata immediately, without adding a placeholder or minimum display delay;
the cancellable page task applies server metadata independently of load completion.
Home uses only already-cached rating metadata during its existing hydration;
it never requests optional ratings before publishing a carousel.
The server-response adapter currently supports the cache format exposed by the
[MDBList Ratings plugin](https://github.com/Druidblack/Jellyfin.Plugin.MDBList_Ratings)
at `GET /Plugins/MdbListRatings/CachedByItemId?itemId=...`. This is a read-only
server metadata request. Plozz does not call rating services, supply keys,
request server-side refreshes, or load plugin scripts, artwork, or external links.

Movies, series, seasons, and episodes use their own authorized server item ID.
No plugin calls are made for listings, unsupported item types, non-Guid IDs,
or Emby, where this Jellyfin-specific API is unavailable. Plex and Silo retain
their existing server-rating integrations.

A nonempty valid cached set replaces ambiguous native scores and uses the shared
provider-display contract: plain-text service names (except the existing approved
TMDb mark), stable server order, and normalized scores with explicit scales.
Equivalent sources are deduplicated by positive vote count, keeping the first
on ties. Existing Plozz rating visibility and spoiler controls still apply.
No new setting is added, and the plugin's web-only presentation toggle is not
used. External enrichment cannot add to or overwrite a supplied set.

Absent caches, empty/unusable sets, unsupported endpoints, and logged plugin
failures preserve ordinary native ratings and existing enrichment behavior.
Background requests have a two-second cancellation deadline, never a loading
or playback delay. Successful sets are reused for five minutes and cache misses
for thirty seconds in a bounded, 64-item, provider-scoped memory cache.
A missing endpoint is not
probed again for five minutes in that provider instance. Cancellation propagates
instead of returning a successful item. Malformed entries are logged and omitted
without discarding other valid ratings. State is scoped to the authenticated
provider instance; there is no global ratings cache for this integration.

## Episode identity and order

`DisplayOrder` is retained as `MediaItem.episodeOrdering` for community-marker
coordinate conversion, including Jellyfin/Emby's DVD (`altdvd`) and alternate
(`alttwo`) spellings. Missing order stays absent; unrecognized values stay
unknown. Episode `ProviderIds.Tvdb` identifies the episode, not its series.
The owning series provides its separate TVDB ID and order during playback.

## Library recommendations

Jellyfin's Home layout and Emby's legacy fallback read `CustomPrefs` from
`/DisplayPreferences/usersettings` as nullable strings. An unset unrelated
preference such as `tvhome` must not reject the whole layout. Null Home slots
use the same defaults as missing or empty slots; explicit `none` stays hidden.
Non-string values and HTTP, transport, or decoding failures still propagate.

Emby's native Home section endpoint owns each section's media selection. Requests
to `/Users/{userID}/Sections/{sectionID}/Items` must not override `IncludeItemTypes`
or `MediaTypes`: doing so can replace an audio section's contents with videos.
The video Home importer filters unsupported returned item types locally, including
when an unknown section has no collection or item-type metadata. Audio/reading-only
results therefore produce no Home row, even with a retained custom arrangement.
This applies on both platforms and does not change tvOS's separate Music area.

Provider-style Home separates `/Items/Resume` from each TV library's
`/Shows/NextUp`, and starts with per-library Latest rather than five movie
recommendation shelves per library. Resume-only Home requests do not call Next
Up; disabled Next Up rows are not fetched. Other consumers of `continueWatching`
retain the existing combined feed and its independent-endpoint failure handling.
Useful items survive failure of the companion endpoint, but an empty successful
feed cannot turn that failure into authoritative empty history. Home and
series-resume callers receive the failure instead. Support details identify
Resume and Next Up separately; bounded recent activity records only scope,
endpoint counts and the number of successful feeds, without media or account IDs.

Series-specific resume lookups allow resumable `/Shows/NextUp` candidates.
Compatible bridges can return an empty series-scoped `/Items/Resume` even when
their account-wide feed contains the saved episode. The existing two scoped
requests still suffice: exact series matching and Resume-first deduplication
remain intact. Ordinary Home Next Up requests continue excluding resumable
episodes. This does not bypass excluded libraries or change server-owned
minimum-resume thresholds.

Global Home history is account-wide on every provider, including Jellyfin and
Emby. Combined Continue Watching, resume-only Home, and account-wide server
Resume/Next Up rows do not apply catalog visibility as a history filter.
They use the signed-in server user's history even when catalogs are hidden or
cannot be enumerated. Shared Home aggregation, not server-name or extension
detection, selects that scope.

Explicit library-scoped callers still use the standard `ParentId` parameter
and stamp returned items with that library; an empty scope makes no requests.
An empty scoped feed never triggers an unscoped retry. The synthetic Collections
directory is never treated as a media library. History requests need no separate
system-info probe, catalog scan, or extra compatibility retry.
Account, server-user, and profile boundaries, independent-endpoint error handling,
and cancellation remain unchanged. `JellyfinHistoryVisibilityTests` covers these
explicit scope rules for both providers; the shared Home visibility tests cover
account-wide selection independently of library availability.

Home recommendations are opt-in individual rows on every platform. Their Home
identity is the recommendation type and its occurrence within that type, not
the changing baseline movie title or category ID. This keeps a hidden
"More like..." slot hidden when its subject changes. The library Recommended
screen still uses the server's own category identities and full inventory.

Watched- and liked-movie similarity rows share the concise localized heading
`More like [movie title]`. The server title remains unchanged apart from trimming
surrounding whitespace; absent or blank titles retain `Suggested movies`.

`/Movies/Recommendations` category IDs are strings on Jellyfin and nullable
64-bit integers on Emby. `MovieRecommendationDto` normalizes integers directly
to decimal strings without floating-point conversion, preserving exact stable
row IDs across refreshes. Existing string IDs are unchanged; null or absent IDs
retain the provider's recommendation-type/subject fallback. Malformed values
still fail decoding rather than silently removing recommendations or errors.

The movie-recommendation decoder also accepts the compatible bridge's verified
empty query-result shape: exactly `Items: []`, `TotalRecordCount: 0`, and
`StartIndex: 0`. This means no recommendation shelves, not a failed library.
Canonical category arrays remain unchanged. Missing/null fields, contradictory
counts, error or additional keys, and nonempty envelopes still fail with Details:
the observed empty response does not establish a populated-envelope contract.
The compatibility path adds no request, cache, or capability override; a later
refresh can return normal categories, and cancellation continues to propagate.

`JellyfinLibraryScopingTests` uses backend-specific recommendation fixtures and
covers full Int64 boundaries, exact IDs above 2^53, malformed IDs, library scope,
stable category identity after rows are reordered, and strict empty-envelope
compatibility with refresh and cancellation.

## Library alphabet navigation

The A–Z index first requests the library's total with `Limit=0`. A valid response
that nevertheless contains items establishes that the endpoint does not honor
count-only queries. Plozz logs that unsupported capability and omits the index
without a retry message or the remaining 27 letter requests. Ordinary browsing,
catalog order and paging are unchanged on mobile and TV.

Servers can honor `Limit=0` while ignoring alphabet predicates. Before the
remaining letter fan-out, Plozz compares `NameLessThan=Z` and `NameStartsWith=Z`
with the total. If both disjoint queries return the entire nonempty library,
alphabet filtering is unsupported and the rail is omitted after three requests.
The probe counts are reused for supported indexes, retaining 28 requests overall.
This does not scan or cap the library; empty, all-Z and non-Latin libraries remain
valid. The compatibility result is logged without server or library identifiers.

This handles virtual catalogs without matching profile names, hosts or server
branding. Catalog page totals are not alphabet offsets when the endpoint ignores
count-only requests or the `NameLessThan`/`NameStartsWith` predicates.
The result applies only to that scoped request; another library or refresh can
still supply an index. No unsupported flag is persisted on the profile/account.

Native Jellyfin/Emby count-only responses retain bounded letter queries and
ascending/descending offsets. Apart from the exact ignored-predicate pattern
above, missing, negative or contradictory counts, invalid JSON,
authorization/transport failures, and cancellation are still errors, not evidence
that the capability is unsupported. Rejected counts retain secret-safe numeric
diagnostics so a response failure can be distinguished from unsupported behavior.

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

## Playback negotiation

Remote-source descriptions can explicitly declare a file size while the bridge's
structured `Size` field contains a conflicting value derived from another field.
For remote sources only, one unambiguous byte-unit size in the source description
owns the displayed/mapped file size and version sorting. Decimal GB/MB and French
Go/Mo are distinct from bitrate tokens such as Mb/Mbps; binary GiB/MiB keep their
binary multipliers. Filenames, locators, and conflicting size declarations are not
size evidence. Local sources retain the structured byte count, and raw source
revisions/IDs/playback locators are unchanged.

Remote descriptions may also explicitly name languages that the bridge omits
from `MediaStreams`. Dedicated fields such as `🌍 French | Multi | English`
supplement the same source's display-language inventory before playback, on
detail pages, and in the player. Named languages are deduplicated against the
structured codes; `Multi` is not counted. Local files keep their stream metadata.
The bridge's compact `🇫🇷 🇨🇦 🇬🇧 ✓ • 💾 87,8 Go` and globe-prefixed variant
also carry language flags. Those explicit headers supply French/English before
playback; the Canadian variant does not become a third language. Flag parsing
requires the compact header's size-field shape; arbitrary country/subtitle
labels and filenames are not language evidence.
Description languages never create selectable audio tracks, change playback
preferences, override codecs, or leak into other versions.

Remote movie/episode detail responses sometimes expose one generic source while
`GET /Items/{id}/PlaybackInfo?UserId=...` contains the actual inventory.
`item(id:)` is strictly presentation metadata: Home rows, focused heroes, detail
pages and episode badges never request PlaybackInfo as background enrichment.
GET is not proof of a cheap read: Jellyfin can refresh STRM metadata and run
media probes while producing its playback inventory.

Play and explicitly opening Version use `playbackItem(id:)`, which requests this
inventory for movies and episodes and requires it to succeed. Each version retains
its original source ID and its own technical/audio-language facts; generic item
streams must not overwrite the real default source. Compatible servers can resolve
their streams lazily at this endpoint; item-detail source counts and `IsRemote`
flags do not establish completeness, even after an earlier playback.
Browsing remains available without an inventory request, but playback cannot
mistake lightweight metadata for a confirmed single-version title. Missing or duplicate
IDs and unsupported/failed inventory requests block playback through its error
presentation while leaving browsing available. Cancellation still propagates.
An explicitly remote source whose ID is the item ID and whose description starts
with the bridge's `No streams · ` marker is a negative lookup, not a file. It is
excluded from inventories and rejected before creating a playback locator, even
when the bridge supplies invented tracks and direct-play support. Ordinary file
names and local files are not classified by loose keyword matching.
An all-placeholder inventory throws `StreamingQualityError.noStreams`, distinct
from a missing item, malformed response or connection failure. Detail pages can
therefore offer a truthful, retryable `No streams found` action without treating
a temporary error as proof that a title has no streams.
Both backends expose Version even when the cached list has zero or one source.
Opening the overflow menu alone does not load it. The version page owns loading,
failure and explicit Retry, and shares alternate-file resolution with the Play gate.

`PlaybackInfoRequestCoordinator` admits one VOD inventory GET or negotiation POST
per server in this app process, with at most 16 queued requests. Concurrent inventory
readers for the same client, user and item share in-flight work; changed credentials
do not share results. Queued work retains its caller's task-local diagnostics and
authorization context. Cancelling a queued caller removes its work. Cancelling a
started inventory reader does not free admission before the transport finishes;
started negotiation responses still reach playback-session cleanup.
An ambiguous timeout, connection failure, invalid response (including HTTP 5xx),
or decoding failure stops queued requests and rejects new ones for at least
30 seconds; longer numeric Retry-After values are safely bounded and honored.
Nothing retries automatically when that pause expires. Inventory GET also disables address-failover
replay, so a lost response cannot trigger a second probe through the same server's
other address.

This is client-side containment, not a server FFprobe limit: a single request can
still probe multiple files, and other clients, plugins and scans remain independent.
It does not establish the cause or resolution of a reported server OOM.

Version-preparation diagnostics distinguish the item-detail GET from the inventory
GET, transport timeouts from HTTP failures, and decoding from source validation.
Validation identifies an empty inventory, missing/blank/duplicate source IDs,
an explicit unavailable placeholder, or server refusal without retaining source
IDs or payloads. The shared version gate and explicit detail/episode discovery
capture these facts through `PlaybackPreparationDiagnostics`; failures remain
visible without converting an unavailable inventory into a playable fallback.

Inventory GET does not send a device profile, open a stream, or report playback.
Its generated `PlaySessionId` is not an owned encoding session and needs no stop
request. This differs from playback negotiation below; see the pinned
[`MediaInfoController`](https://github.com/jellyfin/jellyfin/blob/e53a6d3e6ae29cb05c55c7b8edf2d237a1f75c16/Jellyfin.Api/Controllers/MediaInfoController.cs)
and `MediaInfoHelper`. If actual negotiation omits an explicitly selected source,
both ordinary and quality-controlled playback fail rather than substitute a
different version, and release any negotiation session they own.

Forced conversion disables both `AllowVideoStreamCopy` and
`AllowAudioStreamCopy` in PlaybackInfo's body and query. Disabling DirectStream
alone does not prohibit codec copying inside HLS. A rejected forced rendition
cannot fall back to the same original file or a different requested version.
Ordinary negotiation and lossless remux retain the server's copy permissions.
When video encoding is necessary, Automatic chooses the first supported codec
in the server-issued list rather than replacing `hevc,h264` with H.264.

Negotiation owns its play session until it returns a usable `PlaybackRequest`.
Detail failures, cancellation, rejected retries, and invalid final locators
release the owned session. Best-effort remux pins the selected source and
releases whichever decision is abandoned. Cleanup is awaited independently of
the caller's cancellation and always includes both device and play-session IDs.
Server/network cleanup failures remain diagnostic failures, not proof of release.

Decoder-backed hosts keep a server-approved direct file on the local engine.
The legacy extra server-remux negotiation for Dolby Vision MKV and `hev1` MP4
is native-only: the linked engine already owns container repair and native
display signaling. Server-required conversion, explicit forced conversion,
quality limits, selected versions and tracks remain authoritative on both
Jellyfin and Emby. Regression fixtures cover both affected file shapes, the
native-only remux path, and required conversions.

This ownership was cross-checked against
[Sodalite's stream selection](https://github.com/superuser404notfound/Sodalite/blob/31799bde53e2d93384216b3f9b2523600896ef2b/Sodalite/Player/PlaybackStreamSelection.swift),
[Swiftfin's playback builder](https://github.com/jellyfin/Swiftfin/blob/b0cb3127b1cef57b6508581be1cfe9addd5539a2/Shared/Objects/MediaPlayerManager/MediaPlayerItem/MediaPlayerItem%2BBuild.swift),
and the [linked engine's pipeline contract](https://github.com/brandomoore/AetherEngine/blob/c1ce4cf48bad416e6be5230032a2b7f332e833d8/docs/architecture.md).
These are protocol/design references, not copied implementations. Client
differences do not establish the cause of an individual playback failure.

Protocol references: Jellyfin's pinned
[`MediaInfoHelper`](https://github.com/jellyfin/jellyfin/blob/e53a6d3e6ae29cb05c55c7b8edf2d237a1f75c16/Jellyfin.Api/Helpers/MediaInfoHelper.cs),
[`EncodingHelper`](https://github.com/jellyfin/jellyfin/blob/e53a6d3e6ae29cb05c55c7b8edf2d237a1f75c16/MediaBrowser.Controller/MediaEncoding/EncodingHelper.cs),
and [`HlsSegmentController`](https://github.com/jellyfin/jellyfin/blob/e53a6d3e6ae29cb05c55c7b8edf2d237a1f75c16/Jellyfin.Api/Controllers/HlsSegmentController.cs);
Emby's pinned
[`PlaybackInfoRequest` and encoding-stop schema](https://github.com/MediaBrowser/Emby.SDK/blob/1faf8176df7ede9152c38f27a5925e6ccaf5e12b/Resources/OpenApi/openapi_v3.json);
Swiftfin's ordered
[`AVPlayer transcoding profiles`](https://github.com/jellyfin/Swiftfin/blob/791fe1249e12ffd066c763f28b4291866a14ac49/Shared/Objects/VideoPlayerType/VideoPlayerType%2BAVPlayer.swift).
`JellyfinPlaybackNegotiationTests` covers both backends, including cancellation
against a transport that requires an uncancelled cleanup request.

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
movie/TV library. `MediaProvider.collections(in:page:)` displays the authenticated
server's collection list, matching the native Jellyfin client.

Keep both native entry points: a Collections library beside Movies/TV Shows and
the Collections shortcut inside those libraries. If a video account's views omit
a `boxsets` library, Plozz adds one localized, account-scoped directory without
scanning media. A real `boxsets` view retains its identity and title;
never add a duplicate. Empty and music-only accounts get no synthetic directory.
Each collection directory uses one `Limit=1` BoxSet request to establish whether
it contains any collections. Home automatically hides a confirmed-empty entry
unless the profile explicitly enables it in Libraries. Discovery retains the
entry for that control; a later refresh shows newly populated directories.
Failures are logged and remain unknown, never converted into an empty result.
This check does not load collection members or populate the full browse cache.

The synthetic directory ID is navigation identity only. Browsing it uses the same
cached BoxSet listing without `ParentId`; the in-library shortcut still forwards
its real library ID. It offers collection sorting, not media filters or a
request-per-letter index. It is excluded from scoped Home media feeds and search
library enumeration, so it cannot widen a hidden-library query to the whole server.

Do not assume `ParentId=<movie-library>&IncludeItemTypes=BoxSet` scopes this query:
released Jellyfin 10.10.7/10.11.0 and the published Emby implementation explicitly
clear `ParentId` for BoxSet listing. Send the selected library as browsing
context and respect the result: it may contain all collections visible to that
server user or a server-filtered subset. Do not enumerate library media and
collection members to impose stricter client-side filtering.

Compatible endpoints can serve virtual catalogs rather than indexed local media.
Use verified endpoint capabilities and response contracts for optimizations;
neither server branding nor a server version establishes collection scoping.

The compatible strategy reads only the BoxSet list in 500-item pages, retaining
primary image tags. Collection-list responses are much smaller than full media
records; the larger batch avoids extra round trips for typical catalogs.
A provider/session-bound, single-flight
snapshot (maximum four library/sort entries) supplies subsequent grid pages
without further listing requests; page zero refreshes it. This cache is in memory,
not persisted across app restarts. Some compatible
servers omit rows while retaining their paging offsets, so a short
page can overlap the next page's prefix. Enumeration deduplicates that prefix
and advances by raw response-row count, not the number of new IDs. If a repeated
tail alone reaches the exact reported end, enumeration makes one extra request
at that boundary and requires an empty page before accepting completion. This
covers a sparse final list page without accepting a server that ignores offsets.
Connection failures get one cancellation-aware retry of the same read, with a
250-ms delay; other errors are not retried. Remaining request failures, early
empty pages, duplicates within a page, and other non-advancing/non-prefix repeats
remain errors. Browse Details includes the
failed enumeration stage, reason, offset, row count and reported total, never
collection/library IDs or media titles.
Only completed snapshots are cached; missing child counts do not mean an empty
collection. The native listing path needs no membership-progress phase.
Each consumer owns its own cancellable wait: leaving
one page does not cancel a replacement page's shared work. Only the last consumer
cancels the worker, and late cleanup cannot remove a newer flight.

Listing preserves the server's requested collection-list sort. Random order
is the exception: enumerate candidates in stable name order, shuffle once, then
retain that order. Visible cards and cached grid pages retain that order instead
of requesting independently shuffled server pages that could omit collections.

`MediaProvider.collectionMembers(of:page:)` pages direct members through
`/Users/{userID}/Items?ParentId={collectionID}&Recursive=false`. It deliberately
omits `IncludeItemTypes`, `SortBy`, and `SortOrder`: members can have mixed kinds,
and the server owns collection membership and display order. Library listing
remains a separate `items(in:kind:page:)` query; the member API is unchanged.
Member requests explicitly enable `UserData` and request it with the other
fields, retaining the server user's watched state and unplayed episode count.
Zero unplayed episodes must not become an unwatched flag merely because a
partial response omits the aggregate `Played` boolean.

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
