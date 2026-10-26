import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import MALService
@testable import TestSupportNetworking

final class MALHistorySnapshotTests: XCTestCase {
    private func row(_ id: Int = 100, status: String = "completed", extra: String = "") -> String {
        """
        {"node":{"id":\(id),"title":"Fixture movie","media_type":"movie"},
         "list_status":{"status":"\(status)","score":8,"num_episodes_watched":1,
         "is_rewatching":false,"num_times_rewatched":2,"updated_at":"2026-10-24T10:00:00Z"\(extra)}}
        """
    }

    private func page(_ rows: [String], next: String? = nil) -> String {
        let paging = next.map { #""next":"\#($0)""# } ?? ""
        return #"{"data":[\#(rows.joined(separator: ","))],"paging":{\#(paging)}}"#
    }

    private func http(_ pages: [String]) -> RecordingHTTPClient {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/users/@me", json: #"{"id":7,"name":"fixture"}"#)
        for page in pages { http.stub(pathSuffix: "/users/@me/animelist", json: page) }
        return http
    }

    private func snapshot(
        _ http: any HTTPClient, validate: @escaping @Sendable () async throws -> Void = {}
    ) async throws -> TrackerHistorySnapshot {
        try await MALClient(config: .init(clientID: "fixture"), http: http).historySnapshot(
            accessToken: "fixture", connectionID: "connection", validateScope: validate
        )
    }

    func testCompleteReadIncludesAllStatusesAndPreservesAnimeFacts() async throws {
        let http = http([
            page([row()], next: "https://api.myanimelist.net/v2/users/@me/animelist?offset=1&limit=999&status=dropped"),
            page([row(99, status: "plan_to_watch")])
        ])
        let result = try await snapshot(HistoryHTTP(http: http))
        XCTAssertEqual(result.trackerID, "myanimelist")
        XCTAssertEqual(result.observations.count, 2)
        XCTAssertEqual(result.observations[0].fact, .animeList(try .init(
            status: .completed, episodesWatched: 1, repeats: 2, score: 8,
            updatedAt: Date.ISO8601FormatStyle().parse("2026-10-24T10:00:00Z")
        )))
        XCTAssertEqual(result.observations[0].kind, .movie)
        XCTAssertEqual(result.observations[0].sourceTitle, "Fixture movie")
        XCTAssertEqual(result.observations[0].identities, [.external(source: "myanimelist", value: "100")])
        XCTAssertEqual(http.sentPaths, ["/users/@me", "/users/@me/animelist", "/users/@me/animelist", "/users/@me"])
        for (index, sent) in http.sent.filter({ $0.path.hasSuffix("animelist") }).enumerated() {
            XCTAssertEqual(sent.queryItems.first { $0.name == "offset" }?.value, String(index))
            XCTAssertEqual(sent.queryItems.first { $0.name == "limit" }?.value, "1000")
            XCTAssertEqual(sent.queryItems.first { $0.name == "nsfw" }?.value, "true")
            XCTAssertEqual(sent.queryItems.first { $0.name == "sort" }?.value, "list_updated_at")
            XCTAssertNil(sent.queryItems.first { $0.name == "status" })
            let fields = try XCTUnwrap(sent.queryItems.first { $0.name == "fields" }?.value)
            XCTAssertTrue(fields.contains("list_status{"))
            XCTAssertFalse(fields.contains("comments"))
            XCTAssertFalse(fields.contains("finish_date"))
        }
    }

    func testEmptyListIsExhaustedAndOwnerIsStillChecked() async throws {
        let http = http([page([])])
        let result = try await snapshot(http)
        XCTAssertTrue(result.observations.isEmpty)
        XCTAssertEqual(http.sentPaths.filter { $0 == "/users/@me" }.count, 2)
    }

    func testRewatchingUnknownFieldsAndCountAliasesStayInformational() throws {
        let rewatching = row().replacingOccurrences(of: #""is_rewatching":false"#, with: #""is_rewatching":true"#)
        let record = try JSONDecoder().decode(MALHistoryEntry.self, from: Data(rewatching.utf8))
        guard case .animeList(let progress) = try record.observation().fact else { return XCTFail("List expected") }
        XCTAssertEqual(progress.status, .rewatching)
        for counts in [#""num_watched_episodes":3"#, #""num_episodes_watched":3,"num_watched_episodes":3"#] {
            let raw = #"{"node":{"id":1},"list_status":{\#(counts),"score":0}}"#
            let entry = try JSONDecoder().decode(MALHistoryEntry.self, from: Data(raw.utf8))
            let observation = try entry.observation()
            XCTAssertEqual(observation.kind, .series)
            guard case .animeList(let progress) = observation.fact else { return XCTFail("List expected") }
            XCTAssertNil(progress.status)
            XCTAssertNil(progress.score)
            XCTAssertNil(progress.updatedAt)
            XCTAssertNil(progress.repeats)
            XCTAssertEqual(progress.episodesWatched, 3)
        }
    }

    func testInvalidRecordsCannotDisappearFromTheSnapshot() async {
        for invalid in [
            row(0), row(status: "unknown"), row(extra: #","num_watched_episodes":2"#),
            row().replacingOccurrences(of: #""score":8"#, with: #""score":11"#),
            row().replacingOccurrences(of: #""num_episodes_watched":1"#, with: #""num_episodes_watched":-1"#),
            row().replacingOccurrences(of: #""num_times_rewatched":2"#, with: #""num_times_rewatched":-1"#),
            row().replacingOccurrences(of: "2026-10-24T10:00:00Z", with: "2026-10"),
            #"{"node":null,"list_status":{}}"#, #"{"node":{"id":1},"list_status":null}"#
        ] {
            do { _ = try await snapshot(http([page([invalid])])) ; XCTFail("Invalid entry accepted") }
            catch { XCTAssertEqual(error as? TrackerHistoryError, .invalidObservation) }
        }
    }

    func testUntrustedRepeatedOrNoncontiguousNextLinksAreNotFollowed() async {
        for next in [
            "https://example.test/v2/users/@me/animelist?offset=1",
            "http://api.myanimelist.net/v2/users/@me/animelist?offset=1",
            "https://fixture@api.myanimelist.net/v2/users/@me/animelist?offset=1",
            "https://api.myanimelist.net/v2/users/other/animelist?offset=1",
            "https://api.myanimelist.net/v2/users/@me/animelist?offset=1&offset=1",
            "https://api.myanimelist.net/v2/users/@me/animelist?offset=1#fragment",
            "https://api.myanimelist.net/v2/users/@me/animelist?offset=01",
            "https://api.myanimelist.net/v2/users/@me/animelist?offset=0",
            "https://api.myanimelist.net/v2/users/@me/animelist?offset=2"
        ] {
            let http = http([page([row()], next: next)])
            do { _ = try await snapshot(http); XCTFail("Untrusted pagination accepted") }
            catch { XCTAssertEqual(error as? TrackerHistoryError, .incompleteSnapshot) }
            XCTAssertEqual(http.sent.count, 2)
        }
    }

    func testMissingPaginationNullRowsDuplicatesAndChangingOrderFailClosed() async {
        let later = row(99).replacingOccurrences(of: "10:00:00Z", with: "11:00:00Z")
        for response in [
            #"{"data":[]}"#, #"{"data":null,"paging":{}}"#, #"{"data":[null],"paging":{}}"#,
            page([row(), row()]), page([row(), later]),
            page([], next: "https://api.myanimelist.net/v2/users/@me/animelist?offset=1")
        ] {
            do { _ = try await snapshot(http([response])); XCTFail("Incomplete list accepted") }
            catch { XCTAssertNotNil(error as? TrackerHistoryError) }
        }
        let http = http([
            page([row()], next: "https://api.myanimelist.net/v2/users/@me/animelist?offset=1"),
            page([row()])
        ])
        do { _ = try await snapshot(http); XCTFail("Repeated ID accepted") }
        catch { XCTAssertEqual(error as? TrackerHistoryError, .incompleteSnapshot) }
    }

    func testOwnerChangeAndScopeChangeDoNotPublishHistory() async {
        let http = http([page([row()])])
        http.stub(pathSuffix: "/users/@me", json: #"{"id":8}"#)
        do { _ = try await snapshot(http); XCTFail("Changed owner accepted") }
        catch { XCTAssertEqual(error as? TrackerHistoryError, .scopeChanged) }
        for failureAt in 1...6 {
            let gate = ScopeGate(failureAt: failureAt)
            let http = self.http([page([])])
            do { _ = try await snapshot(http, validate: { try await gate.check() }); XCTFail("Changed scope accepted") }
            catch { XCTAssertEqual(error as? TrackerHistoryError, .scopeChanged) }
            XCTAssertEqual(http.sent.count, failureAt / 2)
        }
    }

    func testHTTPFailureAndCancellationNeverRetry() async {
        let http = http([page([])])
        http.error = .rateLimited(retryAfter: 60)
        do { _ = try await snapshot(http); XCTFail("Throttling ignored") }
        catch { XCTAssertEqual(error as? AppError, .rateLimited(retryAfter: 60)) }
        XCTAssertEqual(http.sent.count, 1)
        let cancelled = self.http([page([])])
        let task = Task {
            try await snapshot(HistoryHTTP(http: cancelled, afterSend: {
                withUnsafeCurrentTask { $0?.cancel() }
            }))
        }
        do { _ = try await task.value; XCTFail("Cancellation ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(cancelled.sent.count, 1)
    }

    func testRecordAndByteBoundsAreEnforced() async {
        let oversized = page((1...1001).map { row($0) })
        for response in [oversized, String(repeating: " ", count: 8 * 1_024 * 1_024 + 1)] {
            do { _ = try await snapshot(http([response])); XCTFail("Oversized page accepted") }
            catch { XCTAssertEqual(error as? TrackerHistoryError, .incompleteSnapshot) }
        }
    }

    func testNonExhaustingHistoryStopsAtOneHundredFullPages() async {
        let http = NonExhaustingHTTP()
        do { _ = try await snapshot(http); XCTFail("Unbounded pagination") }
        catch { XCTAssertEqual(error as? TrackerHistoryError, .incompleteSnapshot) }
        let pages = await http.pages
        XCTAssertEqual(pages, 100)
    }

    @MainActor
    func testHistoryRefreshPreservesConnectionAndStopsForChangedGrantOrStorageFailure() async throws {
        for behavior in 0..<4 {
            let http = http([page([])])
            http.stub(pathSuffix: "/v1/oauth2/token", json:
                #"{"access_token":"refreshed","refresh_token":"rotated","expires_in":3600}"#)
            let store = FailableStore()
            let original = MALTokens(accessToken: "fixture", refreshToken: "refresh", expiresAt: .distantFuture)
            try store.save(original)
            let transport = ServiceHTTP(http: http)
            let service = MALService(config: .init(clientID: "fixture"), http: transport, tokenStore: store)
            await service.refreshStatus()
            let connection = try XCTUnwrap(service.historyConnectionID)
            var expired = original
            expired.expiresAt = .distantPast
            try store.save(expired)
            let replacement = MALTokens(accessToken: "other", refreshToken: "other", expiresAt: .distantFuture)
            transport.afterSend = { path in
                guard path == "/v1/oauth2/token" else { return }
                switch behavior {
                case 1: try store.save(replacement)
                case 2: await service.setActiveProfile(namespace: "other")
                case 3: store.failSave = true
                default: break
                }
            }
            do {
                _ = try await service.historySnapshot(expectedConnectionID: connection)
                XCTAssertEqual(behavior, 0)
                XCTAssertEqual(service.historyConnectionID, connection)
                XCTAssertEqual(store.load()?.accessToken, "refreshed")
            } catch {
                XCTAssertNotEqual(behavior, 0)
                XCTAssertFalse(http.sentPaths.contains("/users/@me/animelist"))
                if behavior == 1 { XCTAssertEqual(store.load(), replacement) }
                if behavior == 2 { XCTAssertNil(store.load()) }
                if behavior == 3 { XCTAssertEqual(error as? AppError, .invalidResponse) }
            }
            XCTAssertEqual(http.sentPaths.filter { $0 == "/v1/oauth2/token" }.count, 1)
        }
    }

    @MainActor
    func testDurableIdentitySurvivesRefreshAndRelaunchButNotSameTokenReconnect() async throws {
        let http = http([])
        http.stub(pathSuffix: "/api/redeem", json: """
        {"service":"myanimelist","accessToken":"fixture","refreshToken":"refresh","expiresIn":3600}
        """)
        http.stub(pathSuffix: "/v1/oauth2/token", json: """
        {"access_token":"fixture","refresh_token":"refresh","expires_in":3600}
        """)
        let config = MALConfig(clientID: "fixture")
        let tokens = MALTokens(accessToken: "fixture", refreshToken: "refresh", expiresAt: .distantFuture)
        let store = InMemoryMALTokenStore(tokens: tokens)
        let service = MALService(config: config, http: http, tokenStore: store)
        await service.refreshStatus()
        let first = try XCTUnwrap(service.historySyncIdentity)
        XCTAssertEqual(service.historySyncCategories, [.watched])
        var expired = tokens
        expired.expiresAt = .distantPast
        try store.save(expired)
        await service.refreshStatus()
        XCTAssertEqual(service.historySyncIdentity, first)
        let restored = MALService(config: config, http: http, tokenStore: store)
        await restored.refreshStatus()
        XCTAssertEqual(restored.historySyncIdentity, first)
        var revocations = 0
        service.onHistorySyncDisconnect = { revocations += 1 }
        await service.setActiveProfile(namespace: "other")
        XCTAssertNil(service.historySyncIdentity)
        await service.setActiveProfile(namespace: nil)
        XCTAssertEqual(service.historySyncIdentity, first)
        service.submitAuthorizationCode("fixture-code")
        await service.connectTask?.value
        let next = try XCTUnwrap(service.historySyncIdentity)
        XCTAssertNotEqual(next, first)
        XCTAssertEqual(store.load()?.accessToken, tokens.accessToken)
        service.submitAuthorizationCode("fixture-code")
        await service.connectTask?.value
        XCTAssertNotEqual(service.historySyncIdentity, next)
        XCTAssertEqual(revocations, 2)
    }

    @MainActor
    func testConnectionSaveAndPermissionRevocationFailuresAreExplicit() async throws {
        let http = http([])
        http.stub(pathSuffix: "/api/redeem", json: """
        {"service":"myanimelist","accessToken":"fixture","refreshToken":"refresh","expiresIn":3600}
        """)
        let store = FailableStore()
        store.failSave = true
        let service = MALService(config: .init(clientID: "fixture"), http: http, tokenStore: store)
        service.submitAuthorizationCode("fixture-code")
        await service.connectTask?.value
        XCTAssertEqual(service.phase, .error("Could not save the connection. Try again."))
        XCTAssertNil(store.load())
        store.failSave = false
        service.submitAuthorizationCode("fixture-code")
        await service.connectTask?.value
        XCTAssertNotNil(service.historySyncIdentity)
        service.onHistorySyncDisconnect = { throw TrackerHistorySyncError.revocationFailed }
        let saved = store.load()
        service.submitAuthorizationCode("fixture-code")
        await service.connectTask?.value
        XCTAssertEqual(service.phase, .error("Sync is paused. Retry before closing the app."))
        XCTAssertEqual(store.load(), saved)
        await service.disconnect()
        XCTAssertNotNil(store.load())
        XCTAssertEqual(service.phase, .error("Could not disconnect. Retry before closing the app."))
        service.onHistorySyncDisconnect = nil
        store.failClear = true
        await service.disconnect()
        XCTAssertNotNil(store.load())
        XCTAssertEqual(service.phase, .error("Could not disconnect. Retry before closing the app."))
        store.failClear = false
        await service.disconnect()
        XCTAssertEqual(service.phase, .disconnected)
        XCTAssertNil(store.load())
    }

    @MainActor
    func testLateCredentialRejectionCannotDeleteSynchronizedReplacement() async throws {
        let http = http([])
        let store = InMemoryMALTokenStore(tokens: .init(
            accessToken: "old", refreshToken: "old-refresh", expiresAt: .distantFuture
        ))
        let replacement = MALTokens(
            accessToken: "new", refreshToken: "new-refresh", expiresAt: .distantFuture, accountIdentity: "new-connection"
        )
        let transport = ServiceHTTP(http: http)
        transport.afterSend = { _ in
            try store.save(replacement)
            throw AppError.unauthorized
        }
        let service = MALService(config: .init(clientID: "fixture"), http: transport, tokenStore: store)
        service.onHistorySyncDisconnect = { XCTFail("A stale rejection must not revoke current permission") }
        await service.refreshStatus()
        XCTAssertEqual(store.load(), replacement)
    }

    private actor ScopeGate {
        let failureAt: Int
        var count = 0
        init(failureAt: Int) { self.failureAt = failureAt }
        func check() throws {
            count += 1
            if count == failureAt { throw TrackerHistoryError.scopeChanged }
        }
    }

    private struct HistoryHTTP: HTTPClient {
        let http: RecordingHTTPClient
        var afterSend: @Sendable () async -> Void = {}
        func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
            XCTAssertEqual(endpoint.method, .get)
            XCTAssertEqual(endpoint.redirectPolicy, .sameOrigin)
            XCTAssertTrue(endpoint.redactsURLForLogging)
            XCTAssertEqual(endpoint.maximumResponseBytes, 8 * 1_024 * 1_024)
            XCTAssertEqual(endpoint.headers["Authorization"], "Bearer fixture")
            let result = try await http.send(endpoint, baseURL: baseURL)
            await afterSend()
            return result
        }
    }

    private actor NonExhaustingHTTP: HTTPClient {
        private(set) var pages = 0
        func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
            let body: String
            if endpoint.path == "/users/@me" { body = #"{"id":7}"# }
            else {
                pages += 1
                let rows = (1...1000).map { index in
                    #"{"node":{"id":\#((pages - 1) * 1000 + index)},"list_status":{}}"#
                }.joined(separator: ",")
                body = """
                {"data":[\(rows)],"paging":{"next":"https://api.myanimelist.net/v2/users/@me/animelist?offset=\(pages * 1000)"}}
                """
            }
            return (Data(body.utf8), HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @MainActor
    private final class ServiceHTTP: HTTPClient {
        let http: RecordingHTTPClient
        var afterSend: (@MainActor @Sendable (String) async throws -> Void)?
        init(http: RecordingHTTPClient) { self.http = http }
        func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
            let result = try await http.send(endpoint, baseURL: baseURL)
            try await afterSend?(endpoint.path)
            return result
        }
    }

    private final class FailableStore: MALTokenStoring, @unchecked Sendable {
        private let storage = InMemoryMALTokenStore()
        private let lock = NSLock()
        private var failure = false
        private var clearFailure = false
        var failClear: Bool {
            get { lock.lock(); defer { lock.unlock() }; return clearFailure }
            set { lock.lock(); defer { lock.unlock() }; clearFailure = newValue }
        }
        var failSave: Bool {
            get { lock.lock(); defer { lock.unlock() }; return failure }
            set { lock.lock(); defer { lock.unlock() }; failure = newValue }
        }
        func load() -> MALTokens? { storage.load() }
        func save(_ tokens: MALTokens) throws {
            if failSave { throw AppError.invalidResponse }
            try storage.save(tokens)
        }
        func clear() throws {
            if failClear { throw AppError.invalidResponse }
            try storage.clear()
        }
        func setNamespace(_ namespace: String?) { storage.setNamespace(namespace) }
    }
}
