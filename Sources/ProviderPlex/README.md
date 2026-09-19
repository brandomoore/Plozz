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

Movie/show sections expose a derived, section-scoped Collections library. It
uses the same library grid and collection detail as Jellyfin/Emby, not a separate
Plex selector. IDs (`plex:collections:<sectionID>`) identify collection *lists*;
they must never be sent to a metadata/children endpoint or interpreted as item IDs.

Discovery pages `/library/sections/{sectionID}/all?type=18`. Collection membership
uses `MediaProvider.collectionMembers(of:page:)`, backed by paged
`/library/metadata/{ratingKey}/children`, with no type or sort override. That same
endpoint serves static and smart collections and preserves their server order.
Detail loading reads bounded pages, publishes only a complete result, and exposes
failures separately from an empty collection with a retry action on both platforms.

Protocol references: python-plexapi
[`LibrarySection.collections` / `search`](https://github.com/pkkid/python-plexapi/blob/master/plexapi/library.py),
[`SEARCHTYPES`](https://github.com/pkkid/python-plexapi/blob/master/plexapi/utils.py),
and [`Collection._items`](https://github.com/pkkid/python-plexapi/blob/master/plexapi/collection.py).

Tests: `PlexCollectionBrowsingTests` and shared `CollectionDetailBrowsingTests`.

## Where to look first

- `PlexProvider.swift` / `PlexClient.swift` — the `MediaProvider` entry.
- `PlexAuthClient.swift` + `PlexPinFlow.swift` — sign-in & Home-user PIN.
- `PlexConnectionResolver.swift` — how a usable base URL is chosen.
- `PlexDeviceProfile.swift` — what the server is told this device can play.
