import XCTest
import AppRuntime
import CoreModels
import CoreNetworking
import FeatureHomeCore
import ProviderPlex

private actor PlexCompletionHTTPClient: HTTPClient {
    private(set) var requests: [Endpoint] = []
    private var rejectsDismissal = false
    private var responses: [String: Data] = [:]

    func rejectDismissal() { rejectsDismissal = true }

    func respond(to path: String, json: String) {
        responses[path] = Data(json.utf8)
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        requests.append(endpoint)
        if rejectsDismissal && endpoint.path == "/actions/removeFromContinueWatching" {
            throw AppError.notFound
        }
        return (
            responses[endpoint.path] ?? Data("{}".utf8),
            HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}

final class PlexCompletionVersusDismissalTests: XCTestCase {
    private func provider(http: PlexCompletionHTTPClient) -> PlexProvider {
        PlexProvider(
            session: UserSession(
                server: MediaServer(
                    id: "plex", name: "Test", baseURL: URL(string: "https://plex.example")!, provider: .plex
                ),
                userID: "user", userName: "Test", deviceID: "device", accessToken: "TOKEN"
            ),
            http: http
        )
    }

    private func reconciler(http: PlexCompletionHTTPClient) -> WatchStateReconciler {
        let provider = provider(http: http)
        let applier = AppShellWatchMutationApplier(
            resolveProvider: { _ in provider },
            applyTrakt: { _ in }, applySimkl: { _ in }, applyAniList: { _ in }, applyMAL: { _ in }
        )
        return WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: applier)
    }

    func testNextEpisodeWithOldResumeRanksAheadOfOtherShowsAfterSeriesActivity() async throws {
        let http = PlexCompletionHTTPClient()
        await http.respond(to: "/hubs/continueWatching/items", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"e5","type":"episode","title":"Episode 5","index":5,"parentIndex":1,
           "grandparentRatingKey":"900","viewOffset":133500,"lastViewedAt":1650000000}
        ]}}
        """)
        await http.respond(to: "/library/metadata/900", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"900","type":"show","lastViewedAt":1700000000}
        ]}}
        """)
        let items = try await provider(http: http).continueWatching(limit: 30)
        let next = try XCTUnwrap(items.first)
        let otherItems = (1...22).map { index in
            MediaItem(
                id: "other-\(index)", title: "Other \(index)", kind: .movie,
                lastPlayedAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(index))
            )
        }
        let row = HomeAggregator.sortedByRecency(otherItems + [next])
        XCTAssertEqual(row.count, 23)
        XCTAssertEqual(row.first?.id, "e5", "The successor must rank first, not 23rd under its old resume date")
        XCTAssertEqual(row.first?.resumePosition, 133.5)
    }

    func testCompletingAnEpisodeScrobblesAndClearsProgressWithoutDismissingTheShow() async throws {
        let http = PlexCompletionHTTPClient()
        await http.respond(to: "/library/metadata/42", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"42","type":"episode","viewCount":0,"viewOffset":2500000}
        ]}}
        """)
        let reconciler = reconciler(http: http)
        let episode = MediaItem(id: "42", title: "Episode", kind: .episode, sourceAccountID: "plex")
        let mutation = try XCTUnwrap(WatchMutationFactory.playbackStop(
            item: episode, position: 2_500, watchedPercent: 99,
            primaryAccountID: "plex", crossServerSync: false
        ))
        await reconciler.enqueue(mutation)
        await reconciler.drain()
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.path), ["/library/metadata/42", "/:/scrobble", "/:/progress"])
        XCTAssertEqual(requests.last?.queryItems.first { $0.name == "time" }?.value, "0")
    }

    func testMarkingWatchedClearsProgressWithoutDismissingForEveryMediaKind() async throws {
        for kind in [MediaItemKind.movie, .episode, .season, .series] {
            let http = PlexCompletionHTTPClient()
            let type = kind == .series ? "show" : kind.rawValue
            await http.respond(to: "/library/metadata/42", json: """
            {"MediaContainer":{"size":1,"Metadata":[
              {"ratingKey":"42","type":"\(type)","viewCount":0}
            ]}}
            """)
            let reconciler = reconciler(http: http)
            let item = MediaItem(id: "42", title: "Item", kind: kind, sourceAccountID: "plex")
            let mutation = try XCTUnwrap(WatchMutationFactory.playedToggle(
                item: item, played: true, primaryAccountID: "plex", crossServerSync: false
            ))
            await reconciler.enqueue(mutation)
            await reconciler.drain()
            let requests = await http.requests
            XCTAssertEqual(requests.map(\.path), ["/library/metadata/42", "/:/scrobble", "/:/progress"], "\(kind)")
        }
    }

    func testWritingZeroPositionIsNotAnExplicitDismissal() async {
        let http = PlexCompletionHTTPClient()
        let reconciler = reconciler(http: http)
        await reconciler.enqueue(WatchMutation(
            capturedAt: Date(), canonicalMediaID: "episode", resumePosition: 0,
            targets: [.init(accountID: "plex", itemID: "42")]
        ))
        await reconciler.drain()
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.path), ["/:/progress"])
    }

    func testExplicitRemovalStillDismissesWithoutMarkingWatchedOrErasingResume() async throws {
        let http = PlexCompletionHTTPClient()
        let reconciler = reconciler(http: http)
        let episode = MediaItem(id: "42", title: "Episode", kind: .episode, sourceAccountID: "plex")
        let mutation = try XCTUnwrap(WatchMutationFactory.removeFromContinueWatching(
            item: episode, primaryAccountID: "plex", crossServerSync: false
        ))
        await reconciler.enqueue(mutation)
        await reconciler.drain()
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.path), ["/actions/removeFromContinueWatching"])
    }

    func testUnsupportedExplicitDismissalFallsBackToClearingProgress() async {
        let http = PlexCompletionHTTPClient()
        await http.rejectDismissal()
        let reconciler = reconciler(http: http)
        await reconciler.enqueue(WatchMutation(
            capturedAt: Date(), canonicalMediaID: "episode", clearResume: true,
            targets: [.init(accountID: "plex", itemID: "42")]
        ))
        await reconciler.drain()
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.path), ["/actions/removeFromContinueWatching", "/:/progress"])
        let pending = await reconciler.pendingCount
        XCTAssertEqual(pending, 0)
    }
}
