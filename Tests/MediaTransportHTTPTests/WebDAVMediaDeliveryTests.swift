import CoreModels
import XCTest
@testable import MediaTransportHTTP
@testable import TestSupportNetworking

final class WebDAVMediaDeliveryTests: XCTestCase {
    private actor StreamedBody {
        var data = Data()
        func append(_ chunk: Data) { data.append(chunk) }
    }

    func testWholeDeliveryUsesOneAnonymousUnconditionalResponse() async throws {
        let body = StreamedBody()
        let payload = Data(repeating: 7, count: 1000)
        StubURLProtocol.queue(
            StubResponse(statusCode: 200, headers: ["Content-Length": "1000"], body: payload, onRequest: {
                XCTAssertEqual($0.httpMethod, "GET")
                for header in ["Range", "If-Match", "If-Unmodified-Since", "Authorization", "Cookie", "Referer"] {
                    XCTAssertNil($0.value(forHTTPHeaderField: header))
                }

                XCTAssertEqual($0.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
            }), for: delivery
        )
        try await client().streamWholeDelivery(
            representation: .init(validator: .unvalidatedPlayback, totalLength: 1000,
                                  resourceURL: delivery, usesAnonymousSession: true),
            sessionKey: key()
        ) { await body.append($0) }
        let actual = await body.data
        XCTAssertEqual(actual, payload)
        XCTAssertEqual(StubURLProtocol.requests(for: delivery).count, 1)
    }

    func testWholeDeliveryCancellationDrainsConsumerBeforeReturning() async throws {
        let started = expectation(description: "Consumer started")
        let finished = expectation(description: "Consumer exited")
        StubURLProtocol.queue(StubResponse(statusCode: 200, body: Data(repeating: 1, count: 1000)), for: delivery)
        let client = client()
        let representation = RangeProbeResult(
            validator: .unvalidatedPlayback, totalLength: 1000,
            resourceURL: delivery, usesAnonymousSession: true
        )
        let key = try key()
        let task = Task {
            try await client.streamWholeDelivery(representation: representation, sessionKey: key) { _ in
                started.fulfill()
                defer { finished.fulfill() }
                try await Task.sleep(for: .seconds(30))
                XCTFail("Cancelled consumer must not finish its write")
            }
        }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled transfer must not succeed")
        } catch is CancellationError {
        } catch let error as TransportError { XCTAssertEqual(error, .cancelled) }
        await fulfillment(of: [finished], timeout: 1)
    }

    func testWholeDeliveryAccountRetirementCancelsItsNetworkRequest() async throws {
        let started = expectation(description: "Request started")
        let registry = TransportSessionRegistry(testProtocolClasses: [StubURLProtocol.self])
        let client = WebDAVClient(registry: registry)
        let key = try key()
        let representation = RangeProbeResult(
            validator: .unvalidatedPlayback, totalLength: 1000,
            resourceURL: delivery, usesAnonymousSession: true
        )
        StubURLProtocol.queue(
            StubResponse(statusCode: 200, body: Data(repeating: 1, count: 1000),
                         delay: .seconds(30), onRequest: { _ in started.fulfill() }), for: delivery
        )
        let task = Task {
            try await client.streamWholeDelivery(representation: representation, sessionKey: key) { _ in
                XCTFail("Retired account must not deliver bytes")
            }
        }
        await fulfillment(of: [started], timeout: 3)
        await registry.invalidate(key)
        do {
            try await task.value
            XCTFail("Retired request must fail")
        } catch let error as TransportError { XCTAssertEqual(error, .cancelled) }
    }

    func testWholeDeliveryPreservesHTTPRefusalAndCooldown() async throws {
        let client = client()
        let key = try key()
        StubURLProtocol.queue(
            StubResponse(statusCode: 429, headers: ["Retry-After": "30"]), for: delivery
        )
        for _ in 0..<2 {
            do {
                try await client.streamWholeDelivery(
                    representation: .init(validator: .unvalidatedPlayback, totalLength: 1000,
                                          resourceURL: delivery, usesAnonymousSession: true),
                    sessionKey: key
                ) { _ in XCTFail("HTTP refusal cannot deliver media") }
                XCTFail("Expected cooldown")
            } catch let error as TransportError {
                guard case .protocolError(status: 429, detail: _) = error else {
                    return XCTFail("Lost HTTP refusal: \(error)")
                }
            }
        }
        XCTAssertEqual(StubURLProtocol.requests(for: delivery).count, 1)
    }

    func testWholeDeliveryRejectsInvalidOrIncompleteResponses() async throws {
        for (status, headers, count) in [
            (206, ["Content-Range": "bytes 0-999/1000"], 1000),
            (200, ["Content-Encoding": "gzip"], 1000),
            (200, ["Content-Length": "999"], 999),
            (200, [:], 999),
            (200, [:], 1001),
            (403, [:], 0)
        ] {
            StubURLProtocol.queue(
                StubResponse(statusCode: status, headers: headers, body: Data(repeating: 1, count: count)),
                for: delivery
            )
            do {
                try await client().streamWholeDelivery(
                    representation: .init(validator: .unvalidatedPlayback, totalLength: 1000,
                                          resourceURL: delivery, usesAnonymousSession: true),
                    sessionKey: key()
                ) { _ in }
                XCTFail("Accepted invalid whole response: \(status), \(headers), \(count)")
            } catch is TransportError {
            }
        }
    }

    func testWholeDeliveryDoesNotFollowRedirectOrUseOtherRoles() async throws {
        let replacement = URL(string: "https://replacement.example.net/file")!
        StubURLProtocol.queue(redirect: StubRedirect(location: replacement), for: delivery)
        do {
            try await client().streamWholeDelivery(
                representation: .init(validator: .unvalidatedPlayback, totalLength: 1000,
                                      resourceURL: delivery, usesAnonymousSession: true),
                sessionKey: key()
            ) { _ in XCTFail("Redirect body is not media") }
            XCTFail("Active delivery URL must not change")
        } catch is TransportError {}
        XCTAssertTrue(StubURLProtocol.requests(for: replacement).isEmpty)
        for role in TransportRole.allCases where role != .playback {
            let other = try TransportSessionKey(
                accountID: "account", credentialRevision: UUID(), origin: root.origin,
                trustRevision: UUID(), role: role
            )
            do {
                try await client().streamWholeDelivery(
                    representation: .init(validator: .unvalidatedPlayback, totalLength: 1000,
                                          resourceURL: delivery, usesAnonymousSession: true),
                    sessionKey: other
                ) { _ in XCTFail("Non-playback role must not receive media") }
                XCTFail("Expected role rejection")
            } catch let error as TransportError { XCTAssertEqual(error, .seekableRequiresValidator) }
        }
        XCTAssertEqual(StubURLProtocol.requests(for: delivery).count, 1)
    }

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

    func testStatFailureRecordsHTTPStatusWithoutResponseBodyOrCredentials() async throws {
        let wasEnabled = HandoffDiagnostics.isEnabled
        HandoffDiagnostics.setEnabled(true)
        defer { HandoffDiagnostics.setEnabled(wasEnabled) }
        StubURLProtocol.queue(
            StubResponse(statusCode: 404, body: Data("private-server-response".utf8)), for: source
        )
        do {
            _ = try await client().properties(
                root: root, path: "/files/movie.mkv", sessionKey: key(),
                credential: .bearerToken("private-account-secret"), trustPolicy: .system
            )
            XCTFail("A failed stat must not become usable metadata")
        } catch let error as TransportError {
            guard case .protocolError(let status, _) = error else { return XCTFail("Unexpected \(error)") }
            XCTAssertEqual(status, 404)
        }
        let line = try XCTUnwrap(HandoffDiagnostics.persistentPlaybackLogText()
            .components(separatedBy: "\n").last { $0.contains("webdav PROPFIND depth=0") })
        XCTAssertTrue(line.contains("role=playback"))
        XCTAssertTrue(line.contains("status=404 bytes=0"))
        for secret in ["private-server-response", "private-account-secret", "example", "movie.mkv"] {
            XCTAssertFalse(line.contains(secret))
        }
    }

    func testRejectedDeliveryProbeRecordsValidatorClassificationsWithoutSecrets() async throws {
        let wasEnabled = HandoffDiagnostics.isEnabled
        HandoffDiagnostics.setEnabled(true)
        defer { HandoffDiagnostics.setEnabled(wasEnabled) }
        let before = HandoffDiagnostics.persistentPlaybackLogText()
        StubURLProtocol.queue(redirect: StubRedirect(location: delivery), for: source)
        StubURLProtocol.queue(
            StubResponse(
                statusCode: 206,
                headers: ["ETag": "W/\"private-validator\"", "Content-Range": "bytes 0-1/1000"],
                body: Data([0, 0])
            ), for: delivery
        )
        do {
            _ = try await client().probeRange(
                root: root, url: source, sessionKey: key(),
                credential: .bearerToken("account-secret"), trustPolicy: .system
            )
            XCTFail("A missing usable validator must still reject playback")
        } catch let error as TransportError {
            XCTAssertEqual(error, .seekableRequiresValidator)
        }
        let after = HandoffDiagnostics.persistentPlaybackLogText()
        let diagnostic = try XCTUnwrap(after.components(separatedBy: "\n").last {
            $0.contains("webdav PROBE_REJECTED")
        })
        XCTAssertFalse(before.contains(diagnostic))
        XCTAssertTrue(diagnostic.contains(
            "failure=seekableRequiresValidator anonymous=true prefetch=false "
                + "status=206 bytes=2 etag=weak lastModified=missing contentRange=valid encoding=missing"
        ))
        for secret in ["account-secret", "private-validator", "signature", "example", "movie.mkv"] {
            XCTAssertFalse(diagnostic.contains(secret))
        }
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

    func testUnvalidatedPlaybackCannotReturnToDAVOrigin() async throws {
        StubURLProtocol.queue(redirect: StubRedirect(location: delivery), for: source)
        StubURLProtocol.queue(redirect: StubRedirect(location: source), for: delivery)
        StubURLProtocol.queue(
            StubResponse(statusCode: 206, headers: ["Content-Range": "bytes 0-1/1000"],
                         body: Data([0, 0])), for: source
        )
        do {
            _ = try await client().probeRange(
                root: root, url: source, sessionKey: key(), credential: .anonymous,
                trustPolicy: .system, allowUnvalidatedPlayback: true
            )
            XCTFail("Anonymous delivery must still finish outside the DAV origin")
        } catch let error as TransportError {
            XCTAssertEqual(error, .seekableRequiresValidator)
        }
    }

    func testUnvalidatedPlaybackCannotEnableSameOriginOrNonPlaybackReads() async throws {
        for anonymous in [false, true] {
            for role in TransportRole.allCases {
                if anonymous && role == .playback { continue }
                let key = try TransportSessionKey(
                    accountID: "account", credentialRevision: UUID(), origin: root.origin,
                    trustRevision: UUID(), role: role
                )
                let target = anonymous ? delivery : source
                if anonymous {
                    StubURLProtocol.queue(redirect: StubRedirect(location: delivery), for: source)
                }
                StubURLProtocol.queue(
                    StubResponse(statusCode: 206, headers: ["Content-Range": "bytes 0-1/1000"],
                                 body: Data([0, 0])), for: target
                )
                do {
                    _ = try await client().probeRange(
                        root: root, url: source, sessionKey: key,
                        credential: .anonymous, trustPolicy: .system, allowUnvalidatedPlayback: true
                    )
                    XCTFail("Only anonymous playback delivery may omit validators")
                } catch let error as TransportError {
                    XCTAssertEqual(error, .seekableRequiresValidator)
                }
                let count = StubURLProtocol.requests(for: target).count
                let representation = RangeProbeResult(
                    validator: .unvalidatedPlayback, totalLength: 1000,
                    resourceURL: target, usesAnonymousSession: anonymous
                )
                do {
                    _ = try await client().readRange(
                        url: target, start: 0, end: 1, representation: representation,
                        sessionKey: key, credential: .anonymous, trustPolicy: .system
                    )
                    XCTFail("Unvalidated reads must retain the session-role boundary")
                } catch let error as TransportError {
                    XCTAssertEqual(error, .seekableRequiresValidator)
                }
                XCTAssertEqual(StubURLProtocol.requests(for: target).count, count)
            }
        }
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
