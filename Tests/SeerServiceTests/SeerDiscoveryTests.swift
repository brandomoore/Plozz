import XCTest
import CoreModels
import CoreNetworking
@testable import SeerService

/// Fake `HTTPClient` that branches by request **host**, not just path —
/// `SeerRecordingHTTPClient` (used by the rest of `SeerServiceTests`) matches
/// on path suffix only, which can't tell two discovery candidates apart.
private final class HostRoutedHTTPClient: HTTPClient, @unchecked Sendable {
    indirect enum Behavior {
        case json(String, status: Int = 200)
        case error(AppError)
        /// Sleeps before responding — used to prove `discover(timeout:)`
        /// actually cuts a slow/hung probe off instead of waiting on it.
        case delay(TimeInterval, then: Behavior)
    }

    private let lock = NSLock()
    private var behaviors: [String: Behavior] = [:]
    private var probes: [String] = []
    private var requests: [(Endpoint, URL)] = []
    private let defaultBehavior: Behavior

    init(default defaultBehavior: Behavior = .error(.serverUnreachable)) {
        self.defaultBehavior = defaultBehavior
    }

    func stub(host: String, _ behavior: Behavior) {
        lock.lock(); defer { lock.unlock() }
        behaviors[host] = behavior
    }

    func probeCount(forHost host: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return probes.filter { $0 == host }.count
    }

    var recordedRequests: [(Endpoint, URL)] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let host = baseURL.host ?? ""
        lock.lock()
        probes.append(host)
        requests.append((endpoint, baseURL))
        let behavior = behaviors[host] ?? defaultBehavior
        lock.unlock()

        return try await respond(baseURL: baseURL, behavior: behavior)
    }

    private func respond(baseURL: URL, behavior: Behavior) async throws -> (Data, HTTPURLResponse) {
        switch behavior {
        case let .json(json, status):
            return (Data(json.utf8), HTTPURLResponse(url: baseURL, statusCode: status, httpVersion: nil, headerFields: nil)!)
        case let .error(appError):
            throw appError
        case let .delay(seconds, then):
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            return try await respond(baseURL: baseURL, behavior: then)
        }
    }
}

final class SeerDiscoveryTests: XCTestCase {
    func testOlderJellyfinSeerrRemainsDiscoverableWithoutOfferingAccountReuse() async {
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/status", json: #"{"version":"3.3.0"}"#)
        http.stub(pathSuffix: "/settings/public", json: #"{"initialized":true,"mediaServerType":2,"mediaServerLogin":true}"#)
        http.stub(pathSuffix: "/quickconnect/check", json: "{}", status: 404)
        let discovery = SeerDiscovery(http: http, subnetHosts: { [] })
        let url = URL(string: "https://requests.example.test/seerr")!
        let results = await collect(discovery.discover(
            urlHints: [url], includesSubnet: false, inspectMethods: true
        ))
        XCTAssertEqual(results.map(\.baseURL), [url])
        XCTAssertEqual(results.first?.loginMethods?.jellyfinQuickConnect, false)
        XCTAssertEqual(http.sentPaths, [
            "/api/v1/status", "/api/v1/settings/public", "/api/v1/auth/jellyfin/quickconnect/check"
        ])
    }

    func testRemoteCandidatesPreserveHTTPSCustomPortAndProxyPathWithoutGuessingDomains() throws {
        let source = try XCTUnwrap(URL(string: "https://media.example.test:8443/media/jellyfin"))
        let candidates = SeerDiscovery.setupCandidates(mediaURLs: [source, source])
        XCTAssertTrue(candidates.contains(source))
        XCTAssertTrue(candidates.contains(URL(string: "https://media.example.test:8443")!))
        XCTAssertTrue(candidates.contains(URL(string: "https://media.example.test:8443/seerr")!))
        XCTAssertTrue(candidates.contains(URL(string: "https://media.example.test/seerr")!))
        XCTAssertTrue(candidates.contains(URL(string: "https://media.example.test:5055")!))
        XCTAssertTrue(candidates.allSatisfy { $0.scheme == "https" && $0.host == source.host })
        XCTAssertEqual(candidates.count, Set(candidates).count)
    }

    func testCandidateGenerationRejectsCredentialedRoutesAndKeepsIPv6AndPlexLocalHost() {
        let candidates = SeerDiscovery.setupCandidates(mediaURLs: [
            URL(string: "https://name:password@example.test")!,
            URL(string: "https://example.test?token=private")!,
            URL(string: "https://192-168-1-9.fixture.plex.direct:32400")!,
            URL(string: "https://[fd00::5]:8920/jellyfin")!
        ])
        XCTAssertFalse(candidates.contains { $0.host == "example.test" })
        XCTAssertTrue(candidates.contains(URL(string: "http://192.168.1.9:5055")!))
        XCTAssertTrue(candidates.contains(URL(string: "http://[fd00::5]:5055")!))
        XCTAssertTrue(candidates.contains(URL(string: "https://[fd00::5]:8920/jellyfin")!))
    }

    func testExactURLFastPhaseDoesNotSweepSubnetAndPreservesItsOrigin() async {
        let http = HostRoutedHTTPClient(default: .json(#"{"version":"3.5.2"}"#))
        let discovery = SeerDiscovery(http: http, subnetHosts: {
            XCTFail("Known endpoints must not enumerate the subnet")
            return ["192.168.1.12"]
        })
        let url = URL(string: "https://requests.example.test:15056/my/seerr")!
        let results = await collect(discovery.discover(urlHints: [url, url], includesSubnet: false))
        XCTAssertEqual(results.map(\.baseURL), [url])
        XCTAssertEqual(http.probeCount(forHost: "requests.example.test"), 1)
    }

    func testDiscoveryReturnsReadyCapabilitiesWithoutCredentialsOrCrossOriginRetries() async {
        let http = HostRoutedHTTPClient(default: .json(
            #"{"version":"3.5.2","initialized":true,"mediaServerType":1,"mediaServerLogin":true,"localLogin":false}"#
        ))
        let url = URL(string: "https://requests.example.test:8443/seerr")!
        let results = await collect(makeDiscovery(http).discover(
            urlHints: [url], includesSubnet: false, inspectMethods: true
        ))
        XCTAssertEqual(results.first?.loginMethods?.mediaServerType, 1)
        XCTAssertEqual(results.first?.loginMethods?.mediaServerLogin, true)
        XCTAssertEqual(http.recordedRequests.map { $0.0.path }, ["/api/v1/status", "/api/v1/settings/public"])
        for (endpoint, baseURL) in http.recordedRequests {
            XCTAssertEqual(baseURL, url)
            XCTAssertTrue(endpoint.headers.isEmpty)
            XCTAssertEqual(endpoint.redirectPolicy, .sameOrigin)
            XCTAssertFalse(endpoint.allowsAutomaticAddressRetry)
        }
    }

    /// All these tests inject `subnetHosts: { [] }` so results come only from
    /// `hostHints` — fully hermetic, no dependency on the test machine's real
    /// network interfaces.
    private func makeDiscovery(_ http: HostRoutedHTTPClient) -> SeerDiscovery {
        SeerDiscovery(http: http, port: 5055, concurrency: 4, subnetHosts: { [] })
    }

    private func collect(_ stream: AsyncStream<DiscoveredSeerServer>) async -> [DiscoveredSeerServer] {
        var results: [DiscoveredSeerServer] = []
        for await server in stream { results.append(server) }
        return results
    }

    func testValidStatusResponseYieldsServer() async {
        let http = HostRoutedHTTPClient()
        http.stub(host: "192.168.1.50", .json(#"{"version":"1.33.2"}"#))
        let discovery = makeDiscovery(http)

        let results = await collect(discovery.discover(hostHints: ["192.168.1.50"], timeout: 2))

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.baseURL.absoluteString, "http://192.168.1.50:5055")
        XCTAssertEqual(results.first?.version, "1.33.2")
    }

    func testUnreachableHostsYieldNothing() async {
        let http = HostRoutedHTTPClient(default: .error(.serverUnreachable))
        let discovery = makeDiscovery(http)

        let results = await collect(discovery.discover(hostHints: ["10.0.0.1", "10.0.0.2"], timeout: 2))

        XCTAssertTrue(results.isEmpty)
    }

    func testResponseWithoutVersionIsRejected() async {
        // Guards against an unrelated device answering 200 with arbitrary
        // JSON on port 5055 — must not be mistaken for a Seerr server.
        let http = HostRoutedHTTPClient()
        http.stub(host: "10.0.0.5", .json(#"{"unrelated":true}"#))
        let discovery = makeDiscovery(http)

        let results = await collect(discovery.discover(hostHints: ["10.0.0.5"], timeout: 2))

        XCTAssertTrue(results.isEmpty)
    }

    func testEmptyVersionStringIsRejected() async {
        let http = HostRoutedHTTPClient()
        http.stub(host: "10.0.0.6", .json(#"{"version":""}"#))
        let discovery = makeDiscovery(http)

        let results = await collect(discovery.discover(hostHints: ["10.0.0.6"], timeout: 2))

        XCTAssertTrue(results.isEmpty)
    }

    func testDuplicateHintsProbedOnlyOnce() async {
        let http = HostRoutedHTTPClient()
        http.stub(host: "192.168.1.9", .json(#"{"version":"1.0.0"}"#))
        let discovery = makeDiscovery(http)

        let results = await collect(discovery.discover(hostHints: ["192.168.1.9", "192.168.1.9"], timeout: 2))

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(http.probeCount(forHost: "192.168.1.9"), 1)
    }

    func testMixOfValidAndInvalidHintsOnlyYieldsValidOnes() async {
        let http = HostRoutedHTTPClient()
        http.stub(host: "192.168.1.10", .json(#"{"version":"1.33.2","commitTag":"abc"}"#))
        http.stub(host: "192.168.1.11", .error(.serverUnreachable))
        let discovery = makeDiscovery(http)

        let results = await collect(discovery.discover(hostHints: ["192.168.1.10", "192.168.1.11"], timeout: 2))

        XCTAssertEqual(results.map { $0.baseURL.host }, ["192.168.1.10"])
    }

    func testPlexAliasesAndSubnetAddressProduceOneProbeAndResultPerHost() async {
        let http = HostRoutedHTTPClient()
        http.stub(host: "192.168.1.9", .json(#"{"version":"3.5.2"}"#))
        http.stub(host: "192.168.1.10", .json(#"{"version":"3.5.2"}"#))
        let discovery = SeerDiscovery(
            http: http, port: 5055, concurrency: 4,
            subnetHosts: { ["192.168.1.9", "192.168.1.10"] }
        )
        let aliases = ["192-168-1-9.first.plex.direct", "192-168-1-9.second.PLEX.DIRECT"]

        let results = await collect(discovery.discover(
            hostHints: aliases + ["192.168.1.9", "192-168-1-10.other.plex.direct"], timeout: 2
        ))

        XCTAssertEqual(Set(results.map(\.baseURL.absoluteString)),
                       ["http://192.168.1.9:5055", "http://192.168.1.10:5055"])
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(http.probeCount(forHost: "192.168.1.9"), 1)
        XCTAssertEqual(http.probeCount(forHost: "192.168.1.10"), 1)
        for alias in aliases { XCTAssertEqual(http.probeCount(forHost: alias.lowercased()), 0) }
    }

    func testDiscoveryDoesNotRewriteOtherHostnamesOrMalformedPlexAddresses() async {
        let http = HostRoutedHTTPClient(default: .json(#"{"version":"3.5.2"}"#))
        let hosts = ["192-168-1-9.example.com", "999-168-1-9.test.plex.direct", "requests.local"]

        let results = await collect(makeDiscovery(http).discover(hostHints: hosts, timeout: 2))

        XCTAssertEqual(Set(results.compactMap(\.baseURL.host)), Set(hosts))
        for host in hosts { XCTAssertEqual(http.probeCount(forHost: host), 1) }
    }

    func testSubnetSweepCandidatesAreAlsoProbed() async {
        // hostHints is empty here — the only candidate comes from the
        // injected `subnetHosts` closure, confirming the sweep path (not just
        // hints) feeds the same probe/yield pipeline.
        let http = HostRoutedHTTPClient()
        http.stub(host: "192.168.1.77", .json(#"{"version":"1.20.0"}"#))
        let discovery = SeerDiscovery(http: http, port: 5055, concurrency: 4, subnetHosts: { ["192.168.1.77"] })

        let results = await collect(discovery.discover(timeout: 2))

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.baseURL.absoluteString, "http://192.168.1.77:5055")
    }

    func testHintsDedupedAgainstSubnetSweep() async {
        let http = HostRoutedHTTPClient()
        http.stub(host: "192.168.1.9", .json(#"{"version":"1.0.0"}"#))
        let discovery = SeerDiscovery(http: http, port: 5055, concurrency: 4, subnetHosts: { ["192.168.1.9"] })

        let results = await collect(discovery.discover(hostHints: ["192.168.1.9"], timeout: 2))

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(http.probeCount(forHost: "192.168.1.9"), 1)
    }

    func testNoCandidatesFinishesImmediatelyWithNoResults() async {
        let http = HostRoutedHTTPClient()
        let discovery = makeDiscovery(http)

        let results = await collect(discovery.discover(timeout: 2))

        XCTAssertTrue(results.isEmpty)
    }

    func testTimeoutCutsOffSlowProbes() async {
        // A host that never answers within the timeout must not be waited
        // on — `discover` should finish at `timeout`, not at the probe's own
        // (much longer) delay.
        let http = HostRoutedHTTPClient()
        http.stub(host: "10.0.0.9", .delay(5, then: .json(#"{"version":"1.0.0"}"#)))
        let discovery = makeDiscovery(http)

        let start = Date()
        let results = await collect(discovery.discover(hostHints: ["10.0.0.9"], timeout: 0.2))
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(results.isEmpty)
        XCTAssertLessThan(elapsed, 2, "discover(timeout:) should cut off long before the probe's own 5s delay")
    }
}
