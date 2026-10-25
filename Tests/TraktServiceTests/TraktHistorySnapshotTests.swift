import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import TestSupportNetworking
@testable import TraktService

final class TraktHistorySnapshotTests: XCTestCase {
    private let date = "2026-10-24T12:00:00.000Z"

    private func headers(page: Int = 1, count: Int = 0) -> [String: String] {
        [
            "X-Pagination-Page": String(page), "X-Pagination-Limit": "100",
            "X-Pagination-Page-Count": String((count + 99) / 100),
            "X-Pagination-Item-Count": String(count)
        ]
    }

    private func activity(_ stamp: String? = nil) -> String {
        let stamp = stamp ?? date
        return """
        {"all":"\(stamp)","movies":{"watched_at":"\(stamp)","paused_at":"\(stamp)"},
         "episodes":{"watched_at":"\(stamp)","paused_at":"\(stamp)"}}
        """
    }

    private func watch(_ id: Int = 1, media: String = #""type":"movie","movie":{"ids":{"tmdb":550}}"#) -> String {
        #"{"id":\#(id),"watched_at":"\#(date)","action":"watch",\#(media)}"#
    }

    private func http(history: String = "[]", historyCount: Int = 0, resume: String = "[]", resumeCount: Int = 0) -> RecordingHTTPClient {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/users/settings", json: #"{"user":{"username":"fixture"}}"#)
        http.stub(pathSuffix: "/sync/last_activities", json: activity())
        http.stub(pathSuffix: "/users/me/history", json: history, headers: headers(count: historyCount))
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
        XCTAssertEqual(result.observations[2].fact, .resumePercentage(
            percent: 32.5, updatedAt: TraktClient.parseTimestamp(date)
        ))
        XCTAssertEqual(http.sentPaths, ["/sync/last_activities", "/users/me/history", "/sync/playback", "/sync/last_activities"])
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
    func testCoordinatedRefreshPreservesTheCapturedGrant() async throws {
        let store = InMemoryTraktTokenStore(tokens: .init(
            accessToken: "fixture", refreshToken: "fixture-refresh", expiresAt: .distantFuture, accountIdentity: "grant"
        ))
        let http = http()
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
