import Foundation
import XCTest
import CoreModels
import CoreNetworking
@testable import TraktService
@testable import TestSupportNetworking

private let config = TraktConfig(clientID: "client")
private let rotatedJSON = """
{"access_token":"new-access","refresh_token":"new-refresh","expires_in":604800,"created_at":\(Int(Date().timeIntervalSince1970))}
"""
private let expired = TraktTokens(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: .distantPast)

final class TraktPKCETests: XCTestCase {
    func testRFC7636ChallengeAndSecretlessAuthorization() throws {
        let request = try TraktPKCE(
            config: config,
            verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
            state: "state"
        )
        let components = try XCTUnwrap(URLComponents(url: request.authorizationURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "auth.trakt.tv")
        XCTAssertEqual(components.path, "/oauth/authorize")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["redirect_uri"], config.redirectURI.absoluteString)
        XCTAssertNil(query["code_verifier"])
        XCTAssertNil(query["client_secret"])
    }

    func testVerifierAndStateAreFreshForEveryAttempt() throws {
        let a = try TraktPKCE(config: config)
        let b = try TraktPKCE(config: config)
        XCTAssertEqual(a.verifier.count, 43)
        XCTAssertEqual(a.state.count, 43)
        XCTAssertNotEqual(a.verifier, b.verifier)
        XCTAssertNotEqual(a.state, b.state)
        XCTAssertNotEqual(a.verifier, a.state)
    }

    func testCallbackRejectsMismatchedOriginPathStateAndDuplicateParameters() throws {
        let request = try TraktPKCE(config: config, state: "expected")
        let valid = config.redirectURI.absoluteString
        XCTAssertEqual(try request.authorizationCode(from: XCTUnwrap(URL(string: valid + "?code=one&state=expected"))), "one")
        for url in [
            "http://plozz.app/auth/trakt/callback?code=one&state=expected",
            "https://other.example/auth/trakt/callback?code=one&state=expected",
            "https://plozz.app/?code=one&state=expected",
            valid + "?code=one&state=wrong",
            valid + "?code=one",
            valid + "?code=one&code=two&state=expected",
            valid + "?code=one&state=expected&state=expected",
            valid + "?code=one&state=expected#fragment",
            valid + "?state=expected&code=",
        ] {
            XCTAssertThrowsError(try request.authorizationCode(from: XCTUnwrap(URL(string: url))))
        }
        XCTAssertThrowsError(try request.authorizationCode(from: XCTUnwrap(URL(string: valid + "?error=access_denied&state=expected")))) {
            XCTAssertEqual($0 as? AppError, .cancelled)
        }
    }
}

final class TraktModernOAuthTests: XCTestCase {
    func testAllOAuthEndpointsUseAuthHostAndNoSecret() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/oauth/device/code", json: """
        {"device_code":"device","user_code":"ABCD","verification_url":"https://auth.trakt.tv/activate","expires_in":600,"interval":5}
        """)
        http.stub(pathSuffix: "/oauth/device/token", json: rotatedJSON)
        http.stub(pathSuffix: "/oauth/token", json: rotatedJSON)
        http.stubEmpty(pathSuffix: "/oauth/revoke")
        http.stub(pathSuffix: "/users/settings", json: #"{"user":{"username":"viewer"}}"#)
        let client = TraktClient(config: config, http: http)
        _ = try await client.requestDeviceCode()
        _ = try await client.requestToken(deviceCode: "device")
        _ = try await client.exchangeCode("code", verifier: "verifier")
        _ = try await client.refreshToken("refresh")
        try await client.revoke(accessToken: "access")
        _ = try await client.userSettings(accessToken: "access")
        for request in http.sent where request.path.hasPrefix("/oauth/") {
            XCTAssertEqual(request.baseURL.host, "auth.trakt.tv")
            XCTAssertEqual(request.json?["client_id"] as? String, "client")
            XCTAssertNil(request.json?["client_secret"])
        }
        XCTAssertEqual(http.sent[2].json?["code_verifier"] as? String, "verifier")
        XCTAssertEqual(http.sent[2].json?["redirect_uri"] as? String, config.redirectURI.absoluteString)
        XCTAssertEqual(http.sent[3].json?["redirect_uri"] as? String, config.redirectURI.absoluteString)
        XCTAssertEqual(http.sent.last?.baseURL.host, "api.trakt.tv")
    }

    func testRefreshInvalidGrantRequiresReconnect() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/oauth/token", json: #"{"error":"invalid_grant","error_description":"session not found"}"#, status: 400)
        do {
            _ = try await TraktAuthService(config: config, http: http).refresh("old")
            XCTFail("Expected rejected grant")
        } catch {
            XCTAssertEqual(error as? AppError, .unauthorized)
        }
    }

    func testTerminalPollingStatusesDoNotRetry() async {
        for status in [404, 409, 410, 418, 500] {
            let http = RecordingHTTPClient()
            http.stub(pathSuffix: "/oauth/device/token", json: "{}", status: status)
            let auth = TraktAuthService(config: config, http: http, sleep: { _ in })
            do {
                _ = try await auth.awaitToken(for: TraktDeviceCode(
                    deviceCode: "device", userCode: "ABCD", verificationURL: "https://auth.trakt.tv/activate",
                    expiresIn: 600, interval: 5
                ))
                XCTFail("Expected terminal error for \(status)")
            } catch {
                XCTAssertEqual(http.sent.count, 1)
            }
        }
    }

    func testPollingThrottleRespectsRetryAfterAndSlowsSubsequentPolls() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/oauth/device/token", json: "{}", status: 429, headers: ["Retry-After": "30"])
        http.stub(pathSuffix: "/oauth/device/token", json: "{}", status: 400)
        http.stub(pathSuffix: "/oauth/device/token", json: rotatedJSON)
        let delays = DelayRecorder()
        let auth = TraktAuthService(config: config, http: http, sleep: { await delays.record($0) })
        _ = try await auth.awaitToken(for: TraktDeviceCode(
            deviceCode: "device", userCode: "ABCD", verificationURL: "https://auth.trakt.tv/activate",
            expiresIn: 600, interval: 5
        ))
        let recorded = await delays.values
        XCTAssertEqual(recorded, [5, 30, 30])
    }
}

private actor DelayRecorder {
    var values: [TimeInterval] = []
    func record(_ value: TimeInterval) { values.append(value) }
}

final class TraktCredentialLifecycleTests: XCTestCase {
    @MainActor
    func testCancelAfterCredentialCommitDoesNotPretendDisconnected() async {
        let http = SuspendedSettingsHTTPClient()
        let store = InMemoryTraktTokenStore()
        let service = TraktService(config: config, http: http, tokenStore: store)
        var notifications = 0
        service.onConnectionAvailable = { notifications += 1 }
        service.connect { url, callback in
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "state" })?.value ?? ""
            return URL(string: callback.absoluteString + "?code=approved&state=\(state)")!
        }
        let task = service.connectTask
        await http.waitUntilStarted()
        XCTAssertEqual(service.phase, .connected(username: "Trakt"))
        XCTAssertEqual(store.load()?.accessToken, "new-access")
        service.cancelConnect()
        XCTAssertEqual(service.phase, .connected(username: "Trakt"))
        await http.failSettings()
        await task?.value
        XCTAssertEqual(service.phase, .connected(username: "Trakt"))
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(store.load()?.accessToken, "new-access")
    }

    @MainActor
    func testPKCEPersistenceFailureNeverPublishesConnected() async {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/oauth/token", json: rotatedJSON)
        let store = FailingTraktTokenStore(tokens: nil)
        let service = TraktService(config: config, http: http, tokenStore: store)
        service.connect { url, callback in
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "state" })?.value ?? ""
            return URL(string: callback.absoluteString + "?code=approved&state=\(state)")!
        }
        await service.connectTask?.value
        guard case .error = service.phase else { return XCTFail("Failed persistence must be visible") }
        XCTAssertNil(store.load())
        XCTAssertEqual(http.sentPaths, ["/oauth/token"])
    }

    @MainActor
    func testProfileSwitchInvalidatesBrowserCallbackBeforeExchange() async {
        let http = RecordingHTTPClient()
        let store = InMemoryTraktTokenStore()
        let service = TraktService(config: config, http: http, tokenStore: store)
        let began = expectation(description: "Browser opened")
        var resume: CheckedContinuation<URL, Never>?
        var result: URL?
        service.connect { url, callback in
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "state" })?.value ?? ""
            result = URL(string: callback.absoluteString + "?code=approved&state=\(state)")!
            return await withCheckedContinuation {
                resume = $0
                began.fulfill()
            }
        }
        let task = service.connectTask
        await fulfillment(of: [began], timeout: 5)
        await service.setActiveProfile(namespace: "B")
        if let result { resume?.resume(returning: result) }
        await task?.value
        XCTAssertEqual(service.phase, .disconnected)
        XCTAssertNil(store.load())
        store.setNamespace(nil)
        XCTAssertNil(store.load())
        XCTAssertTrue(http.sentPaths.isEmpty)
    }

    @MainActor
    func testPKCESavesBeforePublishingConnectedAndExchangesOnce() async {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/oauth/token", json: rotatedJSON)
        http.stub(pathSuffix: "/users/settings", json: #"{"user":{"username":"viewer"}}"#)
        let store = InMemoryTraktTokenStore()
        let service = TraktService(config: config, http: http, tokenStore: store)
        var notifications = 0
        service.onConnectionAvailable = {
            XCTAssertEqual(store.load()?.accessToken, "new-access")
            notifications += 1
        }
        service.connect { url, callback in
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "state" })?.value ?? ""
            return URL(string: callback.absoluteString + "?code=approved&state=\(state)")!
        }
        await service.connectTask?.value
        XCTAssertEqual(service.phase, .connected(username: "viewer"))
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(http.sentPaths, ["/oauth/token", "/users/settings"])
    }

    func testDurableScrobblePropagatesRefreshFailureWithoutSendingStop() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/oauth/token", json: "{}", status: 500)
        let store = InMemoryTraktTokenStore(tokens: expired)
        let scrobbler = TraktScrobbler(config: config, http: http, tokenStore: store)
        do {
            try await scrobbler.scrobbleResult(
                item: MediaItem(id: "movie", title: "Movie", kind: .movie, providerIDs: ["Imdb": "tt1"]),
                progress: 100, event: .stop
            )
            XCTFail("A refresh failure must retain the outbox mutation")
        } catch {
            XCTAssertEqual(error as? AppError, .invalidResponse)
        }
        XCTAssertEqual(http.sentPaths, ["/oauth/token"])
        XCTAssertEqual(store.load(), expired)
    }

    func testIndependentAdaptersShareOneSingleUseRefresh() async throws {
        let http = ControlledRefreshHTTPClient()
        let store = InMemoryTraktTokenStore(tokens: expired)
        let coordinator = TraktTokenCoordinator()
        let auth = TraktAuthService(config: config, http: http)
        let first = Task { try await coordinator.accessToken(store: store.snapshot(), auth: auth) }
        await http.waitUntilStarted()
        let second = Task { try await coordinator.accessToken(store: store.snapshot(), auth: auth) }
        await http.release()
        let values = try await [first.value, second.value]
        XCTAssertEqual(values, ["new-access", "new-access"])
        let count = await http.refreshCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.load()?.refreshToken, "new-refresh")
    }

    func testDisconnectRejectsLateRefreshFromAnotherStoreInstance() async throws {
        let http = ControlledRefreshHTTPClient()
        let store = InMemoryTraktTokenStore(tokens: expired)
        let coordinator = TraktTokenCoordinator()
        let refresh = Task {
            try await coordinator.accessToken(store: store.snapshot(), auth: TraktAuthService(config: config, http: http))
        }
        await http.waitUntilStarted()
        _ = try await coordinator.disconnect(store: store.snapshot())
        await http.release()
        do {
            _ = try await refresh.value
            XCTFail("A late response must not restore a disconnected account")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertNil(store.load())
    }

    func testFailedRotatedTokenWriteRetriesPersistenceNotConsumedGrant() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/oauth/token", json: rotatedJSON)
        let store = FailingTraktTokenStore(tokens: expired)
        let coordinator = TraktTokenCoordinator()
        let auth = TraktAuthService(config: config, http: http)
        do {
            _ = try await coordinator.accessToken(store: store, auth: auth)
            XCTFail("Persistence failure must propagate")
        } catch {
            XCTAssertTrue(error is FailingTraktTokenStore.Failure)
        }
        XCTAssertEqual(store.load(), expired)
        let access = try await coordinator.accessToken(store: store, auth: auth)
        XCTAssertEqual(access, "new-access")
        XCTAssertEqual(http.sentPaths, ["/oauth/token"])
        XCTAssertEqual(store.load()?.refreshToken, "new-refresh")
    }

    @MainActor
    func testPlaybackScrobblerKeepsOriginalProfile() async throws {
        let http = RecordingHTTPClient()
        http.stubEmpty(pathSuffix: "/scrobble/stop")
        http.stub(pathSuffix: "/users/settings", json: #"{"user":{"username":"B"}}"#)
        let store = InMemoryTraktTokenStore(tokens: TraktTokens(accessToken: "a", refreshToken: "a-refresh", expiresAt: .distantFuture))
        store.setNamespace("B")
        try store.save(TraktTokens(accessToken: "b", refreshToken: "b-refresh", expiresAt: .distantFuture))
        store.setNamespace(nil)
        let service = TraktService(config: config, http: http, tokenStore: store)
        let bound = service.playbackScrobbler()
        await service.setActiveProfile(namespace: "B")
        try await bound.scrobbleResult(
            item: MediaItem(id: "movie", title: "Movie", kind: .movie, providerIDs: ["Imdb": "tt1"]),
            progress: 100, event: .stop
        )
        XCTAssertEqual(http.sent.last?.headers["Authorization"], "Bearer a")
    }
}

private final class FailingTraktTokenStore: TraktTokenStoring, @unchecked Sendable {
    enum Failure: Error { case write }
    private let underlying: InMemoryTraktTokenStore
    private let lock = NSLock()
    private var failNextWrite = true

    init(tokens: TraktTokens?) { underlying = InMemoryTraktTokenStore(tokens: tokens) }
    var coordinationID: String { underlying.coordinationID }
    func snapshot() -> any TraktTokenStoring { self }
    func setNamespace(_ namespace: String?) { underlying.setNamespace(namespace) }
    func load() -> TraktTokens? { underlying.load() }
    func clear() throws { try underlying.clear() }
    func save(_ tokens: TraktTokens) throws {
        lock.lock()
        defer { lock.unlock() }
        if failNextWrite {
            failNextWrite = false
            throw Failure.write
        }
        try underlying.save(tokens)
    }
}

private actor ControlledRefreshHTTPClient: HTTPClient {
    var refreshCount = 0
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var responseWaiter: CheckedContinuation<Void, Never>?
    private var released = false

    func waitUntilStarted() async {
        if refreshCount > 0 { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() {
        released = true
        responseWaiter?.resume()
        responseWaiter = nil
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        guard endpoint.path == "/oauth/token" else { throw AppError.notFound }
        refreshCount += 1
        startedWaiters.forEach { $0.resume() }
        startedWaiters = []
        if !released {
            await withCheckedContinuation { responseWaiter = $0 }
        }
        return (Data(rotatedJSON.utf8), HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor SuspendedSettingsHTTPClient: HTTPClient {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var settingsWaiter: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func failSettings() {
        settingsWaiter?.resume()
        settingsWaiter = nil
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        if endpoint.path == "/oauth/token" {
            return (Data(rotatedJSON.utf8), HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        guard endpoint.path == "/users/settings" else { throw AppError.notFound }
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters = []
        await withCheckedContinuation { settingsWaiter = $0 }
        throw AppError.serverUnreachable
    }
}
