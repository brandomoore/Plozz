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
- `DetailMetadataResolver` — fills missing descriptions, cast, directors, writers, producers, composers, studios,
  genres and confirmed title facts after a provider's full detail response, using the same pipeline on
  tvOS and iOS/iPadOS. Cast and crew are separate gaps: an existing cast does not
  hide missing directors, and adding cast never erases server crew. Source
  changes and cancellation discard stale results. Household source preferences
  and the current TMDB credential still apply.
  TMDB credits use the movie, series, season or episode endpoint as appropriate;
  cast uses explicit billing order before deduplication and the upstream limit,
  retaining response order for ties or absent billing and placing guest stars last.
  Producer/executive-producer and composer gaps use the same scoped credits request
  and preserve server-supplied groups; general department credits are not promoted.
  The response retains scoped credits as matching evidence, including
  roles already supplied by the server. A unique name plus an overlapping role on
  that same title can join native and TMDB portraits through `creditIdentity`;
  ambiguous names and conflicting identities stay separate. This display-only
  link never replaces native person IDs, biography handles, or server role data.
  an episode never inherits a whole show's directing/writing credits. Exact
  external IDs take precedence and a failed ID lookup never falls back to a
  different title. A title-only match must agree on title and any supplied year.
  Season and episode cache keys remain distinct from the series and each other.
  Child detail queries promote only explicit series IDs for show-level providers,
  retaining season/episode numbers for scoped credits; an episode's own ID or
  title never stands in for an unidentified show.
  Before accepting fields or threading IDs, the pipeline rejects live or cached
  responses that contradict a known, well-formed external ID. Namespace aliases
  cannot override authoritative IDs; rejected matches fall through to the next
  source without contributing metadata. Cache keys include the complete known
  identity, so adding a stronger ID cannot reuse metadata resolved for an earlier,
  less-identified query, even when a provider returns no IDs with its fields.
  TMDB transport failures report provider health, rather than caching an outage
  or revoked credential as an authoritative absence of credits.
  Movie/series original language and series production status/catalog totals
  use the existing identity-checked TMDB detail response, with sourced-field
  provenance and gap-only merging. Discover requests the same fields. Unknown
  statuses and nonpositive totals remain absent; local episode counts, empty
  schedules and audio-selection heuristics are not evidence for these facts.
  Series facts never propagate to seasons/episodes or personal-video mode.
  Artwork, playable identity, file/stream facts and Common Sense are not filled
  by this resolver.
  Detail pages pass the effective UI/profile locale to text enrichment, including
  missing-text resolution for external/discovery details.
  TMDB detail, episode, credits and matching requests carry that language;
  when a localized title search misses an English release alias, identity lookup
  retries the English search with the same exact-title/year checks. Detail text
  still comes from the requested-language endpoint.
  Provider-result keys and detail snapshots separate language variants. Query
  copies retain language when promoting series IDs or threading matched IDs.
  Providers without requested-language text support cannot fill descriptions,
  genres, titles or taglines for non-English requests; their artwork and other
  capabilities remain available. Missing localized text stays absent rather than
  silently falling back to known English-only text. Server/NFO text is never
  translated or replaced. Child descriptions use scoped providers, not a series
  description returned by an unscoped adapter. The independent English-only
  `OverviewRouter` no longer races library-detail enrichment.
  Its keyless English Wikipedia overview fallback now participates in the same
  ordered pipeline for movie/series gaps; Wikipedia artwork remains idle-only.
  Retained detail models update their language in place, discard late old-language
  work and refill gaps from native metadata, not previously enriched text.
  This does not translate existing server metadata or change the language of
  discovery-feed seeds or share-scanner metadata. Selecting French cannot guarantee
  French descriptions when the server or external service has no such text.
- `HeroDiscoveryProviding` — separate candidate-feed seam for TMDB,
  AniList, TheTVDB, and TVmaze. It does not call Trakt.
- `HeroDiscoveryService` — bounded, coalesced public-feed reads, provider-level
  caching/backoff, and interleaved deduplication. Per-profile watch state and
  library ownership are applied afterward, never stored in the public-feed cache.
- `MetadataDiscoveryHTTPClient` — identifying User-Agent, explicit HTTP/decode
  failures, bounded request admission, and response-size checks for discovery.

## Community skip markers

`CommunitySkipMarkerService` uses IntroDB (`introdb.app`) and TheIntroDB
[`GET /v4/media`](https://theintrodb.org/openapi.yaml), not the retired v3
endpoint. Server markers retain priority by segment kind on TV and mobile.
Lookups remain optional and cancellation prevents late publication.
Both databases use `MetadataHTTP`, which sends the identifying
`User-Agent: Plozz/1.0 (+https://github.com/thatcube/Plozz)` header.
Request-level tests cover that header on TheIntroDB movie and episode lookups.

TheIntroDB prefers TVDB identity, then TMDB/IMDb when ordering is unspecified.
An episode's own TVDB ID is sent as `tvdb_episode_id`, never as the show's ID.
Series IDs and explicit episode ordering come from the owning provider.
Known TVDB orders always retain `mapping`, including with an episode ID, and
use TVDB or IMDb addressing, never TMDB. TMDB-numbered episodes require TMDB
addressing even when an episode ID is available. Without a compatible series
identifier, or with an explicitly unknown order, no request is sent. Missing
ordering retains the previous default behavior. IntroDB has no conversion
parameter, so known non-aired orders bypass it.

These constraints reflect the deployed v4 behavior, not just its published
contract. On 2026-10-17, Futurama (`tvdb_id=73871`, `imdb_id=tt0149460`,
`tmdb_id=615`), alternate S7E1 "Rebirth" (`tvdb_episode_id=1051911`), returned
another episode's intro without `mapping=alternate`, despite the episode ID.
TVDB and IMDb addressing with that mapping returned Rebirth's intro/credits;
TMDB addressing ignored the mapping. An episode ID is therefore only a hint,
not permission to change numbering systems or omit conversion.

Finite positive runtime is sent as `duration_ms` to select the nearest release
cluster; unknown runtime is omitted, not sent as the special zero-duration
group. The optional episode-name hint is omitted for TMDB addressing, where the
API ignores it. Movies never send TV-only parameters. Combined-episode files
do not use single-episode community markers. Empty/episode-list/version-list
responses yield no timestamps; open ends need a known runtime, and negative,
reversed or out-of-runtime segments are discarded.

TheIntroDB arrays represent separate intervals, not competing candidates to
collapse into one late window. IntroDB's explicit `post_credits` interval is
non-skippable: it can shorten or split that source's overlapping credits, never
extend them. Malformed or zero-start scene reports are ignored without losing
valid markers. A finite credits end alone does not establish a scene or permit
extending the range. Server-first, per-kind source precedence and optional
fallback requests remain unchanged; marker count is not a confidence score.

Real-media checks against Plex, Jellyfin, both community APIs, and decoded
ending frames found separate credits/scene windows in Iron Man, Deadpool and
The Avengers, and ordinary closing credits in Inception. They also found
misplaced server markers, shifted community timing, and a zero-start community
scene. These checks validate range-preserving behavior, not universal marker
accuracy or compatibility between different releases of a title.

## Discovery sources

The dedicated Discover destination uses `TMDbDiscoveryProvider.browse` when
Seerr is not configured. Its five paginated feeds are separate from Home's
recent-release selection: upcoming movies and first series premieres retain
future dates. Public candidates do not prove local playback access.
`AppRuntime.DiscoverRuntime` shares Home's live library-identity verification
before the page applies Available now or Hide watched. These profile-specific
results are never written to the public metadata cache.

Featured defaults to a two-calendar-year release window. Full dates use a rolling
cutoff; year-only metadata retains the boundary year rather than inventing a
release day. Undated titles do not qualify on popularity alone. This policy does
not filter Continue Watching, Watchlist, Recently Added, or Random library picks.

TMDB combines weekly movie/TV trends, recent popular movie/TV discovery, and
currently airing series in five requests. All-time top-rated and watchlist-based
recommendation feeds are not used. Older series qualify only with current airing
evidence: TMDB's next-seven-day feed, AniList's next episode, or TVmaze's
today/tomorrow season premieres. Their original release years remain unchanged.
AniList supplies seasonal/trending anime and is opt-in. TheTVDB supplies
current-year catalog browsing, with response dates checked against the same
release policy. No provider adds per-title detail requests to establish recency.

Discovery provenance is retained on `MediaItem.discoverySources`. Hero source
labels are a per-profile option, off by default.
General provider credits remain in Attributions & Licenses.
Per-source item links in `MediaItem.discoveryURLs` survive
deduplication independently of the title's single metadata-provenance entry.
iOS exposes those links through visible attribution badges; tvOS shows enabled
credits without adding a focus stop.
Keep credits and links when binding a result to a library copy or merging
duplicates. TVmaze data is CC BY-SA. See the providers' current terms before
changing their use:

- [TMDB API FAQ](https://developer.themoviedb.org/docs/faq)
- [AniList API terms](https://docs.anilist.co/guide/terms-of-use)
- [TheTVDB API licensing](https://thetvdb.com/api-information)
- [TVmaze API and licensing](https://www.tvmaze.com/api)

SIMKL Trending is not a discovery source. Older profile selections discard its
retired identifier without resetting other settings, and the discovery content
version invalidates previously cached hero pools. SIMKL watchlist and
watch-history integrations remain independent and unchanged.

When Seerr is configured, before publishing external hero titles,
`HeroMetadataEnricher` resolves missing
TMDB request identities through the same cached metadata pipeline as detail
pages. This requests only the identity field, with at most four concurrent
lookups, and never promotes an external title to a playable library item.
Already identified, owned, unsupported, and personal-media items skip this work.

## Invariants

- **Single-image logo selection.** TMDB logos include SVG-origin artwork through
  the CDN's PNG rendition at the existing `w500` size. Language and rating choose
  one logo in a single pass over the usual images response; there is no extra
  endpoint, candidate-image download, SVG renderer, or contrast-analysis pass.
  Better-ranked originals can improve dark-background legibility, but metadata
  ranking does not guarantee contrast. Server artwork and configured source
  priority remain authoritative. External logos prefer the active app language
  (including profile overrides), then untagged artwork, English, and other
  languages; ratings break ties. Regional language tags use the image API's
  language code. Logo URL and presentation caches include that language, so
  switching languages cannot reuse a previously selected English logo. This
  versions only logo keys, not posters/backdrops, and never translates or
  replaces server titles, taglines, or synopses.
- **Portrait hero artwork is opt-in.** Compact mobile heroes prefer a
  language-neutral portrait, then a language-neutral landscape, then usable
  fallback artwork. TMDB and TheTVDB rank the image lists already returned by
  their usual hero request; there is no OCR, additional endpoint, or image-download
  fan-out. Neutral-language metadata is evidence, not a guarantee of textless
  pixels. Providers without this metadata retain their existing hero lookup.
  Hero-specific URL cache keys leave ordinary posters and landscape heroes
  unchanged. Live provider preferences, library-first settings, series identity,
  and the separate overlaid hero logo remain in force.
  Dedicated server square backgrounds take precedence on compact Home and detail
  heroes under Recommended or Library artwork preferences. They are not poster
  substitutes; an explicit online preference still uses this portrait lookup first.
- **Landscape title artwork is a separate capability.** Artwork-only landscape
  cards may request `landscapeCardURL` when native title art is absent. TMDB
  selects language-tagged backdrops from its existing images response, preferring
  the requested language, then English, then vote order. Untagged backgrounds
  are not title-art candidates. Language metadata is a signal, not OCR.
  Unsupported providers return no title-art result; ordinary hero ranking and
  logos are unchanged. Cache keys isolate this role and language, and live
  provider enablement/order still apply. Logo-composited cards request clean
  backgrounds instead, avoiding an intentional second title over this artwork.
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
