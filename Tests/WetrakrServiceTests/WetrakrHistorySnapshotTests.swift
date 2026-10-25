import CoreModels
import CoreNetworking
import CoreTrackerAuth
import Foundation
import XCTest
@testable import WetrakrService
@testable import TestSupportNetworking

final class WetrakrHistorySnapshotTests: XCTestCase {
    private let date = "2026-10-24T12:00:00.000Z"
    private let movies = "/sync/tracking/watched/history/movies"
    private let episodes = "/sync/tracking/watched/history/episodes"

    private func headers(_ count: Int = 0, next: String? = nil) -> [String: String] {
        var headers = ["X-Pagination-Item-Count": String(count)]
        headers["X-Pagination-Next"] = next
        return headers
    }

    private func watch(_ play: String = "play-1", unknown: Bool = false) -> String {
        #"{"id":1,"type":"movie","ids":{"tmdb":550},"play_id":"\#(play)","watched_at":"\#(date)","watched_at_unknown":\#(unknown)}"#
    }

    private func progress(_ percent: Double = 32.5, runtime: String = "1000", status: String = "paused") -> String {
        #"{"id":1,"type":"movie","ids":{"tmdb":550},"playback":{"status":"\#(status)","progress_percent":\#(percent),"runtime_seconds":\#(runtime),"tracked_at":"\#(date)"}}"#
    }

    private func http(history: String = "[]", count: Int = 0) -> RecordingHTTPClient {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/account/settings", json: #"{"id":42,"info":{"username":"fixture"}}"#)
        http.stub(pathSuffix: "/sync/last_activities", json: #"{"all":"\#(date)"}"#)
        http.stub(pathSuffix: movies, json: history, headers: headers(count))
        http.stub(pathSuffix: episodes, json: "[]", headers: headers())
        http.stub(pathSuffix: "/sync/tracking/playing/movies", json: "[]", headers: headers())
        http.stub(pathSuffix: "/sync/tracking/playing/episodes", json: "[]", headers: headers())
        return http
    }

    private func snapshot(
        _ http: any HTTPClient, reader: WetrakrHistoryReader = WetrakrHistoryReader(), connection: String = "connection"
    ) async throws -> TrackerHistorySnapshot {
        try await reader.snapshot(
            client: .init(config: .init(clientID: "history-fixture"), http: http, gate: .init()),
            accessToken: "fixture", connectionID: connection, validateScope: {}
        )
    }

    func testCompleteReadIsGETOnlyAndPreservesRewatchesAndUnknownDates() async throws {
        let http = http(history: "[\(watch()),\(watch("play-2", unknown: true))]", count: 2)
        let result = try await snapshot(HistoryHTTP(http: http))
        XCTAssertEqual(result.trackerID, "wetrakr")
        XCTAssertEqual(result.observations.map(\.recordID), ["watched/play-1", "watched/play-2"])
        XCTAssertEqual(result.observations.map(\.fact), [.watched(at: try WetrakrDate.parse(date)), .watched(at: nil)])
        XCTAssertEqual(http.sentPaths, [
            "/sync/last_activities", movies, episodes,
            "/sync/tracking/playing/movies", "/sync/tracking/playing/episodes", "/sync/last_activities"
        ])
        for request in http.sent where request.path != "/sync/last_activities" {
            XCTAssertEqual(request.queryItems.first { $0.name == "compact" }?.value, "true")
            XCTAssertEqual(request.queryItems.first { $0.name == "limit" }?.value, "5000")
            XCTAssertNil(request.queryItems.first { $0.name == "page" })
        }
    }

    func testOpaqueCursorMustExhaustWithTheExactAdvertisedCount() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/sync/last_activities", json: #"{"all":"\#(date)"}"#)
        http.stub(pathSuffix: movies, json: "[\(watch())]", headers: headers(2, next: "opaque/+=="))
        http.stub(pathSuffix: movies, json: "[\(watch("play-2"))]", headers: headers(2))
        for path in [episodes, "/sync/tracking/playing/movies", "/sync/tracking/playing/episodes"] {
            http.stub(pathSuffix: path, json: "[]", headers: headers())
        }
        let result = try await snapshot(http)
        XCTAssertEqual(result.observations.count, 2)
        XCTAssertEqual(http.sent.filter { $0.path == movies }.map {
            $0.queryItems.first { $0.name == "after" }?.value
        }, [nil, "opaque/+=="])
    }

    func testMissingTotalsTruncationAndNonExhaustedCursorsNeverPublishPartialHistory() async {
        for fields in [[:], headers(-1), headers(100_001), headers(2), headers(1, next: "unfinished")] {
            let http = RecordingHTTPClient()
            http.stub(pathSuffix: "/sync/last_activities", json: #"{"all":"\#(date)"}"#)
            http.stub(pathSuffix: movies, json: "[\(watch())]", headers: fields)
            do { _ = try await snapshot(http); XCTFail("Incomplete snapshot") }
            catch { XCTAssertEqual(error as? TrackerHistoryError, .incompleteSnapshot) }
            XCTAssertFalse(http.sentPaths.contains(episodes))
        }
    }

    func testRepeatedRecordsCursorsAndChangingTotalsFailClosed() async {
        for kind in 0..<3 {
            let http = RecordingHTTPClient()
            http.stub(pathSuffix: "/sync/last_activities", json: #"{"all":"\#(date)"}"#)
            http.stub(pathSuffix: movies, json: "[\(watch())]", headers: headers(3, next: "cursor"))
            http.stub(
                pathSuffix: movies, json: "[\(watch(kind == 0 ? "play-1" : "play-2"))]",
                headers: headers(kind == 2 ? 4 : 3, next: kind == 1 ? "cursor" : "next")
            )
            do { _ = try await snapshot(http); XCTFail("Changed pagination") }
            catch { XCTAssertEqual(error as? TrackerHistoryError, .incompleteSnapshot) }
            XCTAssertEqual(http.sentPaths.filter { $0 == movies }.count, 2)
        }
    }

    func testPausedRuntimePairConvertsPercentageOnceAndBoundaryValuesRemainInformational() async throws {
        for (percent, runtime, status, expectedSeconds) in [
            (32.5, "1000", "paused", Optional(325.0)),
            (32.5, "null", "paused", nil), (32.5, "1000", "playing", nil),
            (0.0, "1000", "paused", nil), (100.0, "1000", "paused", nil)
        ] {
            let record = try JSONDecoder().decode(
                WetrakrHistoryRecord.self, from: Data(progress(percent, runtime: runtime, status: status).utf8)
            )
            let observation = try record.observation(target: "movies", playback: true)
            let date = try WetrakrDate.parse(date)
            XCTAssertEqual(observation.fact, expectedSeconds.map {
                .resume(seconds: $0, runtime: 1000, updatedAt: date)
            } ?? .resumePercentage(percent: percent, updatedAt: date))
        }
    }

    func testPlayingListsAreReadCompletelyAndRefreshedEvenWhenActivitiesMatch() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/sync/last_activities", json: #"{"all":"\#(date)"}"#)
        for path in [movies, episodes, "/sync/tracking/playing/episodes"] {
            http.stub(pathSuffix: path, json: "[]", headers: headers())
        }
        http.stub(pathSuffix: "/sync/tracking/playing/movies", json: "[\(progress())]", headers: headers(1))
        http.stub(pathSuffix: "/sync/tracking/playing/movies", json: "[]", headers: headers())
        let reader = WetrakrHistoryReader()
        let first = try await snapshot(http, reader: reader)
        XCTAssertEqual(first.observations.count, 1)
        let second = try await snapshot(http, reader: reader)
        XCTAssertTrue(second.observations.isEmpty, "A removed playing entry is not a clear")
        XCTAssertEqual(http.sentPaths.filter { $0 == movies }.count, 1)
        XCTAssertEqual(http.sentPaths.filter { $0 == "/sync/tracking/playing/movies" }.count, 2)
    }

    func testChangedActivityRefetchesWatchedHistoryWithoutInferringAnUnwatch() async throws {
        let reader = WetrakrHistoryReader()
        let first = try await snapshot(http(history: "[\(watch())]", count: 1), reader: reader)
        XCTAssertEqual(first.observations.count, 1)
        let changed = RecordingHTTPClient()
        changed.stub(pathSuffix: "/sync/last_activities", json: #"{"all":"2026-10-24T13:00:00.000Z"}"#)
        for path in [movies, episodes, "/sync/tracking/playing/movies", "/sync/tracking/playing/episodes"] {
            changed.stub(pathSuffix: path, json: "[]", headers: headers())
        }
        let second = try await snapshot(changed, reader: reader)
        XCTAssertTrue(second.observations.isEmpty)
        XCTAssertTrue(changed.sentPaths.contains(movies))
    }

    func testActivityRaceDoesNotSeedACacheOrPublishPartialHistory() async throws {
        let reader = WetrakrHistoryReader()
        let changed = http(history: "[\(watch())]", count: 1)
        changed.stub(pathSuffix: "/sync/last_activities", json: #"{"all":"2026-10-24T13:00:00.000Z"}"#)
        do { _ = try await snapshot(changed, reader: reader); XCTFail("Concurrent activity") }
        catch { XCTAssertEqual(error as? TrackerHistoryError, .incompleteSnapshot) }
        let stable = http()
        _ = try await snapshot(stable, reader: reader)
        XCTAssertTrue(stable.sentPaths.contains(movies))
    }

    func testHistoryCacheNeverCrossesConnections() async throws {
        let reader = WetrakrHistoryReader()
        _ = try await snapshot(http(history: "[\(watch())]", count: 1), reader: reader)
        let other = http()
        let result = try await snapshot(other, reader: reader, connection: "another")
        XCTAssertTrue(result.observations.isEmpty)
        XCTAssertTrue(other.sentPaths.contains(movies))
    }

    func testEpisodeIdentityRequiresItsOwnAndParentCatalogIDs() throws {
        let full = #"{"id":3,"type":"episode","ids":{"tmdb":200},"show_id":2,"show_ids":{"tmdb":100},"season_number":0,"number":1,"play_id":"episode-play","watched_at":"\#(date)"}"#
        for parent in [true, false] {
            let json = parent ? full : full.replacingOccurrences(of: #""show_ids":{"tmdb":100},"#, with: "")
            let record = try JSONDecoder().decode(WetrakrHistoryRecord.self, from: Data(json.utf8))
            let observation = try record.observation(target: "episodes", playback: false)
            let item = MediaItem(
                id: "server", title: "Episode", kind: .episode, seasonNumber: 0, episodeNumber: 1,
                providerIDs: ["Tmdb": "200", "SeriesTmdb": "100"]
            )
            XCTAssertEqual(observation.matches(item), parent)
            XCTAssertTrue(observation.requiresExactEpisodeIdentity)
            XCTAssertNil(observation.episodeOrdering)
        }
    }

    func testMalformedRowsAndProgressAreNeverSilentlyDropped() async {
        for record in [
            watch().replacingOccurrences(of: #""id":1"#, with: #""id":0"#),
            watch().replacingOccurrences(of: #""tmdb":550"#, with: #""tmdb":-1"#),
            watch().replacingOccurrences(of: #""play-1""#, with: #""""#),
            watch().replacingOccurrences(of: date, with: "not-a-date"),
            watch().replacingOccurrences(of: #""movie""#, with: #""show""#)
        ] {
            do { _ = try await snapshot(http(history: "[\(record)]", count: 1)); XCTFail("Malformed row") }
            catch { XCTAssertTrue(error is TrackerHistoryError || error is AppError) }
        }
        for json in [progress(-1), progress(101), progress(runtime: "0"), progress(status: "unknown")] {
            do {
                let row = try JSONDecoder().decode(WetrakrHistoryRecord.self, from: Data(json.utf8))
                _ = try row.observation(target: "movies", playback: true)
                XCTFail("Malformed progress")
            } catch { XCTAssertEqual(error as? TrackerHistoryError, .invalidObservation) }
        }
    }

    func testHTTPFailuresAreExplicitAndNeverRetried() async {
        for status in [401, 403, 429, 500] {
            let http = RecordingHTTPClient()
            http.stub(pathSuffix: "/sync/last_activities", json: "{}", status: status, headers: ["Retry-After": "60"])
            do { _ = try await snapshot(http); XCTFail("Remote refusal") }
            catch {
                switch status {
                case 401: XCTAssertEqual(error as? AppError, .unauthorized)
                case 403: XCTAssertEqual(error as? WetrakrError, .requestBlocked)
                case 429: XCTAssertEqual(error as? AppError, .rateLimited(retryAfter: 60))
                default: XCTAssertEqual(error as? AppError, .invalidResponse)
                }
            }
            XCTAssertEqual(http.sentPaths.count, 1)
        }
    }

    func testResponseByteAndPageSizeLimitsAreEnforced() async {
        let oversizedPage = "[" + (1...5_001).map { watch("play-\($0)") }.joined(separator: ",") + "]"
        for body in [oversizedPage, "[]" + String(repeating: " ", count: 8 * 1_024 * 1_024)] {
            let http = RecordingHTTPClient()
            http.stub(pathSuffix: "/sync/last_activities", json: #"{"all":"\#(date)"}"#)
            http.stub(pathSuffix: movies, json: body, headers: headers(5_001))
            do { _ = try await snapshot(HistoryHTTP(http: http)); XCTFail("Unbounded read") }
            catch { XCTAssertEqual(error as? TrackerHistoryError, .incompleteSnapshot) }
            XCTAssertFalse(http.sentPaths.contains(episodes))
        }
    }

    @MainActor
    func testScopeIsCheckedAfterWaitingForTheSharedRequestGate() async throws {
        let occupied = expectation(description: "Shared request gate is occupied")
        let queued = expectation(description: "Reader reached dispatch")
        let hold = HeldHistoryGate(started: occupied)
        let gate = WetrakrRequestGate()
        let scope = HistoryScope(queued: queued)
        let blocker = Task {
            try await gate.run(clientID: "history-fixture", accessToken: "fixture", request: .other) {
                await hold.wait()
            }
        }
        await fulfillment(of: [occupied], timeout: 2)
        let http = http()
        let read = Task {
            try await WetrakrHistoryReader().snapshot(
                client: .init(config: .init(clientID: "history-fixture"), http: http, gate: gate),
                accessToken: "fixture", connectionID: "connection", validateScope: { try await scope.validate() }
            )
        }
        await fulfillment(of: [queued], timeout: 2)
        scope.current = false
        await hold.release()
        _ = try await blocker.value
        do { _ = try await read.value; XCTFail("Stale queued request") }
        catch { XCTAssertEqual(error as? TrackerHistoryError, .scopeChanged) }
        XCTAssertTrue(http.sentPaths.isEmpty)
    }

    @MainActor
    func testCancellationBeforeReadSendsNothing() async {
        let http = http()
        let task = Task { try await snapshot(http) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled read") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(http.sentPaths.isEmpty)
    }

    @MainActor
    func testCoordinatedRefreshRetainsGrantButProfileSwitchRevokesPreview() async throws {
        let store = InMemoryTrackerTokenStore(tokens: .init(
            accessToken: "fixture", refreshToken: "refresh", expiresAt: .distantFuture, accountIdentity: "grant"
        ))
        let http = http()
        let service = WetrakrService(config: .init(clientID: "history-fixture"), http: http, tokenStore: store, coordinator: .init())
        await service.setActiveProfile(namespace: nil)
        let connection = try XCTUnwrap(service.historyConnectionID)
        var expired = try XCTUnwrap(store.load())
        expired.expiresAt = .distantPast
        try store.save(expired)
        http.stub(pathSuffix: "/oauth/token/refresh", json: #"{"access_token":"rotated","refresh_token":"new-refresh","expires_in":7200,"token_type":"bearer"}"#)
        let snapshot = try await service.historySnapshot(expectedConnectionID: connection)
        XCTAssertEqual(snapshot.connectionID, connection)
        XCTAssertEqual(service.historyConnectionID, connection)
        XCTAssertEqual(store.load()?.accessToken, "rotated")
        await service.setActiveProfile(namespace: "child")
        do { _ = try await service.historySnapshot(expectedConnectionID: connection); XCTFail("Old profile") }
        catch { XCTAssertEqual(error as? TrackerHistoryError, .scopeChanged) }
        await service.setActiveProfile(namespace: nil)
        XCTAssertNotEqual(service.historyConnectionID, connection)
    }

    @MainActor
    func testGrantReplacementDuringReadRejectsTheResponseAndStopsLaterCalls() async throws {
        let store = InMemoryTrackerTokenStore(tokens: .init(
            accessToken: "fixture", refreshToken: "refresh", expiresAt: .distantFuture, accountIdentity: "grant"
        ))
        let http = http()
        let service = WetrakrService(
            config: .init(clientID: "history-fixture"), http: HistoryHTTP(http: http, replacing: store),
            tokenStore: store, coordinator: .init()
        )
        await service.refreshStatus()
        let connection = try XCTUnwrap(service.historyConnectionID)
        do { _ = try await service.historySnapshot(expectedConnectionID: connection); XCTFail("Changed grant") }
        catch { XCTAssertEqual(error as? TrackerHistoryError, .scopeChanged) }
        XCTAssertFalse(http.sentPaths.contains(episodes))
    }
}

private struct HistoryHTTP: HTTPClient {
    let http: RecordingHTTPClient
    var replacing: InMemoryTrackerTokenStore?
    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        try await sendRaw(endpoint, baseURL: baseURL)
    }
    func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        guard endpoint.method == .get else { throw AppError.invalidResponse }
        if endpoint.path.hasPrefix("/sync/") {
            XCTAssertEqual(endpoint.maximumResponseBytes, 8 * 1_024 * 1_024)
            XCTAssertTrue(endpoint.redactsURLForLogging)
        }
        if endpoint.path.hasSuffix("/history/movies") {
            try replacing?.save(.init(
                accessToken: "replaced", refreshToken: "replaced-refresh", expiresAt: .distantFuture, accountIdentity: "new-grant"
            ))
        }
        return try await http.sendRaw(endpoint, baseURL: baseURL)
    }
}

@MainActor private final class HistoryScope {
    var current = true
    private var calls = 0
    private let queued: XCTestExpectation
    init(queued: XCTestExpectation) { self.queued = queued }
    func validate() throws {
        guard current else { throw TrackerHistoryError.scopeChanged }
        calls += 1
        if calls == 2 { queued.fulfill() }
    }
}

private actor HeldHistoryGate {
    private let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    init(started: XCTestExpectation) { self.started = started }
    func wait() async {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }
    func release() { continuation?.resume(); continuation = nil }
}
