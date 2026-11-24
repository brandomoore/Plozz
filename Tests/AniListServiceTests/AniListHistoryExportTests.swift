import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import AniListService
@testable import TestSupportNetworking

final class AniListHistoryExportTests: XCTestCase {
    private let target = AniListHistoryExportTarget(userID: 7, mediaID: 100)
    private let movie = MediaItem(id: "movie", title: "Movie", kind: .movie, isPlayed: true, providerIDs: ["AniList": "100", "Mal": "200"])
    private let acknowledgement = #"{"data":{"SaveMediaListEntry":{"id":1100,"userId":7,"mediaId":100,"status":"COMPLETED"}}}"#

    private func response(status: String? = nil, owner: Int = 7, entryOwner: Int = 7, format: String = "MOVIE") -> String {
        let entry = status.map {
            """
            {"id":1100,"userId":\(entryOwner),"mediaId":100,"status":"\($0)","progress":1,"repeat":0,
             "score":0,"updatedAt":1700000000,"media":{"id":100,"idMal":200,"type":"ANIME","format":"\(format)"}}
            """
        } ?? "null"
        return """
        {"data":{"Viewer":{"id":\(owner)},"Media":{"id":100,"idMal":200,"type":"ANIME",
        "format":"\(format)","mediaListEntry":\(entry)}}}
        """
    }

    private func client(_ http: any HTTPClient) -> AniListClient {
        .init(config: .init(clientID: "fixture", clientSecret: "fixture"), http: http)
    }

    func testExactAniListAndMALIDsResolveWithoutTitleSearch() async throws {
        for ids in [["AniList": "100"], ["Mal": "200"], ["AniList": "100", "Mal": "200"]] {
            let http = RecordingHTTPClient()
            http.stub(pathSuffix: "", json: response())
            var item = movie
            item.providerIDs = ids
            let actual = try await client(http).resolveHistoryExport(item, accessToken: "fixture", validateScope: {})
            XCTAssertEqual(actual, target)
            let sent = try XCTUnwrap(http.sent.first)
            let query = try XCTUnwrap(sent.json?["query"] as? String)
            XCTAssertFalse(query.contains("search"))
            XCTAssertFalse(query.contains("mutation"))
            XCTAssertEqual(sent.json?["variables"] as? [String: Int], ids["AniList"] == nil ? ["malId": 200] : ["id": 100])
        }
    }

    func testMissingAndSeriesIdentitiesCannotTriggerLookupOrMutation() async {
        for (kind, ids) in [
            (MediaItemKind.movie, [:]), (.movie, ["AniList": "0"]),
            (.movie, ["Mal": "-2"]), (.movie, ["Tmdb": "100"]),
            (.episode, ["AniList": "100"]), (.series, ["AniList": "100"])
        ] {
            let http = RecordingHTTPClient()
            let item = MediaItem(id: "item", title: "Movie", kind: kind, providerIDs: ids)
            XCTAssertFalse(AniListClient.supportsHistoryExport(item))
            do { _ = try await client(http).resolveHistoryExport(item, accessToken: "fixture", validateScope: {}); XCTFail("Unsupported item") }
            catch { XCTAssertEqual(error as? TrackerHistoryExportError, .unsupported) }
            XCTAssertTrue(http.sent.isEmpty)
        }
    }

    func testWrongFormatOwnerOrIdentityRejectsTargetState() async {
        for payload in [
            response(format: "TV"), response(owner: 8), response(status: "COMPLETED", entryOwner: 8),
            response().replacingOccurrences(of: #""id":100"#, with: #""id":101"#),
            response(status: "COMPLETED").replacingOccurrences(of: #""mediaId":100"#, with: #""mediaId":101"#),
            response().replacingOccurrences(of: #","mediaListEntry":null"#, with: ""),
            response().replacingOccurrences(of: #""idMal":200"#, with: #""idMal":0"#),
            #"{"data":null,"errors":[{"message":"fixture","status":401}]}"#
        ] {
            let http = RecordingHTTPClient()
            http.stub(pathSuffix: "", json: payload)
            do { _ = try await client(http).historyExportState(target, accessToken: "fixture", validateScope: {}); XCTFail("Invalid state accepted") }
            catch {}
            XCTAssertEqual(http.sent.count, 1)
        }
    }

    func testContradictorySourceIDsAreNeverSilentlyIgnored() async {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "", json: response().replacingOccurrences(of: #""idMal":200"#, with: #""idMal":201"#))
        do { _ = try await client(http).resolveHistoryExport(movie, accessToken: "fixture", validateScope: {}); XCTFail("Wrong MAL ID") }
        catch { XCTAssertEqual(error as? TrackerHistoryError, .invalidObservation) }
    }

    func testAllExistingListStatesRemainExplicitEvidence() async throws {
        for status in ["PLANNING", "CURRENT", "PAUSED", "DROPPED", "REPEATING", "COMPLETED"] {
            let http = RecordingHTTPClient()
            http.stub(pathSuffix: "", json: response(status: status))
            let state = try await client(http).historyExportState(target, accessToken: "fixture", validateScope: {})
            XCTAssertEqual(state.observations.count, 1)
            XCTAssertEqual(state.isWatched, status == "COMPLETED")
        }
    }

    func testMutationSendsOnlyCompletionStatusWithNoFabricatedHistory() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "", json: acknowledgement)
        try await client(ExportTransport(http: http)).exportMovieCompletion(target, accessToken: "fixture", authorize: {})
        let request = try XCTUnwrap(http.sent.first)
        XCTAssertEqual(request.json?["variables"] as? [String: Int], ["mediaId": 100])
        let query = try XCTUnwrap(request.json?["query"] as? String)
        XCTAssertTrue(query.contains("status: COMPLETED"))
        for forbidden in ["progress:", "repeat:", "score:", "notes:", "startedAt:", "completedAt:"] {
            XCTAssertFalse(query.contains(forbidden))
        }
        XCTAssertEqual(http.sent.count, 1)
    }

    func testMalformedPartialForeignAndErrorAcknowledgementsRemainUncertain() async {
        for payload in [
            "{}", #"{"data":null}"#, #"{"data":{"SaveMediaListEntry":null}}"#,
            acknowledgement.replacingOccurrences(of: #""mediaId":100"#, with: #""mediaId":101"#),
            acknowledgement.replacingOccurrences(of: #""userId":7"#, with: #""userId":8"#),
            acknowledgement.replacingOccurrences(of: "COMPLETED", with: "CURRENT"),
            acknowledgement.dropLast().description + #","errors":[{"message":"fixture","status":500}]}"#
        ] {
            let http = RecordingHTTPClient()
            http.stub(pathSuffix: "", json: payload)
            do { try await client(http).exportMovieCompletion(target, accessToken: "fixture", authorize: {}); XCTFail("Uncertain reply accepted") }
            catch { XCTAssertEqual(error as? TrackerHistoryExportError, .uncertainWrite) }
            XCTAssertEqual(http.sent.count, 1)
        }
    }

    func testDefiniteHTTPRefusalsDifferFromTransportAndServerUncertainty() async {
        for status in [401, 403, 429, 500, 502, 204] {
            let http = RecordingHTTPClient()
            http.stub(pathSuffix: "", json: "{}", status: status)
            do { try await client(http).exportMovieCompletion(target, accessToken: "fixture", authorize: {}); XCTFail("Failed response") }
            catch {
                let expected: TrackerHistoryExportError = status == 429 ? .notWritten(.rateLimited(retryAfter: nil))
                    : [401, 403].contains(status) ? .notWritten(.unauthorized) : .uncertainWrite
                XCTAssertEqual(error as? TrackerHistoryExportError, expected)
            }
        }
        for notSent in [false, true] {
            let transport = ExportTransport(http: RecordingHTTPClient(), failBeforeSending: notSent, failAfterSending: !notSent)
            do { try await client(transport).exportMovieCompletion(target, accessToken: "fixture", authorize: {}); XCTFail("Failed transport") }
            catch {
                XCTAssertEqual(error as? TrackerHistoryExportError, notSent ? .notWritten(.serverUnreachable) : .uncertainWrite)
            }
        }
    }

    func testAuthorizationRunsBeforeMutationDispatch() async {
        let http = RecordingHTTPClient()
        do {
            try await client(http).exportMovieCompletion(target, accessToken: "fixture") {
                throw TrackerHistoryError.scopeChanged
            }
            XCTFail("Revoked authorization")
        } catch { XCTAssertEqual(error as? TrackerHistoryError, .scopeChanged) }
        XCTAssertTrue(http.sent.isEmpty)
    }

    @MainActor
    func testProductionFactoryRequiresExplicitSelectionAndIndependentReadback() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "", json: #"{"data":{"Viewer":{"id":7,"name":"fixture"}}}"#)
        http.stub(pathSuffix: "", json: #"{"data":{"Viewer":{"id":7}}}"#)
        http.stub(pathSuffix: "", json: #"{"data":{"Viewer":{"id":7},"Page":{"pageInfo":{"currentPage":1,"perPage":50,"hasNextPage":false},"mediaList":[]}}}"#)
        for _ in 0..<4 { http.stub(pathSuffix: "", json: response()) }
        http.stub(pathSuffix: "", json: acknowledgement)
        http.stub(pathSuffix: "", json: response(status: "COMPLETED"))
        let service = AniListService(
            config: .init(clientID: "fixture", clientSecret: "fixture"), http: http,
            tokenStore: InMemoryAniListTokenStore(tokens: .init(accessToken: "fixture"))
        )
        await service.refreshStatus()
        let provider = ExportProvider(movie: movie)
        let source = TrackerServerHistorySource(
            scope: .init(profile: .init(id: ProfileStore.defaultProfileID, name: "Test"), accounts: [
                .init(id: "account", server: provider.session.server, userID: "viewer", userName: "Viewer", deviceID: "device")
            ]),
            accounts: [.init(id: "account", serverName: "Server", userName: "Viewer")],
            resolveProvider: { _ in provider }, isAuthorized: { true }, isPlaying: { _, _ in false }
        )
        let session = try service.makeHistoryExportSession(
            source: source, store: DurableLocalStateStore(secureStore: ExportSecureStore())
        )
        XCTAssertEqual(http.sent.count, 1)
        XCTAssertFalse(session.preservesWatchDates)
        await session.compare(accountID: "account", library: .init(id: "library", title: "Movies", kind: .movie))
        XCTAssertNil(session.error)
        XCTAssertEqual(session.rows.map(\.status), [.ready])
        XCTAssertEqual(http.sent.count, 3)
        let selection = Set(session.rows.map(\.id))
        await session.apply(rowIDs: selection, confirmed: false)
        XCTAssertEqual(http.sent.count, 3)
        await session.apply(rowIDs: selection, confirmed: true)
        XCTAssertNil(session.error)
        XCTAssertEqual(http.sent.count, 9)
        if case .confirmed? = session.outcomes.values.first {} else { XCTFail("Missing completion readback") }
        XCTAssertEqual(http.sent.compactMap { $0.json?["query"] as? String }.filter { $0.hasPrefix("mutation") }.count, 1)
    }
}

private struct ExportTransport: HTTPClient {
    let http: RecordingHTTPClient
    var failBeforeSending = false
    var failAfterSending = false
    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        try await http.send(endpoint, baseURL: baseURL)
    }
    func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        XCTAssertEqual(endpoint.redirectPolicy, .sameOrigin)
        XCTAssertEqual(endpoint.maximumResponseBytes, 1_024 * 1_024)
        XCTAssertTrue(endpoint.reportsUndeliveredRequests)
        XCTAssertTrue(endpoint.redactsURLForLogging)
        if failBeforeSending { throw HTTPRequestNotSentError(underlying: .serverUnreachable) }
        if failAfterSending { throw AppError.serverUnreachable }
        return try await http.sendRaw(endpoint, baseURL: baseURL)
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
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws { XCTFail("Historical export must not report playback") }
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
