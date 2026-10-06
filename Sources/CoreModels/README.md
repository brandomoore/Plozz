# CoreModels

The Foundation-only, **zero-dependency** core of Plozz. Defines the domain
language every other module speaks.

## Responsibility

- Domain value types: `MediaItem`, `MediaLibrary`, `MediaServer`,
  `UserSession`, `Account`, `Profile`, `MusicTrack`, `Person`, etc.
- The dual-provider abstraction: `MediaProvider` protocol, `ProviderKind`,
  `ProviderRegistry` / `ProviderResolving`, `ResolvedAccount`.
- Cross-cutting UI state: `LoadState`, `AppError`.
- Shared decode/encode helpers: `JSONDecoder.plozz`, `JSONEncoder.plozz`.
- Subtitle behaviour + appearance model: `SubtitleBehavior`, `SubtitleStyle`,
  plus the neutral `SubtitleColor` / `SubtitleEdgeStyle` / `SubtitleMode` primitives.
- Profiles persistence contract: `ProfilePersisting`, `ProfileStore`,
  `ProfilesModel`, plus the Plex Home-user mapping (`PlexHomeUser`).

## Invariants

- **No SwiftUI / AVKit / UIKit imports.** This module compiles on Linux so
  pure-logic tests can run there. UI lives in `CoreUI` and feature modules.
- **Never hold secrets.** Tokens are owned by `FeatureAuth` (Keychain). Types
  here (e.g. `Account`, `Profile`) carry only non-secret metadata.
- **Provider-agnostic.** No type here may assume Jellyfin- or Plex-specific
  behavior; the only provider seam is `MediaProvider`.
- **Collections are server-defined groups, not alternate title sources.**
  Collection identity stays scoped to the owning account and item ID, even when
  two groups share a catalogue collection ID or physical server. Library
  collection discovery uses `collections(in:page:)`, advertised through
  `.libraryCollections`; `collectionMembers(of:page:)`
  is separate and preserves server membership/order rather than the grid's sort.

## Public surface, at a glance

| Concept | Entry point |
| --- | --- |
| Provider abstraction | `MediaProvider`, `ProviderKind`, `ProviderRegistry` |
| Domain models | `MediaItem`, `MediaLibrary`, `MediaServer`, `UserSession` |
| Multi-account | `Account`, `ResolvedAccount`, `AggregatedLibrary` |
| Profiles | `Profile`, `ProfileStore`, `ProfilesModel`, `PlexHomeUser` |
| UI state | `LoadState`, `AppError` |
| Subtitles | `SubtitleBehavior`, `SubtitleStyle` (rendered by `FeaturePlayback`) |

## Watch-state replay identity

New shell watch intents carry `WatchMutationServerScope`: the originating Plozz
profile and stable account/server/user identities, including the existing Plex
Home binding. It contains no credentials or process-local token revisions.
Runtime validation must also confirm that the selected Plex viewer's credential
is actually installed before resolving its provider.

The reconciler uses the existing delivery-authorization checks before dispatch.
An unavailable server viewer defers the intact mutation without consuming its
retry budget; it can resume when that viewer returns, including after relaunch.
Server-user scope separates coalescing/clocks, live-session guards and UI replay.
It does not replace the separate, deliberately non-restorable authorization
requirement used for consent-gated library-channel completion.

Scoped mutations use a version-2 ID envelope so older readers reject them rather
than ignore an unfamiliar identity field. Removing or altering that requirement
also fails decoding. Legacy unscoped mutations remain readable under their
existing behavior. They are not retroactively stamped with the current
server-user scope: their historical viewer cannot be reconstructed.

## Where to look first

- `MediaProvider.swift` — the protocol that defines every backend.
- `ProviderRegistry.swift` — how features resolve a provider from a session.
- `AppError.swift` — the single error currency used everywhere.
