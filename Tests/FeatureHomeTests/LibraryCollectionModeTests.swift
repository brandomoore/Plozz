import CoreModels
import FeatureHomeCore
import XCTest

@MainActor
final class LibraryCollectionModeTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsName: String!

    override func setUp() async throws {
        try await super.setUp()
        defaultsName = "LibraryCollectionModeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: defaultsName)
        defaults = nil
        try await super.tearDown()
    }

    func testOnlyCapableMovieAndSeriesLibrariesOfferCollections() async {
        for kind: MediaItemKind in [.movie, .series, .collection, .folder, .unknown, .season] {
            for supported in [false, true] {
                let provider = LibraryModeProvider(supportsCollections: supported)
                let model = model(provider, kind: kind)
                let expected = supported && (kind == .movie || kind == .series)
                XCTAssertEqual(model.supportsCollections, expected)
                XCTAssertEqual(model.contentMode, .titles)
                await model.setContentMode(.collections)
                XCTAssertEqual(model.contentMode, expected ? .collections : .titles)
                let requests = await provider.requests
                XCTAssertEqual(requests.count, expected ? 1 : 0)
            }
        }
    }

    func testEveryBackendUsesLibraryScopedCollectionsAndKeepsTitleBrowseDefault() async {
        for kind: ProviderKind in [.plex, .jellyfin, .emby] {
            let provider = LibraryModeProvider(kind: kind)
            let model = model(provider)
            await model.loadFirstPage()
            XCTAssertEqual(model.contentMode, .titles)
            XCTAssertEqual(model.item(at: 0)?.kind, .movie)
            await model.setContentMode(.collections)
            XCTAssertEqual(model.item(at: 0)?.kind, .collection)
            XCTAssertEqual(model.item(at: 0)?.sourceAccountID, "owning-account")
            let requests = await provider.requests
            XCTAssertEqual(requests.map(\.mode), [.titles, .collections])
            XCTAssertEqual(requests.map(\.containerID), ["real-library", "real-library"])
            XCTAssertEqual(requests.map(\.kind), [.movie, .collection])
            XCTAssertEqual(requests.map(\.page.startIndex), [0, 0])
        }
    }

    func testNativeCollectionRootKeepsExistingItemsBrowseAndNeverAddsAnotherMode() async {
        let provider = LibraryModeProvider()
        let model = model(provider, kind: .collection)
        await model.loadFirstPage()
        await model.setContentMode(.collections)
        XCTAssertFalse(model.supportsCollections)
        XCTAssertEqual(model.availableSortFields, [.name, .dateAdded])
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.mode, .titles)
        XCTAssertEqual(requests.first?.kind, .collection)
    }

    func testSwitchClearsCountSlotsScrollAndLatePagesBeforeResponse() async {
        let provider = LibraryModeProvider(titleCount: 40, collectionCount: 12)
        let model = model(provider)
        await model.loadFirstPage()
        await model.itemAppeared(at: 8)
        XCTAssertNotNil(model.item(at: 8))
        XCTAssertEqual(model.topVisibleIndex, 8)
        let oldGeneration = model.contentGeneration

        await provider.hold(.collections, at: 0)
        let switching = Task { await model.setContentMode(.collections) }
        await provider.waitForHeldRequest(.collections, at: 0)
        XCTAssertEqual(model.state, .loading)
        XCTAssertEqual(model.totalCount, 0)
        XCTAssertTrue(model.loaded.isEmpty)
        XCTAssertNil(model.pageError)
        XCTAssertNil(model.topVisibleIndex)
        XCTAssertTrue(model.letterEntries.isEmpty)
        XCTAssertNotEqual(model.contentGeneration, oldGeneration)
        await provider.release(.collections, at: 0)
        await switching.value

        XCTAssertEqual(model.totalCount, 12)
        XCTAssertEqual(model.loadedCount, 2)
        XCTAssertNil(model.item(at: 8))
        await model.itemAppeared(at: 4, generation: oldGeneration)
        XCTAssertNil(model.item(at: 4), "A retired title cell must not page collections.")
        await model.itemAppeared(at: 4)
        model.itemDisappeared(at: 4, generation: oldGeneration)
        XCTAssertEqual(model.topVisibleIndex, 4)
        XCTAssertEqual(model.item(at: 4)?.id, "collection-4")

        await model.setContentMode(.titles)
        XCTAssertEqual(model.totalCount, 40)
        XCTAssertEqual(model.loadedCount, 2)
        XCTAssertNil(model.item(at: 4), "Collection slots never become cached title slots.")
        XCTAssertNil(model.topVisibleIndex)
    }

    func testTitleAndCollectionSortsRestoreIndependently() async {
        let provider = LibraryModeProvider()
        let model = model(provider)
        let titleSort = CoreModels.SortDescriptor(field: .communityRating, direction: .descending)
        let collectionSort = CoreModels.SortDescriptor(field: .dateAdded, direction: .descending)
        await model.setSort(titleSort)
        await model.setContentMode(.collections)
        XCTAssertEqual(model.sort, .default)
        XCTAssertEqual(model.availableSortFields, [.name, .dateAdded])
        await model.setSort(collectionSort)
        let beforeUnsupportedSort = await provider.requests.count
        await model.setSort(titleSort)
        let afterUnsupportedSort = await provider.requests.count
        XCTAssertEqual(afterUnsupportedSort, beforeUnsupportedSort)
        XCTAssertEqual(model.sort, collectionSort)
        await model.setContentMode(.titles)
        XCTAssertEqual(model.sort, titleSort)
        await model.setContentMode(.collections)
        XCTAssertEqual(model.sort, collectionSort)
        let lastRequest = await provider.requests.last
        XCTAssertEqual(lastRequest?.page.sort, collectionSort)
    }

    func testReturningFromCollectionDetailRetainsModePagesAndScroll() async {
        let provider = LibraryModeProvider(collectionCount: 20)
        let model = model(provider)
        await model.setContentMode(.collections)
        await model.itemAppeared(at: 8)
        let requestsBefore = await provider.requests.count
        let slotBefore = model.slot(at: 8)
        await model.loadFirstPageIfNeeded()
        let requestsAfter = await provider.requests.count
        XCTAssertEqual(requestsAfter, requestsBefore)
        XCTAssertEqual(model.contentMode, .collections)
        XCTAssertEqual(model.topVisibleIndex, 8)
        XCTAssertTrue(model.slot(at: 8) === slotBefore)
        XCTAssertEqual(model.item(at: 8)?.id, "collection-8")
    }

    func testNewLibraryOrAccountStartsInTitlesAndRetainsItsOwnSource() async {
        let firstProvider = LibraryModeProvider(accountID: "server-a")
        let first = model(firstProvider, accountID: "account-a")
        await first.setContentMode(.collections)
        XCTAssertEqual(first.item(at: 0)?.sourceAccountID, "account-a")

        let secondProvider = LibraryModeProvider(accountID: "server-b")
        let second = model(secondProvider, accountID: "account-b")
        XCTAssertEqual(second.contentMode, .titles)
        await second.loadFirstPage()
        XCTAssertEqual(second.item(at: 0)?.sourceAccountID, "account-b")
        await second.setContentMode(.collections)
        XCTAssertEqual(second.item(at: 0)?.sourceAccountID, "account-b")
        XCTAssertEqual(first.item(at: 0)?.sourceAccountID, "account-a")
        XCTAssertEqual(first.sourceServerID, "server-a")
        XCTAssertEqual(second.sourceServerID, "server-b")

        let anotherLibrary = model(firstProvider, libraryID: "other-library", accountID: "account-a")
        XCTAssertEqual(anotherLibrary.contentMode, .titles)
        await anotherLibrary.setContentMode(.collections)
        let request = await firstProvider.requests.last
        XCTAssertEqual(request?.containerID, "other-library")
    }

    func testEmptyCollectionsAreNotTheMovieCountAndCanSwitchBack() async {
        let provider = LibraryModeProvider(titleCount: 40, collectionCount: 0)
        let model = model(provider)
        await model.loadFirstPage()
        await model.setContentMode(.collections)
        XCTAssertEqual(model.state, .empty)
        XCTAssertEqual(model.totalCount, 0)
        XCTAssertTrue(model.loaded.isEmpty)
        XCTAssertTrue(model.supportsCollections)
        await model.setContentMode(.titles)
        XCTAssertEqual(model.state, .loaded(40))
    }

    func testFailedCollectionsRemainRetryableAndDoNotLookEmpty() async {
        let provider = LibraryModeProvider()
        let model = model(provider)
        await provider.fail(.collections, at: 0)
        await model.setContentMode(.collections)
        XCTAssertEqual(model.state, .failed(.serverUnreachable))
        XCTAssertEqual(model.totalCount, 0)
        XCTAssertTrue(model.loaded.isEmpty)
        XCTAssertEqual(model.contentMode, .collections)
        await provider.clearFailures()
        await model.loadFirstPage()
        XCTAssertEqual(model.state, .loaded(12))
        let requests = await provider.requests
        XCTAssertEqual(requests.map(\.mode), [.collections, .collections])
    }

    func testSlowFirstPageCannotOverwriteNewMode() async {
        let provider = LibraryModeProvider()
        let model = model(provider)
        await provider.hold(.titles, at: 0)
        let titleLoad = Task { await model.loadFirstPage() }
        await provider.waitForHeldRequest(.titles, at: 0)
        await model.setContentMode(.collections)
        await provider.release(.titles, at: 0)
        await titleLoad.value
        XCTAssertEqual(model.contentMode, .collections)
        XCTAssertEqual(model.totalCount, 12)
        XCTAssertEqual(model.item(at: 0)?.id, "collection-0")
    }

    func testCollectionPageFailureRetriesWithoutReplacingLoadedGrid() async {
        let provider = LibraryModeProvider()
        let model = model(provider)
        await model.setContentMode(.collections)
        let firstSlot = model.slot(at: 0)
        await provider.fail(.collections, at: 4)
        await model.itemAppeared(at: 4)
        XCTAssertEqual(model.pageError, .serverUnreachable)
        XCTAssertEqual(model.state, .loaded(12))
        XCTAssertNil(model.item(at: 4))

        await model.itemAppeared(at: 6)
        XCTAssertEqual(model.pageError, .serverUnreachable,
                       "Another successful page must not hide an outstanding failure.")
        await provider.clearFailures()
        await model.retryFailedPages()
        XCTAssertNil(model.pageError)
        XCTAssertTrue(firstSlot === model.slot(at: 0))
        XCTAssertEqual(model.item(at: 4)?.id, "collection-4")
    }

    func testSlowCollectionFirstPageCannotOverwriteReturnedTitlesOrSort() async {
        let provider = LibraryModeProvider()
        let model = model(provider)
        let chosen = CoreModels.SortDescriptor(field: .dateAdded, direction: .descending)
        await model.setSort(chosen)
        await provider.hold(.collections, at: 0)
        let collectionLoad = Task { await model.setContentMode(.collections) }
        await provider.waitForHeldRequest(.collections, at: 0)
        await model.setContentMode(.titles)
        await provider.release(.collections, at: 0)
        await collectionLoad.value
        XCTAssertEqual(model.contentMode, .titles)
        XCTAssertEqual(model.sort, chosen)
        XCTAssertEqual(model.totalCount, 40)
        XCTAssertEqual(model.item(at: 0)?.id, "title-0")
    }

    func testRetiredPageErrorCannotContaminateNewMode() async {
        let provider = LibraryModeProvider()
        let model = model(provider)
        await model.loadFirstPage()
        await provider.fail(.titles, at: 4)
        await provider.hold(.titles, at: 4)
        let oldPage = Task { await model.itemAppeared(at: 4) }
        await provider.waitForHeldRequest(.titles, at: 4)
        await model.setContentMode(.collections)
        await provider.release(.titles, at: 4)
        await oldPage.value
        XCTAssertNil(model.pageError)
        XCTAssertEqual(model.state, .loaded(12))
        XCTAssertNil(model.item(at: 4))
    }

    func testRetiredPageCompletionCannotRemoveNewModesInFlightPage() async {
        let provider = LibraryModeProvider()
        let model = model(provider)
        await model.loadFirstPage()
        await provider.hold(.titles, at: 4)
        let oldPage = Task { await model.itemAppeared(at: 4) }
        await provider.waitForHeldRequest(.titles, at: 4)
        await model.setContentMode(.collections)
        await provider.hold(.collections, at: 4)
        let newPage = Task { await model.itemAppeared(at: 4) }
        await provider.waitForHeldRequest(.collections, at: 4)

        await provider.release(.titles, at: 4)
        await oldPage.value
        let adjacentCell = Task { await model.itemAppeared(at: 5) }
        // Yield while the adjacent cell joins the existing page task.
        for _ in 0..<10 { await Task.yield() }
        let requests = await provider.requests
        XCTAssertEqual(requests.filter { $0.mode == .collections && $0.page.startIndex == 4 }.count, 1)
        XCTAssertNil(model.item(at: 4), "An old title page must never fill collection slots.")
        await provider.release(.collections, at: 4)
        await newPage.value
        await adjacentCell.value
        XCTAssertEqual(model.item(at: 4)?.id, "collection-4")
        XCTAssertEqual(model.totalCount, 12)
    }

    func testCollectionModeClearsAndDoesNotRequestTitleLetterIndex() async {
        let provider = LibraryModeProvider(collectionCount: 40)
        let model = model(provider)
        await model.loadFirstPage()
        let deadline = Date().addingTimeInterval(1)
        while model.letterEntries.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(model.showsLetterRail)
        await model.setContentMode(.collections)
        XCTAssertFalse(model.showsLetterRail)
        XCTAssertTrue(model.letterEntries.isEmpty)
        let requests = await provider.letterRequests
        XCTAssertEqual(requests, [.movie])
    }

    private func model(
        _ provider: LibraryModeProvider,
        kind: MediaItemKind = .movie,
        libraryID: String = "real-library",
        accountID: String = "owning-account"
    ) -> LibraryBrowseViewModel {
        LibraryBrowseViewModel(
            provider: provider, containerID: libraryID, containerKind: kind,
            pageSize: 2, defaults: defaults, sourceAccountID: accountID
        )
    }
}

private actor LibraryModeProvider: MediaProvider, CapabilityReporting {
    struct Request: Sendable {
        let mode: LibraryContentMode
        let containerID: String
        let kind: MediaItemKind
        let page: PageRequest
    }

    private struct Key: Hashable {
        let mode: LibraryContentMode
        let index: Int
    }

    nonisolated let kind: ProviderKind
    nonisolated let session: UserSession
    nonisolated let capabilities: ProviderCapability
    private let titleCount: Int
    private let collectionCount: Int
    private var holds: Set<Key> = []
    private var held: [Key: CheckedContinuation<Void, Never>] = [:]
    private var heldObservers: [Key: CheckedContinuation<Void, Never>] = [:]
    private var failures: Set<Key> = []
    private(set) var requests: [Request] = []
    private(set) var letterRequests: [MediaItemKind] = []

    init(
        kind: ProviderKind = .jellyfin,
        accountID: String = "server",
        supportsCollections: Bool = true,
        titleCount: Int = 40,
        collectionCount: Int = 12
    ) {
        self.kind = kind
        self.titleCount = titleCount
        self.collectionCount = collectionCount
        capabilities = supportsCollections ? [.video, .libraryCollections] : [.video]
        session = UserSession(
            server: MediaServer(
                id: accountID, name: "Server",
                baseURL: URL(string: "https://media.example")!, provider: kind
            ),
            userID: "user", userName: "Viewer", deviceID: "device", accessToken: "test-token"
        )
    }

    func hold(_ mode: LibraryContentMode, at index: Int) {
        holds.insert(Key(mode: mode, index: index))
    }

    func waitForHeldRequest(_ mode: LibraryContentMode, at index: Int) async {
        let key = Key(mode: mode, index: index)
        guard held[key] == nil else { return }
        await withCheckedContinuation { heldObservers[key] = $0 }
    }

    func release(_ mode: LibraryContentMode, at index: Int) {
        held.removeValue(forKey: Key(mode: mode, index: index))?.resume()
    }

    func fail(_ mode: LibraryContentMode, at index: Int) {
        failures.insert(Key(mode: mode, index: index))
    }

    func clearFailures() { failures = [] }

    func collections(in libraryID: String, page: PageRequest) async throws -> MediaPage {
        try await response(.collections, containerID: libraryID, kind: .collection, page: page)
    }

    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        try await response(.titles, containerID: containerID, kind: kind, page: page)
    }

    private func response(
        _ mode: LibraryContentMode, containerID: String,
        kind: MediaItemKind, page: PageRequest
    ) async throws -> MediaPage {
        requests.append(Request(mode: mode, containerID: containerID, kind: kind, page: page))
        let key = Key(mode: mode, index: page.startIndex)
        let fails = failures.contains(key)
        if holds.remove(key) != nil {
            // Intentionally cancellation-insensitive to exercise stale replies.
            await withCheckedContinuation { continuation in
                held[key] = continuation
                heldObservers.removeValue(forKey: key)?.resume()
            }
        }
        if fails { throw AppError.serverUnreachable }
        let total = mode == .collections ? collectionCount : titleCount
        let prefix = mode == .collections ? "collection" : "title"
        let start = min(page.startIndex, total)
        let end = min(start + page.limit, total)
        return MediaPage(
            items: (start..<end).map {
                MediaItem(id: "\(prefix)-\($0)", title: "\(prefix) \($0)", kind: kind)
            },
            startIndex: page.startIndex, totalCount: total
        )
    }

    func letterIndex(
        in containerID: String, kind: MediaItemKind, sort: CoreModels.SortDescriptor
    ) async throws -> [LibraryLetterIndexEntry] {
        letterRequests.append(kind)
        return [
            LibraryLetterIndexEntry(letter: "A", startIndex: 0),
            LibraryLetterIndexEntry(letter: "B", startIndex: 20)
        ]
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
