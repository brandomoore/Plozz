@testable import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import TestSupportNetworking
@testable import TraktService

final class TraktHistorySnapshotTests: XCTestCase {
    private let date = "2026-10-24T12:00:00.000Z"

    private func headers(page: Int = 1, count: Int = 0, limit: Int = 100) -> [String: String] {
        [
            "X-Pagination-Page": String(page), "X-Pagination-Limit": String(limit),
            "X-Pagination-Page-Count": String((count + limit - 1) / limit),
            "X-Pagination-Item-Count": String(count)
        ]
    }

    private func activity(_ stamp: String? = nil, movieWatch: String? = nil, moviePause: String? = nil) -> String {
        let stamp = stamp ?? date
        return """
        {"all":"\(stamp)","movies":{"watched_at":"\(movieWatch ?? stamp)","paused_at":"\(moviePause ?? stamp)"},
         "episodes":{"watched_at":"\(stamp)","paused_at":"\(stamp)"}}
        """
    }

    private func watch(_ id: Int = 1, media: String = #""type":"movie","movie":{"ids":{"tmdb":550}}"#) -> String {
        #"{"id":\#(id),"watched_at":"\#(date)","action":"watch",\#(media)}"#
    }

    private func http(history: String = "[]", historyCount: Int = 0, resume: String = "[]", resumeCount: Int = 0, watchLimit: Int = 100) -> RecordingHTTPClient {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/users/settings", json: #"{"user":{"username":"fixture"}}"#)
        http.stub(pathSuffix: "/sync/last_activities", json: activity())
        http.stub(pathSuffix: "/users/me/history", json: history, headers: headers(count: historyCount, limit: watchLimit))
        http.stub(pathSuffix: "/sync/playback", json: resume, headers: headers(count: resumeCount))
        return http
    }

    private func snapshot(_ http: any HTTPClient) async throws -> TrackerHistorySnapshot {
        try await TraktClient(config: .init(clientID: "fixture"), http: http).historySnapshot(
            accessToken: "fixture", connectionID: "connection", validateScope: {}
        )
    }

    func testCompleteReadIsGETOnlyAndRetainsIndividualPlaysAndPercentages() async throws {
        let progress = #"{"id":1,"progress":32.5,"paused_at":"\#(date)","type":"movie","movie":{"ids":{"tmdb":550}}}"#
        let http = http(history: "[\(watch()),\(watch(2))]", historyCount: 2, resume: "[\(progress)]", resumeCount: 1)
        let result = try await snapshot(ReadOnlyHistoryHTTP(http: http))
        XCTAssertEqual(result.trackerID, "trakt")
        XCTAssertEqual(result.observations.map(\.recordID), ["watched/1", "watched/2", "resume/1"])
        XCTAssertEqual(result.observations[2].fact, .pausedPercentage(
            percent: 32.5, updatedAt: TraktClient.parseTimestamp(date)
        ))
        XCTAssertEqual(http.sentPaths, ["/sync/last_activities", "/users/me/history", "/sync/playback", "/sync/last_activities"])
    }

    func testWriteBatchRevalidatesCompleteReadWithCurrentAccountActivity() async throws {
        let http = http(history: "[\(watch())]", historyCount: 1)
        let source = try await snapshot(http)
        let verify = try XCTUnwrap(source.isStillCurrent)
        let unchanged = try await verify()
        XCTAssertTrue(unchanged)
        http.stub(pathSuffix: "/sync/last_activities", json: activity("2026-10-24T12:00:01.000Z"))
        _ = try await verify() // Consume the retained first response in the recording transport.
        let changed = try await verify()
        XCTAssertFalse(changed)
        XCTAssertEqual(http.sentPaths.filter { $0 == "/users/me/history" }.count, 1)
    }

    func testAllHistoryPagesAreRequired() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/sync/last_activities", json: activity())
        http.stub(
            pathSuffix: "/users/me/history", json: "[" + (1...100).map { watch($0) }.joined(separator: ",") + "]",
            headers: headers(count: 101)
        )
        http.stub(pathSuffix: "/users/me/history", json: "[\(watch(101))]", headers: headers(page: 2, count: 101))
        http.stub(pathSuffix: "/sync/playback", json: "[]", headers: headers())
        let result = try await snapshot(http)
        XCTAssertEqual(result.observations.count, 101)
        XCTAssertEqual(http.sent.filter { $0.path == "/users/me/history" }.map {
            $0.queryItems.first { $0.name == "page" }?.value
        }, ["1", "2"])
    }

    func testMissingOrContradictoryPaginationCannotProduceAComparison() async {
        var wrongPage = headers()
        wrongPage["X-Pagination-Page"] = "2"
        var wrongLimit = headers()
        wrongLimit["X-Pagination-Limit"] = "10"
        var wrongPages = headers(count: 1)
        wrongPages["X-Pagination-Page-Count"] = "2"
        var overLimit = headers(count: 100_001)
        overLimit["X-Pagination-Page-Count"] = "1001"
        for fields in [[:], wrongPage, wrongLimit, wrongPages, overLimit, headers(count: 1)] {
            let http = RecordingHTTPClient()
            http.stub(pathSuffix: "/sync/last_activities", json: activity())
            http.stub(pathSuffix: "/users/me/history", json: "[]", headers: fields)
            do {
                _ = try await snapshot(http)
                XCTFail("Incomplete evidence must fail")
            } catch {
                XCTAssertEqual(error as? TrackerHistoryError, .incompleteSnapshot)
            }
            XCTAssertFalse(http.sentPaths.contains("/sync/playback"))
        }
    }

    func testDuplicateRecordsAndChangingPageTotalsAreRejected() async {
        for changedCount in [101, 102] {
            let http = RecordingHTTPClient()
            http.stub(pathSuffix: "/sync/last_activities", json: activity())
            http.stub(
                pathSuffix: "/users/me/history", json: "[" + (1...100).map { watch($0) }.joined(separator: ",") + "]",
                headers: headers(count: 101)
            )
            http.stub(pathSuffix: "/users/me/history", json: "[\(watch(1))]", headers: headers(page: 2, count: changedCount))
            do { _ = try await snapshot(http); XCTFail("Changed or repeated page must fail") }
            catch { XCTAssertEqual(error as? TrackerHistoryError, .incompleteSnapshot) }
        }
    }

    func testLowerFinalWatchCountRequiresExactMembershipAcrossIndependentDateRanges() async throws {
        let old = (1...100).map { watch($0).replacingOccurrences(of: date, with: "2000-05-01T12:00:00Z") }
        let recent = watch(101).replacingOccurrences(of: date, with: "2090-05-01T12:00:00Z")
        let unexpectedID = recent.replacingOccurrences(of: #""id":101"#, with: #""id":102"#)
        for (lastRange, count, activityChanged) in [(recent, 1, false), ("", 0, false), (unexpectedID, 1, false), (recent, 1, true)] {
            let http = RecordingHTTPClient()
            http.stub(pathSuffix: "/sync/last_activities", json: activity())
            if activityChanged {
                http.stub(pathSuffix: "/sync/last_activities", json: activity("2026-10-24T12:00:01.000Z"))
            }
            let path = "/users/me/history"
            let full = "[" + old.joined(separator: ",") + "]"
            http.stub(pathSuffix: path, json: full, headers: headers(count: 105))
            http.stub(pathSuffix: path, json: "[\(recent)]", headers: headers(page: 2, count: 101))
            http.stub(pathSuffix: path, json: full, headers: headers(count: 100))
            http.stub(pathSuffix: path, json: "[\(lastRange)]", headers: headers(count: count))
            http.stub(pathSuffix: "/sync/playback", json: "[]", headers: headers())
            if lastRange == recent && !activityChanged {
                let result = try await snapshot(http)
                XCTAssertEqual(Set(result.observations.map(\.recordID)), Set((1...101).map { "watched/\($0)" }))
            } else {
                do { _ = try await snapshot(http); XCTFail("Missing, substituted or changing history must not authorize sync") }
                catch { XCTAssertEqual(error as? TrackerHistoryError, .incompleteSnapshot) }
                XCTAssertEqual(http.sentPaths.contains("/sync/playback"), activityChanged)
            }
            XCTAssertEqual(http.sent.filter { $0.path == path }.map { $0.queryItems.map(\.name) },
                           [["page", "limit"], ["page", "limit"], ["end_at", "page", "limit"], ["start_at", "page", "limit"]])
        }
    }

    func testActivityChangesInvalidateTheWholeSnapshot() async {
        let http = http(history: "[\(watch())]", historyCount: 1)
        http.stub(pathSuffix: "/sync/last_activities", json: activity("2026-10-24T12:00:01.000Z"))
        do { _ = try await snapshot(http); XCTFail("Concurrent tracker activity must invalidate the comparison") }
        catch { XCTAssertEqual(error as? TrackerHistoryError, .incompleteSnapshot) }
    }

    func testMalformedRecordsAreNotSilentlyDropped() async {
        let records = [
            watch(0), watch(media: #""type":"movie","movie":{"ids":{"tmdb":-1}}"#),
            watch(media: #""type":"movie","movie":{"ids":{}}"#),
            watch(media: #""type":"show","show":{"ids":{"tmdb":1}}"#),
            watch().replacingOccurrences(of: date, with: "not-a-date"),
            watch().replacingOccurrences(of: #""action":"watch""#, with: #""action":"unknown""#),
            watch(media: #""type":"episode","episode":{"season":1,"ids":{"tmdb":2}},"show":{"ids":{"tmdb":1}}"#)
        ]
        for record in records {
            do {
                _ = try await snapshot(http(history: "[\(record)]", historyCount: 1))
                XCTFail("Malformed record must not become an empty comparison")
            } catch { XCTAssertEqual(error as? TrackerHistoryError, .invalidObservation) }
        }
    }

    func testPercentageBoundsRemainObservationsNotClearOrCompletedEvents() async throws {
        for percent in [0, 100] {
            let progress = #"{"id":9,"progress":\#(percent),"paused_at":"\#(date)","type":"movie","movie":{"ids":{"tmdb":550}}}"#
            let result = try await snapshot(http(resume: "[\(progress)]", resumeCount: 1))
            XCTAssertEqual(result.observations[0].fact, .resumePercentage(
                percent: Double(percent), updatedAt: TraktClient.parseTimestamp(date)
            ))
        }
        let invalid = #"{"id":9,"progress":101,"paused_at":"\#(date)","type":"movie","movie":{"ids":{"tmdb":550}}}"#
        do { _ = try await snapshot(http(resume: "[\(invalid)]", resumeCount: 1)); XCTFail("Invalid percentage") }
        catch { XCTAssertEqual(error as? TrackerHistoryError, .invalidObservation) }
    }

    func testEpisodeMatchRequiresExactEpisodeAndParentIDsWithoutInferringOrder() async throws {
        let record = watch(media: #""type":"episode","episode":{"season":1,"number":2,"ids":{"tmdb":200}},"show":{"ids":{"tmdb":100}}"#)
        let result = try await snapshot(http(history: "[\(record)]", historyCount: 1))
        let observed = try XCTUnwrap(result.observations.first)
        XCTAssertNil(observed.episodeOrdering)
        XCTAssertTrue(observed.requiresExactEpisodeIdentity)
        var item = MediaItem(
            id: "server", title: "Episode", kind: .episode, seasonNumber: 1, episodeNumber: 2,
            providerIDs: ["Tmdb": "200", "SeriesTmdb": "100"]
        )
        XCTAssertTrue(observed.matches(item))
        item.providerIDs["Tmdb"] = "100"
        XCTAssertFalse(observed.matches(item), "Inherited show IDs cannot authorize episode writes")
    }

    func testAuthenticationAndThrottleErrorsRemainExplicitWithoutRetries() async {
        for status in [401, 403, 429, 500] {
            let http = RecordingHTTPClient()
            http.stub(pathSuffix: "/sync/last_activities", json: "{}", status: status, headers: ["Retry-After": "60"])
            do { _ = try await snapshot(http); XCTFail("HTTP failure must not become empty history") }
            catch {
                let expected: AppError = status == 429 ? .rateLimited(retryAfter: 60)
                    : (status == 401 || status == 403 ? .unauthorized : .invalidResponse)
                XCTAssertEqual(error as? AppError, expected)
            }
            XCTAssertEqual(http.sentPaths.count, 1)
        }
    }

    @MainActor
    func testCancellationBeforeReadSendsNothing() async {
        let http = http()
        let task = Task { try await snapshot(http) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must not become an empty snapshot") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(http.sentPaths.isEmpty)
    }

    @MainActor
    func testUnchangedRepeatDoesNotRequestAnyWatchOrPlaybackPages() async throws {
        let store = InMemoryTraktTokenStore(tokens: .init(
            accessToken: "fixture", refreshToken: "fixture-refresh", expiresAt: .distantFuture, accountIdentity: "grant"
        ))
        let http = http(history: "[\(watch())]", historyCount: 1, watchLimit: 250)
        let service = TraktService(config: .init(clientID: "fixture"), http: http, tokenStore: store)
        await service.refreshStatus()
        let connection = try XCTUnwrap(service.historyConnectionID)
        let first = try await service.historySnapshot(expectedConnectionID: connection)
        let initial = http.sentPaths.count
        let next = try await service.historySnapshot(expectedConnectionID: connection)
        XCTAssertEqual(next.observations, first.observations)
        XCTAssertEqual(Array(http.sentPaths.dropFirst(initial)), ["/sync/last_activities"])
    }

    func testPersistedMultiPageHistoryReopensWithOneGETAndPauseOnlyRefreshesMovies() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        func read(_ transport: RecordingHTTPClient, scope: String = "first-grant") async throws -> TrackerHistorySnapshot {
            try await TraktClient(config: .init(clientID: "fixture"), http: transport).historySnapshot(
                accessToken: "fixture", connectionID: "ephemeral", cache: .init(directory: folder),
                cacheScope: scope, validateScope: {}
            )
        }
        let source = http(history: "[" + (1...100).map { watch($0) }.joined(separator: ",") + "]", historyCount: 101)
        source.stub(pathSuffix: "/users/me/history", json: "[\(watch(101))]", headers: headers(page: 2, count: 101))
        let original = try await read(source)
        XCTAssertEqual(original.observations.count, 101)
        let control = RecordingHTTPClient()
        control.stub(pathSuffix: "/sync/last_activities", json: activity())
        let reopened = try await read(control)
        XCTAssertEqual(reopened.observations, original.observations)
        XCTAssertEqual(control.sentPaths, ["/sync/last_activities"])

        let moved = "2026-10-25T12:00:00Z"
        let pause = #"{"id":9,"progress":32.5,"paused_at":"\#(moved)","type":"movie","movie":{"ids":{"tmdb":550}}}"#
        let updated = RecordingHTTPClient()
        updated.stub(pathSuffix: "/sync/last_activities", json: activity(moviePause: moved))
        updated.stub(pathSuffix: "/sync/playback/movies", json: "[\(pause)]", headers: headers(count: 1))
        let paused = try await read(updated)
        XCTAssertEqual(paused.observations.count, 102)
        XCTAssertEqual(paused.observations.last?.fact, .pausedPercentage(percent: 32.5, updatedAt: TraktClient.parseTimestamp(moved)))
        XCTAssertEqual(updated.sentPaths, ["/sync/last_activities", "/sync/playback/movies", "/sync/last_activities"])

        let replacement = http()
        let empty = try await read(replacement, scope: "replacement-grant")
        XCTAssertTrue(empty.observations.isEmpty)
        XCTAssertTrue(replacement.sentPaths.contains("/users/me/history"))
    }

    func testChangedWatchUsesTitleRevisionNotWatchDateAndFailedReadDoesNotAdvanceCache() async throws {
        let cache = TraktHistoryCache()
        func read(_ transport: RecordingHTTPClient) async throws -> TrackerHistorySnapshot {
            try await TraktClient(config: .init(clientID: "fixture"), http: transport).historySnapshot(
                accessToken: "fixture", connectionID: "grant", cache: cache, cacheScope: "test", validateScope: {}
            )
        }
        func movie(_ id: Int, title: Int) -> String {
            watch(id, media: #""type":"movie","movie":{"ids":{"trakt":\#(title),"tmdb":550}}"#)
        }
        let initial = http(history: "[\(movie(1, title: 10)),\(movie(2, title: 20)),\(movie(3, title: 30))]", historyCount: 3)
        _ = try await read(initial)
        let old = "2000-01-01T12:00:00Z", revised = "2026-10-25T12:00:00Z"
        let summaries = """
        [{"movie":{"ids":{"trakt":10}},"plays":1,"last_updated_at":"\(old)"},
         {"movie":{"ids":{"trakt":20}},"plays":1,"last_updated_at":"\(revised)"}]
        """
        for complete in [false, true] {
            let transport = RecordingHTTPClient()
            transport.stub(pathSuffix: "/sync/last_activities", json: activity(movieWatch: revised))
            transport.stub(pathSuffix: "/users/me/watched/movies", json: summaries)
            let new = movie(4, title: 20).replacingOccurrences(of: date, with: old)
            transport.stub(pathSuffix: "/users/me/history/movies/20", json: complete ? "[\(new)]" : "[]", headers: headers(count: 1))
            if complete {
                let changed = try await read(transport)
                XCTAssertEqual(Set(changed.observations.map(\.recordID)), ["watched/1", "watched/4"])
                XCTAssertEqual(transport.sentPaths, ["/sync/last_activities", "/users/me/watched/movies",
                                                      "/users/me/history/movies/20", "/sync/last_activities"])
            } else {
                do { _ = try await read(transport); XCTFail("Incomplete changed title") }
                catch { XCTAssertEqual(error as? TrackerHistoryError, .incompleteSnapshot) }
            }
        }
    }

    func testNewEpisodeInAnotherShowDoesNotPageThroughUnchangedEpisodeHistory() async throws {
            let cache = TraktHistoryCache()
            func read(_ transport: RecordingHTTPClient) async throws -> TrackerHistorySnapshot {
                try await TraktClient(config: .init(clientID: "fixture"), http: transport).historySnapshot(
                    accessToken: "fixture", connectionID: "grant", cache: cache, cacheScope: "test", validateScope: {}
                )
            }
            func episode(_ play: Int, show: Int) -> String {
                watch(play, media: #""type":"episode","episode":{"season":0,"number":1,"ids":{"trakt":\#(show+1)}},"show":{"ids":{"trakt":\#(show)}}"#)
            }
            let path = "/users/me/history"
            let seed = http(history: "[" + (1...100).map { episode($0, show: 10) }.joined(separator: ",") + "]", historyCount: 101)
            seed.stub(pathSuffix: path, json: "[\(episode(101, show: 10))]", headers: headers(page: 2, count: 101))
            _ = try await read(seed)
            let transport = RecordingHTTPClient(), later = "2026-10-25T12:00:00Z"
            let activity = #"{"all":"\#(later)","movies":{"watched_at":"\#(date)","paused_at":"\#(date)"},"episodes":{"watched_at":"\#(later)","paused_at":"\#(date)"}}"#
            transport.stub(pathSuffix: "/sync/last_activities", json: activity)
            transport.stub(pathSuffix: "/users/me/watched/shows", json: """
                [{"show":{"ids":{"trakt":10}},"plays":101,"last_updated_at":"2026-10-10T12:00:00Z"},
                 {"show":{"ids":{"trakt":20}},"plays":1,"last_updated_at":"\(later)"}]
                """)
            transport.stub(pathSuffix: path + "/shows/20", json: "[\(episode(102, show: 20))]", headers: headers(count: 1))
            let result = try await read(transport)
            XCTAssertEqual(result.observations.count, 102)
            XCTAssertEqual(result.observations.last?.recordID, "watched/102")
            XCTAssertEqual(transport.sentPaths, ["/sync/last_activities", "/users/me/watched/shows", path + "/shows/20", "/sync/last_activities"])
    }

    @MainActor
    func testCoordinatedRefreshPreservesTheCapturedGrant() async throws {
        let store = InMemoryTraktTokenStore(tokens: .init(
            accessToken: "fixture", refreshToken: "fixture-refresh", expiresAt: .distantFuture, accountIdentity: "grant"
        ))
        let http = http(watchLimit: 250)
        let service = TraktService(config: .init(clientID: "fixture"), http: http, tokenStore: store)
        await service.refreshStatus()
        let connection = try XCTUnwrap(service.historyConnectionID)
        var expired = try XCTUnwrap(store.load())
        expired.expiresAt = .distantPast
        try store.save(expired)
        http.stub(
            pathSuffix: "/oauth/token",
            json: #"{"access_token":"rotated","refresh_token":"rotated-refresh","expires_in":7200,"created_at":\#(Int(Date().timeIntervalSince1970))}"#
        )
        let result = try await service.historySnapshot(expectedConnectionID: connection)
        XCTAssertEqual(result.connectionID, connection)
        XCTAssertEqual(service.historyConnectionID, connection)
        XCTAssertEqual(store.load()?.accessToken, "rotated")
        XCTAssertEqual(http.sentPaths.filter { $0 == "/oauth/token" }.count, 1)
    }

    @MainActor
    func testHistoryLimitRetriesOnlyTheThrottledPageAndHonorsLongCooldown() async throws {
        let path = "/users/me/history"
        let http = http(history: "[" + (1...250).map { watch($0) }.joined(separator: ",") + "]", historyCount: 251, watchLimit: 250)
        http.stub(pathSuffix: path, json: "{}", status: 429, headers: ["Retry-After": "1"])
        http.stub(pathSuffix: path, json: "[\(watch(251))]", headers: headers(page: 2, count: 251, limit: 250))
        let gate = TraktHistoryReadCooldown()
        http.stub(pathSuffix: "/sync/last_activities", json: activity())
        http.stub(pathSuffix: "/sync/last_activities", json: "{}", status: 429, headers: ["Retry-After": "120"])
        func read() async throws -> TrackerHistorySnapshot {
            try await TraktClient(config: .init(clientID: "fixture"), http: http, historyRead: .init(cooldown: gate))
                .historySnapshot(accessToken: "fixture", connectionID: "fixture", validateScope: {})
        }
        let snapshot = try await read()
        XCTAssertEqual(snapshot.observations.count, 251)
        XCTAssertEqual(http.sent.filter { $0.path == path }.compactMap { $0.queryItems.first { $0.name == "page" }?.value }, ["1", "2", "2"])
        let before = http.sentPaths.count
        for _ in 1...2 {
            do { _ = try await read(); XCTFail("Throttling must not return partial evidence") }
            catch {
                guard case .rateLimited(let delay) = error as? AppError else { return XCTFail("Expected a cooldown") }
                XCTAssertGreaterThan(delay ?? 0, 110)
            }
        }
        XCTAssertEqual(http.sentPaths.count, before + 1)
    }

    @MainActor
    func testProfileSwitchAndGrantReplacementRevokeCapturedConnection() async throws {
        let store = InMemoryTraktTokenStore(tokens: .init(
            accessToken: "fixture", refreshToken: "fixture-refresh", expiresAt: .distantFuture, accountIdentity: "grant"
        ))
        let http = http()
        let service = TraktService(config: .init(clientID: "fixture"), http: http, tokenStore: store)
        await service.refreshStatus()
        let connection = try XCTUnwrap(service.historyConnectionID)
        await service.setActiveProfile(namespace: "child")
        do { _ = try await service.historySnapshot(expectedConnectionID: connection); XCTFail("Old profile") }
        catch { XCTAssertEqual(error as? TrackerHistoryError, .scopeChanged) }
        await service.setActiveProfile(namespace: nil)
        XCTAssertNotEqual(service.historyConnectionID, connection, "Returning to the same profile does not revive a preview")
        let returned = try XCTUnwrap(service.historyConnectionID)
        try store.save(.init(
            accessToken: "replacement", refreshToken: "replacement-refresh", expiresAt: .distantFuture, accountIdentity: "new-grant"
        ))
        do { _ = try await service.historySnapshot(expectedConnectionID: returned); XCTFail("Replaced grant") }
        catch { XCTAssertEqual(error as? TrackerHistoryError, .scopeChanged) }
        XCTAssertFalse(http.sentPaths.contains("/users/me/history"))
    }

    @MainActor
    func testGrantChangeDuringNetworkReadStopsLaterRequests() async throws {
        let store = InMemoryTraktTokenStore(tokens: .init(
            accessToken: "fixture", refreshToken: "fixture-refresh", expiresAt: .distantFuture, accountIdentity: "grant"
        ))
        let http = http()
        let service = TraktService(
            config: .init(clientID: "fixture"), http: ReadOnlyHistoryHTTP(http: http, replacing: store), tokenStore: store
        )
        await service.refreshStatus()
        let connection = try XCTUnwrap(service.historyConnectionID)
        do { _ = try await service.historySnapshot(expectedConnectionID: connection); XCTFail("Stale completion") }
        catch { XCTAssertEqual(error as? TrackerHistoryError, .scopeChanged) }
        XCTAssertFalse(http.sentPaths.contains("/sync/playback"))
    }
}

private struct ReadOnlyHistoryHTTP: HTTPClient {
    let http: RecordingHTTPClient
    var replacing: InMemoryTraktTokenStore? = nil

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        try await sendRaw(endpoint, baseURL: baseURL)
    }

    func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        guard endpoint.method == .get else { throw AppError.invalidResponse }
        if endpoint.path == "/users/me/history" {
            try replacing?.save(.init(
                accessToken: "new", refreshToken: "new-refresh", expiresAt: .distantFuture, accountIdentity: "new-grant"
            ))
        }
        return try await http.sendRaw(endpoint, baseURL: baseURL)
    }
}
