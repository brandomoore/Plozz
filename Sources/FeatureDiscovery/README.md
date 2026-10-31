# FeatureDiscovery

LAN auto-discovery of Jellyfin and Emby servers (Plozz's "drop the box on the
network and Plozz finds it" experience) plus the server-picker UI and
last-server persistence. Plex relies on `plex.tv` for server enumeration
in `ProviderPlex`, not LAN UDP.

## Responsibility

- `ServerDiscovering` — the platform-agnostic protocol; an
  `AsyncStream<MediaServer>` of unique servers, capped by a timeout.
  Lives in its own portable file so view-models can depend on the
  abstraction without importing the `Network`-based implementation.
- `JellyfinDiscoveryParser` — parses the shared Jellyfin/Emby UDP discovery responses
  into `MediaServer` value types (independent of the transport so it's
  unit-testable on Linux).
- Concrete Apple-platform implementation — uses `Network` framework UDP
  multicast/broadcast on tvOS to find servers on the local subnet.
- `ServerPickerView` + `ServerPickerViewModel` — the focusable tvOS UI
  that streams discovered servers, supports manual URL entry, validates
  the URL via the appropriate provider, and surfaces clear loading /
  empty / error states.
- `LastServerStore` — remembers the most-recently-used server so relaunch
  jumps straight to sign-in instead of re-discovering.

## Invariants

- **No tokens stored here.** Only non-secret server metadata
  (`MediaServer`).
- **Every provider represented.** Server selection must produce a
  `MediaServer` whose `provider: ProviderKind` is set correctly — the
  rest of the app branches on that.
- **Network errors degrade visibly.** Discovery timing out is normal and
  yields the manual-URL fallback path, not an error toast.
- **Manual Jellyfin/Emby entry resolves before sign-in on both platforms.**
  Bare hosts and HTTP addresses try HTTPS first, then the conventional HTTP
  address and port 8096 when no port was entered. Explicit ports and proxy
  paths are preserved; explicit HTTPS never falls back to HTTP. At most three
  credential-free public-info requests use the short discovery timeout.
  Certificate/client-certificate rejection stops discovery rather than
  downgrading. Cancellation and rejected access stop further attempts.
  Only the verified server address is passed to password/Quick Connect sign-in
  and remembered. UDP announcements, saved-account routing, Plex and Silo
  retain their existing address rules; this does not add background polling.
- **Setup evidence is explicit-submission only.** Jellyfin/Emby validation records
  each attempted candidate and outcome in `ServerConnectionDiagnostics`, including
  successful fallback. Reports retain HTTP/HTTPS, port/prefix presence, timing,
  response format/status, and numeric transport errors, never addresses or payloads.
  Background reachability checks do not fill the journal. Connection policy,
  TLS checks, retry limits, and timeouts are unchanged by instrumentation.
- **Compiles without UI.** The parser + abstraction live in plain Swift;
  views are guarded by `#if canImport(SwiftUI)`.

## Where to look first

- `ServerDiscovering.swift` — the protocol every consumer should use.
- `JellyfinDiscoveryParser.swift` — UDP payload → `MediaServer`.
- `ServerPickerViewModel.swift` — the orchestration & validation loop.
