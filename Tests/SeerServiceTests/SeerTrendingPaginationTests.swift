import XCTest
import CoreModels
@testable import SeerService

@MainActor
final class SeerTrendingPaginationTests: XCTestCase {
    private let path = "/discover/trending"
    private let baseURL = URL(string: "https://requests.example.com/seerr")!

    private func makeService(
        _ http: SeerRecordingHTTPClient,
        store: InMemorySeerConnectionStore? = nil
    ) -> SeerService {
        SeerService(
            connectionStore: store ?? InMemorySeerConnectionStore(
                connection: SeerConnection(baseURL: baseURL, apiKey: "KEY")
            ),
            http: http
        )
    }

    private func movie(_ id: Int) -> String {
        #"{"id":\#(id),"mediaType":"movie","title":"Movie \#(id)"}"#
    }

    private func enqueuePage(
        _ http: SeerRecordingHTTPClient,
        number: Int,
        totalPages: Int,
        results: [String],
        totalResults: Int = 100
    ) {
        http.enqueueStub(
            pathSuffix: path,
            json: """
            {"page":\(number),"totalPages":\(totalPages),"totalResults":\(totalResults),
             "results":[\(results.joined(separator: ","))]}
            """
        )
    }

    private func requestedPages(_ http: SeerRecordingHTTPClient) -> [String] {
        http.sent.filter { $0.path.hasSuffix(path) }.compactMap { request in
            request.queryItems.first { $0.name == "page" }?.value
        }
    }

    func testLargerPoolFetchesThreePagesInUpstreamOrderWithOriginalServerScope() async throws {
        let http = SeerRecordingHTTPClient()
        for page in 1...3 {
            enqueuePage(
                http,
                number: page,
                totalPages: 20,
                results: (((page - 1) * 20 + 1)...(page * 20)).map(movie)
            )
        }

        let items = try await makeService(http).trending(limit: 48)

        XCTAssertEqual(items.map(\.id), (1...48).map { "seer:movie:\($0)" })
        XCTAssertEqual(requestedPages(http), ["1", "2", "3"])
        for request in http.sent {
            XCTAssertEqual(request.baseURL, baseURL)
            XCTAssertEqual(request.headers["X-Api-Key"], "KEY")
            XCTAssertNil(request.headers["X-API-User"])
            XCTAssertEqual(request.queryItems.first { $0.name == "language" }?.value, "en")
        }
    }

    func testSmallLimitStopsOnFirstPage() async throws {
        let http = SeerRecordingHTTPClient()
        enqueuePage(http, number: 1, totalPages: 20, results: (1...20).map(movie))

        let items = try await makeService(http).trending(limit: 5)

        XCTAssertEqual(items.map(\.id), (1...5).map { "seer:movie:\($0)" })
        XCTAssertEqual(requestedPages(http), ["1"])
    }

    func testNonpositiveLimitsDoNotRequestAnyPages() async throws {
        let http = SeerRecordingHTTPClient()
        let service = makeService(http)

        for limit in [0, -1, Int.min] {
            let items = try await service.trending(limit: limit)
            XCTAssertTrue(items.isEmpty)
        }
        XCTAssertTrue(http.sentPaths.isEmpty)
    }

    func testMappingRejectionsAndDuplicatesBackfillWithoutCollapsingMovieTVIdentity() async throws {
        let http = SeerRecordingHTTPClient()
        enqueuePage(http, number: 1, totalPages: 3, results: [
            #"{"id":1,"mediaType":"movie","title":"First","mediaInfo":{"status":5}}"#,
            movie(1),
            #"{"id":1,"mediaType":"tv","name":"Series"}"#,
            #"{"id":9,"mediaType":"person","name":"Actor"}"#,
            #"{"id":3,"mediaType":"movie","title":" "}"#
        ])
        enqueuePage(http, number: 2, totalPages: 3, results: [
            movie(1),
            #"{"id":1,"mediaType":"TV","name":"Series duplicate"}"#,
            movie(3),
            #"{"id":4,"mediaType":"tv"}"#
        ])
        enqueuePage(http, number: 3, totalPages: 3, results: [
            #"{"id":4,"mediaType":"tv","name":"Now named"}"#,
            movie(5),
            movie(6)
        ])

        let items = try await makeService(http).trending(limit: 5)

        XCTAssertEqual(items.map(\.id), [
            "seer:movie:1", "seer:series:1", "seer:movie:3", "seer:series:4", "seer:movie:5"
        ])
        XCTAssertEqual(items.first?.title, "First")
        XCTAssertEqual(items.first?.availability, .available, "Ownership is caller policy")
        XCTAssertEqual(requestedPages(http), ["1", "2", "3"])
    }

    func testEntireUnmappablePageStillAdvances() async throws {
        let http = SeerRecordingHTTPClient()
        enqueuePage(http, number: 1, totalPages: 2, results: [
            #"{"id":1,"mediaType":"person","name":"Actor"}"#,
            #"{"id":2,"mediaType":"movie","title":" "}"#
        ])
        enqueuePage(http, number: 2, totalPages: 2, results: [movie(3)])

        let items = try await makeService(http).trending(limit: 1)

        XCTAssertEqual(items.map(\.id), ["seer:movie:3"])
        XCTAssertEqual(requestedPages(http), ["1", "2"])
    }

    func testReportedLastPageStopsEvenWhenPoolIsShort() async throws {
        let http = SeerRecordingHTTPClient()
        enqueuePage(http, number: 1, totalPages: 2, results: [movie(1), movie(2)])
        enqueuePage(http, number: 2, totalPages: 2, results: [movie(3)])

        let items = try await makeService(http).trending(limit: 48)

        XCTAssertEqual(items.map(\.id), ["seer:movie:1", "seer:movie:2", "seer:movie:3"])
        XCTAssertEqual(requestedPages(http), ["1", "2"])
    }

    func testEmptyFirstPageWithZeroTotalsEndsNormally() async throws {
        let http = SeerRecordingHTTPClient()
        enqueuePage(http, number: 1, totalPages: 0, results: [], totalResults: 0)

        let items = try await makeService(http).trending(limit: 48)

        XCTAssertTrue(items.isEmpty)
        XCTAssertEqual(requestedPages(http), ["1"])
    }

    func testEmptyLaterPageStopsDespiteInflatedTotals() async throws {
        let http = SeerRecordingHTTPClient()
        enqueuePage(http, number: 1, totalPages: Int.max, results: [movie(1)])
        enqueuePage(http, number: 2, totalPages: Int.max, results: [])

        let items = try await makeService(http).trending(limit: 48)

        XCTAssertEqual(items.map(\.id), ["seer:movie:1"])
        XCTAssertEqual(requestedPages(http), ["1", "2"])
    }

    func testRepeatedContentStopsDespiteAdvancingPageNumbers() async throws {
        let http = SeerRecordingHTTPClient()
        enqueuePage(http, number: 1, totalPages: Int.max, results: [movie(1), movie(2)])
        enqueuePage(http, number: 2, totalPages: Int.max, results: [movie(2), movie(1)])
        enqueuePage(http, number: 3, totalPages: Int.max, results: [movie(3)])

        let items = try await makeService(http).trending(limit: 48)

        XCTAssertEqual(items.map(\.id), ["seer:movie:1", "seer:movie:2"])
        XCTAssertEqual(requestedPages(http), ["1", "2"])
    }

    func testFivePageBudgetBoundsSparseChangingResultsAndHugeTotals() async throws {
        let http = SeerRecordingHTTPClient()
        for page in 1...6 {
            enqueuePage(http, number: page, totalPages: Int.max, results: [movie(page)])
        }

        let items = try await makeService(http).trending(limit: Int.max)

        XCTAssertEqual(items.map(\.id), (1...5).map { "seer:movie:\($0)" })
        XCTAssertEqual(requestedPages(http), ["1", "2", "3", "4", "5"])
    }

    func testCandidateBudgetBoundsOversizedPageAndHugeRequestedLimit() async throws {
        let http = SeerRecordingHTTPClient()
        enqueuePage(http, number: 1, totalPages: Int.max, results: (1...120).map(movie))

        let items = try await makeService(http).trending(limit: Int.max)

        XCTAssertEqual(items.map(\.id), (1...100).map { "seer:movie:\($0)" })
        XCTAssertEqual(requestedPages(http), ["1"])
    }

    func testFivePageBudgetAlsoBoundsWhollyUnmappablePages() async throws {
        let http = SeerRecordingHTTPClient()
        for page in 1...6 {
            enqueuePage(http, number: page, totalPages: Int.max, results: [
                #"{"id":\#(page),"mediaType":"person","name":"Actor"}"#
            ])
        }

        let items = try await makeService(http).trending(limit: 48)

        XCTAssertTrue(items.isEmpty)
        XCTAssertEqual(requestedPages(http), ["1", "2", "3", "4", "5"])
    }

    func testMalformedPageMetadataThrowsInsteadOfReturningPartialSuccess() async {
        let invalidPages = [
            (number: 1, totalPages: 3, totalResults: 100),
            (number: 0, totalPages: 3, totalResults: 100),
            (number: 3, totalPages: 3, totalResults: 100),
            (number: 2, totalPages: -1, totalResults: 100),
            (number: 2, totalPages: 1, totalResults: 100),
            (number: 2, totalPages: 3, totalResults: -1)
        ]
        for metadata in invalidPages {
            let http = SeerRecordingHTTPClient()
            enqueuePage(http, number: 1, totalPages: 3, results: [movie(1)])
            enqueuePage(
                http,
                number: metadata.number,
                totalPages: metadata.totalPages,
                results: [movie(2)],
                totalResults: metadata.totalResults
            )

            do {
                _ = try await makeService(http).trending(limit: 48)
                XCTFail("Expected malformed pagination to fail: \(metadata)")
            } catch {
                XCTAssertEqual(error as? AppError, .invalidResponse)
            }
            XCTAssertEqual(requestedPages(http), ["1", "2"])
        }
    }

    func testLaterHTTPAndDecodingFailuresPreserveOriginalError() async {
        let failures: [(status: Int, json: String, error: AppError)] = [
            (401, "{}", .unauthorized),
            (404, "{}", .notFound),
            (500, "{}", .invalidResponse),
            (200, "{}", .decoding)
        ]
        for failure in failures {
            let http = SeerRecordingHTTPClient()
            enqueuePage(http, number: 1, totalPages: 3, results: [movie(1)])
            http.enqueueStub(pathSuffix: path, json: failure.json, status: failure.status)

            do {
                _ = try await makeService(http).trending(limit: 48)
                XCTFail("Expected later page failure, not partial success")
            } catch {
                XCTAssertEqual(error as? AppError, failure.error)
            }
            XCTAssertEqual(requestedPages(http), ["1", "2"])
        }
    }

    func testTransportErrorsIncludingCancellationPropagateUnchanged() async {
        for failure in [AppError.serverUnreachable, .cancelled, .rateLimited(retryAfter: 20)] {
            let http = SeerRecordingHTTPClient()
            http.error = failure

            do {
                _ = try await makeService(http).trending(limit: 48)
                XCTFail("Expected transport failure")
            } catch {
                XCTAssertEqual(error as? AppError, failure)
            }
            XCTAssertEqual(requestedPages(http), ["1"])
        }
    }

    func testAlreadyCancelledFetchMakesNoRequests() async {
        let http = SeerRecordingHTTPClient()
        let service = makeService(http)
        let fetch = Task { try await service.trending(limit: 48) }
        fetch.cancel()

        do {
            _ = try await fetch.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertTrue(http.sentPaths.isEmpty)
    }

    func testCancellationRejectsLateSuccessfulResponseEvenWhenLimitIsSatisfied() async {
        let http = SeerRecordingHTTPClient()
        enqueuePage(http, number: 1, totalPages: 3, results: [movie(1)])
        enqueuePage(http, number: 2, totalPages: 3, results: [movie(2)])
        http.suspend(pathSuffix: path, onRequestNumber: 2)
        let service = makeService(http)
        let fetch = Task { try await service.trending(limit: 2) }
        await http.waitUntilSuspended(pathSuffix: path)
        fetch.cancel()
        http.resume(pathSuffix: path)

        do {
            _ = try await fetch.value
            XCTFail("Expected cancellation, not stale completed pool")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertEqual(requestedPages(http), ["1", "2"])
    }

    func testConnectionReplacementRejectsPartialPoolWithoutFetchingNewServerPages() async throws {
        for replacementURL in [baseURL, URL(string: "https://new.example.com")!] {
            let http = SeerRecordingHTTPClient()
            enqueuePage(http, number: 1, totalPages: 3, results: [movie(1)])
            enqueuePage(http, number: 2, totalPages: 3, results: [movie(2)])
            http.stub(pathSuffix: "/status", json: #"{"version":"2.0"}"#)
            http.suspend(pathSuffix: path, onRequestNumber: 2)
            let store = InMemorySeerConnectionStore(
                connection: SeerConnection(baseURL: baseURL, apiKey: "KEY")
            )
            let service = makeService(http, store: store)
            let fetch = Task { try await service.trending(limit: 48) }
            await http.waitUntilSuspended(pathSuffix: path)
            try store.save(SeerConnection(baseURL: replacementURL, apiKey: "NEW"))
            await service.reloadConnection()
            http.resume(pathSuffix: path)

            do {
                _ = try await fetch.value
                XCTFail("Expected replaced connection to cancel trending")
            } catch is CancellationError {
                // Expected.
            } catch {
                XCTFail("Expected CancellationError, got \(error)")
            }
            XCTAssertEqual(requestedPages(http), ["1", "2"])
            for request in http.sent where request.path.hasSuffix(path) {
                XCTAssertEqual(request.baseURL, baseURL)
                XCTAssertEqual(request.headers["X-Api-Key"], "KEY")
            }
        }
    }

    func testDisconnectRejectsInFlightTrending() async {
        let http = SeerRecordingHTTPClient()
        enqueuePage(http, number: 1, totalPages: 1, results: [movie(1)])
        http.suspend(pathSuffix: path)
        let service = makeService(http)
        let fetch = Task { try await service.trending(limit: 1) }
        await http.waitUntilSuspended(pathSuffix: path)
        service.disconnect()
        http.resume(pathSuffix: path)

        do {
            _ = try await fetch.value
            XCTFail("Expected disconnect to cancel trending")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertEqual(requestedPages(http), ["1"])
    }
}
