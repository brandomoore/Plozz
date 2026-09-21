import CoreModels
import CoreNetworking
import XCTest
@testable import SeerService

@MainActor
final class SeerDiscoveryStatusTests: XCTestCase {
    private func service(
        _ http: any HTTPClient,
        budget: Duration = .seconds(5),
        store: InMemorySeerConnectionStore? = nil
    ) -> SeerService {
        SeerService(
            connectionStore: store ?? InMemorySeerConnectionStore(connection: .init(
                baseURL: URL(string: "https://requests.example.test")!, apiKey: "fixture"
            )),
            http: http,
            discoveryStatusResponseBudget: budget
        )
    }

    private func candidates(_ range: ClosedRange<Int> = 1...20) -> [MediaItem] {
        range.map { id in
            MediaItem(
                id: "candidate-\(id)", title: "Title \(id)",
                kind: id.isMultiple(of: 2) ? .series : .movie,
                providerIDs: ["Tmdb": "\(id)"], discoverySources: [.tvdb],
                availability: .unknown, locallyValidatedPlayableSource: false
            )
        }
    }

    private func gatedHTTP(
        failures: Set<Int> = [],
        bodies: [Int: String] = [:]
    ) -> SeerDiscoveryStatusHTTPClient {
        let http = SeerDiscoveryStatusHTTPClient(failures: failures, bodies: bodies)
        addTeardownBlock {
            http.releaseAll()
            await self.fulfillment(
                of: [http.returned(http.snapshot.requests.count)], timeout: 1
            )
        }
        return http
    }

    private func call(
        _ service: SeerService,
        items: [MediaItem]? = nil
    ) -> ObservedSeerStatusCall {
        let call = ObservedSeerStatusCall(service: service, items: items ?? candidates())
        addTeardownBlock { await call.cancel() }
        return call
    }

    func testRequestIdentityRequiresSupportedKindAndPositiveTMDBID() {
        let service = service(SeerRecordingHTTPClient())
        XCTAssertTrue(service.hasRequestIdentity(for: MediaItem(
            id: "tmdb", title: "Movie", kind: .movie, providerIDs: ["Tmdb": "42"]
        )))
        for key in ["tmdb", "TMDB", "Tmdb"] {
            XCTAssertTrue(service.hasRequestIdentity(for: MediaItem(
                id: "external", title: "Show", kind: .series, providerIDs: [key: "42"]
            )), key)
        }
        XCTAssertFalse(service.hasRequestIdentity(for: MediaItem(
            id: "anilist", title: "Anime", kind: .series, providerIDs: ["AniList": "42"]
        )))
        XCTAssertFalse(service.hasRequestIdentity(for: MediaItem(
            id: "bad", title: "Bad", kind: .movie, providerIDs: ["Tmdb": "-1"]
        )))
        XCTAssertFalse(service.hasRequestIdentity(for: MediaItem(
            id: "episode", title: "Episode", kind: .episode, providerIDs: ["Tmdb": "42"]
        )))
    }

    func testStatusUsesDisplayedIDsAndSkipsUnrequestableTitles() async {
        let http = SeerRecordingHTTPClient()
        http.stub(pathSuffix: "/movie/42", json: #"{"mediaInfo":{"status":2}}"#)
        let items = [
            MediaItem(
                id: "outside-trending", title: "Movie", kind: .movie,
                providerIDs: ["Tmdb": "42"], discoverySources: [.tvdb],
                availability: .unknown, locallyValidatedPlayableSource: false
            ),
            MediaItem(
                id: "anime", title: "Anime", kind: .series,
                providerIDs: ["AniList": "9"], discoverySources: [.anilist],
                availability: .unknown, locallyValidatedPlayableSource: false
            )
        ]
        let updates = await service(http).availabilityUpdates(for: items)
        XCTAssertEqual(updates.map(\.id), ["outside-trending"])
        XCTAssertEqual(updates.first?.availability, .pending)
        XCTAssertEqual(http.sentPaths.filter { $0.hasSuffix("/movie/42") }.count, 1)
        XCTAssertFalse(http.sentPaths.contains { $0.contains("/discover/") })
    }

    func testHungFirstWaveReturnsAtOverallDeadlineWithoutAdmittingMore() async {
        let http = gatedHTTP()
        let service = service(http, budget: .milliseconds(150))
        let startedAt = ContinuousClock.now
        let call = call(service)
        await fulfillment(of: [http.started(4)], timeout: 1)
        await fulfillment(of: [call.finished], timeout: 1)

        XCTAssertEqual(call.result?.count, 0)
        XCTAssertLessThan(startedAt.duration(to: .now), .seconds(1))
        XCTAssertEqual(http.snapshot.requests.count, 4)
        XCTAssertEqual(http.snapshot.active, 4, "The native transport ignores cancellation")
        XCTAssertEqual(http.snapshot.maximumActive, 4)
    }

    func testDeadlineKeepsCompletedPartialStatusesInInputOrder() async {
        let http = gatedHTTP()
        let service = service(http, budget: .milliseconds(300))
        let call = call(service)
        await fulfillment(of: [http.started(4)], timeout: 1)

        http.release(3)
        await fulfillment(of: [http.started(5)], timeout: 1)
        http.release(1)
        await fulfillment(of: [http.started(6)], timeout: 1)
        await fulfillment(of: [call.finished], timeout: 1)

        XCTAssertEqual(call.result?.map(\.id), ["candidate-1", "candidate-3"])
        XCTAssertEqual(call.result?.map(\.availability), [.pending, .pending])
        XCTAssertEqual(http.snapshot.requests.count, 6)
        XCTAssertEqual(http.snapshot.active, 4)
    }

    func testCallerCancellationReturnsPromptlyAndIgnoresLateCompletion() async {
        let http = gatedHTTP()
        let service = service(http, budget: .seconds(10))
        let cancelled = call(service)
        await fulfillment(of: [http.started(4)], timeout: 1)
        cancelled.cancel()
        await fulfillment(of: [cancelled.finished], timeout: 1)
        XCTAssertEqual(cancelled.result?.count, 0)
        XCTAssertEqual(http.snapshot.active, 4)

        http.releaseAll()
        await fulfillment(of: [http.returned(4)], timeout: 1)
        let fresh = call(service, items: candidates(101...104))
        await fulfillment(of: [fresh.finished], timeout: 1)

        XCTAssertEqual(cancelled.result?.count, 0)
        XCTAssertEqual(fresh.result?.map(\.id), candidates(101...104).map(\.id))
        XCTAssertEqual(Set(http.snapshot.requests.map(\.id)), Set([1, 2, 3, 4, 101, 102, 103, 104]))
        XCTAssertEqual(http.snapshot.maximumActive, 4)
    }

    func testCancellationBeforeAdmissionDoesNotStartHTTP() async {
        let http = gatedHTTP()
        let service = service(http)
        let cancelled = call(service)
        cancelled.cancel()
        await fulfillment(of: [cancelled.finished], timeout: 1)

        XCTAssertEqual(cancelled.result?.count, 0)
        XCTAssertTrue(http.snapshot.requests.isEmpty)
    }

    func testConnectionRotationFencesQueuedWorkAndCompletedPartialResults() async throws {
        let http = gatedHTTP()
        let originalURL = URL(string: "https://old.example.test")!
        let replacementURL = URL(string: "https://new.example.test")!
        let store = InMemorySeerConnectionStore(connection: .init(
            baseURL: originalURL, apiKey: "old-fixture"
        ))
        let service = service(http, budget: .seconds(10), store: store)
        let revision = service.connectionRevision
        let original = call(service)
        await fulfillment(of: [http.started(4)], timeout: 1)
        http.release(1)
        await fulfillment(of: [http.started(5)], timeout: 1)

        let queued = call(service, items: candidates(101...120))
        await fulfillment(of: [queued.started], timeout: 1)
        try store.save(.init(baseURL: replacementURL, apiKey: "new-fixture"))
        await service.reloadConnection()
        await fulfillment(of: [original.finished, queued.finished], timeout: 1)

        XCTAssertNotEqual(service.connectionRevision, revision)
        XCTAssertEqual(original.result?.count, 0, "Even previously completed old statuses are fenced")
        XCTAssertEqual(queued.result?.count, 0)
        XCTAssertEqual(http.snapshot.requests.count, 5)
        XCTAssertTrue(http.snapshot.requests.allSatisfy { $0.baseURL == originalURL })
        XCTAssertEqual(http.snapshot.active, 4)

        let replacement = call(service, items: candidates(201...220))
        await fulfillment(of: [replacement.started], timeout: 1)
        XCTAssertEqual(http.snapshot.requests.count, 5, "Retired native work still owns its permits")
        http.releaseAll()
        await fulfillment(of: [replacement.finished], timeout: 1)

        XCTAssertEqual(replacement.result?.map(\.id), candidates(201...220).map(\.id))
        XCTAssertEqual(http.snapshot.requests.count, 25)
        XCTAssertTrue(http.snapshot.requests.dropFirst(5).allSatisfy {
            $0.baseURL == replacementURL && $0.id >= 201
        })
        XCTAssertEqual(http.snapshot.maximumActive, 4)
    }

    func testOverlappingAndPostDeadlineCallsShareActualNativeLimit() async {
        let http = gatedHTTP()
        let service = service(http, budget: .milliseconds(150))
        let first = call(service)
        await fulfillment(of: [http.started(4)], timeout: 1)
        let overlapping = call(service, items: candidates(101...120))
        await fulfillment(of: [overlapping.started], timeout: 1)
        await fulfillment(of: [first.finished, overlapping.finished], timeout: 1)
        XCTAssertEqual(first.result?.count, 0)
        XCTAssertEqual(overlapping.result?.count, 0)

        let afterDeadline = call(service, items: candidates(201...220))
        await fulfillment(of: [afterDeadline.finished], timeout: 1)
        XCTAssertEqual(afterDeadline.result?.count, 0)
        XCTAssertEqual(http.snapshot.requests.count, 4)
        XCTAssertEqual(http.snapshot.active, 4)
        XCTAssertEqual(http.snapshot.maximumActive, 4)

        http.releaseAll()
        let recovered = call(service, items: candidates(301...320))
        await fulfillment(of: [recovered.finished], timeout: 1)
        XCTAssertEqual(recovered.result?.map(\.id), candidates(301...320).map(\.id))
        XCTAssertEqual(http.snapshot.requests.count, 24, "Expired queues must not start late")
        XCTAssertEqual(http.snapshot.maximumActive, 4)
    }

    func testFastBatchStillReturnsAllTwentyAndCapsEligibleCandidates() async {
        let http = gatedHTTP()
        http.releaseAll()
        let service = service(http)
        let unsupported = MediaItem(
            id: "episode", title: "Episode", kind: .episode,
            providerIDs: ["Tmdb": "999"], availability: .unknown
        )
        let items = [unsupported] + candidates(1...25)
        let call = call(service, items: items)
        await fulfillment(of: [call.finished], timeout: 1)

        XCTAssertEqual(call.result?.map(\.id), candidates().map(\.id))
        XCTAssertEqual(call.result?.map(\.availability), Array(repeating: .pending, count: 20))
        XCTAssertEqual(http.snapshot.requests.count, 20)
        XCTAssertLessThanOrEqual(http.snapshot.maximumActive, 4)
    }

    func testOrdinaryFailuresKeepSuccessfulUpdatesAndPreserveSourceOwnership() async {
        let http = gatedHTTP(
            failures: [2],
            bodies: [
                1: #"{"mediaInfo":{"status":3,"downloadStatus":[{"size":100,"sizeLeft":25}]}}"#,
                3: "not-json"
            ]
        )
        http.releaseAll()
        let service = service(http)
        let items = candidates(1...6)
        let call = call(service, items: items)
        await fulfillment(of: [call.finished], timeout: 1)

        let expected = items.enumerated().compactMap { index, item -> MediaItem? in
            guard index != 1, index != 2 else { return nil }
            var updated = item
            updated.availability = index == 0 ? .processing : .pending
            updated.downloadProgress = index == 0 ? 0.75 : nil
            return updated
        }
        XCTAssertEqual(call.result, expected, "Only status and progress may change")
        XCTAssertEqual(http.snapshot.requests.count, 6)
    }

    func testUnconfiguredUnsupportedAndZeroBudgetBatchesDoNotPerformIO() async {
        let http = gatedHTTP()
        let unconfigured = service(http, store: InMemorySeerConnectionStore())
        let unconfiguredUpdates = await unconfigured.availabilityUpdates(for: candidates())
        XCTAssertTrue(unconfiguredUpdates.isEmpty)

        let configured = service(http)
        var local = candidates(1...1)[0]
        local.availability = nil
        let unsupported = [
            local,
            MediaItem(id: "episode", title: "Episode", kind: .episode,
                      providerIDs: ["Tmdb": "42"], availability: .unknown),
            MediaItem(id: "anilist", title: "Anime", kind: .series,
                      providerIDs: ["AniList": "42"], availability: .unknown),
            MediaItem(id: "zero", title: "Invalid", kind: .movie,
                      providerIDs: ["Tmdb": "0"], availability: .unknown)
        ]
        let unsupportedUpdates = await configured.availabilityUpdates(for: unsupported)
        XCTAssertTrue(unsupportedUpdates.isEmpty)

        let zeroBudget = service(http, budget: .zero)
        let zero = call(zeroBudget)
        await fulfillment(of: [zero.finished], timeout: 1)
        XCTAssertEqual(zero.result?.count, 0)
        XCTAssertTrue(http.snapshot.requests.isEmpty)
    }
}
