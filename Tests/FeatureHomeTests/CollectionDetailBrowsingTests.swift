import CoreModels
import FeatureHomeCore
import XCTest

@MainActor
final class CollectionDetailBrowsingTests: XCTestCase {
    func testAllProvidersPageCompleteOrderedMembershipAndTagOwningAccount() async {
        for kind: ProviderKind in [.plex, .jellyfin, .emby] {
            let provider = CollectionDetailProvider(kind: kind, members: members())
            let model = ItemDetailViewModel(
                provider: provider, itemID: provider.collection.id,
                sourceAccountID: "owning-account"
            )
            await model.load()
            XCTAssertEqual(model.state.value?.children.map(\.id), ["z", "a", "nested", "episode", "last"])
            XCTAssertEqual(model.state.value?.children.map(\.sourceAccountID),
                           Array(repeating: "owning-account", count: 5))
            XCTAssertEqual(model.state.value?.childrenLoaded, true)
            XCTAssertEqual(model.state.value?.collectionMembersState, .loaded(5))
            let requests = await provider.requests
            XCTAssertEqual(requests.map(\.startIndex), [0, 2, 4])
            XCTAssertTrue(requests.allSatisfy { $0.limit == PageRequest.defaultLimit })
        }
    }

    func testCollectionFailureIsRetryableAndNotEmpty() async {
        let provider = CollectionDetailProvider(kind: .plex, members: members(), failureIndex: 0)
        let model = ItemDetailViewModel(provider: provider, itemID: provider.collection.id)
        await model.load()
        XCTAssertEqual(model.state.value?.collectionMembersState, .failed(.unauthorized))
        XCTAssertEqual(model.state.value?.childrenLoaded, false)
        await provider.setFailureIndex(nil)
        await model.retryCollectionMembers()
        XCTAssertEqual(model.state.value?.collectionMembersState, .loaded(5))
        XCTAssertEqual(model.state.value?.children.count, 5)
    }

    func testLatePageFailureDoesNotPublishPartialMembership() async {
        let provider = CollectionDetailProvider(kind: .emby, members: members(), failureIndex: 2)
        let model = ItemDetailViewModel(provider: provider, itemID: provider.collection.id)
        await model.load()
        XCTAssertEqual(model.state.value?.collectionMembersState, .failed(.unauthorized))
        XCTAssertEqual(model.state.value?.children, [])
        XCTAssertEqual(model.state.value?.childrenLoaded, false)
    }

    func testEmptyCollectionIsAuthoritativeForEveryProvider() async {
        for kind: ProviderKind in [.plex, .jellyfin, .emby] {
            let provider = CollectionDetailProvider(kind: kind, members: [])
            let model = ItemDetailViewModel(provider: provider, itemID: provider.collection.id)
            await model.load()
            XCTAssertEqual(model.state.value?.collectionMembersState, .empty)
            XCTAssertEqual(model.state.value?.childrenLoaded, true)
        }
    }

    func testServerRepeatingPageFailsInsteadOfLoopingOrDroppingMembers() async {
        let provider = CollectionDetailProvider(kind: .plex, members: members(), repeatsFirstPage: true)
        let model = ItemDetailViewModel(provider: provider, itemID: provider.collection.id)
        await model.load()
        XCTAssertEqual(model.state.value?.collectionMembersState, .failed(.invalidResponse))
        let requests = await provider.requests
        XCTAssertEqual(requests.map(\.startIndex), [0, 2])
    }

    func testNewerRetryWinsOverSlowPreviousLoad() async {
        let provider = CollectionDetailProvider(kind: .plex, members: members(), holdsFirstPage: true)
        let model = ItemDetailViewModel(provider: provider, itemID: provider.collection.id)
        let first = Task { await model.load() }
        await provider.waitForHeldRequest()
        let replacement = MediaItem(id: "replacement", title: "Replacement", kind: .movie)
        await provider.replaceMembers([replacement])
        await model.retryCollectionMembers()
        await provider.releaseHeldRequest()
        await first.value
        XCTAssertEqual(model.state.value?.children.map(\.id), ["replacement"])
        XCTAssertEqual(model.state.value?.collectionMembersState, .loaded(1))
    }

    func testCancellationDoesNotBecomeEmptyOrFailedCollection() async {
        let provider = CollectionDetailProvider(kind: .jellyfin, members: members(), holdsFirstPage: true)
        let model = ItemDetailViewModel(provider: provider, itemID: provider.collection.id)
        let task = Task { await model.load() }
        await provider.waitForHeldRequest()
        task.cancel()
        await provider.releaseHeldRequest()
        await task.value
        XCTAssertEqual(model.state.value?.childrenLoaded, false)
        XCTAssertEqual(model.state.value?.collectionMembersState, .loading)
        await model.retryCollectionMembers()
        XCTAssertEqual(model.state.value?.collectionMembersState, .loaded(5))
    }

    func testCollectionListUsesSharedSortsAndAccountRouting() async {
        for kind: ProviderKind in [.plex, .jellyfin, .emby] {
            let provider = CollectionDetailProvider(kind: kind, members: members())
            let model = LibraryBrowseViewModel(
                provider: provider, containerID: "collections", containerKind: .collection,
                sourceAccountID: "owning-account"
            )
            XCTAssertEqual(model.availableSortFields, [.name, .dateAdded])
            await model.loadFirstPage()
            XCTAssertEqual(model.item(at: 0)?.sourceAccountID, "owning-account")
            XCTAssertEqual(model.item(at: 0)?.kind, .collection)
        }
    }

    private func members() -> [MediaItem] {
        [
            MediaItem(id: "z", title: "Z", kind: .movie),
            MediaItem(id: "a", title: "A", kind: .series),
            MediaItem(id: "nested", title: "Nested", kind: .collection),
            MediaItem(id: "episode", title: "Episode", kind: .episode),
            MediaItem(id: "last", title: "Last", kind: .movie)
        ]
    }
}

private actor CollectionDetailProvider: MediaProvider {
    nonisolated let kind: ProviderKind
    nonisolated let session: UserSession
    nonisolated let collection = MediaItem(id: "collection", title: "Collection", kind: .collection)
    private var members: [MediaItem]
    private var failureIndex: Int?
    private let repeatsFirstPage: Bool
    private var holdsFirstPage: Bool
    private var heldRequest: CheckedContinuation<Void, Never>?
    private var heldObserver: CheckedContinuation<Void, Never>?
    private(set) var requests: [PageRequest] = []

    init(
        kind: ProviderKind, members: [MediaItem], failureIndex: Int? = nil,
        repeatsFirstPage: Bool = false, holdsFirstPage: Bool = false
    ) {
        self.kind = kind
        self.members = members
        self.failureIndex = failureIndex
        self.repeatsFirstPage = repeatsFirstPage
        self.holdsFirstPage = holdsFirstPage
        session = UserSession(
            server: MediaServer(
                id: UUID().uuidString, name: "Server",
                baseURL: URL(string: "https://media.example")!, provider: kind
            ),
            userID: "user", userName: "Viewer", deviceID: "device", accessToken: "test-token"
        )
    }

    func setFailureIndex(_ index: Int?) { failureIndex = index }
    func replaceMembers(_ items: [MediaItem]) { members = items }
    func waitForHeldRequest() async {
        guard heldRequest == nil else { return }
        await withCheckedContinuation { heldObserver = $0 }
    }
    func releaseHeldRequest() {
        heldRequest?.resume()
        heldRequest = nil
    }

    func collectionMembers(of collectionID: String, page: PageRequest) async throws -> MediaPage {
        requests.append(page)
        if failureIndex == page.startIndex { throw AppError.unauthorized }
        let snapshot = members
        if holdsFirstPage {
            holdsFirstPage = false
            await withCheckedContinuation { continuation in
                heldRequest = continuation
                heldObserver?.resume()
                heldObserver = nil
            }
        }
        let offset = repeatsFirstPage ? 0 : page.startIndex
        return MediaPage(
            items: Array(snapshot.dropFirst(offset).prefix(2)),
            startIndex: page.startIndex, totalCount: snapshot.count
        )
    }

    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { collection }
    func children(of itemID: String) async throws -> [MediaItem] {
        XCTFail("Collection detail must use paged membership, not generic children")
        throw AppError.invalidResponse
    }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [collection], startIndex: page.startIndex, totalCount: 1)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
