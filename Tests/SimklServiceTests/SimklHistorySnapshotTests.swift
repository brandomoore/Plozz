import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import SimklService
@testable import TestSupportNetworking

@MainActor
final class SimklHistorySnapshotTests: XCTestCase {
    private let date = "2026-10-24T12:00:00Z"
    private let later = "2026-10-24T12:01:00Z"

    private func activity(_ stamp: String? = nil, movieFields: [String: String] = [:]) throws -> String {
        let fields = Dictionary(uniqueKeysWithValues: [
            "all", "plantowatch", "watching", "hold", "dropped", "completed", "removed_from_list", "playback", "rated_at"
        ].map { ($0, date) })
        let object: [String: Any] = [
            "all": stamp ?? date, "tv_shows": fields, "anime": fields,
            "movies": fields.merging(movieFields) { _, new in new }
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func movie(_ id: Int = 1, status: String = "completed", watchedAt: String = "1970-01-01T00:00:01Z") -> String {
        #"{"status":"\#(status)","last_watched_at":"\#(watchedAt)","movie":{"ids":{"simkl":\#(id),"tmdb":\#(500 + id)}}}"#
    }

    private func http(
        activities: [String]? = nil, movies: [String] = ["{}"], shows: String = "{}", anime: String = "{}",
        playback: [String] = ["[]"]
    ) throws -> RecordingHTTPClient {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/users/settings", json: #"{"account":{"id":1},"user":{"name":"fixture"}}"#)
        for json in try activities ?? [activity()] { http.stub(pathSuffix: "/sync/activities", json: json) }
        for json in movies { http.stub(pathSuffix: "/sync/all-items/movies", json: json) }
        http.stub(pathSuffix: "/sync/all-items/shows", json: shows)
        http.stub(pathSuffix: "/sync/all-items/anime", json: anime)
        for json in playback { http.stub(pathSuffix: "/sync/playback", json: json) }
        return http
    }

    private func reader(_ http: any HTTPClient, includesListStates: Bool = false) -> SimklHistoryReader {
        SimklHistoryReader(
            client: .init(config: .init(clientID: "fixture"), http: http, gate: .init()), includesListStates: includesListStates
        )
    }

    private func snapshot(_ reader: SimklHistoryReader, connection: String = "connection") async throws -> TrackerHistorySnapshot {
        try await reader.snapshot(accessToken: "fixture", connectionID: connection, validateScope: {})
    }

    func testInitialCompleteReadIsSequentialGETOnlyAndUsesOriginalEpisodes() async throws {
        let http = try http(movies: [#"{"movies":[\#(movie())]}"#])
        let result = try await snapshot(reader(ReadOnlySimklHistoryHTTP(http: http)))
        XCTAssertEqual(result.trackerID, "simkl")
        XCTAssertEqual(result.observations.count, 1)
        XCTAssertEqual(result.observations[0].fact, .watched(at: nil), "The sentinel is not a 1970 play")
        XCTAssertEqual(http.sentPaths, [
            "/sync/activities", "/sync/all-items/shows", "/sync/all-items/movies",
            "/sync/all-items/anime", "/sync/playback", "/sync/activities"
        ])
        for request in http.sent {
            XCTAssertEqual(request.headers["User-Agent"], "Plozz/1.0")
            XCTAssertEqual(request.queryItems.first { $0.name == "client_id" }?.value, "fixture")
            XCTAssertEqual(request.queryItems.first { $0.name == "app-name" }?.value, "Plozz")
            XCTAssertFalse(request.queryItems.contains { $0.name == "date_from" || $0.name == "allow_rewatch" })
            if request.path.contains("/all-items/") {
                XCTAssertEqual(request.queryItems.first { $0.name == "extended" }?.value, "full")
                XCTAssertEqual(request.queryItems.first { $0.name == "include_all_episodes" }?.value, "original")
                XCTAssertEqual(request.queryItems.first { $0.name == "episode_watched_at" }?.value, "yes")
            }
        }
    }

    func testUnchangedActivityDoesNotReadLibraryAgain() async throws {
        let http = try http()
        let source = reader(http)
        _ = try await snapshot(source)
        _ = try await snapshot(source)
        XCTAssertEqual(http.sentPaths.count, 7)
        XCTAssertEqual(http.sentPaths.last, "/sync/activities")
    }

    func testDeltaMergesInsteadOfReplacingAndUsesSavedTimestampVerbatim() async throws {
        let changed = try activity(later, movieFields: ["completed": later])
        let http = try http(
            activities: [activity(), activity(), changed, changed],
            movies: [#"{"movies":[\#(movie())]}"#, #"{"movies":[\#(movie(2))]}"#]
        )
        let source = reader(http)
        _ = try await snapshot(source)
        let result = try await snapshot(source)
        XCTAssertEqual(result.observations.map(\.recordID), ["movies/1", "movies/2"])
        let reads = http.sent.filter { $0.path == "/sync/all-items/movies" }
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(reads[1].queryItems.first { $0.name == "date_from" }?.value, date)
        XCTAssertEqual(http.sentPaths.filter { $0 == "/sync/all-items/shows" }.count, 1)
    }

    func testRatingsOnlyChangesDoNotReadHistoryOrPlayback() async throws {
        let changed = try activity(later, movieFields: ["rated_at": later])
        let http = try http(activities: [activity(), activity(), changed, changed])
        let source = reader(http)
        _ = try await snapshot(source)
        _ = try await snapshot(source)
        XCTAssertEqual(http.sentPaths.suffix(2), ["/sync/activities", "/sync/activities"])
        XCTAssertEqual(http.sentPaths.count, 8)
    }

    func testRemovalReconciliationNeverCreatesUnwatchOrResumeClear() async throws {
        let changed = try activity(later, movieFields: ["removed_from_list": later])
        let http = try http(
            activities: [activity(), activity(), changed, changed],
            movies: [#"{"movies":[\#(movie())]}"#, "{}"]
        )
        let source = reader(http)
        _ = try await snapshot(source)
        let result = try await snapshot(source)
        XCTAssertTrue(result.observations.isEmpty)
        let request = try XCTUnwrap(http.sent.last { $0.path == "/sync/all-items/movies" })
        XCTAssertEqual(request.queryItems.first { $0.name == "extended" }?.value, "simkl_ids_only")
        XCTAssertFalse(request.queryItems.contains { $0.name == "date_from" })
    }

    func testPlaybackRemovalReplacesCurrentSetWithoutInventingClears() async throws {
        let changed = try activity(later, movieFields: ["playback": later])
        let progress = #"{"id":9,"progress":42.5,"paused_at":"\#(date)","type":"movie","movie":{"ids":{"simkl":1,"tmdb":501}}}"#
        let http = try http(activities: [activity(), activity(), changed, changed], playback: ["[\(progress)]", "[]"])
        let source = reader(http)
        let initial = try await snapshot(source)
        XCTAssertEqual(initial.observations[0].fact, .resumePercentage(percent: 42.5, updatedAt: try SimklHistoryDate.parse(date)))
        let removed = try await snapshot(source)
        XCTAssertTrue(removed.observations.isEmpty)
    }

    func testActivityChangingDuringReadRejectsComparisonAndDoesNotSaveBaseline() async throws {
        let changed = try activity(later)
        let http = try http(activities: [activity(), changed, changed, changed])
        let source = reader(http)
        do { _ = try await snapshot(source); XCTFail("Must reject a changing source") }
        catch { XCTAssertEqual(error as? TrackerHistoryError, .incompleteSnapshot) }
        _ = try await snapshot(source)
        let requests = http.sent.filter { $0.path == "/sync/all-items/movies" }
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { !$0.queryItems.contains { $0.name == "date_from" } })
    }

    func testFailedDeltaRetainsPreviousBaselineForTheNextAttempt() async throws {
        let changed = try activity(later, movieFields: ["completed": later])
        let http = try http(
            activities: [activity(), activity(), changed, changed, changed],
            movies: [#"{"movies":[\#(movie())]}"#, #"{"movies":[{}]}"#, #"{"movies":[\#(movie(2))]}"#]
        )
        let source = reader(http)
        _ = try await snapshot(source)
        do { _ = try await snapshot(source); XCTFail("Malformed delta must fail") }
        catch { XCTAssertEqual(error as? TrackerHistoryError, .invalidObservation) }
        let result = try await snapshot(source)
        XCTAssertEqual(result.observations.map(\.recordID), ["movies/1", "movies/2"])
        let deltas = http.sent.filter { $0.path == "/sync/all-items/movies" }.dropFirst()
        XCTAssertEqual(deltas.count, 2)
        XCTAssertTrue(deltas.allSatisfy { $0.queryItems.first { $0.name == "date_from" }?.value == date })
    }

    func testMoviesNotCompletedDoNotImplyUnwatched() async throws {
        for status in ["plantowatch", "dropped", "notinteresting"] {
            let http = try http(movies: [#"{"movies":[\#(movie(status: status))]}"#])
            let result = try await snapshot(reader(http))
            XCTAssertTrue(result.observations.isEmpty)
        }
    }

    func testExportReadRetainsMovieListStatesWithoutInventingHistory() async throws {
        for (status, state) in [
            ("plantowatch", TrackerHistoryListState.planning), ("dropped", .dropped), ("notinteresting", .dropped)
        ] {
            let http = try http(movies: [#"{"movies":[\#(movie(status: status))]}"#])
            let source = reader(ReadOnlySimklHistoryHTTP(http: http), includesListStates: true)
            let result = try await snapshot(source)
            XCTAssertEqual(result.observations.map(\.recordID), ["movies/1/state"])
            XCTAssertEqual(result.observations.first?.fact, .listState(state))
            XCTAssertFalse(try TrackerHistoryExportState(observations: result.observations).isWatched)
            _ = try await snapshot(source)
            XCTAssertEqual(http.sentPaths.count, 7, "List protection must reuse the activity cache")
            XCTAssertEqual(http.sentPaths.last, "/sync/activities")
        }
    }

    func testExportReadKeepsParentListStateSeparateFromEpisodeEvidence() async throws {
        for (status, state) in [
            ("plantowatch", TrackerHistoryListState.planning), ("watching", .watching),
            ("hold", .paused), ("dropped", .dropped), ("completed", .completed)
        ] {
            let record = """
            {"status":"\(status)","watched_episodes_count":1,"show":{"ids":{"simkl":1,"tvdb":100}},
             "seasons":[{"number":1,"episodes":[{"number":2,"watched_at":"\(date)","ids":{"tvdb_id":200}}]}]}
            """
            for kind in [SimklHistoryKind.shows, .anime] {
                let http = try http(
                    shows: kind == .shows ? #"{"shows":[\#(record)]}"# : "{}",
                    anime: kind == .anime ? #"{"anime":[\#(record)]}"# : "{}"
                )
                let result = try await snapshot(reader(http, includesListStates: true))
                XCTAssertEqual(result.observations.count, 3)
                XCTAssertEqual(result.observations[0].fact, .listState(state))
                XCTAssertEqual(result.observations[0].kind, .series)
                XCTAssertEqual(result.observations[1].fact, .watched(at: try SimklHistoryDate.parse(date)))
                XCTAssertEqual(result.observations[1].kind, .episode)
                XCTAssertEqual(result.observations[2].fact, .episodeCount(watched: 1, repeats: nil))
                XCTAssertEqual(http.sentPaths.count, 6)
            }
        }
    }

    func testExportListStateDeltaReplacesOldWatchWithoutInventingUnwatch() async throws {
        let changed = try activity(later, movieFields: ["completed": later, "dropped": later])
        let http = try http(
            activities: [activity(), activity(), changed, changed],
            movies: [
                #"{"movies":[\#(movie()),\#(movie(2, status: "plantowatch"))]}"#,
                #"{"movies":[\#(movie(status: "dropped"))]}"#
            ]
        )
        let source = reader(http, includesListStates: true)
        let before = try await snapshot(source)
        XCTAssertEqual(before.observations.map(\.fact), [.watched(at: nil), .listState(.planning)])
        let after = try await snapshot(source)
        XCTAssertEqual(after.observations.map(\.recordID), ["movies/1/state", "movies/2/state"])
        XCTAssertEqual(after.observations.map(\.fact), [.listState(.dropped), .listState(.planning)])
        let reads = http.sent.filter { $0.path == "/sync/all-items/movies" }
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(reads.last?.queryItems.first { $0.name == "date_from" }?.value, date)
    }

    func testExportListStateRemovalDropsProtectionWithoutServerInstructions() async throws {
        let changed = try activity(later, movieFields: ["removed_from_list": later])
        let http = try http(
            activities: [activity(), activity(), changed, changed],
            movies: [#"{"movies":[\#(movie(status: "plantowatch"))]}"#, "{}"]
        )
        let source = reader(http, includesListStates: true)
        let before = try await snapshot(source)
        XCTAssertEqual(before.observations.count, 1)
        let after = try await snapshot(source)
        XCTAssertTrue(after.observations.isEmpty)
        let read = try XCTUnwrap(http.sent.last { $0.path == "/sync/all-items/movies" })
        XCTAssertEqual(read.queryItems.first { $0.name == "extended" }?.value, "simkl_ids_only")
        XCTAssertFalse(read.queryItems.contains { $0.name == "date_from" })
    }

    func testExportListStateRejectsUnknownOrIncompleteStatus() async throws {
        for record in [
            movie(status: "unknown-state"), #"{"movie":{"ids":{"simkl":1,"tmdb":501}}}"#
        ] {
            let http = try http(movies: [#"{"movies":[\#(record)]}"#])
            do {
                _ = try await snapshot(reader(http, includesListStates: true))
                XCTFail("Incomplete list state cannot prove absence")
            } catch { XCTAssertEqual(error as? TrackerHistoryError, .invalidObservation) }
        }
    }

    func testOriginalEpisodesRequireEpisodeAndDistinctParentIdentity() async throws {
        let show = """
        {"status":"completed","watched_episodes_count":12,
         "show":{"ids":{"simkl":1,"tvdb":100}},
         "seasons":[{"number":1,"episodes":[{"number":2,"watched_at":"\(date)","ids":{"tvdb_id":200}}]}]}
        """
        let http = try http(shows: #"{"shows":[\#(show)]}"#)
        let result = try await snapshot(reader(http))
        XCTAssertEqual(result.observations.count, 2, "Do not synthesize twelve episodes")
        let episode = result.observations[0]
        var item = MediaItem(
            id: "server", title: "Episode", kind: .episode, seasonNumber: 1, episodeNumber: 2,
            providerIDs: ["Tvdb": "200", "SeriesTvdb": "100"]
        )
        XCTAssertTrue(episode.matches(item))
        item.providerIDs["Tvdb"] = "100"
        XCTAssertFalse(episode.matches(item))
        XCTAssertEqual(result.observations[1].fact, .episodeCount(watched: 12, repeats: nil))
    }

    func testAnimeAggregateCannotBecomeIndividualEpisodes() async throws {
        let http = try http(anime: #"{"anime":[{"status":"completed","watched_episodes_count":50,"show":{"ids":{"simkl":1,"mal":21}}}]}"#)
        let result = try await snapshot(reader(http))
        XCTAssertEqual(result.observations.count, 1)
        XCTAssertEqual(result.observations[0].kind, .series)
        XCTAssertEqual(result.observations[0].fact, .episodeCount(watched: 50, repeats: nil))
    }

    func testOlderPlaybackTimestampDoesNotBecomeAnInventedPauseDate() async throws {
        let record = #"{"id":1,"progress":100,"watched_at":"\#(date)","movie":{"ids":{"simkl":1,"tmdb":501}}}"#
        let result = try await snapshot(reader(http(playback: ["[\(record)]"])))
        XCTAssertEqual(result.observations[0].fact, .resumePercentage(percent: 100, updatedAt: nil))
    }

    func testMalformedAndDuplicateResponsesDoNotBecomeEmptyComparisons() async throws {
        for json in [
            #"{"movies":[\#(movie()),\#(movie())]}"#,
            #"{"movies":[\#(movie(0))]}"#,
            #"{"movies":[\#(movie(status: "invented"))]}"#,
            #"{"movies":[\#(movie(watchedAt: "invalid"))]}"#,
            #"{"unknown":[]}"#, #"{"movies":null}"#, "[]",
            #"{"error":"max_items"}"#
        ] {
            do { _ = try await snapshot(reader(http(movies: [json]))); XCTFail("Must reject \(json)") }
            catch { XCTAssertTrue(error is TrackerHistoryError || error is DecodingError) }
        }
    }

    func testMissingActivityEvidenceStopsBeforeLibraryReads() async throws {
        let http = try http(activities: [#"{"all":"2026-10-24T12:00:00Z","tv_shows":{},"movies":{},"anime":{}}"#])
        do { _ = try await snapshot(reader(http)); XCTFail("Incomplete activity") }
        catch { XCTAssertEqual(error as? TrackerHistoryError, .incompleteSnapshot) }
        XCTAssertEqual(http.sentPaths, ["/sync/activities"])
    }

    func testHTTPFailuresAreExplicitAndNeverRetried() async throws {
        for code in [401, 403, 429, 500] {
            let http = RecordingHTTPClient()
            http.stub(pathSuffix: "/sync/activities", json: "{}", status: code, headers: ["Retry-After": "20"])
            do { _ = try await snapshot(reader(http)); XCTFail("HTTP failure") }
            catch {
                XCTAssertEqual(error as? AppError, code == 429 ? .rateLimited(retryAfter: 20)
                    : (code == 401 || code == 403 ? .unauthorized : .invalidResponse))
            }
            XCTAssertEqual(http.sentPaths.count, 1)
        }
    }

    func testOversizedTypeSplitsByStatusRatherThanRepeatingTheRequest() async throws {
        let http = try http(movies: [])
        http.stub(pathSuffix: "/sync/all-items/movies", json: #"{"error":"max_items"}"#, status: 400)
        for status in ["plantowatch", "completed", "dropped"] {
            http.stub(pathSuffix: "/sync/all-items/movies/\(status)", json: status == "completed" ? #"{"movies":[\#(movie())]}"# : "{}")
        }
        let result = try await snapshot(reader(http))
        XCTAssertEqual(result.observations.count, 1)
        XCTAssertEqual(http.sentPaths.filter { $0.hasPrefix("/sync/all-items/movies") }, [
            "/sync/all-items/movies", "/sync/all-items/movies/plantowatch",
            "/sync/all-items/movies/completed", "/sync/all-items/movies/dropped"
        ])
    }

    func testPlaybackAtLimitFailsRatherThanAssumingCompleteness() async throws {
        let records = (1...10_000).map { #"{"id":\#($0),"progress":5,"movie":{"ids":{"simkl":1}}}"# }.joined(separator: ",")
        let http = try http(playback: ["[\(records)]"])
        do { _ = try await snapshot(reader(http)); XCTFail("Potentially truncated playback") }
        catch { XCTAssertEqual(error as? TrackerHistoryError, .incompleteSnapshot) }
    }

    func testConnectionChangeDiscardsReadCache() async throws {
        let http = try http()
        let source = reader(http)
        _ = try await snapshot(source)
        _ = try await snapshot(source, connection: "new")
        XCTAssertEqual(http.sentPaths.filter { $0 == "/sync/all-items/movies" }.count, 2)
    }

    func testCancellationBeforeReadSendsNothing() async throws {
        let http = try http()
        let source = reader(http)
        let task = Task { try await self.snapshot(source) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(http.sentPaths.isEmpty)
    }

    func testProfileSwitchAwayAndBackInvalidatesEarlierConnection() async throws {
        let http = try http()
        let store = InMemorySimklTokenStore(tokens: .init(accessToken: "fixture"))
        let service = SimklService(config: .init(clientID: "fixture"), http: http, tokenStore: store)
        await service.refreshStatus()
        let connection = try XCTUnwrap(service.historyConnectionID)
        let durable = try XCTUnwrap(service.historySyncIdentity)
        XCTAssertFalse(durable.allowsForegroundChecks)
        XCTAssertEqual(service.historySyncCategories, [.watched])
        await service.setActiveProfile(namespace: "other")
        XCTAssertNil(service.historySyncIdentity)
        await service.setActiveProfile(namespace: nil)
        XCTAssertNotEqual(service.historyConnectionID, connection)
        XCTAssertEqual(service.historySyncIdentity, durable)
        do { _ = try await service.historySnapshot(expectedConnectionID: connection); XCTFail("Stale profile") }
        catch { XCTAssertEqual(error as? TrackerHistoryError, .scopeChanged) }
        XCTAssertFalse(http.sentPaths.contains("/sync/activities"))
    }

    func testDurableIdentitySurvivesRelaunchButSameTokenReconnectCreatesNewConsentScope() async throws {
        let http = try http()
        http.stub(pathSuffix: "/oauth/pin", json: """
        {"user_code":"FIXTURE","verification_url":"https://example.test","expires_in":600,"interval":5}
        """)
        http.stub(pathSuffix: "/oauth/pin/FIXTURE", json: #"{"result":"OK","access_token":"fixture"}"#)
        let legacy = try JSONDecoder().decode(SimklTokens.self, from: Data(#"{"accessToken":"fixture"}"#.utf8))
        let store = InMemorySimklTokenStore(tokens: legacy)
        let service = SimklService(config: .init(clientID: "fixture"), http: http, tokenStore: store)
        await service.refreshStatus()
        let first = try XCTUnwrap(service.historySyncIdentity)
        let restored = SimklService(config: .init(clientID: "fixture"), http: http, tokenStore: store)
        await restored.refreshStatus()
        XCTAssertEqual(restored.historySyncIdentity, first)
        var revocations = 0
        service.onHistorySyncDisconnect = { revocations += 1 }
        service.connect()
        await service.connectTask?.value
        let next = try XCTUnwrap(service.historySyncIdentity)
        XCTAssertNotEqual(next, first)
        let saved = try XCTUnwrap(store.load())
        XCTAssertEqual(saved.accessToken, legacy.accessToken)
        XCTAssertEqual(try JSONDecoder().decode(SimklTokens.self, from: JSONEncoder().encode(saved)), saved)
        service.connect()
        await service.connectTask?.value
        XCTAssertNotEqual(service.historySyncIdentity, next)
        XCTAssertEqual(revocations, 2)
    }

    func testPersistenceFailuresNeverReportConnectedOrDisconnectedSuccess() async throws {
        let http = try http()
        http.stub(pathSuffix: "/oauth/pin", json: """
        {"user_code":"FIXTURE","verification_url":"https://example.test","expires_in":600,"interval":5}
        """)
        http.stub(pathSuffix: "/oauth/pin/FIXTURE", json: #"{"access_token":"fixture"}"#)
        let store = FailableStore()
        store.failure = .save
        let service = SimklService(config: .init(clientID: "fixture"), http: http, tokenStore: store)
        service.connect()
        await service.connectTask?.value
        XCTAssertEqual(service.phase, .error("Could not save the connection. Try again."))
        XCTAssertNil(store.load())
        store.failure = nil
        service.connect()
        await service.connectTask?.value
        XCTAssertNotNil(service.historySyncIdentity)
        service.onHistorySyncDisconnect = { throw TrackerHistorySyncError.revocationFailed }
        let saved = store.load()
        service.connect()
        await service.connectTask?.value
        XCTAssertEqual(service.phase, .error("Sync is paused. Retry before closing the app."))
        XCTAssertEqual(store.load(), saved)
        await service.disconnect()
        XCTAssertNotNil(store.load())
        XCTAssertEqual(service.phase, .error("Could not disconnect. Retry before closing the app."))
        service.onHistorySyncDisconnect = nil
        store.failure = .clear
        await service.disconnect()
        XCTAssertNotNil(store.load())
        XCTAssertEqual(service.phase, .error("Could not disconnect. Retry before closing the app."))
        store.failure = nil
        await service.disconnect()
        XCTAssertNil(store.load())
        XCTAssertEqual(service.phase, .disconnected)
    }

    func testLateCredentialRejectionCannotDeleteSynchronizedReplacement() async throws {
        let store = InMemorySimklTokenStore(tokens: .init(accessToken: "old"))
        let replacement = SimklTokens(accessToken: "new", accountIdentity: "new-connection")
        let service = SimklService(
            config: .init(clientID: "fixture"),
            http: ReplacedCredentialHTTP(store: store, replacement: replacement), tokenStore: store
        )
        service.onHistorySyncDisconnect = { XCTFail("A stale rejection must not revoke current permission") }
        await service.refreshStatus()
        XCTAssertEqual(store.load(), replacement)
    }

    private struct ReplacedCredentialHTTP: HTTPClient {
        let store: InMemorySimklTokenStore
        let replacement: SimklTokens
        func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
            try store.save(replacement)
            throw AppError.unauthorized
        }
    }

    private final class FailableStore: SimklTokenStoring, @unchecked Sendable {
        enum Failure { case save, clear }
        private let lock = NSLock()
        private var storedFailure: Failure?
        private let storage = InMemorySimklTokenStore()
        var authorizationGeneration: UUID { storage.authorizationGeneration }
        var failure: Failure? {
            get { lock.lock(); defer { lock.unlock() }; return storedFailure }
            set { lock.lock(); defer { lock.unlock() }; storedFailure = newValue }
        }
        func load() -> SimklTokens? { storage.load() }
        func save(_ tokens: SimklTokens) throws {
            if failure == .save { throw AppError.invalidResponse }
            try storage.save(tokens)
        }
        func clear() throws {
            if failure == .clear { throw AppError.invalidResponse }
            try storage.clear()
        }
        func setNamespace(_ namespace: String?) { storage.setNamespace(namespace) }
    }

    func testGrantReplacementDuringReadRejectsResultsAndStopsRequests() async throws {
        let http = try http()
        let store = InMemorySimklTokenStore(tokens: .init(accessToken: "fixture"))
        let service = SimklService(
            config: .init(clientID: "fixture"), http: ReadOnlySimklHistoryHTTP(http: http, replacing: store),
            tokenStore: store
        )
        await service.refreshStatus()
        let connection = try XCTUnwrap(service.historyConnectionID)
        do { _ = try await service.historySnapshot(expectedConnectionID: connection); XCTFail("Changed grant") }
        catch { XCTAssertEqual(error as? TrackerHistoryError, .scopeChanged) }
        XCTAssertEqual(http.sentPaths.last, "/sync/all-items/shows")
        XCTAssertFalse(http.sentPaths.contains("/sync/all-items/movies"))
    }
}

private struct ReadOnlySimklHistoryHTTP: HTTPClient {
    let http: RecordingHTTPClient
    var replacing: InMemorySimklTokenStore? = nil

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        try await sendRaw(endpoint, baseURL: baseURL)
    }

    func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        guard endpoint.method == .get else { throw AppError.invalidResponse }
        if endpoint.path == "/sync/all-items/shows" { try replacing?.save(.init(accessToken: "replacement")) }
        return try await http.sendRaw(endpoint, baseURL: baseURL)
    }
}
