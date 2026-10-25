import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import AniListService
@testable import TestSupportNetworking

final class AniListHistorySnapshotTests: XCTestCase {
    private func entry(
        _ id: Int = 100, owner: Int = 7, status: String = #""COMPLETED""#,
        format: String = #""MOVIE""#, progress: String = "1", repeats: String = "2", score: String = "8.5"
    ) -> String {
        """
        {"id":\(id + 1000),"userId":\(owner),"mediaId":\(id),"status":\(status),
         "progress":\(progress),"repeat":\(repeats),"score":\(score),"updatedAt":1700000000,
         "media":{"id":\(id),"idMal":\(id + 2000),"type":"ANIME","format":\(format),
         "title":{"english":"Fixture title","romaji":"Fixture"}}}
        """
    }

    private func page(_ rows: [String], number: Int = 1, next: Bool = false, owner: Int = 7) -> String {
        """
        {"data":{"Viewer":{"id":\(owner)},"Page":{
         "pageInfo":{"currentPage":\(number),"perPage":50,"hasNextPage":\(next),"total":-42},
         "mediaList":[\(rows.joined(separator: ","))]}}}
        """
    }

    private func http(_ pages: [String]) -> RecordingHTTPClient {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "", json: #"{"data":{"Viewer":{"id":7}}}"#)
        for page in pages { http.stub(pathSuffix: "", json: page) }
        return http
    }

    private func snapshot(
        _ http: any HTTPClient, validate: @escaping @Sendable () async throws -> Void = {}
    ) async throws -> TrackerHistorySnapshot {
        try await AniListClient(config: .init(clientID: "fixture", clientSecret: "fixture"), http: http)
            .historySnapshot(accessToken: "fixture", connectionID: "connection", validateScope: validate)
    }

    func testQueriesExhaustPagesWithoutRelyingOnTotalAndPreserveListFacts() async throws {
        let rows = (51...100).reversed().map { entry($0) }
        let http = http([page(rows, next: true), page([entry(50)], number: 2)])
        let result = try await snapshot(HistoryHTTP(http: http))
        XCTAssertEqual(result.trackerID, "anilist")
        XCTAssertEqual(result.connectionID, "connection")
        XCTAssertEqual(result.observations.count, 51)
        let first = try XCTUnwrap(result.observations.first)
        XCTAssertEqual(first.recordID, "list/1100")
        XCTAssertEqual(first.sourceTitle, "Fixture title")
        XCTAssertEqual(first.kind, .movie)
        XCTAssertEqual(first.identities, [
            .external(source: "anilist", value: "100"), .external(source: "myanimelist", value: "2100")
        ])
        XCTAssertEqual(first.fact, .animeList(try .init(
            status: .completed, episodesWatched: 1, repeats: 2, score: 8.5,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )))
        XCTAssertEqual(http.sent.count, 3)
        for (index, sent) in http.sent.dropFirst().enumerated() {
            let query = try XCTUnwrap(sent.json?["query"] as? String)
            XCTAssertTrue(query.contains("score(format: POINT_10_DECIMAL)"))
            XCTAssertTrue(query.contains("sort: [MEDIA_ID_DESC]"))
            XCTAssertFalse(query.contains("status: PLANNING"))
            XCTAssertFalse(query.contains("total"))
            let variables = try XCTUnwrap(sent.json?["variables"] as? [String: Int])
            XCTAssertEqual(variables, ["userId": 7, "page": index + 1])
        }
    }

    func testEmptyListIsACompleteReadNotAnUnwatch() async throws {
        let result = try await snapshot(http([page([])]))
        XCTAssertTrue(result.observations.isEmpty)
    }

    func testNullProgressRemainsUnknownAndZeroScoreIsUnrated() throws {
        let raw = entry(status: "null", format: "null", progress: "null", repeats: "null", score: "0")
            .replacingOccurrences(of: #""updatedAt":1700000000"#, with: #""updatedAt":null"#)
        let record = try JSONDecoder().decode(AniListHistoryEntry.self, from: Data(raw.utf8))
        let observation = try record.observation()
        XCTAssertEqual(observation.kind, .series)
        XCTAssertEqual(observation.fact, .animeList(try .init(
            status: nil, episodesWatched: nil, repeats: nil, score: nil, updatedAt: nil
        )))
    }

    func testEveryKnownStatusIsPreservedWithoutInventingEpisodeHistory() throws {
        let states: [(String, TrackerAnimeListProgress.Status)] = [
            ("CURRENT", .watching), ("PLANNING", .planning), ("COMPLETED", .completed),
            ("DROPPED", .dropped), ("PAUSED", .paused), ("REPEATING", .rewatching)
        ]
        for (raw, expected) in states {
            let record = try JSONDecoder().decode(
                AniListHistoryEntry.self, from: Data(entry(status: "\"\(raw)\"", format: #""TV""#).utf8)
            )
            let observation = try record.observation()
            guard case .animeList(let progress) = observation.fact else { return XCTFail("List evidence expected") }
            XCTAssertEqual(progress.status, expected)
            XCTAssertEqual(observation.kind, .series)
            XCTAssertNil(observation.season)
            XCTAssertNil(observation.episode)
        }
    }

    func testMalformedIdentityCountsAndStatesRejectTheEntireRead() async {
        let invalid = [
            entry(0), entry(owner: 8), entry(status: #""UNKNOWN""#), entry(progress: "-1"),
            entry(repeats: "-1"), entry(score: "10.1"), entry(score: "-1"),
            entry().replacingOccurrences(of: #""type":"ANIME""#, with: #""type":"MANGA""#),
            entry().replacingOccurrences(of: #""idMal":2100"#, with: #""idMal":0"#),
            entry().replacingOccurrences(of: #""id":100,"idMal""#, with: #""id":99,"idMal""#),
            entry().replacingOccurrences(of: #""updatedAt":1700000000"#, with: #""updatedAt":-1"#)
        ]
        for row in invalid {
            do { _ = try await snapshot(http([page([row])])) ; XCTFail("Invalid entry accepted") }
            catch { XCTAssertNotNil(error as? TrackerHistoryError) }
        }
    }

    func testMissingNullOrPartialDataNeverPublishesASnapshot() async {
        for response in [
            "{}", #"{"data":null}"#, #"{"data":{"Viewer":{"id":7},"Page":null}}"#,
            page([entry()]).replacingOccurrences(of: #""hasNextPage":false"#, with: #""hasNextPage":null"#),
            page([entry()]).replacingOccurrences(of: #""perPage":50"#, with: #""perPage":25"#),
            page([entry()]).replacingOccurrences(of: #""mediaList":["#, with: #""mediaList":[null,"#),
            #"{"data":{"Viewer":{"id":7}},"errors":[{"message":"private remote error","status":500}]}"#
        ] {
            do { _ = try await snapshot(http([response])); XCTFail("Partial response accepted") }
            catch { XCTAssertTrue(error is TrackerHistoryError || error is AppError) }
        }
    }

    func testGraphQLErrorsAreNotSuccessEvenWhenDataIsPresent() async {
        for status in [401, 429, 500] {
            let http = RecordingHTTPClient()
            http.stub(pathSuffix: "", json: """
            {"data":{"Viewer":{"id":7}},"errors":[{"message":"fixture error","status":\(status)}]}
            """)
            do { _ = try await snapshot(http); XCTFail("Error data accepted") }
            catch {
                switch status {
                case 401: XCTAssertEqual(error as? AppError, .unauthorized)
                case 429: XCTAssertEqual(error as? AppError, .rateLimited(retryAfter: nil))
                default: XCTAssertEqual(error as? AppError, .invalidResponse)
                }
            }
            XCTAssertEqual(http.sent.count, 1)
        }
    }

    func testOwnerChangeAndBrokenPaginationStopBeforeMoreReads() async {
        for response in [
            page([entry()], owner: 8), page([entry()], number: 2),
            page([entry()], next: true), page([entry(), entry()]),
            page([entry(99), entry(100)]), page((1...51).reversed().map { entry($0) })
        ] {
            let http = http([response])
            do { _ = try await snapshot(http); XCTFail("Broken page accepted") }
            catch { XCTAssertNotNil(error as? TrackerHistoryError) }
            XCTAssertEqual(http.sent.count, 2)
        }

        let first = page((51...100).reversed().map { entry($0) }, next: true)
        for last in [page([entry(100)], number: 2), page([entry(50)], number: 1)] {
            let http = http([first, last])
            do { _ = try await snapshot(http); XCTFail("Repeated page accepted") }
            catch { XCTAssertEqual(error as? TrackerHistoryError, .incompleteSnapshot) }
            XCTAssertEqual(http.sent.count, 3)
        }
    }

    func testErrorsWithNullPartialFieldsPreserveAuthAndThrottleFailures() async {
        for status in [401, 429] {
            let http = RecordingHTTPClient()
            http.stub(pathSuffix: "", json: """
            {"data":{"Viewer":null},"errors":[{"message":"fixture","status":\(status)}]}
            """)
            do { _ = try await snapshot(http); XCTFail("Partial error accepted") }
            catch {
                XCTAssertEqual(error as? AppError, status == 401 ? .unauthorized : .rateLimited(retryAfter: nil))
            }
        }
    }

    func testNonExhaustingHistoryStopsAtOneThousandFullPages() async {
        let http = NonExhaustingHTTP()
        do { _ = try await snapshot(http); XCTFail("Unbounded pagination") }
        catch { XCTAssertEqual(error as? TrackerHistoryError, .incompleteSnapshot) }
        let pages = await http.pages
        XCTAssertEqual(pages, 1000)
    }

    func testScopeCheckRunsBeforeDispatchAndAfterEachResponse() async {
        for failureAt in 1...5 {
            let gate = ScopeGate(failureAt: failureAt)
            let http = http([page([])])
            do {
                _ = try await snapshot(http, validate: { try await gate.check() })
                XCTFail("Changed scope accepted")
            } catch { XCTAssertEqual(error as? TrackerHistoryError, .scopeChanged) }
            XCTAssertEqual(http.sent.count, min(failureAt / 2, 2))
        }
    }

    func testCancellationAfterResponseDoesNotFetchAnotherPage() async {
        let http = http([page([])])
        let task = Task {
            try await snapshot(HistoryHTTP(http: http, afterSend: {
                withUnsafeCurrentTask { $0?.cancel() }
            }))
        }
        do { _ = try await task.value; XCTFail("Cancellation accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(http.sent.count, 1)
    }

    func testResponseByteLimitIsEnforcedEvenByAnIgnoringTransport() async {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "", json: String(repeating: " ", count: 8 * 1_024 * 1_024 + 1))
        do { _ = try await snapshot(http); XCTFail("Oversized response accepted") }
        catch { XCTAssertEqual(error as? TrackerHistoryError, .incompleteSnapshot) }
    }

    @MainActor
    func testServiceFencesReplacedTokensProfileChangesAndDisconnect() async throws {
        for change in 0..<3 {
            let http = RecordingHTTPClient()
            http.stub(pathSuffix: "", json: #"{"data":{"Viewer":{"id":7,"name":"fixture"}}}"#)
            let store = InMemoryAniListTokenStore(tokens: AniListTokens(accessToken: "fixture"))
            let transport = ServiceHTTP(http: http)
            let service = AniListService(
                config: .init(clientID: "fixture", clientSecret: "fixture"), http: transport, tokenStore: store
            )
            await service.refreshStatus()
            let connection = try XCTUnwrap(service.historyConnectionID)
            transport.afterSend = {
                switch change {
                case 0: try store.save(AniListTokens(accessToken: "replacement"))
                case 1: await service.setActiveProfile(namespace: "other")
                default: await service.disconnect()
                }
            }
            do { _ = try await service.historySnapshot(expectedConnectionID: connection); XCTFail("Scope changed") }
            catch { XCTAssertEqual(error as? TrackerHistoryError, .scopeChanged) }
            XCTAssertEqual(http.sent.count, 2)
        }
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

    private actor NonExhaustingHTTP: HTTPClient {
            private(set) var pages = 0
            func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
                let json = try XCTUnwrap(endpoint.body)
                let request = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
                let variables = try XCTUnwrap(request["variables"] as? [String: Any])
                let body: String
                if let page = variables["page"] as? Int {
                    pages += 1
                    let rows = (0..<50).map { index in
                        let id = 50_001 - (page - 1) * 50 - index
                        return #"{"id":\#(id),"userId":7,"mediaId":\#(id),"media":{"id":\#(id),"type":"ANIME"}}"#
                    }.joined(separator: ",")
                    body = """
                    {"data":{"Viewer":{"id":7},"Page":{
                    "pageInfo":{"currentPage":\(page),"perPage":50,"hasNextPage":true},"mediaList":[\(rows)]}}}
                    """
                } else { body = #"{"data":{"Viewer":{"id":7}}}"# }
                return (Data(body.utf8), HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
    }

    private struct HistoryHTTP: HTTPClient {
        let http: RecordingHTTPClient
        var afterSend: @Sendable () async -> Void = {}
        func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
            XCTAssertEqual(endpoint.method, .post)
            XCTAssertEqual(endpoint.redirectPolicy, .sameOrigin)
            XCTAssertEqual(endpoint.maximumResponseBytes, 8 * 1_024 * 1_024)
            XCTAssertTrue(endpoint.redactsURLForLogging)
            XCTAssertEqual(endpoint.headers["Authorization"], "Bearer fixture")
            let json = try XCTUnwrap(endpoint.body)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
            let query = try XCTUnwrap(body["query"] as? String)
            XCTAssertTrue(query.hasPrefix("query"))
            XCTAssertFalse(query.contains("mutation"))
            let result = try await http.send(endpoint, baseURL: baseURL)
            await afterSend()
            return result
        }
    }

    @MainActor
    private final class ServiceHTTP: HTTPClient {
        let http: RecordingHTTPClient
        var afterSend: (@MainActor @Sendable () async throws -> Void)?
        init(http: RecordingHTTPClient) { self.http = http }
        func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
            let result = try await http.send(endpoint, baseURL: baseURL)
            try await afterSend?()
            return result
        }
    }
}
