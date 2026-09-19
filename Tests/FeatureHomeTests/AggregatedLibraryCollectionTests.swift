import CoreModels
import FeatureHomeCore
import XCTest
@testable import FeatureHome

final class AggregatedLibraryCollectionTests: XCTestCase {
    func testCollectionsKeepOwnersAndEachLibraryScope() async throws {
        let first = CollectionSourceFixture(collections: [collection("12", title: "Bond")])
        let second = CollectionSourceFixture(collections: [collection("12", title: "Bond")])
        let provider = aggregate(first, second)
        XCTAssertTrue(provider.capabilities.contains(.libraryCollections))

        let page = try await provider.collections(in: "merged", page: PageRequest())
        XCTAssertEqual(page.totalCount, 2)
        XCTAssertEqual(Set(page.items.map(\.sourceAccountID)), ["first", "second"])
        XCTAssertTrue(page.items.allSatisfy { $0.sources.count <= 1 })
        let firstRequests = await first.collectionRequests
        let secondRequests = await second.collectionRequests
        let firstTitleRequests = await first.titleRequests
        let secondTitleRequests = await second.titleRequests
        XCTAssertEqual(firstRequests.map(\.libraryID), ["first-library"])
        XCTAssertEqual(secondRequests.map(\.libraryID), ["second-library"])
        XCTAssertEqual(firstTitleRequests, 0)
        XCTAssertEqual(secondTitleRequests, 0)
    }

    func testMovieAndCollectionCachesNeverMix() async throws {
        let source = CollectionSourceFixture(collections: [collection("set", title: "Collection")])
        let provider = aggregate(source)
        let titles = try await provider.items(in: "merged", kind: .movie, page: PageRequest())
        let collections = try await provider.collections(in: "merged", page: PageRequest())
        let titlesAgain = try await provider.items(in: "merged", kind: .movie, page: PageRequest())
        XCTAssertEqual(titles.items.map(\.id), ["movie"])
        XCTAssertEqual(collections.items.map(\.id), ["set"])
        XCTAssertEqual(titlesAgain.items, titles.items)
    }

    func testCollectionsPageBoundedlyWithoutMergingSameCatalogueIdentity() async throws {
        let first = CollectionSourceFixture(collections: (0..<30).map { collection("a-\($0)", title: String(format: "A%02d", $0)) })
        let second = CollectionSourceFixture(collections: (0..<30).map { collection("b-\($0)", title: String(format: "B%02d", $0)) })
        let provider = aggregate(first, second)
        var items: [MediaItem] = []
        for start in stride(from: 0, to: 60, by: 10) {
            let page = try await provider.collections(
                in: "merged", page: PageRequest(startIndex: start, limit: 10)
            )
            items.append(contentsOf: page.items)
            XCTAssertEqual(page.totalCount, 60)
        }
        XCTAssertEqual(items.count, 60)
        XCTAssertEqual(Set(items.map(\.stablePresentationID)).count, 60)
        let firstRequests = await first.collectionRequests
        let secondRequests = await second.collectionRequests
        XCTAssertEqual(firstRequests.map(\.page.startIndex), [0, 20])
        XCTAssertEqual(secondRequests.map(\.page.startIndex), [0, 20])
        XCTAssertTrue((firstRequests + secondRequests).allSatisfy { $0.page.limit == 20 })
    }

    func testNewFirstPageRefreshesCollections() async throws {
        let source = CollectionSourceFixture(collections: [collection("old", title: "Old")])
        let provider = aggregate(source)
        _ = try await provider.collections(in: "merged", page: PageRequest())
        await source.replaceCollections([collection("new", title: "New")])
        let refreshed = try await provider.collections(in: "merged", page: PageRequest())
        XCTAssertEqual(refreshed.items.map(\.id), ["new"])
    }

    func testFailedCollectionSourceIsNotAnEmptyOrPartialSuccess() async throws {
        let first = CollectionSourceFixture(collections: [collection("first", title: "A")])
        let second = CollectionSourceFixture(collections: [collection("second", title: "B")])
        await second.setFailure(.serverUnreachable)
        let provider = aggregate(first, second)
        do {
            _ = try await provider.collections(in: "merged", page: PageRequest())
            XCTFail("A failed source must remain retryable, not look empty or complete.")
        } catch {
            XCTAssertEqual(error as? AppError, .serverUnreachable)
        }
        await second.setFailure(nil)
        let recovered = try await provider.collections(in: "merged", page: PageRequest())
        XCTAssertEqual(recovered.items.map(\.id), ["first", "second"])
    }

    func testUnsupportedSourceDoesNotAdvertiseOrPartiallyServeCollections() async {
        let first = CollectionSourceFixture(collections: [])
        let second = CollectionSourceFixture(collections: [], supportsCollections: false)
        let provider = aggregate(first, second)
        XCTAssertFalse(provider.capabilities.contains(.libraryCollections))
        do {
            _ = try await provider.collections(in: "merged", page: PageRequest())
            XCTFail("Unsupported aggregate must not expose incomplete discovery.")
        } catch {
            XCTAssertEqual(error as? AppError, .notFound)
        }
        let requests = await first.collectionRequests
        XCTAssertTrue(requests.isEmpty)
    }

    @MainActor
    func testMergedMovieLibraryOffersModeButAllLibrariesDoesNot() {
        let provider = aggregate(CollectionSourceFixture(collections: []))
        let movies = LibraryBrowseViewModel(provider: provider, containerID: "merged", containerKind: .movie)
        let all = LibraryBrowseViewModel(provider: provider, containerID: "all", containerKind: .unknown)
        XCTAssertTrue(movies.supportsCollections)
        XCTAssertFalse(all.supportsCollections)
    }

    private func collection(_ id: String, title: String) -> MediaItem {
        MediaItem(id: id, title: title, kind: .collection, providerIDs: ["Tmdb": "same-catalogue"])
    }

    private func aggregate(_ first: CollectionSourceFixture, _ second: CollectionSourceFixture? = nil) -> AggregatedLibraryProvider {
        var sources = [AggregatedLibrarySource(accountID: "first", containerID: "first-library", provider: first)]
        if let second {
            sources.append(AggregatedLibrarySource(accountID: "second", containerID: "second-library", provider: second))
        }
        return AggregatedLibraryProvider(sources: sources)
    }
}

private actor CollectionSourceFixture: MediaProvider, CapabilityReporting {
    nonisolated let kind: ProviderKind = .plex
    nonisolated let capabilities: ProviderCapability
    nonisolated let session = UserSession(
        server: MediaServer(id: "server", name: "Server", baseURL: URL(string: "https://example.test")!, provider: .plex),
        userID: "viewer", userName: "Viewer", deviceID: "device", accessToken: "fixture"
    )
    private var collectionItems: [MediaItem]
    private var failure: AppError?
    private(set) var collectionRequests: [(libraryID: String, page: PageRequest)] = []
    private(set) var titleRequests = 0

    init(collections: [MediaItem], supportsCollections: Bool = true) {
        collectionItems = collections
        capabilities = supportsCollections ? [.libraryCollections] : []
    }

    func replaceCollections(_ items: [MediaItem]) { collectionItems = items }
    func setFailure(_ error: AppError?) { failure = error }

    func collections(in libraryID: String, page: PageRequest) async throws -> MediaPage {
        collectionRequests.append((libraryID, page))
        if let failure { throw failure }
        return MediaPage(
            items: Array(collectionItems.dropFirst(page.startIndex).prefix(page.limit)),
            startIndex: page.startIndex, totalCount: collectionItems.count
        )
    }

    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        titleRequests += 1
        return MediaPage(
            items: [MediaItem(id: "movie", title: "Movie", kind: .movie)],
            startIndex: page.startIndex, totalCount: 1
        )
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
