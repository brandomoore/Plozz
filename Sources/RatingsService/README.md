# RatingsService

External-ratings enrichment for `MediaItem`s. Adds rating badges (IMDb, RT,
Metacritic, AniList) on top of any score the user's own server already
provides. External services are optional quality improvements, not a prerequisite
for browsing or playback.

## Responsibility

- `ExternalRatingsProviding` — the small `async`, non-throwing protocol
  every source conforms to: `func ratings(for: MediaItem) async -> [ExternalRating]`.
  Failures degrade to `[]` so the detail screen is never blocked.
- `AniListRatingsProvider` — **keyless** AniList GraphQL community score
  for anime titles. The default-on, no-config source.
- `OMDbRatingsProvider` — optional IMDb / Rotten Tomatoes / Metacritic
  enrichment for movies & TV. Requires the user's own OMDb API key
  (BYOK) — disabled when absent.
- `DisabledRatingsProvider` — no-op conformer used so call sites can
  inject a non-optional provider.
- `RatingsCache` — persistent disk cache of resolved rating sets per item
  so a library is enriched once and reused across launches.
- `RatingsServiceConfig` + `RatingsServiceFactory` — composition helpers
  that build the appropriate composite provider for a given config (e.g.
  AniList-only vs AniList + OMDb).

## Invariants

- **Non-throwing at the seam.** Missing key, absent external id, or
  network error always returns `[]`.
- **Configured sources coexist.** AniList is available without a key; TMDB and
  OMDb activate when configured. No permanent keyless-first ordering is implied.
- **No UI imports.** Pure logic, Linux-portable.
- **No secrets logged.** API keys are never written to logs.

## Where to look first

- `ExternalRatingsProviding.swift` — the protocol & `DisabledRatingsProvider`.
- `RatingsServiceFactory.swift` — how `AppShell` composes the active
  provider set.
- `RatingsCache.swift` — persistent enrichment cache.
- `AppRuntime/PublicMetaDBRatingsProvider.swift` wraps the ordinary provider with
  an opt-in PublicMetaDB overall community score. It preserves the cache-only
  Home contract, keeps profile/key-scoped results outside the shared disk cache
  and leaves other source badges intact when PublicMetaDB is unavailable.
