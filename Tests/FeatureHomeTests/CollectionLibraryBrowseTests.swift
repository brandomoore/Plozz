import CoreModels
import FeatureHomeCore
import XCTest

@MainActor
final class CollectionLibraryBrowseTests: XCTestCase {
    func testCollectionRouteUsesConcreteItemAndOwningAccountNotLibraryOrigin() {
        let item = MediaItem(id: "collection-42", title: "Movie night", kind: .collection)
            .taggingSource("owning-account")
        let route = CollectionBrowseRoute(item: item, fallbackAccountID: "other-origin")
        XCTAssertEqual(route?.collectionID, "collection-42")
        XCTAssertEqual(route?.title, "Movie night")
        XCTAssertEqual(route?.accountID, "owning-account")
        XCTAssertNotEqual(route, CollectionBrowseRoute(
            item: MediaItem(id: "collection-42", title: "Movie night", kind: .collection)
                .taggingSource("another-account")
        ))
        XCTAssertNil(CollectionBrowseRoute(
            item: MediaItem(id: "movie", title: "Movie", kind: .movie)
        ), "Normal movie/edition details must not enter collection browsing.")
        XCTAssertNil(CollectionBrowseRoute(
            item: MediaItem(id: "series", title: "Show", kind: .series)
        ))
    }

    func testExplicitMemberScopeDoesNotChangeNativeCollectionRootContract() async {
        let provider = CollectionGridProvider()
        let root = LibraryBrowseViewModel(
            provider: provider, containerID: "boxsets", containerKind: .collection
        )
        let members = LibraryBrowseViewModel(
            provider: provider, containerID: "collection-42", containerKind: .collection,
            sourceAccountID: "owner", browseScope: .collectionMembers
        )
        await root.loadFirstPage()
        await members.loadFirstPage()
        let libraryIDs = await provider.libraryIDs
        let collectionIDs = await provider.collectionIDs
        XCTAssertEqual(libraryIDs, ["boxsets"])
        XCTAssertTrue(collectionIDs.allSatisfy { $0 == "collection-42" })
        XCTAssertEqual(root.item(at: 0)?.kind, .collection)
        XCTAssertEqual(root.availableSortFields, [.name, .dateAdded])
        XCTAssertEqual(members.item(at: 0)?.kind, .movie)
        XCTAssertEqual(members.item(at: 0)?.sourceAccountID, "owner")
        XCTAssertTrue(members.availableSortFields.isEmpty)
        XCTAssertFalse(members.supportsCollections)
        XCTAssertFalse(members.showsLetterRail)
        await members.setContentMode(.collections)
        await members.setSort(CoreModels.SortDescriptor(field: .dateAdded, direction: .descending))
        XCTAssertEqual(members.contentMode, .titles)
        XCTAssertEqual(members.sort, .default)
        let after = await provider.collectionIDs
        XCTAssertEqual(after, collectionIDs, "Unsupported controls must not reload or reorder members.")
    }

    func testSparseMembersKeepServerOrderAndFillCappedPagesForAllProviders() async {
        for kind: ProviderKind in [.plex, .jellyfin, .emby] {
            let provider = CollectionGridProvider(kind: kind)
            let model = makeModel(provider, pageSize: 4)
            await model.loadFirstPage()
            XCTAssertEqual(model.totalCount, 8)
            XCTAssertEqual(model.loadedCount, 4)
            XCTAssertEqual((0..<4).compactMap { model.item(at: $0)?.id }, ["z", "a", "nested", "m"])
            XCTAssertNil(model.item(at: 4))
            await model.itemAppeared(at: 4)
            XCTAssertEqual((4..<8).compactMap { model.item(at: $0)?.id }, ["e", "b", "y", "c"])
            XCTAssertEqual((0..<8).compactMap { model.item(at: $0)?.sourceAccountID },
                           Array(repeating: "owner", count: 8))
            let requests = await provider.memberRequests
            XCTAssertEqual(requests.map(\.startIndex), [0, 2, 4, 6])
            XCTAssertEqual(requests.map(\.limit), [4, 2, 4, 2])
            let nested = model.item(at: 2)!
            let route = CollectionBrowseRoute(item: nested, fallbackAccountID: "wrong-account")
            XCTAssertEqual(route?.collectionID, "nested")
            XCTAssertEqual(route?.accountID, "owner")
        }
    }

    func testReturningFromMemberDetailRetainsPagesAndVisiblePosition() async {
        let provider = CollectionGridProvider()
        let model = makeModel(provider, pageSize: 4)
        await model.loadFirstPage()
        await model.itemAppeared(at: 4)
        let slot = model.slot(at: 4)
        let before = await provider.memberRequests.count
        await model.loadFirstPageIfNeeded()
        let after = await provider.memberRequests.count
        XCTAssertEqual(after, before)
        XCTAssertTrue(slot === model.slot(at: 4))
        XCTAssertEqual(model.topVisibleIndex, 4)
        XCTAssertEqual(model.browseScope, .collectionMembers)
    }

    func testHundredsOfMembersLoadOnlyTheRequestedGridWindows() async {
        let provider = CollectionGridProvider(generatedMemberCount: 600, serverPageLimit: 200)
        let model = makeModel(provider, pageSize: PageRequest.defaultLimit)
        await model.loadFirstPage()
        XCTAssertEqual(model.totalCount, 600)
        XCTAssertEqual(model.loadedCount, 28)
        XCTAssertNil(model.item(at: 599))
        let initialRequests = await provider.memberRequests
        XCTAssertEqual(initialRequests.map(\.startIndex), [0])
        XCTAssertEqual(initialRequests.map(\.limit), [28])

        await model.itemAppeared(at: 599)
        XCTAssertEqual(model.item(at: 599)?.id, "member-599")
        XCTAssertNil(model.item(at: 300), "Jumping to the last page must not fetch intervening pages.")
        let requests = await provider.memberRequests
        XCTAssertEqual(requests.map(\.startIndex), [0, 574])
        XCTAssertEqual(requests.map(\.limit), [28, 42])
        XCTAssertEqual(model.loadedCount, 54)
    }

    func testFailedMemberPageRetriesWithoutLosingServerOrderOrLoadedSlots() async {
        let provider = CollectionGridProvider()
        let model = makeModel(provider, pageSize: 4)
        await model.loadFirstPage()
        let firstSlot = model.slot(at: 0)
        await provider.setFailure(at: 6)
        await model.itemAppeared(at: 4)
        XCTAssertEqual(model.pageError, .serverUnreachable)
        XCTAssertEqual(model.state, .loaded(8))
        XCTAssertNil(model.item(at: 4), "Do not publish a partial sparse-grid page after a later failure.")
        await provider.setFailure(at: nil)
        await model.retryFailedPages()
        XCTAssertNil(model.pageError)
        XCTAssertTrue(firstSlot === model.slot(at: 0))
        XCTAssertEqual(model.item(at: 4)?.id, "e")
        XCTAssertEqual(model.item(at: 7)?.id, "c")
    }

    func testEmptyCollectionAndFailedInitialLoadRemainDistinct() async {
        let emptyProvider = CollectionGridProvider(isEmpty: true)
        let empty = makeModel(emptyProvider)
        await empty.loadFirstPage()
        XCTAssertEqual(empty.state, .empty)
        XCTAssertEqual(empty.totalCount, 0)

        let provider = CollectionGridProvider()
        await provider.setFailure(at: 0)
        let failed = makeModel(provider)
        await failed.loadFirstPage()
        XCTAssertEqual(failed.state, .failed(.serverUnreachable))
        XCTAssertEqual(failed.totalCount, 0)
        await provider.setFailure(at: nil)
        await failed.loadFirstPage()
        XCTAssertEqual(failed.state, .loaded(8))
    }

    func testPrematureEmptyMemberPageFailsInsteadOfLeavingPermanentPlaceholders() async {
        let provider = CollectionGridProvider(prematureEmptyIndex: 2)
        let model = makeModel(provider, pageSize: 4)
        await model.loadFirstPage()
        XCTAssertEqual(model.state, .failed(.invalidResponse))
        XCTAssertTrue(model.loaded.isEmpty)
    }

    private func makeModel(
        _ provider: CollectionGridProvider, pageSize: Int = 4
    ) -> LibraryBrowseViewModel {
        LibraryBrowseViewModel(
            provider: provider, containerID: "collection-42", containerKind: .collection,
            pageSize: pageSize, sourceAccountID: "owner", browseScope: .collectionMembers
        )
    }
}

private actor CollectionGridProvider: MediaProvider, CapabilityReporting {
    nonisolated let kind: ProviderKind
    nonisolated let session: UserSession
    nonisolated let capabilities: ProviderCapability = [.video, .libraryCollections]
    private let members: [MediaItem]
    private let prematureEmptyIndex: Int?
    private let serverPageLimit: Int
    private var failureIndex: Int?
    private(set) var memberRequests: [PageRequest] = []
    private(set) var collectionIDs: [String] = []
    private(set) var libraryIDs: [String] = []

    init(
        kind: ProviderKind = .jellyfin,
        isEmpty: Bool = false,
        prematureEmptyIndex: Int? = nil,
        generatedMemberCount: Int? = nil,
        serverPageLimit: Int = 2
    ) {
        self.kind = kind
        self.prematureEmptyIndex = prematureEmptyIndex
        self.serverPageLimit = serverPageLimit
        session = UserSession(
            server: MediaServer(
                id: "owner", name: "Server",
                baseURL: URL(string: "https://media.example")!, provider: kind
            ),
            userID: "viewer", userName: "Viewer", deviceID: "device", accessToken: "test-token"
        )
        if let generatedMemberCount {
            members = (0..<generatedMemberCount).map {
                MediaItem(id: "member-\($0)", title: "Movie \($0)", kind: .movie)
            }
        } else {
            members = isEmpty ? [] : [
            MediaItem(id: "z", title: "Z", kind: .movie),
            MediaItem(id: "a", title: "A", kind: .series),
            MediaItem(id: "nested", title: "Nested", kind: .collection),
            MediaItem(id: "m", title: "M", kind: .movie),
            MediaItem(id: "e", title: "E", kind: .movie),
            MediaItem(id: "b", title: "B", kind: .series),
            MediaItem(id: "y", title: "Y", kind: .movie),
            MediaItem(id: "c", title: "C", kind: .movie)
            ]
        }
    }

    func setFailure(at index: Int?) { failureIndex = index }

    func collectionMembers(of collectionID: String, page: PageRequest) async throws -> MediaPage {
        collectionIDs.append(collectionID)
        memberRequests.append(page)
        if failureIndex == page.startIndex { throw AppError.serverUnreachable }
        let items = prematureEmptyIndex == page.startIndex
            ? [] : Array(members.dropFirst(page.startIndex).prefix(min(serverPageLimit, page.limit)))
        return MediaPage(items: items, startIndex: page.startIndex, totalCount: members.count)
    }

    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        libraryIDs.append(containerID)
        return MediaPage(
            items: [MediaItem(id: "collection-42", title: "Movie night", kind: .collection)],
            startIndex: page.startIndex, totalCount: 1
        )
    }

    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] {
        XCTFail("A collection grid must use paged collectionMembers, not children.")
        return []
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
