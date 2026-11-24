import CoreModels
import CoreNetworking
import FeatureHomeCore
import Foundation
import ProviderPlex
import XCTest
@testable import TestSupportNetworking

@MainActor
final class PlexHomeSectionRequestTests: XCTestCase {
    private let sections = "/library/sections"
    private let promoted = "/hubs/promoted"
    private let now = Date(timeIntervalSince1970: 1_000)

    func testOnlyHomeSharesItsSectionsRead() async throws {
        let http = RecordingHTTPClient()
        let source = account(http)
        for title in ["Home", "Navigation", "Refresh", "Arranger", "Direct"] {
            http.stub(pathSuffix: sections, json: inventory(title))
        }
        let visibility = HomeLibraryVisibilityModel(store: Visibility())
        let now = self.now
        let model = HomeViewModel(
            accounts: [source], layoutStore: InMemoryHomeLayoutStore(),
            contentStore: InMemoryHomeContentStore(), currentVisibility: { visibility.visibility },
            prepareHomeVisibility: {
                await visibility.prepareServerDefaults(accounts: [source], now: now, homeLoad: $0)
            }
        )
        await model.load()
        XCTAssertEqual(model.state.value?.libraries.map(\.library.title), ["Home"])
        XCTAssertEqual(http.sentPaths.filter { $0 == sections || $0 == promoted }, [sections, promoted])

        let navigation = await HomeAggregator().libraryDiscovery(from: [source])
        XCTAssertEqual(navigation.libraries.map(\.library.title), ["Navigation"])
        http.stub(pathSuffix: "/library/metadata/one", json: """
        {"MediaContainer":{"Metadata":[{"ratingKey":"one","type":"movie","title":"One","viewCount":0}]}}
        """)
        http.stubEmpty(pathSuffix: "/:/scrobble")
        let writer = try XCTUnwrap(source.provider as? any PlayedStateWriting)
        try await writer.setPlayed(true, itemID: "one")
        await model.load() // Retained row defaults, not a retained inventory.
        XCTAssertEqual(model.state.value?.libraries.map(\.library.title), ["Refresh"])
        XCTAssertEqual(http.sentPaths.filter { ["/hubs/continueWatching/items", "/:/scrobble"].contains($0) },
                       ["/hubs/continueWatching/items", "/:/scrobble", "/hubs/continueWatching/items"])
        await visibility.prepareServerDefaults(accounts: [source], now: now.addingTimeInterval(121))
        let direct = try await source.provider.libraries()
        XCTAssertEqual(direct.map(\.title), ["Direct"])
        XCTAssertEqual(http.sentPaths.filter { $0 == sections || $0 == promoted },
                       [sections, promoted, sections, sections, sections, promoted, sections])
        XCTAssertEqual(LibraryInventoryStore.shared.load(for: source)?.map(\.title), ["Refresh"],
                       "Neither the arranger nor direct reads should publish Home inventory")
    }

    func testDifferentProviderViewerAccountOrCredentialGenerationRefetches() async {
        enum Change: CaseIterable { case provider, viewer, accountID, revision }
        for change in Change.allCases {
            let http = RecordingHTTPClient()
            let source = account(http)
            let consumer: ResolvedAccount
            switch change {
            case .provider:
                var rotated = source.provider.session
                rotated.accessToken = "rotated-fixture"
                consumer = .init(account: source.account, provider: PlexProvider(session: rotated, http: http))
            case .viewer:
                consumer = .init(account: source.account, provider: source.provider, plexHomeUserID: "child")
            case .accountID:
                var other = source.account
                other.id = "other"
                consumer = .init(account: other, provider: source.provider)
            case .revision:
                consumer = .init(account: source.account, provider: source.provider, credentialRevision: CredentialRevision())
            }
            http.stub(pathSuffix: sections, json: inventory("Earlier"))
            http.stub(pathSuffix: sections, json: inventory("Current"))
            let visibility = HomeLibraryVisibilityModel(store: Visibility())
            let load = HomeLoadLibraryInventory()
            await visibility.prepareServerDefaults(accounts: [source], now: now, homeLoad: load)
            let content = await HomeAggregator().content(from: [consumer], homeLoad: load)
            XCTAssertEqual(content.libraries.map(\.library.title), ["Current"], "\(change)")
            XCTAssertEqual(http.sentPaths.filter { $0 == sections }.count, 2, "\(change)")
            XCTAssertEqual(http.sent.last { $0.path == sections }?.headers["X-Plex-Token"],
                           consumer.provider.session.accessToken)
        }
    }

    func testFailedSectionsDeniedGrantAndFailedPromotionsCannotSupplyInventory() async {
        for failure in ["sections", "no-grant", "promotions"] {
            let http = RecordingHTTPClient()
            let source = account(http, validPromotions: failure != "promotions")
            switch failure {
            case "sections":
                http.stub(pathSuffix: sections, json: "{}", status: 503)
            case "no-grant":
                http.stub(pathSuffix: sections, json: "{}", status: 401)
                http.stub(pathSuffix: "/api/v2/resources", json: "[]")
            default:
                http.stub(pathSuffix: sections, json: inventory("Do not reuse"))
            }
            http.stub(pathSuffix: sections, json: inventory("Recovered"))
            let visibility = HomeLibraryVisibilityModel(store: Visibility())
            let load = HomeLoadLibraryInventory()
            await visibility.prepareServerDefaults(accounts: [source], homeLoad: load)
            let content = await HomeAggregator().unmergedContent(from: [source], homeLoad: load)
            XCTAssertEqual(content.libraries.map(\.library.title), ["Recovered"], failure)
            XCTAssertEqual(http.sentPaths.filter { $0 == sections }.count, 2, failure)
            XCTAssertEqual(visibility.serverMatchFailures.isEmpty, failure == "no-grant", failure)
        }
    }

    func testNewerInventoryPublishedWhilePromotionsArePendingSupersedesHomeRead() async {
        enum Change: CaseIterable { case denied, empty, replacement, artworkOnly }
        for change in Change.allCases {
            let http = RecordingHTTPClient()
            let reached = expectation(description: "Promoted hubs pending: \(change)")
            let release = AsyncStream<Void>.makeStream()
            let source = account(http, transport: GatedPromotionsHTTP(stub: http) {
                reached.fulfill()
                for await _ in release.stream { break }
            })
            http.stub(pathSuffix: sections, json: inventory("Earlier"))
            let expectedIDs: [String]
            switch change {
            case .denied:
                http.stub(pathSuffix: sections, json: "{}", status: 401)
                http.stub(pathSuffix: "/api/v2/resources", json: "{}", status: 401)
                expectedIDs = []
            case .empty:
                http.stub(pathSuffix: sections, json: #"{"MediaContainer":{"Directory":[]}}"#)
                expectedIDs = []
            case .replacement:
                http.stub(pathSuffix: sections, json: inventory("Renamed", id: "2"))
                expectedIDs = ["2"]
            case .artworkOnly:
                // Identical sanitized display inventory, different raw response.
                http.stub(pathSuffix: sections, json: inventory("Earlier", artwork: "new"))
                expectedIDs = ["1"]
            }

            let visibility = HomeLibraryVisibilityModel(store: Visibility())
            let load = HomeLoadLibraryInventory()
            let layout = Task { await visibility.prepareServerDefaults(accounts: [source], homeLoad: load) }
            await fulfillment(of: [reached], timeout: 5)
            let navigation = await HomeAggregator().libraryDiscovery(from: [source])
            XCTAssertEqual(navigation.libraries.map(\.library.id), expectedIDs, "\(change)")
            XCTAssertEqual(navigation.failures.isEmpty, change != .denied)
            release.continuation.finish()
            await layout.value
            XCTAssertTrue(visibility.serverMatchFailures.isEmpty)
            let content = await HomeAggregator().content(from: [source], homeLoad: load)
            XCTAssertEqual(http.sentPaths.filter { $0 == sections }.count, 3, "\(change)")
            XCTAssertEqual(content.libraries.map(\.library.id), expectedIDs, "\(change)")
            if change == .artworkOnly {
                XCTAssertEqual(content.libraries.first?.library.imageURL?.lastPathComponent, "new")
            }
            let cachedIDs = LibraryInventoryStore.shared.load(for: source)?.map(\.id)
            XCTAssertEqual(cachedIDs, change == .denied ? nil : expectedIDs)
        }
    }

    func testCancelledNewerRefreshDoesNotInvalidateHomePublication() async throws {
        let http = RecordingHTTPClient()
        let source = account(http)
        http.stub(pathSuffix: sections, json: inventory("Kept"))
        http.stub(pathSuffix: sections, json: inventory("Unnecessary retry"))
        let load = HomeLoadLibraryInventory()
        let visibility = HomeLibraryVisibilityModel(store: Visibility())
        await visibility.prepareServerDefaults(accounts: [source], homeLoad: load)

        let newer = Task {
            try await LibraryInventoryStore.shared.refresh(for: source) {
                // The newer request has a sequence but must never publish its answer.
                withUnsafeCurrentTask { $0?.cancel() }
                return []
            }
        }
        do {
            _ = try await newer.value
            XCTFail("Cancelled inventory refresh returned success")
        } catch is CancellationError {}
        let content = await HomeAggregator().content(from: [source], homeLoad: load)
        XCTAssertEqual(content.libraries.map(\.library.title), ["Kept"])
        XCTAssertEqual(LibraryInventoryStore.shared.load(for: source)?.map(\.title), ["Kept"])
        XCTAssertEqual(http.sentPaths.filter { $0 == sections }.count, 1)
    }

    private func inventory(_ title: String, id: String = "1", artwork: String = "old") -> String {
        #"{"MediaContainer":{"Directory":[{"key":"\#(id)","type":"movie","title":"\#(title)","thumb":"https://plex.invalid/\#(artwork)"}]}}"#
    }

    private func account(
        _ http: RecordingHTTPClient, validPromotions: Bool = true, transport: (any HTTPClient)? = nil
    ) -> ResolvedAccount {
        let session = UserSession(
            server: .init(id: "fixture", name: "Fixture", baseURL: URL(string: "https://plex.invalid")!, provider: .plex),
            userID: "owner", userName: "Owner", deviceID: "fixture", accessToken: "fixture-token"
        )
        http.stub(pathSuffix: promoted, json: validPromotions ? #"{"MediaContainer":{"Hub":[]}}"# : "{}")
        for path in ["/library/recentlyAdded", "/hubs/continueWatching/items", "/library/sections/watchlist/all"] {
            http.stub(pathSuffix: path, json: #"{"MediaContainer":{"size":0,"Metadata":[]}}"#)
        }
        return ResolvedAccount(account: Account(from: session), provider: PlexProvider(session: session, http: transport ?? http))
    }

    private struct GatedPromotionsHTTP: HTTPClient {
        let stub: RecordingHTTPClient
        let beforePromotions: @Sendable () async -> Void

        func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
            if endpoint.path == "/hubs/promoted" { await beforePromotions() }
            return try await stub.send(endpoint, baseURL: baseURL)
        }
    }

    private struct Visibility: HomeLibraryVisibilityStoring {
        func load() -> HomeLibraryVisibility { .default }
        func save(_ visibility: HomeLibraryVisibility) {}
    }
}
