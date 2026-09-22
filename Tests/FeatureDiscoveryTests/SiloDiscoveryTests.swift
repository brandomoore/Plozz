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

    func testSiloIdentityKeepsSeparateReverseProxyPaths() {
        let first = MediaServer(id: "http://host/one", name: "Silo", baseURL: URL(string: "http://host/one")!, provider: .silo)
        let second = MediaServer(id: "two", name: "Silo", baseURL: URL(string: "http://host/two")!, provider: .silo)
        let authenticated = MediaServer(id: "installation-id", name: "Silo", baseURL: first.baseURL, provider: .silo)
        XCTAssertFalse(ServerIdentity.isSame(first, second))
        XCTAssertTrue(ServerIdentity.isSame(first, authenticated))
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
