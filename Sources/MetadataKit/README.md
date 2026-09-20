# MetadataKit

Artwork, metadata enrichment, and public discovery feeds. The user's own
server remains authoritative for its identities and curated metadata.
Configured app-level metadata keys ship with maintainer builds; a user's own
TMDB key is an optional override, not a prerequisite. No external provider is
load-bearing.

## Responsibility

- `ArtworkRouter` — the single front door for resolving external art.
  Classifies a `MediaItem` (anime / movie / tvShow / music), runs an
  ordered, content-type-specific fallback chain of providers, and memoizes
  the resolved URL in `MetadataDiskCache`.
- `ContentClassification` — turns a `MediaItem` into a routable
  `ContentType` using provider-supplied genre / external-id hints.
- Provider conformers — each isolated behind a small `ArtworkProviding`
  surface and individually unit-testable:
  - **AniList** (GraphQL) — anime hero / poster / score.
  - **Kitsu** (JSON:API) — anime fallback.
  - **TVmaze** — western-TV per-episode stills + posters.
  - **TheTVDB** (`TVDBArtworkProvider` / `TVDBClient`) — bundled keyed tier
    for movie/TV posters + wide backdrops + ids/overview. Attribution required — see the app's
    Settings → Attributions & Licenses and the repo README.
  - **Wikidata / Wikipedia** — cross-domain image lookups, used as last-mile
    backstop and to resolve canonical ids.
  - **Music artwork** (`MusicArtworkProviders`) — Deezer artist
    `picture_xl` + Cover Art Archive / MusicBrainz album covers.
  - **TMDb** (`TMDbMetadataProvider`) — optional Tier-2 source for backdrops
    / posters / per-episode stills / logos, used only when configured.
- `MetadataDiskCache` — small persistent KV cache for resolved URLs so a
  library is enriched with a one-time burst of calls, then effectively
  none.
- `MetadataHTTP` — internal lightweight `URLSession` transport for enrichment.
- `HeroDiscoveryProviding` — separate candidate-feed seam for TMDB, Simkl,
  AniList, TheTVDB, and TVmaze. It does not call Trakt.
- `HeroDiscoveryService` — bounded, coalesced public-feed reads, provider-level
  caching/backoff, and interleaved deduplication. Per-profile watch state and
  library ownership are applied afterward, never stored in the public-feed cache.
- `MetadataDiscoveryHTTPClient` — identifying User-Agent, explicit HTTP/decode
  failures, bounded request admission, and response-size checks for discovery.

## Discovery sources

Featured defaults to a two-calendar-year release window. Full dates use a rolling
cutoff; year-only metadata retains the boundary year rather than inventing a
release day. Undated titles do not qualify on popularity alone. This policy does
not filter Continue Watching, Watchlist, Recently Added, or Random library picks.

TMDB combines weekly movie/TV trends, recent popular movie/TV discovery, and
currently airing series in five requests. All-time top-rated and watchlist-based
recommendation feeds are not used. Older series qualify only with current airing
evidence: TMDB's next-seven-day feed, AniList's next episode, or TVmaze's
today/tomorrow season premieres. Their original release years remain unchanged.
Simkl supplies weekly watcher trends filtered to recent releases and is opt-in.
AniList supplies seasonal/trending anime and is also opt-in. TheTVDB supplies
current-year catalog browsing, with response dates checked against the same
release policy. No provider adds per-title detail requests to establish recency.

Discovery provenance is retained on `MediaItem.discoverySources`. Hero source
labels are a per-profile option, off by default, while Simkl's required
"Simkl Trending" credit always appears when its optional feed contributes.
General provider credits remain in Attributions & Licenses.
Per-source item links in `MediaItem.discoveryURLs` survive
deduplication independently of the title's single metadata-provenance entry.
iOS exposes those links through visible attribution badges; tvOS shows enabled
credits without adding a focus stop. The Simkl mark is the official
[provided PNG](https://us.simkl.in/img_favicon/v2/favicon-192x192.png).
Keep credits and links when binding a result to a library copy or merging
duplicates. TVmaze data is CC BY-SA; Simkl's feed attribution, registered app
parameters, and existing login/sync integration requirements apply. See the providers' current
terms before changing their use:

- [TMDB API FAQ](https://developer.themoviedb.org/docs/faq)
- [Simkl API and feed terms](https://api.simkl.org/api-rules)
- [AniList API terms](https://docs.anilist.co/guide/terms-of-use)
- [TheTVDB API licensing](https://thetvdb.com/api-information)
- [TVmaze API and licensing](https://www.tvmaze.com/api)

## Invariants

- **No required user subscription or user-supplied key.** App credentials and
  keyless endpoints coexist; missing credentials disable only their provider.
- **No UI imports.** Provider and composition logic stay outside the shells.
- **Failures stay explicit.** Existing enrichment is best-effort. Discovery
  adapters throw; their coordinator logs a source failure and retains cached
  results rather than treating a timeout as an authoritative empty catalog.
- **Bounded work.** Discovery consumers have a 15-second response budget.
  Shared loads expire after 20 seconds without renewing when another consumer
  joins; late completions cannot overwrite replacement work. Retired
  work still occupies admission until it actually returns.
- **Cached aggressively.** Resolved URLs persist across launches in
  `MetadataDiskCache`; decoded bytes are cached by `CoreUI`'s
  `ArtworkImageCache`.
- **Policy-aware caches.** Feed keys include the release-window policy.
  `HeroConfigurationKey.discoveryContentVersion` retires pre-policy Featured
  seeds and candidate pools, so an offline fallback cannot restore the old
  all-time feed after upgrading.

## Where to look first

- `ArtworkRouter.swift` — content classification + fallback chains.
- `MetadataProviderConfig.swift` — how the optional TMDb tier is wired.
- `ContentClassification.swift` — the anime / movie / tvShow / music
  decision.
- `docs/METADATA_ARCHITECTURE.md` — the full architectural story.
