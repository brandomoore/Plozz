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

## Where to look first

- `PlexProvider.swift` / `PlexClient.swift` — the `MediaProvider` entry.
- `PlexAuthClient.swift` + `PlexPinFlow.swift` — sign-in & Home-user PIN.
- `PlexConnectionResolver.swift` — how a usable base URL is chosen.
- `PlexDeviceProfile.swift` — what the server is told this device can play.
