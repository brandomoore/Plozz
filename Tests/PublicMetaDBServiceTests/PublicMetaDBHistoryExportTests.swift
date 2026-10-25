import CoreModels
import CoreNetworking
import CoreSecureStore
import Foundation
import XCTest
@testable import PublicMetaDBService
@testable import TestSupportNetworking

@MainActor
final class PublicMetaDBHistoryExportTests: XCTestCase {
    private let library = MediaLibrary(id: "library", title: "Movies", kind: .movie)

    private func movie(id: String = "movie", played: Bool = true, position: Double? = nil) -> MediaItem {
        .init(id: id, title: "Movie", kind: .movie, runtime: 1_000, resumePosition: position,
              isPlayed: played, providerIDs: ["Tmdb": "550"])
    }

    private func fixture(
        items: [MediaItem], providerKind: ProviderKind = .jellyfin,
        http: ExportHTTP = ExportHTTP(), store: DurableLocalStateStore? = nil,
        connectionID: UUID = UUID(), authorization: ExportAuthorization? = nil
    ) throws -> (PublicMetaDBHistoryExportSession, ExportProvider, ExportHTTP) {
        let authorization = authorization ?? ExportAuthorization()
        let provider = ExportProvider(items: items, kind: providerKind)
        let scope = WatchMutationServerScope(
            profile: .init(id: "profile", name: "Test"),
            accounts: [
                .init(id: "account", server: provider.session.server,
                      userID: "user", userName: "Test user", deviceID: "device")
            ]
        )
        let source = TrackerServerHistorySource(
            scope: scope, accounts: [.init(id: "account", serverName: "Server", userName: "Test user")],
            resolveProvider: { _ in provider }, isAuthorized: { authorization.current },
            isPlaying: { _, _ in authorization.playing }
        )
        let client = try PublicMetaDBClient(
            key: "pm-" + String(repeating: "T", count: 60), http: http, gate: .init()
        )
        let session = try PublicMetaDBHistoryExportSession(
            source: source, client: client, connectionID: connectionID,
            store: store ?? DurableLocalStateStore(secureStore: InMemorySecureStore()),
            isConnected: { authorization.connected }
        )
        return (session, provider, http)
    }

    private func preview(_ session: PublicMetaDBHistoryExportSession, mode: PublicMetaDBHistoryExportSession.Mode = .watched) async {
        await session.compare(accountID: "account", library: library, mode: mode)
    }

    private func apply(_ session: PublicMetaDBHistoryExportSession, conflicts: Bool = false, confirmed: Bool = true) async {
        let ids = Set(session.rows.map(\.id))
        await session.apply(rowIDs: ids, overridingConflicts: conflicts ? ids : [], confirmed: confirmed)
    }

    private func assertEqual<Value: Equatable>(
        _ actual: @autoclosure () async -> Value, _ expected: Value,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let value = await actual()
        XCTAssertEqual(value, expected, file: file, line: line)
    }

    func testPreviewIsReadOnlyAndConfirmationBackfillsOnePlayForBothProviderScopes() async throws {
        for kind in [ProviderKind.plex, .jellyfin] {
            let (session, provider, http) = try fixture(items: [movie()], providerKind: kind)
            await preview(session)
            XCTAssertNil(session.error)
            XCTAssertEqual(session.rows.map(\.status), [.ready])
            await assertEqual(await provider.pageOffsets(), [0, 1])
            await assertEqual(await http.mutationCount(), 0)
            await apply(session, confirmed: false)
            XCTAssertEqual(session.error as? TrackerHistoryError, .invalidSelection)
            await assertEqual(await http.mutationCount(), 0)
            await apply(session)
            XCTAssertNil(session.error)
            let posts = await http.posts()
            XCTAssertEqual(posts.count, 1)
            XCTAssertEqual(posts[0].queryItems.first { $0.name == "dedupe" }?.value, "true")
            let payload = try XCTUnwrap(posts[0].body).jsonObject
            XCTAssertTrue(payload?["watched_at"] is NSNull)
            await assertEqual(await provider.writeCount(), 0)
        }
    }

    func testKnownWatchDateIsPreservedButUnfinishedRewatchDateIsNotInvented() async throws {
        for hasResume in [false, true] {
            var item = movie(position: hasResume ? 300 : nil)
            item.lastPlayedAt = Date(timeIntervalSince1970: 1_700_000_000)
            let (session, _, http) = try fixture(items: [item])
            await preview(session)
            XCTAssertEqual(session.rows.first?.exportedWatchDate, hasResume ? nil : item.lastPlayedAt)
            await apply(session)
            XCTAssertNil(session.error)
            let posts = await http.posts()
            let payload = try XCTUnwrap(posts.first?.body).jsonObject
            if hasResume { XCTAssertTrue(payload?["watched_at"] is NSNull) }
            else { XCTAssertEqual(payload?["watched_at"] as? String, "2023-11-14T22:13:20.000Z") }
        }
    }

    func testExistingRemoteHistoryDoesNotBecomeAnotherPlay() async throws {
        let (session, _, http) = try fixture(items: [movie()])
        await http.setWatched(true)
        await preview(session)
        XCTAssertEqual(session.rows.map(\.status), [.alreadyMatches])
        await apply(session)
        XCTAssertEqual(session.error as? TrackerHistoryError, .invalidSelection)
        await assertEqual(await http.mutationCount(), 0)
    }

    func testResumeBoundaryChecksUseExactPublicMetaDBThresholds() async throws {
        for (position, expected) in [
            (19.999, PublicMetaDBHistoryExportSession.Status.unsupported),
            (20.0, .ready), (799.999, .ready), (800.0, .unsupported), (900.0, .unsupported)
        ] {
            let (session, _, http) = try fixture(items: [movie(played: false, position: position)])
            await preview(session, mode: .resume)
            XCTAssertNil(session.error)
            XCTAssertEqual(session.rows.map(\.status), [expected])
            await assertEqual(await http.mutationCount(), 0)
        }
    }

    func testResumeConflictRequiresExplicitOverrideAndUsesMilliseconds() async throws {
        let (session, _, http) = try fixture(items: [movie(played: false, position: 300)])
        await http.setResume(position: 200_000)
        await preview(session, mode: .resume)
        XCTAssertEqual(session.rows.map(\.status), [.conflict])
        await apply(session)
        XCTAssertEqual(session.error as? TrackerHistoryError, .invalidSelection)
        await assertEqual(await http.mutationCount(), 0)
        await apply(session, conflicts: true)
        XCTAssertNil(session.error)
        let posts = await http.posts()
        let payload = try XCTUnwrap(posts.first?.body).jsonObject
        XCTAssertEqual(payload?["position_ms"] as? Double, 300_000)
        XCTAssertEqual(payload?["runtime_ms"] as? Double, 1_000_000)
    }

    func testChangedSourceOrTrackerBaselinePreventsDispatch() async throws {
        for changeSource in [false, true] {
            let (session, provider, http) = try fixture(items: [movie()])
            await preview(session)
            if changeSource { await provider.replace([movie(played: false)]) }
            else { await http.setWatched(true) }
            await apply(session)
            XCTAssertEqual(session.error as? TrackerHistoryError, .stalePreview)
            await assertEqual(await http.mutationCount(), 0)
        }
    }

    func testProfileConnectionAndPageExitRevokeApproval() async throws {
        for kind in 0..<3 {
            let authorization = ExportAuthorization()
            let (session, _, http) = try fixture(items: [movie()], authorization: authorization)
            await preview(session)
            switch kind {
            case 0: authorization.current = false
            case 1: authorization.connected = false
            default: session.cancel()
            }
            await apply(session)
            XCTAssertEqual(session.error as? TrackerHistoryError, .scopeChanged)
            await assertEqual(await http.mutationCount(), 0)
        }
    }

    func testScopeIsCheckedAgainAtDispatchAfterFreshSourceRead() async throws {
        let authorization = ExportAuthorization()
        let (session, provider, http) = try fixture(items: [movie()], authorization: authorization)
        await preview(session)
        await provider.onRead(number: 4) { @MainActor in authorization.current = false }
        await apply(session)
        XCTAssertNotNil(session.error)
        await assertEqual(await http.mutationCount(), 0)
    }

    func testLostWriteReplyIsReconciledWithoutReplayAfterRelaunchOrRemoteDeletion() async throws {
        let store = try DurableLocalStateStore(secureStore: InMemorySecureStore())
        let connectionID = UUID()
        let (first, _, http) = try fixture(items: [movie()], store: store, connectionID: connectionID)
        await http.loseReply(applying: true)
        await preview(first)
        await apply(first)
        XCTAssertNil(first.error)
        await assertEqual(await http.mutationCount(), 1)
        await http.setWatched(false)
        let (second, _, _) = try fixture(items: [movie()], http: http, store: store, connectionID: connectionID)
        await preview(second)
        XCTAssertEqual(second.rows.map(\.status), [.previousAttempt])
        await apply(second)
        await assertEqual(await http.mutationCount(), 1)
    }

    func testUnconfirmedWriteRemainsBlockedAfterRelaunch() async throws {
        let store = try DurableLocalStateStore(secureStore: InMemorySecureStore())
        let connectionID = UUID()
        let (first, _, http) = try fixture(items: [movie()], store: store, connectionID: connectionID)
        await http.loseReply(applying: false)
        await preview(first)
        await apply(first)
        XCTAssertEqual(first.error as? PublicMetaDB.Failure, .uncertainWrite)
        let (second, _, _) = try fixture(items: [movie()], http: http, store: store, connectionID: connectionID)
        await preview(second)
        XCTAssertEqual(second.rows.map(\.status), [.previousAttempt])
        await apply(second)
        await assertEqual(await http.mutationCount(), 1)
    }

    func testMissingIdentityAndDuplicateSourceMatchesAreNotExportable() async throws {
        var missing = movie(id: "missing")
        missing.providerIDs = [:]
        let (session, _, http) = try fixture(items: [movie(), movie(id: "edition"), missing])
        await preview(session)
        XCTAssertEqual(session.rows.map(\.status), [.ambiguous, .ambiguous, .unsupported])
        await apply(session)
        await assertEqual(await http.mutationCount(), 0)
    }

    func testTruncatedInventoryFailsClosedInsteadOfPublishingPartialRows() async throws {
        let (session, provider, http) = try fixture(items: [movie()])
        await provider.setAdvertisedTotal(2)
        await preview(session)
        XCTAssertEqual(session.error as? TrackerHistoryError, .incompleteSnapshot)
        XCTAssertFalse(session.hasCompared)
        XCTAssertTrue(session.rows.isEmpty)
        await assertEqual(await http.mutationCount(), 0)
    }

    func testPlayingTitleCannotBeExported() async throws {
        let authorization = ExportAuthorization()
        authorization.playing = true
        let (session, _, http) = try fixture(items: [movie()], authorization: authorization)
        await preview(session)
        XCTAssertEqual(session.rows.map(\.status), [.playing])
        await apply(session)
        await assertEqual(await http.mutationCount(), 0)
    }

    func testEmptyServerInventoryNeverClearsTrackerHistory() async throws {
        let (session, _, http) = try fixture(items: [])
        await http.setWatched(true)
        await preview(session)
        XCTAssertNil(session.error)
        XCTAssertTrue(session.hasCompared)
        XCTAssertTrue(session.rows.isEmpty)
        await assertEqual(await http.mutationCount(), 0)
    }

    func testReceiptStorageFailurePreventsAnyMutation() async throws {
        let store = try DurableLocalStateStore(secureStore: InMemorySecureStore(), maximumPayloadBytes: 1)
        let (session, _, http) = try fixture(items: [movie()], store: store)
        await preview(session)
        await apply(session)
        XCTAssertEqual(session.error as? DurableLocalStateError, .payloadTooLarge)
        await assertEqual(await http.mutationCount(), 0)
    }

    func testPlaybackStartingAfterPreviewBlocksExport() async throws {
        let authorization = ExportAuthorization()
        let (session, _, http) = try fixture(items: [movie()], authorization: authorization)
        await preview(session)
        authorization.playing = true
        await apply(session)
        XCTAssertEqual(session.error as? AppError, .conflict)
        await assertEqual(await http.mutationCount(), 0)
    }

    func testEpisodeBackfillRefreshesParentIdentityAndRequiresItsOrdering() async throws {
        for ordering in [EpisodeOrdering.tmdb, .tvdbDefault] {
            var episode = movie()
            episode.kind = .episode
            episode.seriesID = "series"
            episode.seasonNumber = 1
            episode.episodeNumber = 2
            episode.providerIDs = ["Tvdb": "900"]
            var series = MediaItem(id: "series", title: "Series", kind: .series, providerIDs: ["Tmdb": "1399"])
            series.episodeOrdering = ordering
            let (session, provider, http) = try fixture(items: [episode])
            await provider.setSeries(series)
            await session.compare(
                accountID: "account", library: .init(id: "library", title: "Shows", kind: .series), mode: .watched
            )
            XCTAssertNil(session.error)
            XCTAssertEqual(session.rows.map(\.status), [ordering == .tmdb ? .ready : .unsupported])
            if ordering == .tmdb {
                await apply(session)
                XCTAssertNil(session.error)
                let posts = await http.posts()
                let payload = try XCTUnwrap(posts.first?.body).jsonObject
                XCTAssertEqual(payload?["tmdb_id"] as? Int, 1399)
                XCTAssertEqual(payload?["season"] as? Int, 1)
                XCTAssertEqual(payload?["episode"] as? Int, 2)
            } else {
                await apply(session)
                await assertEqual(await http.mutationCount(), 0)
            }
        }
    }

    func testDroppedEpisodeNeedsExplicitConflictApproval() async throws {
        var episode = movie()
        episode.kind = .episode
        episode.seasonNumber = 1
        episode.episodeNumber = 2
        episode.episodeOrdering = .tmdb
        episode.providerIDs = ["seriesTmdb": "1399"]
        let (session, _, http) = try fixture(items: [episode])
        await http.setDropped(1399)
        await session.compare(
            accountID: "account", library: .init(id: "library", title: "Shows", kind: .series), mode: .watched
        )
        XCTAssertNil(session.error)
        XCTAssertEqual(session.rows.map(\.status), [.conflict])
        await apply(session)
        await assertEqual(await http.mutationCount(), 0)
        await apply(session, conflicts: true)
        XCTAssertNil(session.error)
        await assertEqual(await http.mutationCount(), 1)
    }

    func testMultiPageInventoryAndPartialBulkFailureRetainIndividualOutcomes() async throws {
        let items = (0..<201).map { index -> MediaItem in
            var item = movie(id: "movie-\(index)", played: index < 2)
            item.providerIDs = ["Tmdb": String(550 + index)]
            return item
        }
        let (session, provider, http) = try fixture(items: items)
        await preview(session)
        XCTAssertNil(session.error)
        XCTAssertEqual(session.rows.count, 2)
        await assertEqual(await provider.pageOffsets(), [0, 200, 201])
        await http.failWrite(number: 2)
        await apply(session)
        XCTAssertEqual(session.error as? PublicMetaDB.Failure, .uncertainWrite)
        XCTAssertEqual(session.outcomes.count, 2)
        if case .confirmed? = session.outcomes[session.rows[0].id] {} else { XCTFail("First write was not confirmed") }
        if case .unconfirmed? = session.outcomes[session.rows[1].id] {} else { XCTFail("Lost write was acknowledged") }
        await assertEqual(await http.mutationCount(), 2)
    }

    func testBatchSharesOnlyItsAcknowledgedUndropWithoutAcceptingLaterRedrop() async throws {
        for redrop in [false, true] {
            let episodes = (1...2).map { number -> MediaItem in
                var item = movie(id: "episode-\(number)")
                item.kind = .episode
                item.seasonNumber = 1
                item.episodeNumber = number
                item.episodeOrdering = .tmdb
                item.providerIDs = ["seriesTmdb": "1399"]
                return item
            }
            let (session, provider, http) = try fixture(items: episodes)
            await http.setDropped(1399)
            await session.compare(
                accountID: "account", library: .init(id: "library", title: "Shows", kind: .series), mode: .watched
            )
            XCTAssertEqual(session.rows.map(\.status), [.conflict, .conflict])
            if redrop {
                await provider.onRead(number: 7) { await http.setDropped(1399) }
            }
            await apply(session, conflicts: true)
            if redrop {
                XCTAssertEqual(session.error as? TrackerHistoryError, .stalePreview)
                await assertEqual(await http.mutationCount(), 1)
            } else {
                XCTAssertNil(session.error)
                await assertEqual(await http.mutationCount(), 2)
                XCTAssertEqual(session.outcomes.count, 2)
                for outcome in session.outcomes.values {
                    if case .confirmed = outcome {} else { XCTFail("Expected both approved episodes to be confirmed") }
                }
            }
        }
    }

    func testDefiniteRejectionRequiresNewPreviewButDoesNotLeaveUncertainReceipt() async throws {
        let (session, _, http) = try fixture(items: [movie()])
        await http.rejectWrites(true)
        await preview(session)
        await apply(session)
        XCTAssertEqual(session.error as? PublicMetaDB.Failure, .blocked)
        await http.rejectWrites(false)
        await preview(session)
        XCTAssertEqual(session.rows.map(\.status), [.ready])
        await apply(session)
        XCTAssertNil(session.error)
        await assertEqual(await http.mutationCount(), 2)
    }
}

@MainActor
private final class ExportAuthorization {
    var current = true
    var connected = true
    var playing = false
}

private actor ExportProvider: MediaProvider {
    nonisolated let kind: ProviderKind
    nonisolated let session: UserSession
    private var values: [MediaItem]
    private var offsets: [Int] = []
    private var reads = 0
    private var writes = 0
    private var advertisedTotal: Int?
    private var series: MediaItem?
    private var readHook: (Int, @Sendable () async -> Void)?

    init(items: [MediaItem], kind: ProviderKind) {
        self.kind = kind
        values = items
        session = .init(
            server: .init(id: "server", name: "Server", baseURL: URL(string: "https://example.test")!, provider: kind),
            userID: "user", userName: "Test user", deviceID: "device", accessToken: ""
        )
    }
    func replace(_ items: [MediaItem]) { values = items }
    func setSeries(_ item: MediaItem) { series = item }
    func setAdvertisedTotal(_ total: Int) { advertisedTotal = total }
    func onRead(number: Int, action: @escaping @Sendable () async -> Void) { readHook = (number, action) }
    func pageOffsets() -> [Int] { offsets }
    func writeCount() -> Int { writes }
    func libraries() async throws -> [MediaLibrary] {
        [.init(id: "library", title: "Library", kind: values.first?.kind == .episode ? .series : .movie)]
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem {
        reads += 1
        if let (number, hook) = readHook, reads == number { await hook() }
        if let series, series.id == id { return series }
        guard let item = values.first(where: { $0.id == id }) else { throw AppError.notFound }
        return item
    }
    func children(of itemID: String) async throws -> [MediaItem] { throw AppError.notFound }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        offsets.append(page.startIndex)
        return .init(
            items: Array(values.dropFirst(page.startIndex).prefix(page.limit)),
            startIndex: page.startIndex, totalCount: advertisedTotal ?? values.count
        )
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws { writes += 1 }
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

private actor ExportHTTP: HTTPClient {
    private var watched: [[String: Any]] = []
    private var resume: [[String: Any]] = []
    private var requests: [Endpoint] = []
    private var losesReply = false
    private var appliesWrite = true
    private var dropped: Int?
    private var failedWriteNumber: Int?
    private var rejectsWrites = false

    func setWatched(_ value: Bool) {
        watched = value ? [["id": "watch", "tmdb_id": 550, "media_type": "movie", "watched_at": NSNull()]] : []
    }
    func setResume(position: Double) {
        resume = [["id": "resume", "tmdb_id": 550, "media_type": "movie", "position_ms": position, "runtime_ms": 1_000_000]]
    }
    func loseReply(applying: Bool) { losesReply = true; appliesWrite = applying }
    func setDropped(_ id: Int) { dropped = id }
    func failWrite(number: Int) { failedWriteNumber = number }
    func rejectWrites(_ value: Bool) { rejectsWrites = value }
    func posts() -> [Endpoint] { requests.filter { $0.method == .post } }
    func mutationCount() -> Int { requests.filter { $0.method != .get }.count }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        requests.append(endpoint)
        var body: [String: Any]
        var status = 200
        if endpoint.method == .get {
            var rows = endpoint.path.hasSuffix("/watched") ? watched : (endpoint.path.hasSuffix("/resume") ? resume : [])
            if endpoint.path.hasSuffix("/dropped"), let dropped {
                rows = [["id": "drop", "tmdb_id": dropped, "media_type": "tv"]]
            }
            for field in ["tmdb_id", "season", "episode"] {
                if let value = endpoint.queryItems.first(where: { $0.name == field })?.value, let id = Int(value) {
                    rows = rows.filter { ($0[field] as? Int) == id }
                }
            }
            body = ["items": rows, "total": rows.count, "page": 1, "perPage": 500, "totalPages": rows.isEmpty ? 0 : 1]
        } else {
            var value = try XCTUnwrap(endpoint.body?.jsonObject)
            let isWatch = endpoint.path.hasSuffix("/watched")
            let fails = failedWriteNumber == mutationCount()
            value["id"] = "\(isWatch ? "watch" : "resume")-\(mutationCount())"
            if appliesWrite && !fails && !rejectsWrites {
                if isWatch { watched.append(value); dropped = nil }
                else { resume = [value] }
            }
            body = isWatch ? ["success": true, "item": value] : ["action": "saved", "item": value]
            if losesReply || fails { body = [:]; status = 503 }
            if rejectsWrites { body = [:]; status = 403 }
        }
        return (
            try JSONSerialization.data(withJSONObject: body),
            try XCTUnwrap(HTTPURLResponse(url: baseURL, statusCode: status, httpVersion: nil, headerFields: nil))
        )
    }
}

private extension Data {
    var jsonObject: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: self)) as? [String: Any]
    }
}
