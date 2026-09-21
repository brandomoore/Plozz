# Native Silo provider

Plozz connects to Silo's native `/api/v2` API, not its separate Jellyfin
compatibility listener. Enter the web application's base URL, approve the
device code in Silo, then select the household profile. PIN-protected profiles
require server verification. Each connection retains that server profile's
library restrictions and watch history; Plozz profiles choose which connections
they use.

## Contracts

- Native device-pairing protocol 2 and playback protocol 3. Check capability
  documents rather than guessing from a server version or its emulated Jellyfin
  identity. Silo is pre-release; contracts were checked against server revision
  `cbc13de10f4af28762be6777cab2f75403eade58`.
- Access tokens, rotating refresh tokens and profile-verification proofs live in
  the account Keychain entry. The raw PIN is never persisted. Refresh is
  single-flight and compare-and-set against the original login revision.
  An uncertain refresh requires sign-in rather than replaying a possibly spent
  token. Silo logins are not cloned through device-to-device credential transfer
  or iCloud Keychain; another device pairs independently.
- Catalog requests use native cursor pagination and explicit `seek` windows.
  Progress is read through the paged, library-scoped progress endpoint; Home's
  native next-up selections are corroborated before inclusion in a restricted
  library view. Versions use the original Silo file ID.
- Playback advertises the capabilities of Plozz's existing players and requests
  a fixed source file. Signed stream and subtitle URLs stay behind in-memory,
  account/revision-bound locators. The provider accepts original HTTP or HLS
  plans with a source-aligned seekable timeline; incompatible plans are released,
  not played with an incorrect clock. Progress samples are sequenced and stop
  requests carry an idempotent stop identifier.
- Watched state and the native Silo watchlist write back to Silo. Batched resume
  synchronization checks each result, not only HTTP success.

## Offline downloads

On iOS/iPadOS, downloads use Silo's managed device registry, native capability
checks, revision guards and authenticated file delivery. They do not reuse a
playback grant or open a player session. Original quality keeps the source when
the server can deliver it; Silo may prepare a compatibility artifact. Reduced
qualities choose an advertised bitrate preset no higher than the requested cap.
Reduced Silo copies use the server-selected audio track; Original preserves
embedded tracks.

Prepared download IDs and revisions are persisted before byte transfer, so
retry/relaunch reconciles the server registry before creating anything. Background
and speed-limited transfers attach current bearer/profile/device headers and
reject cross-origin credential redirects. Offline manifests and supported text
sidecars are pinned beside the media. Completed files remain playable without a
server connection. Completion reports and server-registry removals survive
temporary disconnection in the durable local download state.

The Silo server icon is the SVG supplied by the maintainer, used only to identify
the compatible server. Plozz remains independently branded.

Upstream contract references:
- [Authentication](https://github.com/Silo-Server/silo-server/blob/cbc13de10f4af28762be6777cab2f75403eade58/docs/auth-api.md)
- [Playback](https://github.com/Silo-Server/silo-server/blob/cbc13de10f4af28762be6777cab2f75403eade58/docs/playback-api.md)
- [Downloads](https://github.com/Silo-Server/silo-server/blob/cbc13de10f4af28762be6777cab2f75403eade58/docs/downloads-api.md)

Tests: `ProviderSiloTests`, `SiloCredentialRotationTests`,
`ManagedDownloadLifecycleTests`, and the existing shared playback/download suites.
