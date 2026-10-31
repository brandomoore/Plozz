import CoreModels
import XCTest
@testable import MediaTransportHTTP
@testable import TestSupportNetworking

final class TransportSessionRegistryTests: XCTestCase {
    func testPasswordReuseIsConfinedToTheExactManagedSession() async throws {
        let authorization = "Basic " + Data("fixture:password".utf8).base64EncodedString()
        let server = try LoopbackHTTPServer { request in
            if request.target == "/anonymous" {
                return .init(body: Data(request.headers["authorization"] == nil ? [1] : [0]))
            }
            guard request.headers["authorization"] == authorization else {
                return .init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"fixture\""])
            }
            return .init(body: Data([7]))
        }
        let base = try await server.start()
        let registry = TransportSessionRegistry()
        addTeardownBlock { await registry.drainAll(); await server.stop() }
        let origin = try XCTUnwrap(TransportOrigin(url: base))
        let key = try makeKey(origin: origin)
        let credential = WebDAVCredential.password(username: "fixture", password: "password", policy: .automatic)
        let first = try await registry.session(for: key, credential: credential, trustPolicy: .system)
        XCTAssertNil(first.session.configuration.urlCredentialStorage)
        var request = URLRequest(url: base.appendingPathComponent("dav/file"))
        request.timeoutInterval = 5
        let initial = try await first.data(for: request, maxResponseBytes: 1)
        XCTAssertEqual(initial.data, Data([7]))
        request.httpMethod = "PROPFIND"
        let repeated = try await first.data(for: request, maxResponseBytes: 1)
        XCTAssertEqual(repeated.data, Data([7]))
        let firstRequests = await server.requests
        XCTAssertEqual(firstRequests.count, 3, "Only the first task should pay for a 401 challenge")
        XCTAssertNil(firstRequests.first?.headers["authorization"])

        let otherKeys = try [
            makeKey(accountID: "other", credentialRevision: key.credentialRevision.rawValue,
                    origin: origin, trustRevision: key.trustRevision, role: key.role),
            makeKey(accountID: key.accountID, origin: origin, trustRevision: key.trustRevision, role: key.role),
            makeKey(accountID: key.accountID, credentialRevision: key.credentialRevision.rawValue,
                    origin: origin, role: key.role),
            makeKey(accountID: key.accountID, credentialRevision: key.credentialRevision.rawValue,
                    origin: origin, trustRevision: key.trustRevision, role: .playback)
        ]
        for otherKey in otherKeys {
            let before = await server.requests.count
            let isolated = try await registry.session(for: otherKey, credential: credential, trustPolicy: .system)
            let result = try await isolated.data(for: request, maxResponseBytes: 1)
            XCTAssertEqual(result.data, Data([7]))
            let newRequests = Array(await server.requests.dropFirst(before))
            XCTAssertEqual(newRequests.count, 2)
            XCTAssertNil(newRequests.first?.headers["authorization"], "Another session must not inherit authentication")
        }

        let media = try await registry.mediaSession(for: key, origin: origin)
        let anonymous = try await media.data(
            for: URLRequest(url: base.appendingPathComponent("anonymous")), maxResponseBytes: 1
        )
        XCTAssertEqual(anonymous.data, Data([1]), "Anonymous delivery must not inherit account authentication")
        await registry.invalidate(key)
        let before = await server.requests.count
        let replacement = try await registry.session(for: key, credential: credential, trustPolicy: .system)
        _ = try await replacement.data(for: request, maxResponseBytes: 1)
        let newRequests = Array(await server.requests.dropFirst(before))
        XCTAssertEqual(newRequests.count, 2)
        XCTAssertNil(newRequests.first?.headers["authorization"], "Retirement must discard session authentication")
        let anonymousRequestsBefore = await server.requests.count
        let anonymousAccount = try await registry.session(
            for: makeKey(origin: origin), credential: .anonymous, trustPolicy: .system
        )
        _ = try await anonymousAccount.data(
            for: URLRequest(url: base.appendingPathComponent("anonymous")), maxResponseBytes: 1
        )
        let anonymousRequests = Array(await server.requests.dropFirst(anonymousRequestsBefore))
        XCTAssertNil(anonymousRequests.first?.headers["authorization"])
        let space = URLProtectionSpace(
            host: origin.host, port: origin.port, protocol: origin.scheme,
            realm: "fixture", authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        XCTAssertTrue(URLCredentialStorage.shared.credentials(for: space)?.isEmpty ?? true)
    }

    func testPreviouslyAcceptedPasswordStillFailsWhenServerRejectsIt() async throws {
        let acceptsPassword = LockedValue(true)
        let server = try LoopbackHTTPServer { request in
            if acceptsPassword.get(), request.headers["authorization"] != nil {
                return .init(body: Data([7]))
            }
            return .init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"fixture\""])
        }
        let base = try await server.start()
        let registry = TransportSessionRegistry()
        addTeardownBlock { await registry.drainAll(); await server.stop() }
        let session = try await registry.session(
            for: makeKey(origin: XCTUnwrap(TransportOrigin(url: base))),
            credential: .password(username: "fixture", password: "password", policy: .automatic),
            trustPolicy: .system
        )
        var request = URLRequest(url: base.appendingPathComponent("dav/file"))
        request.timeoutInterval = 5
        _ = try await session.data(for: request, maxResponseBytes: 1)
        acceptsPassword.set(false)
        let before = await server.requests.count
        do {
            _ = try await session.data(for: request, maxResponseBytes: 1)
            XCTFail("Remembered authentication must not turn a server rejection into success")
        } catch let error as TransportError {
            guard case .authenticationFailed = error else { return XCTFail("Unexpected rejection: \(error)") }
        }
        let attempts = await server.requests.count - before
        XCTAssertGreaterThan(attempts, 0)
        XCTAssertLessThanOrEqual(attempts, 2, "A rejected credential must not loop")
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testThrottledSessionSuppressesFurtherRequestsWithoutSleepingOrRetrying() async throws {
        let url = try XCTUnwrap(URL(string: "https://nas.example.com/dav/movie.iso"))
        for headers in [
            ["Retry-After": "60"],
            ["Retry-After": HTTPDate.string(from: Date().addingTimeInterval(60))],
            ["Retry-After": "invalid"],
            [:]
        ] {
            StubURLProtocol.reset()
            let registry = TransportSessionRegistry(testProtocolClasses: [StubURLProtocol.self])
            let session = try await registry.session(for: makeKey(), credential: .anonymous, trustPolicy: .system)
            StubURLProtocol.queue(StubResponse(statusCode: 429, headers: headers), for: url)
            let result = try await session.data(for: URLRequest(url: url), maxResponseBytes: 1)
            XCTAssertEqual(result.response.statusCode, 429)
            for _ in 0..<4 {
                do {
                    _ = try await session.data(for: URLRequest(url: url), maxResponseBytes: 1)
                    XCTFail("The active server cooldown must suppress new tasks")
                } catch let error as TransportError {
                    guard case .protocolError(status: 429, detail: _) = error else {
                        XCTFail("Unexpected cooldown error: \(error)")
                        continue
                    }
                }
            }
            XCTAssertEqual(StubURLProtocol.requests(for: url).count, 1)
            await registry.drainAll()
        }
    }

    func testExpiredRetryAfterPermitsAnExplicitNewRequest() async throws {
        let url = try XCTUnwrap(URL(string: "https://nas.example.com/dav/movie.iso"))
        for value in ["0", HTTPDate.string(from: Date().addingTimeInterval(-60))] {
            StubURLProtocol.reset()
            let registry = TransportSessionRegistry(testProtocolClasses: [StubURLProtocol.self])
            let session = try await registry.session(for: makeKey(), credential: .anonymous, trustPolicy: .system)
            StubURLProtocol.queue(StubResponse(statusCode: 429, headers: ["Retry-After": value]), for: url)
            StubURLProtocol.queue(StubResponse(statusCode: 200, body: Data([7])), for: url)
            _ = try await session.data(for: URLRequest(url: url), maxResponseBytes: 1)
            let next = try await session.data(for: URLRequest(url: url), maxResponseBytes: 1)
            XCTAssertEqual(next.data, Data([7]))
            XCTAssertEqual(StubURLProtocol.requests(for: url).count, 2)
            await registry.drainAll()
        }
    }

    func testDeliveryCooldownDoesNotBlockDAVOrAnotherAccount() async throws {
        let registry = TransportSessionRegistry(testProtocolClasses: [StubURLProtocol.self])
        let key = try makeKey()
        let mediaURL = try XCTUnwrap(URL(string: "https://cdn.example.com/movie"))
        let davURL = try XCTUnwrap(URL(string: "https://nas.example.com/dav"))
        let mediaOrigin = try XCTUnwrap(TransportOrigin(url: mediaURL))
        let media = try await registry.mediaSession(for: key, origin: mediaOrigin)
        StubURLProtocol.queue(StubResponse(statusCode: 429, headers: ["Retry-After": "60"]), for: mediaURL)
        _ = try await media.data(for: URLRequest(url: mediaURL), maxResponseBytes: 1)
        let other = try await registry.mediaSession(for: makeKey(accountID: "other"), origin: mediaOrigin)
        let dav = try await registry.session(for: key, credential: .anonymous, trustPolicy: .system)
        for (session, url) in [(other, mediaURL), (dav, davURL)] {
            StubURLProtocol.queue(StubResponse(statusCode: 200, body: Data([7])), for: url)
            let result = try await session.data(for: URLRequest(url: url), maxResponseBytes: 1)
            XCTAssertEqual(result.data, Data([7]))
        }
        await registry.drainAll()
    }

    func testMediaSessionsSeparateAccountCredentialsAndTrustEvenOnReturnHop() async throws {
        let registry = TransportSessionRegistry()
        let key = try makeKey()
        let origin = try XCTUnwrap(key.origin)
        let account = try await registry.session(
            for: key, credential: .bearerToken("account-secret"),
            trustPolicy: .pinnedLeaf(sha256: Data(repeating: 1, count: 32), revision: key.trustRevision)
        )
        let media = try await registry.mediaSession(for: key, origin: origin)
        XCTAssertFalse(account === media)
        XCTAssertTrue(media.matches(credential: .anonymous, trustPolicy: .system))
        XCTAssertNil(media.session.configuration.urlCredentialStorage)
        XCTAssertNil(media.session.configuration.httpCookieStorage)
        let same = try await registry.mediaSession(for: key, origin: origin)
        XCTAssertTrue(same === media)
        await registry.invalidate(key)
        let count = await registry.liveSessionCount
        XCTAssertEqual(count, 0, "retiring the source also retires its delivery sessions")
    }

    func testMediaSessionsStayScopedToAccountRevisionAndRole() async throws {
        let registry = TransportSessionRegistry()
        let origin = TransportOrigin(url: URL(string: "https://cdn.example.com/")!)!
        let keyA = try makeKey()
        let keyB = try makeKey(accountID: "other")
        let first = try await registry.mediaSession(for: keyA, origin: origin)
        let second = try await registry.mediaSession(for: keyB, origin: origin)
        XCTAssertFalse(first === second)
        await registry.invalidateAll { $0.accountID == keyA.accountID }
        let count = await registry.liveSessionCount
        XCTAssertEqual(count, 1)
        let replacement = try await registry.mediaSession(for: keyA, origin: origin)
        XCTAssertFalse(first === replacement)
    }

    private func makeKey(
        accountID: String = "account-1",
        credentialRevision: UUID = UUID(),
        origin: TransportOrigin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!,
        trustRevision: UUID = UUID(),
        role: TransportRole = .scanner
    ) throws -> TransportSessionKey {
        try TransportSessionKey(
            accountID: accountID,
            credentialRevision: credentialRevision,
            origin: origin,
            trustRevision: trustRevision,
            role: role
        )
    }

    func testEqualKeyReturnsSameSessionInstance() async throws {
        let registry = TransportSessionRegistry()
        let key = try makeKey()
        let first = try await registry.session(for: key, credential: .anonymous, trustPolicy: .system)
        let second = try await registry.session(for: key, credential: .anonymous, trustPolicy: .system)
        XCTAssertTrue(first === second)
        let count = await registry.liveSessionCount
        XCTAssertEqual(count, 1)
    }

    /// Regression guard for the WebDAV scan-parallelism fix: the parallel share
    /// scanner shares ONE scanner-role session across its lister pool, so that
    /// session must allow several connections to the host. A cap of 1 (the prior
    /// value) silently serialized the whole walk onto one connection.
    func testManagedSessionAllowsParallelConnectionsPerHost() async throws {
        let registry = TransportSessionRegistry()
        let session = try await registry.session(for: makeKey(), credential: .anonymous, trustPolicy: .system)
        let cap = session.session.configuration.httpMaximumConnectionsPerHost
        XCTAssertGreaterThanOrEqual(cap, 4, "scanner session must fan the scan pool across connections, not serialize on one")
        XCTAssertEqual(cap, TransportSessionRegistry.maxConnectionsPerHost)
    }

    func testDifferentAccountIDYieldsDistinctSession() async throws {
        let registry = TransportSessionRegistry()
        let revision = UUID()
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let keyA = try makeKey(accountID: "account-A", credentialRevision: revision, origin: origin, trustRevision: revision)
        let keyB = try makeKey(accountID: "account-B", credentialRevision: revision, origin: origin, trustRevision: revision)

        let sessionA = try await registry.session(for: keyA, credential: .anonymous, trustPolicy: .system)
        let sessionB = try await registry.session(for: keyB, credential: .anonymous, trustPolicy: .system)
        XCTAssertFalse(sessionA === sessionB)
        let count = await registry.liveSessionCount
        XCTAssertEqual(count, 2)
    }

    func testDifferentCredentialRevisionYieldsDistinctSession() async throws {
        let registry = TransportSessionRegistry()
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let trust = UUID()
        let keyA = try makeKey(credentialRevision: UUID(), origin: origin, trustRevision: trust)
        let keyB = try makeKey(credentialRevision: UUID(), origin: origin, trustRevision: trust)

        let sessionA = try await registry.session(for: keyA, credential: .anonymous, trustPolicy: .system)
        let sessionB = try await registry.session(for: keyB, credential: .anonymous, trustPolicy: .system)
        XCTAssertFalse(sessionA === sessionB)
    }

    func testDifferentOriginYieldsDistinctSession() async throws {
        let registry = TransportSessionRegistry()
        let revision = UUID()
        let keyA = try makeKey(
            credentialRevision: revision,
            origin: TransportOrigin(url: URL(string: "https://nas-a.example.com/")!)!,
            trustRevision: revision
        )
        let keyB = try makeKey(
            credentialRevision: revision,
            origin: TransportOrigin(url: URL(string: "https://nas-b.example.com/")!)!,
            trustRevision: revision
        )

        let sessionA = try await registry.session(for: keyA, credential: .anonymous, trustPolicy: .system)
        let sessionB = try await registry.session(for: keyB, credential: .anonymous, trustPolicy: .system)
        XCTAssertFalse(sessionA === sessionB)
    }

    func testDifferentTrustRevisionYieldsDistinctSession() async throws {
        let registry = TransportSessionRegistry()
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let credentialRevision = UUID()
        let keyA = try makeKey(credentialRevision: credentialRevision, origin: origin, trustRevision: UUID())
        let keyB = try makeKey(credentialRevision: credentialRevision, origin: origin, trustRevision: UUID())

        let sessionA = try await registry.session(for: keyA, credential: .anonymous, trustPolicy: .system)
        let sessionB = try await registry.session(for: keyB, credential: .anonymous, trustPolicy: .system)
        XCTAssertFalse(sessionA === sessionB)
    }

    func testDifferentRoleYieldsDistinctSession() async throws {
        let registry = TransportSessionRegistry()
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let revision = UUID()
        let keyScanner = try makeKey(credentialRevision: revision, origin: origin, trustRevision: revision, role: .scanner)
        let keyPlayback = try makeKey(credentialRevision: revision, origin: origin, trustRevision: revision, role: .playback)

        let scannerSession = try await registry.session(for: keyScanner, credential: .anonymous, trustPolicy: .system)
        let playbackSession = try await registry.session(for: keyPlayback, credential: .anonymous, trustPolicy: .system)
        XCTAssertFalse(scannerSession === playbackSession)
    }

    func testInvalidateRemovesSessionSoANewOneIsMintedNextTime() async throws {
        let registry = TransportSessionRegistry()
        let key = try makeKey()
        let first = try await registry.session(for: key, credential: .anonymous, trustPolicy: .system)
        await registry.invalidate(key)
        let countAfterInvalidate = await registry.liveSessionCount
        XCTAssertEqual(countAfterInvalidate, 0)

        let second = try await registry.session(for: key, credential: .anonymous, trustPolicy: .system)
        XCTAssertFalse(first === second)
    }

    func testInvalidateAllRemovesOnlyMatchingSessions() async throws {
        let registry = TransportSessionRegistry()
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let keyA = try makeKey(accountID: "keep-me", origin: origin)
        let keyB = try makeKey(accountID: "remove-me", origin: origin)
        _ = try await registry.session(for: keyA, credential: .anonymous, trustPolicy: .system)
        _ = try await registry.session(for: keyB, credential: .anonymous, trustPolicy: .system)

        await registry.invalidateAll(where: { $0.accountID == "remove-me" })
        let count = await registry.liveSessionCount
        XCTAssertEqual(count, 1)
    }

    func testDrainAllRemovesEverySession() async throws {
        let registry = TransportSessionRegistry()
        _ = try await registry.session(for: try makeKey(accountID: "a"), credential: .anonymous, trustPolicy: .system)
        _ = try await registry.session(for: try makeKey(accountID: "b"), credential: .anonymous, trustPolicy: .system)
        await registry.drainAll()
        let count = await registry.liveSessionCount
        XCTAssertEqual(count, 0)
    }

    func testEqualRevisionCannotBeReusedWithDifferentCredentialMaterial() async throws {
        let registry = TransportSessionRegistry()
        let key = try makeKey()
        _ = try await registry.session(
            for: key,
            credential: .password(username: "user", password: "first", policy: .automatic),
            trustPolicy: .system
        )

        do {
            _ = try await registry.session(
                for: key,
                credential: .password(username: "user", password: "second", policy: .automatic),
                trustPolicy: .system
            )
            XCTFail("expected sessionConfigurationMismatch")
        } catch let error as TransportError {
            XCTAssertEqual(error, .sessionConfigurationMismatch)
        }
    }

    func testPinnedTrustRevisionMustMatchSessionKey() async throws {
        let registry = TransportSessionRegistry()
        let key = try makeKey(trustRevision: UUID())
        let policy = TrustPolicy.pinnedLeaf(sha256: Data(repeating: 1, count: 32), revision: UUID())

        do {
            _ = try await registry.session(for: key, credential: .anonymous, trustPolicy: policy)
            XCTFail("expected sessionConfigurationMismatch")
        } catch let error as TransportError {
            XCTAssertEqual(error, .sessionConfigurationMismatch)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testInvalidatedSessionRejectsNewTaskWithoutCallingURLSession() async throws {
        let registry = TransportSessionRegistry(testProtocolClasses: [StubURLProtocol.self])
        let key = try makeKey()
        let session = try await registry.session(for: key, credential: .anonymous, trustPolicy: .system)
        session.invalidateAndCancel()

        do {
            _ = try await session.data(
                for: URLRequest(url: URL(string: "https://nas.example.com/dav")!),
                maxResponseBytes: 1
            )
            XCTFail("expected cancelled")
        } catch let error as TransportError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    // MARK: - Redacted description

    func testSessionKeyDescriptionDoesNotLeakCredentialOrTrustMaterial() throws {
        let key = try makeKey(accountID: "household-nas")
        let description = key.description
        // Only opaque identifiers/origin/role are present — nothing that
        // resolves to a password/token/certificate.
        XCTAssertTrue(description.contains("household-nas"))
        XCTAssertTrue(description.contains("nas.example.com"))
        XCTAssertTrue(description.contains("scanner"))
    }
}
