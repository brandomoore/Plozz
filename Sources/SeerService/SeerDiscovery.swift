import Foundation
import CoreModels
import CoreNetworking

/// A Seerr instance found at a known URL or on the local network.
public struct DiscoveredSeerServer: Sendable, Hashable, Identifiable {
    /// Validated base URL, including any reverse-proxy path — ready to hand straight
    /// to ``SeerConfig/init(baseURL:apiKey:userId:)``.
    public let baseURL: URL
    /// Seerr's reported version (from `/api/v1/status`), for display only.
    public let version: String?
    public let loginMethods: SeerLoginMethods?

    public init(baseURL: URL, version: String?, loginMethods: SeerLoginMethods? = nil) {
        self.baseURL = baseURL
        self.version = version
        self.loginMethods = loginMethods
    }

    public var id: String { baseURL.absoluteString }
}

/// Finds Seerr servers at known URLs and, optionally, on the local network.
///
/// Unlike Jellyfin (a UDP broadcast responder, see `UDPServerDiscovery`) or
/// SMB shares (Bonjour's `_smb._tcp`), Overseerr/Jellyseerr has **no announce
/// protocol at all** — a stock install just binds a port with nothing
/// listening for probes. So discovery here means going and looking:
///
/// 1. Probe any `hostHints` first (already-known Jellyfin/Plex/Emby server
///    hosts, if the caller has them) — Seerr is very commonly co-hosted on
///    the same box as the media server it manages, so this is often an
///    instant, single-request hit.
/// 2. Fall back to a bounded unicast sweep of the local subnet (see
///    ``LocalSubnetScanner``), probing Seerr's default port.
///
/// Each candidate is confirmed by its unauthenticated `GET /api/v1/status` —
/// no API key needed to *find* a server, only to connect to one.
public final class SeerDiscovery: Sendable {
    public struct Request: Sendable {
        public var urls: [URL] = []
        public var hostHints: [String] = []
        public var includesSubnet = true

        public init(urls: [URL] = [], hostHints: [String] = [], includesSubnet: Bool = true) {
            self.urls = urls
            self.hostHints = hostHints
            self.includesSubnet = includesSubnet
        }
    }

    private let http: HTTPClient
    private let port: Int
    private let concurrency: Int
    /// Produces the subnet-sweep candidate list. Defaults to the real local
    /// LAN via ``LocalSubnetScanner``; injectable so tests can supply a fixed
    /// list instead of depending on the test machine's actual interfaces.
    private let subnetHosts: @Sendable () -> [String]

    /// How long Foundation allows a single probe to run (mirrors
    /// `URLSession.plozzDiscovery`'s resource timeout). Used to size the
    /// default `discover` timeout from the candidate count so a full sweep
    /// isn't cut off before every host has had a chance to respond.
    private static let perProbeTimeout: TimeInterval = 3

    public init(
        http: HTTPClient = URLSessionHTTPClient(session: .plozzDiscovery),
        port: Int = 5055,
        concurrency: Int = 48,
        subnetHosts: @escaping @Sendable () -> [String] = { LocalSubnetScanner.allHostAddresses() }
    ) {
        self.http = http
        self.port = port
        self.concurrency = max(1, concurrency)
        self.subnetHosts = subnetHosts
    }

    /// Streams unique servers as they're confirmed. `hostHints` (bare hosts,
    /// no scheme/port — e.g. already-known Jellyfin hosts) are probed first
    /// and are deduplicated against the subnet sweep. Finishes once every
    /// candidate has been probed or `timeout` elapses, whichever is first.
    ///
    /// When `timeout` is `nil` (the default), it's derived from the
    /// candidate count and `concurrency` so a full sweep always has time to
    /// finish — `waves * perProbeTimeout + margin`, where `waves` is how many
    /// batches of `concurrency` probes are needed to cover every candidate.
    /// A fixed default (e.g. 8s) would cut off most of a /24 sweep: at
    /// concurrency 48 that's ~6 waves × up to 3s each, well past 8s.
    public func discover(
        hostHints: [String] = [], urlHints: [URL] = [], includesSubnet: Bool = true,
        inspectMethods: Bool = false, timeout: TimeInterval? = nil
    ) -> AsyncStream<DiscoveredSeerServer> {
        AsyncStream { continuation in
            var seen = Set<String>()
            let hosts = hostHints + (includesSubnet ? subnetHosts() : [])
            let candidates = (urlHints + hosts.compactMap { Self.hostURL($0, port: port) })
                .compactMap { SeerServerIdentity(baseURL: $0).flatMap { URL(string: $0.canonicalURL) } }
                .filter { seen.insert($0.absoluteString).inserted }

            guard !candidates.isEmpty else {
                continuation.finish()
                return
            }

            let waves = (candidates.count + concurrency - 1) / concurrency
            let resolvedTimeout = timeout ?? (Double(waves) * Self.perProbeTimeout * (inspectMethods ? 2 : 1) + 2)

            let work = Task { [http, concurrency] in
                await withTaskGroup(of: DiscoveredSeerServer?.self) { group in
                    var nextIndex = 0
                    func dispatchNext() {
                        // Cancellation-aware: once the timeout fires (or the
                        // stream's consumer disappears), stop spooling up new
                        // tasks for the remaining candidates instead of
                        // burning through all of them just to have each
                        // immediately no-op on `Task.isCancelled`.
                        guard !Task.isCancelled, nextIndex < candidates.count else { return }
                        let url = candidates[nextIndex]
                        nextIndex += 1
                        group.addTask { await Self.probe(url: url, http: http, inspectMethods: inspectMethods) }
                    }

                    while nextIndex < min(concurrency, candidates.count) {
                        dispatchNext()
                    }
                    while let result = await group.next() {
                        if let server = result, !Task.isCancelled {
                            continuation.yield(server)
                        }
                        dispatchNext()
                    }
                }
                continuation.finish()
            }

            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, resolvedTimeout) * 1_000_000_000))
                work.cancel()
            }

            continuation.onTermination = { _ in
                work.cancel()
                timeoutTask.cancel()
            }
        }
    }

    /// Bounded checks on approved media-server routes, not arbitrary ports or sibling domains.
    public static func setupCandidates(mediaURLs: [URL]) -> [URL] {
        var seen = Set<URL>()
        var result: [URL] = []
        func append(_ url: URL?) {
            guard let url, let valid = SeerServerIdentity(baseURL: url).flatMap({ URL(string: $0.canonicalURL) }),
                  seen.insert(valid).inserted else { return }
            result.append(valid)
        }
        for url in mediaURLs {
            guard SeerServerIdentity(baseURL: url) != nil,
                  var origin = URLComponents(url: url, resolvingAgainstBaseURL: false) else { continue }
            if SourceLocalityClassifier.classify(url: url) == .local, let host = url.host {
                append(hostURL(host, port: 5055))
            }
            append(url)
            origin.path = ""
            let ports: [Int?] = origin.port == nil ? [nil] : [origin.port, nil]
            for port in ports {
                var webOrigin = origin
                webOrigin.port = port
                append(webOrigin.url)
                for path in ["/seerr", "/jellyseerr", "/overseerr"] {
                    var pathURL = webOrigin
                    pathURL.path = path
                    append(pathURL.url)
                }
            }
            // A public hostname keeps HTTPS, even on the conventional Seerr port.
            origin.port = 5055
            append(origin.url)
        }
        return result
    }

    private static func hostURL(_ rawHost: String, port: Int) -> URL? {
        let host = discoveryHost(rawHost)
        let hostComponent = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return URL(string: "http://\(hostComponent):\(port)")
    }

    private static func discoveryHost(_ host: String) -> String {
        let host = host.lowercased()
        // Plex's certificate hostname and its LAN address are one discovery target.
        // Only generated HTTP probes change; configured URLs keep their original origin.
        guard host.hasSuffix(".plex.direct"),
              let octets = SourceLocalityClassifier.leadingIPv4(host) else { return host }
        return octets.map(String.init).joined(separator: ".")
    }

    /// Probes one host:port for an unauthenticated `/api/v1/status`. Rejects
    /// anything that isn't shaped like a Seerr response (guards against some
    /// unrelated device answering 200 with arbitrary JSON on this port).
    private static func probe(url baseURL: URL, http: HTTPClient, inspectMethods: Bool) async -> DiscoveredSeerServer? {
        guard !Task.isCancelled else { return nil }
        let endpoint = Endpoint(
            method: .get, path: "/api/v1/status", redirectPolicy: .sameOrigin,
            allowsAutomaticAddressRetry: false
        )
        do {
            let status = try await http.decode(SeerStatus.self, from: endpoint, baseURL: baseURL)
            guard let version = status.version, !version.isEmpty else { return nil }
            var methods: SeerLoginMethods?
            if inspectMethods {
                let value = try await http.decode(SeerLoginMethods.self, from: Endpoint(
                    path: "/api/v1/settings/public", redirectPolicy: .sameOrigin,
                    allowsAutomaticAddressRetry: false
                ), baseURL: baseURL)
                guard value.initialized == true else { return nil }
                methods = try await SeerAuthentication(baseURL: baseURL, http: http)
                    .checkingQuickConnectSupport(for: value)
            }
            return DiscoveredSeerServer(baseURL: baseURL, version: version, loginMethods: methods)
        } catch {
            if !Task.isCancelled { PlozzLog.networking.debug("Seerr discovery candidate did not respond with a ready server") }
            return nil
        }
    }
}
