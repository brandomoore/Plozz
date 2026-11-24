import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import MALService
@testable import TestSupportNetworking

final class MALHistoryExportTests: XCTestCase {
    private let target = MALHistoryExportTarget(userID: 7, mediaID: 100)
    private let movie = MediaItem(
        id: "movie", title: "Fixture movie", kind: .movie, isPlayed: true, providerIDs: ["Mal": "100"]
    )

    private func status(_ value: String = "completed", rewatching: Bool = false) -> String {
        """
        {"status":"\(value)","score":0,"num_episodes_watched":1,"is_rewatching":\(rewatching),
         "num_times_rewatched":0,"updated_at":"2026-10-24T10:00:00Z"}
        """
    }

    private func response(status: String? = nil) -> String {
        """
        {"id":100,"title":"Fixture movie","media_type":"movie","my_list_status":\(status ?? "null")}
        """
    }

    private func http(_ responses: [String]) -> RecordingHTTPClient {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/users/@me", json: #"{"id":7,"name":"fixture"}"#)
        for response in responses { http.stub(pathSuffix: "/anime/100", json: response) }
        return http
    }

    private func client(_ http: any HTTPClient) -> MALClient {
        .init(config: .init(clientID: "fixture"), http: http)
    }

    func testExactMALIdentityResolvesWithoutTitleSearch() async throws {
        let http = http([response()])
        let result = try await client(http).resolveHistoryExport(movie, accessToken: "fixture", validateScope: {})
        XCTAssertEqual(result, target)
        XCTAssertEqual(http.sentPaths, ["/users/@me", "/anime/100", "/users/@me"])
        let request = try XCTUnwrap(http.sent.first { $0.path == "/anime/100" })
        XCTAssertNil(request.queryItems.first { $0.name == "q" })
        let fields = try XCTUnwrap(request.queryItems.first { $0.name == "fields" }?.value)
        XCTAssertTrue(fields.contains("my_list_status{"))
        XCTAssertFalse(fields.contains("comments"))
        XCTAssertFalse(fields.contains("finish_date"))
    }

    func testMissingUnsupportedAndNonMovieIdentitiesNeverMakeRequests() async {
        for (kind, ids) in [
            (MediaItemKind.movie, [:]), (.movie, ["Mal": "0"]), (.movie, ["Mal": "-1"]),
            (.movie, ["AniList": "100"]), (.movie, ["Tmdb": "100"]),
            (.episode, ["Mal": "100"]), (.series, ["Mal": "100"])
        ] {
            let http = RecordingHTTPClient()
            let item = MediaItem(id: "item", title: "Fixture", kind: kind, providerIDs: ids)
            XCTAssertFalse(MALClient.supportsHistoryExport(item))
            do {
                _ = try await client(http).resolveHistoryExport(item, accessToken: "fixture", validateScope: {})
                XCTFail("Unsupported identity accepted")
            } catch { XCTAssertEqual(error as? TrackerHistoryExportError, .unsupported) }
            XCTAssertTrue(http.sent.isEmpty)
        }
    }

    func testAllExistingListStatesRemainProtectedEvidence() async throws {
        for value in ["watching", "completed", "on_hold", "dropped", "plan_to_watch"] {
            for rewatching in [false, true] {
                let http = http([response(status: status(value, rewatching: rewatching))])
                let state = try await client(http).historyExportState(target, accessToken: "fixture", validateScope: {})
                XCTAssertEqual(state.observations.count, 1)
                XCTAssertEqual(state.isWatched, value == "completed" && !rewatching)
            }
        }
        let absent = try await client(http([response()])).historyExportState(
            target, accessToken: "fixture", validateScope: {}
        )
        XCTAssertTrue(absent.observations.isEmpty)
    }

    func testWrongIdentityAndMalformedProgressFailClosed() async {
        for payload in [
            response().replacingOccurrences(of: #""id":100"#, with: #""id":101"#),
            response().replacingOccurrences(of: #""media_type":"movie""#, with: #""media_type":"tv""#),
            response(status: "{}"),
            response(status: status("unknown")),
            response(status: status().replacingOccurrences(of: #""is_rewatching":false"#, with: #""is_rewatching":null"#)),
            response(status: status().replacingOccurrences(of: #""score":0"#, with: #""score":11"#)),
            response(status: status().replacingOccurrences(of: #""num_episodes_watched":1"#, with: #""num_episodes_watched":-1"#))
        ] {
            let http = http([payload])
            do {
                _ = try await client(http).historyExportState(target, accessToken: "fixture", validateScope: {})
                XCTFail("Invalid target state accepted")
            } catch {}
            XCTAssertEqual(http.sentPaths, ["/users/@me", "/anime/100"])
        }
    }

    func testMissingDetailListStateRequiresCompleteAuthenticatedListEvidence() async throws {
        for listStatus in [nil, "completed", "plan_to_watch"] {
            let http = http([response().replacingOccurrences(of: #","my_list_status":null"#, with: "")])
            let entries = listStatus.map {
                """
                {"node":{"id":100,"title":"Fixture movie","media_type":"movie"},"list_status":\(status($0))}
                """
            } ?? ""
            http.stub(pathSuffix: "/users/@me/animelist", json: #"{"data":[\#(entries)],"paging":{}}"#)
            let state = try await client(http).historyExportState(target, accessToken: "fixture", validateScope: {})
            XCTAssertEqual(state.observations.count, listStatus == nil ? 0 : 1)
            XCTAssertEqual(state.isWatched, listStatus == "completed")
            XCTAssertEqual(http.sentPaths, [
                "/users/@me", "/anime/100", "/users/@me", "/users/@me/animelist", "/users/@me", "/users/@me"
            ])
        }
        let incomplete = http([response().replacingOccurrences(of: #","my_list_status":null"#, with: "")])
        incomplete.stub(pathSuffix: "/users/@me/animelist", json: #"{"data":[]}"#)
        do {
            _ = try await client(incomplete).historyExportState(target, accessToken: "fixture", validateScope: {})
            XCTFail("An incomplete list cannot prove absence")
        } catch { XCTAssertEqual(error as? TrackerHistoryError, .invalidObservation) }
    }

    func testForeignAndChangingOwnersRejectTargetState() async {
        for changing in [false, true] {
            let http = http([response()])
            if changing { http.stub(pathSuffix: "/users/@me", json: #"{"id":8}"#) }
            let target = changing ? self.target : MALHistoryExportTarget(userID: 8, mediaID: 100)
            do {
                _ = try await client(http).historyExportState(target, accessToken: "fixture", validateScope: {})
                XCTFail("Foreign owner accepted")
            } catch { XCTAssertEqual(error as? TrackerHistoryError, .scopeChanged) }
        }
    }

    func testWriteSendsStatusOnlyUsingDocumentedPatchContract() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/my_list_status", json: status())
        try await client(ExportHTTP(http: http)).exportMovieCompletion(target, accessToken: "fixture", authorize: {})
        let request = try XCTUnwrap(http.sent.first)
        XCTAssertEqual(request.path, "/anime/100/my_list_status")
        XCTAssertEqual(request.body.flatMap { String(data: $0, encoding: .utf8) }, "status=completed")
        XCTAssertEqual(http.sent.count, 1)
    }

    func testPartialMalformedAndNonCompletedAcknowledgementsRemainUncertain() async {
        for payload in [
            "{}", "null", #"{"status":"completed"}"#, status("watching"),
            status(rewatching: true), String(repeating: " ", count: 1_024 * 1_024 + 1)
        ] {
            let http = RecordingHTTPClient()
            http.stub(pathSuffix: "/my_list_status", json: payload)
            do {
                try await client(http).exportMovieCompletion(target, accessToken: "fixture", authorize: {})
                XCTFail("Uncertain acknowledgement accepted")
            } catch { XCTAssertEqual(error as? TrackerHistoryExportError, .uncertainWrite) }
            XCTAssertEqual(http.sent.count, 1)
        }
    }

    func testDefiniteRefusalsAreDistinctFromUncertainDelivery() async {
        for code in [401, 403, 429, 500, 502, 204] {
            let http = RecordingHTTPClient()
            http.stub(pathSuffix: "/my_list_status", json: "{}", status: code)
            do {
                try await client(http).exportMovieCompletion(target, accessToken: "fixture", authorize: {})
                XCTFail("Failed response accepted")
            } catch {
                let expected: TrackerHistoryExportError = code == 429 ? .notWritten(.rateLimited(retryAfter: nil))
                    : [401, 403].contains(code) ? .notWritten(.unauthorized) : .uncertainWrite
                XCTAssertEqual(error as? TrackerHistoryExportError, expected)
            }
        }
        for notSent in [false, true] {
            let transport = ExportHTTP(http: RecordingHTTPClient(), failure: notSent ? .notSent : .uncertain)
            do {
                try await client(transport).exportMovieCompletion(target, accessToken: "fixture", authorize: {})
                XCTFail("Failed transport accepted")
            } catch {
                XCTAssertEqual(error as? TrackerHistoryExportError, notSent ? .notWritten(.serverUnreachable) : .uncertainWrite)
            }
        }
    }

    func testRevokedAuthorizationPreventsMutationDispatch() async {
        let http = RecordingHTTPClient()
        do {
            try await client(http).exportMovieCompletion(target, accessToken: "fixture") {
                throw TrackerHistoryError.scopeChanged
            }
            XCTFail("Revoked authorization ignored")
        } catch { XCTAssertEqual(error as? TrackerHistoryError, .scopeChanged) }
        XCTAssertTrue(http.sent.isEmpty)
    }

    @MainActor
    func testFactoryRequiresConsentAndUsesIndependentAuthenticatedReadback() async throws {
        let http = http(Array(repeating: response(), count: 4) + [response(status: status())])
        http.stub(pathSuffix: "/users/@me/animelist", json: #"{"data":[],"paging":{}}"#)
        http.stub(pathSuffix: "/my_list_status", json: status())
        let service = MALService(
            config: .init(clientID: "fixture"), http: http,
            tokenStore: InMemoryMALTokenStore(tokens: .init(
                accessToken: "fixture", refreshToken: "refresh", expiresAt: .distantFuture
            ))
        )
        await service.refreshStatus()
        let session = try service.makeHistoryExportSession(source: source(), store: store())
        XCTAssertEqual(http.sent.count, 1)
        XCTAssertFalse(session.preservesWatchDates)
        await session.compare(accountID: "account", library: .init(id: "library", title: "Movies", kind: .movie))
        XCTAssertNil(session.error)
        XCTAssertEqual(session.rows.map(\.status), [.ready])
        XCTAssertEqual(http.sent.count, 4)
        let selection = Set(session.rows.map(\.id))
        await session.apply(rowIDs: selection, confirmed: false)
        XCTAssertEqual(http.sent.count, 4)
        await session.apply(rowIDs: selection, confirmed: true)
        XCTAssertNil(session.error)
        XCTAssertEqual(http.sent.count, 20)
        if case .confirmed? = session.outcomes.values.first {} else { XCTFail("No completion readback") }
        XCTAssertEqual(http.sentPaths.filter { $0.hasSuffix("/my_list_status") }.count, 1)
        XCTAssertEqual(Array(http.sentPaths.suffix(3)), ["/users/@me", "/anime/100", "/users/@me"])
    }

    @MainActor
    func testExportRefreshPreservesIdentityAndRejectsChangedConnection() async throws {
        for replaceConnection in [false, true] {
            let http = http([response()])
            http.stub(pathSuffix: "/users/@me/animelist", json: #"{"data":[],"paging":{}}"#)
            http.stub(pathSuffix: "/v1/oauth2/token", json:
                #"{"access_token":"refreshed","refresh_token":"rotated","expires_in":3600}"#)
            let original = MALTokens(accessToken: "fixture", refreshToken: "refresh", expiresAt: .distantFuture)
            let tokens = InMemoryMALTokenStore(tokens: original)
            let transport = RefreshHTTP(http: http)
            let service = MALService(config: .init(clientID: "fixture"), http: transport, tokenStore: tokens)
            await service.refreshStatus()
            let identity = service.historySyncIdentity
            let session = try service.makeHistoryExportSession(source: source(), store: store())
            var expired = original
            expired.expiresAt = .distantPast
            try tokens.save(expired)
            transport.afterSend = { path in
                if replaceConnection, path == "/v1/oauth2/token" {
                    try tokens.save(.init(accessToken: "other", refreshToken: "other", expiresAt: .distantFuture))
                }
            }
            await session.compare(accountID: "account", library: .init(id: "library", title: "Movies", kind: .movie))
            if replaceConnection {
                XCTAssertEqual(session.error as? TrackerHistoryError, .scopeChanged)
                XCTAssertFalse(http.sentPaths.contains("/users/@me/animelist"))
                XCTAssertEqual(tokens.load()?.accessToken, "other")
            } else {
                XCTAssertNil(session.error)
                XCTAssertEqual(service.historySyncIdentity, identity)
                XCTAssertEqual(tokens.load()?.accessToken, "refreshed")
            }
            XCTAssertEqual(http.sentPaths.filter { $0 == "/v1/oauth2/token" }.count, 1)
        }
    }

    @MainActor
    func testFactoryAndSessionRejectForeignProfilesAndRevokedSource() async throws {
        let http = http([response()])
        let service = MALService(
            config: .init(clientID: "fixture"), http: http,
            tokenStore: InMemoryMALTokenStore(tokens: .init(
                accessToken: "fixture", refreshToken: "refresh", expiresAt: .distantFuture
            ))
        )
        await service.refreshStatus()
        XCTAssertThrowsError(try service.makeHistoryExportSession(source: source(profileID: "other"), store: store()))
        let session = try service.makeHistoryExportSession(source: source(authorized: false), store: store())
        await session.compare(accountID: "account", library: .init(id: "library", title: "Movies", kind: .movie))
        XCTAssertEqual(session.error as? TrackerHistoryError, .scopeChanged)
        XCTAssertEqual(http.sent.count, 1)
    }

    @MainActor
    private func source(
        profileID: String = ProfileStore.defaultProfileID, authorized: Bool = true
    ) -> TrackerServerHistorySource {
        let provider = ExportProvider(movie: movie)
        return .init(
            scope: .init(profile: .init(id: profileID, name: "Test"), accounts: [
                .init(id: "account", server: provider.session.server, userID: "viewer", userName: "Viewer", deviceID: "device")
            ]),
            accounts: [.init(id: "account", serverName: "Server", userName: "Viewer")],
            resolveProvider: { _ in provider }, isAuthorized: { authorized }, isPlaying: { _, _ in false }
        )
    }

    private func store() throws -> DurableLocalStateStore {
        try .init(secureStore: ExportSecureStore())
    }
}

private struct ExportHTTP: HTTPClient {
    enum Failure { case none, notSent, uncertain }
    let http: RecordingHTTPClient
    var failure: Failure = .none
    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        try await http.send(endpoint, baseURL: baseURL)
    }
    func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        XCTAssertEqual(endpoint.method, .patch)
        XCTAssertEqual(endpoint.redirectPolicy, .sameOrigin)
        XCTAssertEqual(endpoint.maximumResponseBytes, 1_024 * 1_024)
        XCTAssertTrue(endpoint.reportsUndeliveredRequests)
        XCTAssertTrue(endpoint.redactsURLForLogging)
        if failure == .notSent { throw HTTPRequestNotSentError(underlying: .serverUnreachable) }
        if failure == .uncertain { throw AppError.serverUnreachable }
        return try await http.sendRaw(endpoint, baseURL: baseURL)
    }
}

@MainActor
private final class RefreshHTTP: HTTPClient {
    let http: RecordingHTTPClient
    var afterSend: (@MainActor @Sendable (String) throws -> Void)?
    init(http: RecordingHTTPClient) { self.http = http }
    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let result = try await http.send(endpoint, baseURL: baseURL)
        try afterSend?(endpoint.path)
        return result
    }
}

private final class ExportSecureStore: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func setString(_ value: String, for key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = value }
    func string(for key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func readString(for key: String) throws -> String? { string(for: key) }
    func removeValue(for key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = nil }
}

private actor ExportProvider: MediaProvider {
    nonisolated let kind: ProviderKind = .jellyfin
    nonisolated let session = UserSession(
        server: .init(id: "server", name: "Server", baseURL: URL(string: "https://example.test")!, provider: .jellyfin),
        userID: "viewer", userName: "Viewer", deviceID: "device", accessToken: ""
    )
    let movie: MediaItem
    init(movie: MediaItem) { self.movie = movie }
    func libraries() async throws -> [MediaLibrary] { [.init(id: "library", title: "Movies", kind: .movie)] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { movie }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        .init(items: page.startIndex == 0 ? [movie] : [], startIndex: page.startIndex, totalCount: 1)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {
        XCTFail("History export must not report playback")
    }
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
