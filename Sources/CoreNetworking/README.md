# CoreNetworking

The shared HTTP transport and logging primitives. Lives between `CoreModels`
and every provider/feature that talks to a remote server.

## Responsibility

- `HTTPClient` protocol + `URLSessionHTTPClient` default conformer:
  - serializes an `Endpoint` against a `baseURL`,
  - returns `(Data, HTTPURLResponse)` or throws `AppError`,
  - exposes a typed `decode(_:from:baseURL:)` convenience.
- `Endpoint`: a transport-agnostic request description (method, path, query,
  headers, body) — providers build these, not raw `URLRequest`s.
  Redirects can follow normally, stay within the original origin, or use
  `doNotFollow` to return the original redirect response and Location header.
  The last policy blocks same-origin redirects too; use it for header-only
  resolvers rather than fetching a human-facing destination.
- `HTTPResponseDiagnostics`: opt-in task-local decode and paging evidence for library
  failures. It preserves the existing thrown `AppError` and fallback contracts,
  discards evidence when the enclosing operation succeeds, and retains at most
  four responses and four paging failures per failed operation. Paging records
  contain only closed-vocabulary stages/reasons and numeric offsets/counts.
  Only status, byte count, payload shape,
  failure kind, expected value type and allowlisted coding-path fields survive.
  Providers label known routes with closed-vocabulary values; the transport
  never copies URLs, query parameters, raw keys, payloads or decoder descriptions
  into the report. No additional requests or successful-response parsing is added.
- `PlaybackPreparationDiagnostics` captures failed version preparation into the
  existing recent-activity log (`format=plozz-preparation-1`). Each attempt records
  its provider/operation, up to four request timings with configured timeout
  budgets, status, byte count, response-format category and numeric URL error,
  plus bounded decode and inventory-validation evidence. Address-discovery probes
  are distinguished from item-detail and source-inventory requests. Successful attempts
  discard their evidence; cancellation is not reported as a failure. There are
  no additional requests, retries, timeout changes or raw response retention.
  The record contains no server address, credentials, item/account ID or title.
  Users can reproduce once and use **Help & Diagnostics → Send Recent Activity
  to Developer** with their existing crash-reporting consent. This is an explicit
  user-submitted attachment, not a new automatic Sentry event or upload permission.
  Failures also retain up to 32 typed records in memory for 48 hours, so the
  privacy-filtered sender keeps request/decode/validation evidence without
  parsing the free-form log. Attempt identifiers become fresh report-local aliases.
- `ServerURLNormalizer`: turns user-typed addresses (with/without scheme,
  trailing slash, port) into a well-formed `URL` for both Jellyfin and Plex.
- `ProviderIconLoader`: best-effort, origin-only `/favicon.ico` requests for
  provider marks. It strips user information, paths, query strings and fragments,
  uses no credential/cookie storage, rejects redirects and authentication,
  and bounds response bytes/time with a memory-only HTTP cache.
- `PlozzLog` (and the `PlozzLogger` category facade): the **single** logging
  entry point. Backed by `OSLog` on Apple platforms, no-op on non-Apple
  hosts. Must never log tokens, Quick Connect secrets, or full
  `Authorization` headers.

## Invariants

- **Approved address routing is bounded and demand-driven.**
  `ServerAddressResolver` shares concurrent credential-free probe sweeps and gives
  local routes a 300 ms head start. Providers use the short discovery timeout;
  successful choices are reused for 30 seconds, then reconsidered on demand.
  Failed connections invalidate the choice immediately. No network monitoring or
  background polling is added. Retry sweeps exclude the failed address even if
  another caller is resolving concurrently.
  Route edits update the existing resolver and fence superseded probe results.
  Ordinary successful traffic confirms reachability without extending the
  selection's lifetime indefinitely; returning to LAN remains discoverable.
  `ServerAddressHTTPClient` blocks cross-origin redirects and retries a failed
  GET once on another approved route, never an uncertain mutation. Probe-capable
  GETs opt out with `Endpoint.allowsAutomaticAddressRetry = false`: a timeout
  cannot establish that the first server operation stopped. Authentication
  failures are not connection failures. A preflight resolution failure preserves
  proof that a one-time exchange was not transmitted.
  `AlternateAddressHTTPIntegrationTests` uses loopback TCP listeners and the
  production URLSession transport for outages, redirects, cancellation,
  transmitted mutations, proxy paths, and retained-client address edits across
  all four managed providers. These controlled protocol fixtures are not live
  upstream-server interoperability tests.
- **Secret-safe by default.** `Authorization`, Quick Connect codes, Plex
  tokens, etc. must not reach `PlozzLog` — pass redacted strings or omit.
- **Provider-agnostic.** No Jellyfin/Plex specifics here. Provider modules
  layer their own headers/DTOs on top.
- **Throws `AppError`, not transport errors.** Non-2xx responses map onto
  `AppError` so feature code only ever speaks one error currency.
- **Platform-portable.** Compiles on Linux for `swift test` — Foundation
  only, no UIKit/SwiftUI.

## Where to look first

- `HTTPClient.swift` — the transport seam every provider depends on.
- `Endpoint.swift` — request shape & query/body helpers.
- `PlozzLog.swift` — how to log without leaking secrets.
- `ServerURLNormalizer.swift` — how user-typed server addresses are accepted.

## IPTV playlist compatibility

`M3UPlaylistParser` is shared by account-backed IPTV imports and the standalone
Live TV loader on iOS/iPadOS and tvOS. It accepts playlist contents, not a
particular hostname, filename extension, or MIME type.

| Input convention | Handling |
| --- | --- |
| Extended M3U/M3U8 and plain absolute HTTP(S) lists | Supported, including headerless `EXTINF` entries, UTF-8 BOM, Latin-1 fallback, and incremental input. |
| Directive and attribute casing | Recognized without changing case-sensitive URLs, tokens, names, or header values. |
| XUI `EXT-X-SESSION-DATA` and unknown comments | Ignored as metadata; an arbitrary `EXT-X-` prefix is not enough to declare HLS. |
| HLS master/media and low-latency directives | Kept out of the channel catalogue. URL loaders can treat recognized playable HLS as one stream; local manifest files are not channel lists. |
| Channel metadata | `tvg-id`, `tvg-name`, `tvg-chno`, `tvg-logo`, country/language, semicolon groups, and persistent `EXTGRP` are supported. `channel-id`, `channel-number`, and `logo` fill absent primary metadata. Guide aliases do not change saved channel identities. |
| Request headers | Inline attributes, quoted/unquoted `EXTVLCOPT`, and percent-encoded pipe suffixes retain their existing precedence and entry scoping. Authentication headers require the account-backed path; invalid headers and credential-bearing redirects remain restricted. |
| Guide declarations | `url-tvg`, `x-tvg-url`, and `tvg-url`, multiple guides, and relative URLs are supported. |

Compatibility was compared with [VLC's M3U importer](https://github.com/videolan/vlc/blob/master/modules/demux/playlist/m3u.c)
and [HLS detection](https://github.com/videolan/vlc/blob/master/modules/demux/hls/HLSManager.cpp),
[Kodi IPTV Simple](https://github.com/kodi-pvr/pvr.iptvsimple/blob/Piers/src/iptvsimple/PlaylistLoader.cpp),
[Jellyfin's M3U parser](https://github.com/jellyfin/jellyfin/blob/master/src/Jellyfin.LiveTv/TunerHosts/M3uParser.cs),
and [iptv-playlist-parser](https://github.com/freearhey/iptv-playlist-parser/blob/master/src/index.js).
These are interoperability references, not dependencies or copied implementations.

This is not full feature parity with those players. UDP/RTP/RTSP, local stream
paths, fractional channel numbers, provider-specific catch-up templates and
time shifts, Kodi inputstream/DRM properties, and browser-based stream extraction
are not enabled by accepting M3U metadata.

`GoogleDrivePlaylistURL` maps Google's HTTPS file viewer/share links (`/file/d/`,
including `/file/u/<account>/d/`, and `/open?id=`) and legacy `/uc?id=` downloads
to `drive.usercontent.google.com/download`. Account import, authentication,
refresh and standalone playlist loading use the same resolver. The original
saved address and channel identities are unchanged; origin-scoped account
headers are not forwarded to the download host, and redirect policies are not
relaxed. Resource keys and explicitly supplied confirmation parameters are
preserved. Unknown hosts/routes, ambiguous identifiers and unrecognized query
parameters are left untouched.

Drive must still return the actual public file: sign-in, quota, or confirmation
HTML is not a playlist. Imports do not reuse browser cookies, scrape HTML forms,
add confirmation grants or bypass access warnings. File imports use the same
M3U parser and need no Drive-specific handling.

Regression coverage lives in `LiveTVPlaylistParserTests` and `ProviderIPTVTests`,
including a synthetic 6,185,484-byte file import, URL import without opening
media streams, and rollback when HLS is discovered after staged entries.
`GoogleDrivePlaylistURLTests`, `LiveTVSourceLoaderTests` and
`IPTVGoogleDriveTests` cover Drive URL forms, header isolation, refresh,
conditional requests and HTML refusals. The latter also has an opt-in live
comparison: place captured M3Us and a JSON array of `{ "name": "...", "url":
"https://...", "file": "sample.m3u" }` records in
`.build/iptv-drive-corpus/manifest.json`, then run `ProviderIPTVTests`. It compares
local-file, account-URL and standalone-URL channel imports without fetching
streams, artwork or guides. Without that ignored manifest, it skips network
access. Never commit captured playlists or their credentials.
