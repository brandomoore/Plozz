import XCTest
@testable import MediaTransportHTTP
@testable import TestSupportNetworking

final class WebDAVMediaDeliveryTests: XCTestCase {
    private let source = URL(string: "https://dav.example.com/files/movie.mkv")!
    private let delivery = URL(string: "https://cdn.example.net/video?signature=short-lived")!

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private var root: WebDAVRoot {
        WebDAVRoot(origin: TransportOrigin(url: source)!, normalizedPath: "/files")
    }

    private func key() throws -> TransportSessionKey {
        try TransportSessionKey(
            accountID: "account", credentialRevision: UUID(), origin: root.origin,
            trustRevision: UUID(), role: .playback
        )
    }

    private func client() -> WebDAVClient {
        WebDAVClient(registry: TransportSessionRegistry(testProtocolClasses: [StubURLProtocol.self]))
    }

    private func queueProbe(at url: URL) {
        StubURLProtocol.queue(
            StubResponse(
                statusCode: 206, headers: ["ETag": "\"delivery-1\"", "Content-Range": "bytes 0-1/1000"],
                body: Data([0, 0]),
                onRequest: {
                    XCTAssertEqual($0.httpMethod, "GET")
                    XCTAssertEqual($0.value(forHTTPHeaderField: "Range"), "bytes=0-1")
                    XCTAssertEqual($0.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
                    XCTAssertNil($0.value(forHTTPHeaderField: "Authorization"))
                    XCTAssertNil($0.value(forHTTPHeaderField: "Cookie"))
                    XCTAssertNil($0.value(forHTTPHeaderField: "Referer"))
                }
            ), for: url
        )
    }

    func testCrossOriginProbeAndReadUseAnonymousSession() async throws {
        let client = client()
        let key = try key()
        StubURLProtocol.queue(
            redirect: StubRedirect(location: delivery, onRequest: {
                XCTAssertNotNil($0.value(forHTTPHeaderField: "Authorization"))
            }), for: source
        )
        queueProbe(at: delivery)
        let representation = try await client.probeRange(
            root: root, url: source, sessionKey: key,
            credential: .bearerToken("account-secret"), trustPolicy: .system
        )
        XCTAssertEqual(representation.resourceURL, delivery)
        XCTAssertTrue(representation.usesAnonymousSession)
        StubURLProtocol.queue(
            StubResponse(
                statusCode: 206, headers: ["ETag": "\"delivery-1\"", "Content-Range": "bytes 500-509/1000"],
                body: Data(repeating: 1, count: 10),
                onRequest: {
                    XCTAssertEqual($0.value(forHTTPHeaderField: "If-Match"), "\"delivery-1\"")
                    XCTAssertEqual($0.value(forHTTPHeaderField: "Range"), "bytes=500-509")
                    XCTAssertNil($0.value(forHTTPHeaderField: "Authorization"))
                }
            ), for: delivery
        )
        let bytes = try await client.readRange(
            url: delivery, start: 500, end: 509, representation: representation,
            sessionKey: key, credential: .bearerToken("account-secret"), trustPolicy: .system
        )
        XCTAssertEqual(bytes.count, 10)
        XCTAssertEqual(StubURLProtocol.requests(for: source).count, 1)
    }

    func testPrefetchedDeliveryRetainsOnlyACompleteValidatedAnonymousPrefix() async throws {
        let count = RangeProbe.initialReadByteCount
        for bodyLength in [count, count - 1, count + 1] {
            StubURLProtocol.queue(redirect: StubRedirect(location: delivery), for: source)
            StubURLProtocol.queue(
                StubResponse(
                    statusCode: 206,
                    headers: ["ETag": "\"delivery-1\"", "Content-Range": "bytes 0-\(count - 1)/1000000"],
                    body: Data(repeating: 42, count: bodyLength),
                    onRequest: {
                        XCTAssertEqual($0.value(forHTTPHeaderField: "Range"), "bytes=0-\(count - 1)")
                        XCTAssertNil($0.value(forHTTPHeaderField: "Authorization"))
                        XCTAssertNil($0.value(forHTTPHeaderField: "Cookie"))
                        XCTAssertEqual($0.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
                    }
                ), for: delivery
            )
            do {
                let result = try await client().probeRange(
                    root: root, url: source, sessionKey: key(),
                    credential: .bearerToken("account-secret"), trustPolicy: .system, prefetch: true
                )
                XCTAssertEqual(bodyLength, count, "Partial or oversized prefixes must fail")
                XCTAssertEqual(result.initialData, Data(repeating: 42, count: count))
                XCTAssertTrue(result.usesAnonymousSession)
                XCTAssertEqual(result.resourceURL, delivery)
            } catch let error as TransportError {
                XCTAssertNotEqual(bodyLength, count, "Valid prefix failed: \(error)")
                switch error {
                case .rangeValidationFailed, .responseTooLarge: break
                default: XCTFail("Unexpected prefix rejection: \(error)")
                }
            }
        }
    }

    func testReturnToDAVOriginNeverRestoresCredentials() async throws {
        let returned = URL(string: "https://dav.example.com/files/returned.mkv")!
        StubURLProtocol.queue(redirect: StubRedirect(location: delivery), for: source)
        StubURLProtocol.queue(redirect: StubRedirect(location: returned, onRequest: {
            XCTAssertNil($0.value(forHTTPHeaderField: "Authorization"))
        }), for: delivery)
        queueProbe(at: returned)
        let result = try await client().probeRange(
            root: root, url: source, sessionKey: key(),
            credential: .bearerToken("account-secret"), trustPolicy: .system
        )
        XCTAssertTrue(result.usesAnonymousSession)
        XCTAssertEqual(result.resourceURL, returned)
    }

    func testSameOriginMediaRedirectRetainsAuthAndRange() async throws {
        let final = URL(string: "https://dav.example.com/files/final.mkv")!
        StubURLProtocol.queue(redirect: StubRedirect(location: final), for: source)
        StubURLProtocol.queue(
            StubResponse(
                statusCode: 206, headers: ["ETag": "\"same\"", "Content-Range": "bytes 0-1/1000"],
                body: Data([0, 0]),
                onRequest: {
                    XCTAssertNotNil($0.value(forHTTPHeaderField: "Authorization"))
                    XCTAssertEqual($0.value(forHTTPHeaderField: "Range"), "bytes=0-1")
                }
            ), for: final
        )
        let result = try await client().probeRange(
            root: root, url: source, sessionKey: key(),
            credential: .bearerToken("account-secret"), trustPolicy: .system
        )
        XCTAssertFalse(result.usesAnonymousSession)
    }

    func testRedirectStatusesAndBodiesAreHandledWithoutDownloadingRedirectBody() async throws {
        for status in [301, 302, 303, 307, 308] {
            StubURLProtocol.queue(
                StubResponse(
                    statusCode: status,
                    headers: ["Location": delivery.absoluteString, "Content-Length": "1000000"],
                    body: Data(repeating: 0, count: 100)
                ), for: source
            )
            queueProbe(at: delivery)
            let result = try await client().probeRange(
                root: root, url: source, sessionKey: key(), credential: .anonymous, trustPolicy: .system
            )
            XCTAssertEqual(result.resourceURL, delivery)
        }
    }

    func testRedirectRejectsUnsafeDestinationsBeforeDispatch() async throws {
        for destination in [
            "http://cdn.example.net/movie", "file:///tmp/movie", "https://user:pass@cdn.example.net/movie",
            "https://127.0.0.1/movie", "https://[::1]/movie", "https://192.168.1.2/movie",
            "https://nas.local/movie", "https://localhost/movie", "https://nas/movie",
            "https://cdn.example.net/movie#fragment", "https://dav.example.com/outside/movie"
        ] {
            let url = try XCTUnwrap(URL(string: destination))
            StubURLProtocol.queue(redirect: StubRedirect(location: url), for: source)
            do {
                _ = try await client().probeRange(
                    root: root, url: source, sessionKey: key(),
                    credential: .bearerToken("account-secret"), trustPolicy: .system
                )
                XCTFail("unsafe destination was accepted")
            } catch is TransportError {
                XCTAssertTrue(StubURLProtocol.requests(for: url).isEmpty)
            }
        }
    }

    func testEveryRedirectHopIsChecked() async throws {
        let local = URL(string: "https://localhost/private")!
        StubURLProtocol.queue(redirect: StubRedirect(location: delivery), for: source)
        StubURLProtocol.queue(redirect: StubRedirect(location: local), for: delivery)
        do {
            _ = try await client().probeRange(
                root: root, url: source, sessionKey: key(), credential: .anonymous, trustPolicy: .system
            )
            XCTFail("unsafe second hop was accepted")
        } catch let error as TransportError {
            guard case .crossOriginRedirectRejected = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertTrue(StubURLProtocol.requests(for: local).isEmpty)
    }

    func testRedirectLoopHasFixedBudget() async throws {
        for _ in 0...WebDAVMediaRedirectPolicy.maximumRedirects {
            StubURLProtocol.queue(redirect: StubRedirect(location: source), for: source)
        }
        do {
            _ = try await client().probeRange(
                root: root, url: source, sessionKey: key(), credential: .anonymous, trustPolicy: .system
            )
            XCTFail("loop should terminate")
        } catch let error as TransportError {
            XCTAssertEqual(error, .tooManyRedirects(limit: 5))
        }
        XCTAssertEqual(StubURLProtocol.requests(for: source).count, 6)
    }

    func testActiveReadDoesNotSilentlyRebindToAnotherDelivery() async throws {
        let client = client()
        let key = try key()
        StubURLProtocol.queue(redirect: StubRedirect(location: delivery), for: source)
        queueProbe(at: delivery)
        let probe = try await client.probeRange(
            root: root, url: source, sessionKey: key, credential: .anonymous, trustPolicy: .system
        )
        let replacement = URL(string: "https://other.example.net/movie")!
        StubURLProtocol.queue(redirect: StubRedirect(location: replacement), for: delivery)
        do {
            _ = try await client.readRange(
                url: delivery, start: 10, end: 19, representation: probe,
                sessionKey: key, credential: .anonymous, trustPolicy: .system
            )
            XCTFail("active representation must remain pinned")
        } catch let error as TransportError {
            guard case .sourceChanged = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertTrue(StubURLProtocol.requests(for: replacement).isEmpty)
    }

    func testBoundedSidecarUsesSameCredentialFreeDeliveryPolicy() async throws {
        StubURLProtocol.queue(redirect: StubRedirect(location: delivery), for: source)
        StubURLProtocol.queue(
            StubResponse(statusCode: 200, body: Data("subtitle".utf8), onRequest: {
                XCTAssertNil($0.value(forHTTPHeaderField: "Authorization"))
            }), for: delivery
        )
        let data = try await client().getBounded(
            root: root, url: source, maxBytes: 64, sessionKey: key(),
            credential: .bearerToken("account-secret"), trustPolicy: .system
        )
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "subtitle")
    }

    func testCancelledProbeDoesNotDispatch() async throws {
        let client = client()
        let key = try key()
        let root = root
        let source = source
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.probeRange(
                root: root, url: source, sessionKey: key, credential: .anonymous, trustPolicy: .system
            )
        }
        do {
            _ = try await task.value
            XCTFail("cancelled work must not start")
        } catch is CancellationError {
            XCTAssertTrue(StubURLProtocol.requests(for: source).isEmpty)
        }
    }
}
