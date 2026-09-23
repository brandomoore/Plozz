import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import CoreModels
import CoreNetworking
@testable import FeatureDiscoveryCore

private actor SiloDiscoveryHTTP: HTTPClient {
    let delay: Duration
    let acceptedHost: String?
    private(set) var active = 0
    private(set) var maximumActive = 0
    private(set) var requestCount = 0

    init(delay: Duration = .zero, acceptedHost: String? = nil) {
        self.delay = delay
        self.acceptedHost = acceptedHost
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        active += 1
        maximumActive = max(maximumActive, active)
        requestCount += 1
        defer { active -= 1 }
        try await Task.sleep(for: delay)
        guard acceptedHost == nil || baseURL.host == acceptedHost else { throw AppError.notFound }
        let json: String
        switch endpoint.path {
        case "/api/v2/system/info":
            json = #"{"api_major":2,"server_version":"test","contract_digest":"digest"}"#
        case "/api/v2/auth/device/capability":
            json = #"{"protocol_versions":[2],"state":"available"}"#
        default: throw AppError.notFound
        }
        XCTAssertEqual(endpoint.redirectPolicy, .sameOrigin)
        XCTAssertNil(endpoint.headers["Authorization"])
        return (Data(json.utf8), HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

final class SiloDiscoveryTests: XCTestCase {
    func testNativeValidationUsesSiloPortAndNotJellyfinCompatibility() async throws {
        let http = SiloDiscoveryHTTP()
        let server = try await ServerValidator(provider: .silo, http: http).validate(rawURL: "192.168.1.71")
        XCTAssertEqual(server.provider, .silo)
        XCTAssertEqual(server.baseURL.port, 8090)
        XCTAssertEqual(server.version, "test")
        let requests = await http.requestCount
        XCTAssertEqual(requests, 2)
    }

    func testDiscoveryOnlyPublishesVerifiedNativeServerAndDeduplicatesCandidates() async {
        let http = SiloDiscoveryHTTP(acceptedHost: "192.168.1.71")
        let matching = URL(string: "http://192.168.1.71:8090")!
        let discovery = SiloServerDiscovery(
            candidates: { [URL(string: "http://192.168.1.70:8090")!, matching, matching] },
            validator: ServerValidator(provider: .silo, http: http))
        var servers: [MediaServer] = []
        for await server in discovery.discover(timeout: 2) { servers.append(server) }
        XCTAssertEqual(servers.map(\.baseURL), [matching])
        let requests = await http.requestCount
        XCTAssertEqual(requests, 3)
    }

    func testDeadlineCancelsOutstandingProbesAndBoundsConcurrency() async {
        let http = SiloDiscoveryHTTP(delay: .seconds(30))
        let discovery = SiloServerDiscovery(
            candidates: { (1...200).map { URL(string: "http://192.168.1.\($0):8090")! } },
            validator: ServerValidator(provider: .silo, http: http))
        let start = ContinuousClock.now
        for await _ in discovery.discover(timeout: 0.05) { XCTFail("Timed-out candidate") }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        let active = await http.active
        let maximum = await http.maximumActive
        XCTAssertEqual(active, 0)
        XCTAssertLessThanOrEqual(maximum, SiloServerDiscovery.maximumConcurrentProbes)
    }

    func testRejectsUnrelatedServiceAndCredentialBearingInput() async {
        let http = StubHTTPClient()
        http.stub(path: "/api/v2/system/info", json: #"{"api_major":2,"server_version":"other","contract_digest":"digest"}"#)
        let validator = ServerValidator(provider: .silo, http: http)
        do {
            _ = try await validator.validate(rawURL: "http://unrelated.test")
            XCTFail("A generic v2 endpoint is not a Silo server")
        } catch { XCTAssertEqual(error as? AppError, .notFound) }
        do {
            _ = try await validator.validate(rawURL: "http://user:secret@host:8090")
            XCTFail("Server addresses must not embed credentials")
        } catch { XCTAssertEqual(error as? AppError, .invalidResponse) }
    }

    @MainActor
    func testManualSubmissionBlocksDuplicateAndRejectsLateResultAfterBack() async {
        let http = SiloDiscoveryHTTP(delay: .milliseconds(100))
        let store = SiloRecentStore()
        let model = ServerPickerViewModel(
            provider: .silo, discovery: EmptySiloDiscovery(),
            validator: ServerValidator(provider: .silo, http: http), store: store
        )
        model.manualURLText = " \n "
        XCTAssertFalse(model.canSubmitManualURL)
        let blank = await model.submitManualURL()
        XCTAssertNil(blank)
        model.manualURLText = " 192.168.1.71 \n"
        let request = Task { await model.submitManualURL() }
        let deadline = ContinuousClock.now + .seconds(2)
        while model.phase != .validating, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(model.phase, .validating)
        XCTAssertFalse(model.canSubmitManualURL)
        let duplicate = await model.submitManualURL()
        XCTAssertNil(duplicate)
        model.stopScan()
        let stale = await request.value
        XCTAssertNil(stale)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(store.recentServers.isEmpty)
    }

    @MainActor
    func testSharedPickerValidatesAndRemembersSiloManualAddress() async {
        let http = SiloDiscoveryHTTP()
        let store = SiloRecentStore()
        let model = ServerPickerViewModel(
            provider: .silo, discovery: EmptySiloDiscovery(),
            validator: ServerValidator(provider: .silo, http: http), store: store
        )
        model.manualURLText = "192.168.1.71"
        let server = await model.submitManualURL()
        XCTAssertEqual(server?.baseURL.absoluteString, "http://192.168.1.71:8090")
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(store.recentServers.first, server)
    }

    func testSiloIdentityKeepsSeparateReverseProxyPaths() {
        let first = MediaServer(id: "http://host/one", name: "Silo", baseURL: URL(string: "http://host/one")!, provider: .silo)
        let second = MediaServer(id: "two", name: "Silo", baseURL: URL(string: "http://host/two")!, provider: .silo)
        let authenticated = MediaServer(id: "installation-id", name: "Silo", baseURL: first.baseURL, provider: .silo)
        XCTAssertFalse(ServerIdentity.isSame(first, second))
        XCTAssertTrue(ServerIdentity.isSame(first, authenticated))
    }

    func testRootURLAndInstallationIdentityMatchWithoutCrossingOrigins() {
        let url = URL(string: "http://192.168.1.71:8090")!
        let authenticated = MediaServer(id: "installation-id", name: "Silo", baseURL: url, provider: .silo)
        let discovered = MediaServer(id: url.absoluteString, name: "Silo", baseURL: url, provider: .silo)
        var slash = discovered
        slash.baseURL = URL(string: url.absoluteString + "/")!
        XCTAssertTrue(ServerIdentity.isSame(authenticated, discovered))
        XCTAssertTrue(ServerIdentity.isSame(discovered, authenticated))
        XCTAssertTrue(ServerIdentity.isSame(slash, authenticated))
        XCTAssertTrue(ServerIdentity.isSame(authenticated, slash))
        for otherURL in ["http://192.168.1.71:8091", "https://192.168.1.71:8090", "http://192.168.1.71:8090/other"] {
            let other = MediaServer(id: otherURL, name: "Other", baseURL: URL(string: otherURL)!, provider: .silo)
            XCTAssertFalse(ServerIdentity.isSame(authenticated, other))
        }
    }

    @MainActor
    func testSavedRecentAndDiscoveredSiloAppearAsOneSignedInServer() async {
        let url = URL(string: "http://192.168.1.71:8090")!
        let saved = MediaServer(id: "installation-id", name: "192.168.1.71", baseURL: url, provider: .silo)
        let recent = MediaServer(id: url.absoluteString, name: "Silo", baseURL: url, provider: .silo)
        let store = SiloRecentStore()
        store.recentServers = [recent]
        let validator = ServerValidator(provider: .silo, http: SiloDiscoveryHTTP())
        let model = ServerPickerViewModel(
            provider: .silo,
            discovery: SiloServerDiscovery(candidates: { [url] }, validator: validator),
            validator: validator, store: store
        )
        model.setSignedInServers([SignedInServer(server: saved, userNames: ["Viewer"])])
        XCTAssertTrue(model.recentServers.isEmpty)
        model.startScan(timeout: 1)
        let deadline = ContinuousClock.now + .seconds(2)
        while model.phase != .idle, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(model.discoveredServers.isEmpty)
        XCTAssertEqual(model.signedInServers.count, 1)
        XCTAssertEqual(model.status(for: saved), .onNetwork)
        XCTAssertEqual(model.signedInServers.first?.server, saved, "Picker deduplication must not migrate saved accounts.")
        model.stopScan()
    }

    @MainActor
    func testSigningInAfterDiscoveryCollapsesTheExistingRow() async {
        let url = URL(string: "http://192.168.1.71:8090")!
        let validator = ServerValidator(provider: .silo, http: SiloDiscoveryHTTP())
        let model = ServerPickerViewModel(
            provider: .silo,
            discovery: SiloServerDiscovery(candidates: { [url] }, validator: validator),
            validator: validator, store: SiloRecentStore()
        )
        model.startScan(timeout: 1)
        let deadline = ContinuousClock.now + .seconds(2)
        while model.phase != .idle, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(model.discoveredServers.count, 1)
        let saved = MediaServer(id: "installation-id", name: "Silo", baseURL: url, provider: .silo)
        model.setSignedInServers([SignedInServer(server: saved, userNames: ["Viewer"])])
        XCTAssertTrue(model.discoveredServers.isEmpty)
        XCTAssertEqual(model.status(for: saved), .onNetwork)
        model.stopScan()
    }

    private final class SiloRecentStore: LastServerStoring, @unchecked Sendable {
        var recentServers: [MediaServer] = []
    }

    private struct EmptySiloDiscovery: ServerDiscovering {
        func discover(timeout: TimeInterval) -> AsyncStream<MediaServer> {
            AsyncStream { $0.finish() }
        }
    }

    #if canImport(Darwin)
    func testSubnetBoundsExcludePublicNetworkBroadcastAndOwnAddress() {
        let candidates = LANIPv4Interface.siloCandidates(host: 0xC0A8_0132, mask: 0xFFFF_FF00)
        XCTAssertEqual(candidates.count, 253)
        XCTAssertTrue(candidates.allSatisfy { $0.port == 8090 })
        XCTAssertFalse(candidates.contains { $0.host == "192.168.1.50" || $0.host == "192.168.1.0" || $0.host == "192.168.1.255" })
        XCTAssertTrue(LANIPv4Interface.siloCandidates(host: 0x0808_0808, mask: 0xFFFF_FF00).isEmpty)
        XCTAssertTrue(LANIPv4Interface.siloCandidates(host: 0xC0A8_0132, mask: 0).isEmpty)
        XCTAssertTrue(LANIPv4Interface.siloCandidates(host: 0xC0A8_0132, mask: 0xFFFF_FFFF).isEmpty)
        XCTAssertEqual(LANIPv4Interface.siloCandidates(host: 0x0A14_0332, mask: 0xFF00_0000).count, 253)
        XCTAssertEqual(LANIPv4Interface.siloCandidates(host: 0xC0A8_0132, mask: 0xFFFF_FF80).count, 125)
    }
    #endif
}
