import CoreModels
import CoreNetworking
import Foundation
import os
@testable import ProviderIPTV
import XCTest

private final class PortalFailoverURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Response = (Int, [String: String], Data)
    private static let state = OSAllocatedUnfairLock<(@Sendable (URLRequest) throws -> Response)?>(initialState: nil)

    static func configuration(handler: @escaping @Sendable (URLRequest) throws -> Response) -> URLSessionConfiguration {
        state.withLock { $0 = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PortalFailoverURLProtocol.self]
        return configuration
    }

    static func reset() {
        state.withLock { $0 = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.state.withLock({ $0 }) else { throw URLError(.unsupportedURL) }
            let (status, headers, data) = try handler(request)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: XCTUnwrap(request.url), statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class IPTVPortalFailoverTests: XCTestCase {
    override func tearDown() {
        PortalFailoverURLProtocol.reset()
        super.tearDown()
    }

    func testCredentialNormalizesDeduplicatesAndPreservesIdentityForAlternateAddresses() throws {
        let primary = try XCTUnwrap(URL(string: "http://primary.test/player_api.php?foo=bar"))
        let backup1 = try XCTUnwrap(URL(string: "http://backup-1.test/"))
        let backup1Dup = try XCTUnwrap(URL(string: "http://BACKUP-1.test:80/player_api.php"))
        let primaryDup = try XCTUnwrap(URL(string: "http://primary.test:80/"))
        let backup2 = try XCTUnwrap(URL(string: "https://backup-2.test:8443/panel/"))

        let credential = try IPTVCredential(
            mode: .xtream,
            address: primary,
            username: "u",
            password: "p",
            headers: ["X-Custom": "secret"],
            alternateAddresses: [primaryDup, backup1, backup1Dup, backup2]
        )

        XCTAssertEqual(credential.address.absoluteString, "http://primary.test")
        XCTAssertEqual(
            credential.alternateAddresses.map(\.absoluteString),
            ["http://backup-1.test", "https://backup-2.test:8443/panel"]
        )
        XCTAssertEqual(
            credential.portalAddresses.map(\.absoluteString),
            ["http://primary.test", "http://backup-1.test", "https://backup-2.test:8443/panel"]
        )

        // Custom headers apply to all configured portals, never to unrelated hosts.
        XCTAssertEqual(credential.headers(for: try XCTUnwrap(URL(string: "http://backup-1.test/live/u/p/1.ts"))), ["X-Custom": "secret"])
        XCTAssertEqual(credential.headers(for: try XCTUnwrap(URL(string: "https://backup-2.test:8443/panel/live/u/p/1.ts"))), ["X-Custom": "secret"])
        XCTAssertEqual(credential.headers(for: try XCTUnwrap(URL(string: "http://other.test/live/u/p/1.ts"))), [:])

        // Encode/decode round-trip preserves alternate addresses, identity, and catalogKey.
        let decoded = try IPTVCredential.decode(try credential.encoded())
        XCTAssertEqual(decoded, credential)

        // Replacing alternates preserves identity and catalogKey.
        let replaced = try credential.replacingAlternateAddresses([backup2])
        XCTAssertEqual(replaced.identity, credential.identity)
        XCTAssertEqual(replaced.catalogKey, credential.catalogKey)
        XCTAssertEqual(replaced.alternateAddresses.map(\.absoluteString), ["https://backup-2.test:8443/panel"])
    }

    func testPortalPoolRanksFastestHealthyAndDemotesDegradedUntilCooldownExpires() async throws {
        let p0 = try XCTUnwrap(URL(string: "http://p0.test"))
        let p1 = try XCTUnwrap(URL(string: "http://p1.test"))
        let p2 = try XCTUnwrap(URL(string: "http://p2.test"))

        let now = OSAllocatedUnfairLock(initialState: TimeInterval(100))
        let pool = IPTVPortalPool(portals: [p0, p1, p2], cooldownSeconds: 60) {
            now.withLock { $0 }
        }

        _ = await pool.applyProbeResults([
            .init(portal: p0, rtt: 0.320, allowedOutputFormats: ["ts"], failed: false),
            .init(portal: p1, rtt: 0.095, allowedOutputFormats: ["ts"], failed: false),
            .init(portal: p2, rtt: nil, allowedOutputFormats: nil, failed: true)
        ])

        var ordered = await pool.orderedPortals()
        XCTAssertEqual(ordered, [p1, p0, p2])
        let activeAfterProbe = await pool.activePortal()
        XCTAssertEqual(activeAfterProbe, p1)

        now.withLock { $0 = 110 }
        await pool.recordFailure(p1)
        ordered = await pool.orderedPortals()
        XCTAssertEqual(ordered.first, p0)
        XCTAssertEqual(ordered.last, p1)

        now.withLock { $0 = 200 }
        await pool.recordSuccess(p2, rtt: 0.050, promote: true)
        let activeAfterRecovery = await pool.activePortal()
        XCTAssertEqual(activeAfterRecovery, p2)
    }

    func testPortalRewritingAndShouldFailOverPolicy() throws {
        let p0 = try XCTUnwrap(URL(string: "http://p0.test/sub"))
        let p1 = try XCTUnwrap(URL(string: "https://p1.test:8443"))
        let stream = try XCTUnwrap(URL(string: "http://p0.test/sub/live/u/p/42.ts?token=abc"))
        let rewritten = IPTVPortalPool.rewriting(stream, from: p0, to: p1)
        XCTAssertEqual(rewritten?.absoluteString, "https://p1.test:8443/live/u/p/42.ts?token=abc")

        let cdn = try XCTUnwrap(URL(string: "http://cdn-edge.other.test/live/42.ts"))
        XCTAssertNil(IPTVPortalPool.rewriting(cdn, from: p0, to: p1))

        XCTAssertTrue(IPTVPortalPool.shouldFailOver(after: IPTVError.httpStatus(502)))
        XCTAssertTrue(IPTVPortalPool.shouldFailOver(after: IPTVError.httpStatus(522)))
        XCTAssertTrue(IPTVPortalPool.shouldFailOver(after: URLError(.cannotFindHost)))
        XCTAssertTrue(IPTVPortalPool.shouldFailOver(after: URLError(.timedOut)))

        XCTAssertFalse(IPTVPortalPool.shouldFailOver(after: IPTVError.authentication))
        XCTAssertFalse(IPTVPortalPool.shouldFailOver(after: IPTVError.expired))
        XCTAssertFalse(IPTVPortalPool.shouldFailOver(after: AppError.conflict))
        XCTAssertFalse(IPTVPortalPool.shouldFailOver(after: AppError.rateLimited(retryAfter: 5)))
        XCTAssertFalse(IPTVPortalPool.shouldFailOver(after: AppError.notFound))
        XCTAssertFalse(IPTVPortalPool.shouldFailOver(after: AppError.accessRestricted))
        XCTAssertFalse(IPTVPortalPool.shouldFailOver(after: CancellationError()))
    }

    func testWarmConnectionSelectsFastestPortalAndOpensNextLiveStreamThere() async throws {
        let authJSON = Data(#"{"user_info":{"auth":1,"status":"Active","allowed_output_formats":["ts"]}}"#.utf8)
        let channelsJSON = Data(#"[{"stream_id":101,"name":"News One","category_id":"1"}]"#.utf8)
        let categoriesJSON = Data(#"[{"category_id":"1","category_name":"News"}]"#.utf8)
        let tsPayload = Data(repeating: 0x47, count: 188 * 4)

        let liveHostsSeen = OSAllocatedUnfairLock(initialState: [String]())

        let config = PortalFailoverURLProtocol.configuration { request in
            let url = try XCTUnwrap(request.url)
            let host = url.host ?? ""
            if url.path.hasPrefix("/live/") {
                liveHostsSeen.withLock { $0.append(host) }
                return (200, ["Content-Type": "video/mp2t"], tsPayload)
            }
            let action = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "action" })?.value
            if action == "get_live_categories" { return (200, [:], categoriesJSON) }
            if action == "get_live_streams" { return (200, [:], channelsJSON) }
            if action == "get_vod_categories" || action == "get_vod_streams"
                || action == "get_series_categories" || action == "get_series" {
                return (200, [:], Data("[]".utf8))
            }
            if host == "slow-primary.test" {
                Thread.sleep(forTimeInterval: 0.18)
                return (200, [:], authJSON)
            }
            if host == "down-backup.test" {
                return (502, [:], Data("Bad Gateway".utf8))
            }
            return (200, [:], authJSON)
        }

        let root = temporaryDirectory()
        let credential = try IPTVCredential(
            mode: .xtream,
            address: XCTUnwrap(URL(string: "http://slow-primary.test")),
            username: "u",
            password: "p",
            alternateAddresses: [
                XCTUnwrap(URL(string: "http://down-backup.test")),
                XCTUnwrap(URL(string: "http://fast-backup.test"))
            ]
        )
        let session = try await IPTVProvider.signIn(
            credential: credential, name: "Fixture", deviceID: "fixture",
            cacheDirectory: root, configuration: config
        )
        let provider = try IPTVProvider(
            context: .init(
                session: session, accountID: "account", credentialRevision: .init(),
                localMediaContext: .init(accountID: "account", profileID: "fixture", profileNamespace: nil)
            ),
            cacheDirectory: root, configuration: config
        )
        addTeardownBlock { await provider.teardown() }

        await provider.warmLiveTVConnection()

        let lease = try await provider.openLiveTVChannel(id: "live:101")
        guard case .authenticatedHTTP(let locator) = lease.playbackSource else {
            return XCTFail("Expected authenticated HTTP playback locator")
        }
        let localURL = try await provider.resolveHTTPResource(locator)
        let (data, response) = try await URLSession.shared.data(from: localURL)
        await lease.close()

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data, tsPayload)
        XCTAssertEqual(liveHostsSeen.withLock { $0 }, ["fast-backup.test"])
    }

    func testLivePlaybackProxyFailsOverSequentiallyWithoutRacingStreamsAndSkipsFailoverOnConnectionLimit() async throws {
        let tsPayload = Data(repeating: 0x47, count: 188 * 4)
        let activeStreams = OSAllocatedUnfairLock(initialState: 0)
        let maxConcurrentStreams = OSAllocatedUnfairLock(initialState: 0)
        let attemptedHosts = OSAllocatedUnfairLock(initialState: [String]())

        let config = PortalFailoverURLProtocol.configuration { request in
            let host = request.url?.host ?? ""
            attemptedHosts.withLock { $0.append(host) }
            let concurrent = activeStreams.withLock { value -> Int in
                value += 1
                return value
            }
            maxConcurrentStreams.withLock { $0 = max($0, concurrent) }
            defer { activeStreams.withLock { $0 -= 1 } }

            if host == "dead-primary.test" {
                return (502, ["Content-Type": "text/html"], Data("Bad Gateway".utf8))
            }
            if host == "limit-primary.test" {
                return (503, ["Content-Type": "application/json"], Data(#"{"error":"maximum connection limits reached"}"#.utf8))
            }
            return (200, ["Content-Type": "video/mp2t"], tsPayload)
        }

        let p0 = try XCTUnwrap(URL(string: "http://dead-primary.test"))
        let p1 = try XCTUnwrap(URL(string: "http://healthy-backup.test"))
        let pool = IPTVPortalPool(portals: [p0, p1])
        let proxy = try IPTVPlaybackProxy(
            origin: try XCTUnwrap(URL(string: "http://dead-primary.test/live/u/p/101.ts")),
            headers: [:],
            configuration: config,
            originPortal: p0,
            alternateOrigins: [
                .init(portal: p1, url: try XCTUnwrap(URL(string: "http://healthy-backup.test/live/u/p/101.ts")))
            ],
            portalPool: pool
        )
        let localURL = try await proxy.start()
        let (data, response) = try await URLSession.shared.data(from: localURL)
        await proxy.stop()

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data, tsPayload)
        XCTAssertEqual(attemptedHosts.withLock { $0 }, ["dead-primary.test", "healthy-backup.test"])
        XCTAssertEqual(maxConcurrentStreams.withLock { $0 }, 1)
        let promotedPortal = await pool.activePortal()
        XCTAssertEqual(promotedPortal, p1)

        attemptedHosts.withLock { $0.removeAll() }
        let limitPortal = try XCTUnwrap(URL(string: "http://limit-primary.test"))
        let limitPool = IPTVPortalPool(portals: [limitPortal, p1])
        let limitProxy = try IPTVPlaybackProxy(
            origin: try XCTUnwrap(URL(string: "http://limit-primary.test/live/u/p/101.ts")),
            headers: [:],
            configuration: config,
            originPortal: limitPortal,
            alternateOrigins: [
                .init(portal: p1, url: try XCTUnwrap(URL(string: "http://healthy-backup.test/live/u/p/101.ts")))
            ],
            portalPool: limitPool
        )
        let limitLocalURL = try await limitProxy.start()
        let (_, limitResponse) = try await URLSession.shared.data(from: limitLocalURL)
        await limitProxy.stop()

        XCTAssertEqual((limitResponse as? HTTPURLResponse)?.statusCode, 503)
        XCTAssertEqual(attemptedHosts.withLock { $0 }, ["limit-primary.test"])
        let remainingPortal = await limitPool.activePortal()
        XCTAssertEqual(remainingPortal, limitPortal)
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-iptv-portal-failover-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
