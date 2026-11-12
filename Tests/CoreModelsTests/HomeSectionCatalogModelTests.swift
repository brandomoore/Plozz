import XCTest
@testable import CoreModels

@MainActor
final class HomeSectionCatalogModelTests: XCTestCase {
    func testCatalogPropagatesRecommendationOwnershipAndExplicitRetry() async throws {
        let suite = "HomeCatalogRecommendations.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let visibility = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults))
        visibility.useRowDefaults(.combined)
        let provider = HomeCatalogProvider()
        let account = ResolvedAccount(account: Account(from: provider.session), provider: provider)
        let library = AggregatedLibrary(
            accountID: account.account.id, accountName: "Viewer", serverName: "Server", providerKind: .plex,
            library: .init(id: "movies", title: "Movies", kind: .movie)
        )
        let model = HomeSectionCatalogModel()
        let scope = HomeRecommendationScope()
        for refresh in [false, true] {
            await model.load(
                libraries: [library], accounts: [account], visibility: visibility,
                recommendationScope: scope, refreshRecommendations: refresh
            )
        }
        let scopes = await provider.recommendationScopes
        let refreshes = await provider.recommendationRefreshes
        XCTAssertEqual(scopes, [scope.id, scope.id])
        XCTAssertEqual(refreshes, [false, true])
        XCTAssertNil(HomeRecommendationScope.current)
        XCTAssertFalse(HomeRecommendationScope.refreshRequested)
    }

    func testCurrentCatalogUsesAuthorizedLocalChoicesBeforeLoadingAndAfterIdentityChanges() async throws {
        let suite = "HomeCatalogImmediate.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let visibility = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults))
        visibility.useRowDefaults(.combined)
        let provider = HomeCatalogProvider()
        let account = ResolvedAccount(account: Account(from: provider.session), provider: provider)
        let library = AggregatedLibrary(
            accountID: account.account.id, accountName: "Viewer", serverName: "Server", providerKind: .plex,
            library: .init(id: "movies", title: "Movies", kind: .movie)
        )
        let model = HomeSectionCatalogModel()
        let immediate = model.currentCatalog(libraries: [library], accounts: [account], visibility: visibility)
        XCTAssertTrue(immediate.choices.contains { $0.library?.key == library.key })
        await model.load(libraries: [library], accounts: [account], visibility: visibility)
        XCTAssertEqual(model.currentCatalog(libraries: [library], accounts: [account], visibility: visibility), model.catalog)
        let changed = model.currentCatalog(libraries: [library], accounts: [], visibility: visibility)
        XCTAssertFalse(changed.choices.contains { $0.library != nil || $0.serverRow != nil })
        let child = ResolvedAccount(
            account: account.account, provider: provider, plexHomeUserID: "child", credentialRevision: account.credentialRevision
        )
        let newIdentity = model.currentCatalog(libraries: [library], accounts: [child], visibility: visibility)
        XCTAssertFalse(newIdentity.choices.contains { $0.serverRow != nil })
        XCTAssertFalse(newIdentity.choices.contains { $0.id == .library(key: library.key, section: "recommended") })
    }

    func testVisiblePagesShareDiscoveryWhenTheRootTaskIsCancelled() async throws {
        let suite = "HomeCatalogConsumers.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let visibility = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults))
        visibility.useRowDefaults(.combined)
        let provider = HomeCatalogProvider()
        await provider.hold()
        let account = ResolvedAccount(account: Account(from: provider.session), provider: provider)
        let model = HomeSectionCatalogModel()
        let root = Task { await model.load(libraries: [], accounts: [account], visibility: visibility) }
        await provider.waitUntilRequested()
        let attached = expectation(description: "Destination starts observing discovery")
        let destination = Task {
            attached.fulfill()
            await model.load(libraries: [], accounts: [account], visibility: visibility)
        }
        await fulfillment(of: [attached], timeout: 2)
        root.cancel()
        await provider.resume()
        await root.value
        await destination.value
        let requests = await provider.requestCount
        XCTAssertEqual(requests, 1, "Opening a destination must not duplicate a live catalog request.")
        XCTAssertTrue(model.catalog.choices.contains { $0.id == .server(accountID: account.account.id, section: "native") })
        XCTAssertTrue(model.serverFailures.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    func testLeavingTheLastPageCancelsDiscoveryWithoutPublishingLateResults() async throws {
        let suite = "HomeCatalogDismissal.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let visibility = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults))
        visibility.useRowDefaults(.combined)
        let provider = HomeCatalogProvider()
        await provider.hold()
        let account = ResolvedAccount(account: Account(from: provider.session), provider: provider)
        let model = HomeSectionCatalogModel()
        let task = Task { await model.load(libraries: [], accounts: [account], visibility: visibility) }
        await provider.waitUntilRequested()
        let original = model.catalog
        task.cancel()
        let stopped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !model.isLoading }, object: nil)
        await fulfillment(of: [stopped], timeout: 2)
        await provider.resume()
        await task.value
        XCTAssertEqual(model.catalog, original)
        XCTAssertTrue(model.serverFailures.isEmpty)
    }

    func testPresetRecoveryRefreshesTheCatalogBeforeCustomizingRows() async throws {
        let suite = "HomeCatalogPreset.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let visibility = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults))
        visibility.useRowDefaults(.combined)
        let provider = HomeCatalogProvider()
        await provider.setFailure(.serverUnreachable)
        let account = ResolvedAccount(account: Account(from: provider.session), provider: provider)
        let model = HomeSectionCatalogModel()
        let originalLoadID = HomeSectionCatalogModel.loadID(libraries: [], accounts: [account], visibility: visibility)
        await model.load(libraries: [], accounts: [account], visibility: visibility)
        XCTAssertEqual(model.serverFailures[account.account.id], .serverUnreachable)
        await provider.setFailure(nil)
        visibility.useRowDefaults(.matchServer)
        XCTAssertNotEqual(
            HomeSectionCatalogModel.loadID(libraries: [], accounts: [account], visibility: visibility), originalLoadID
        )
        await model.load(libraries: [], accounts: [account], visibility: visibility)
        let native = HomeRowID.server(accountID: account.account.id, section: "native")
        XCTAssertEqual(model.catalog.sections(in: visibility.visibility).enabled, [native])
        XCTAssertTrue(model.serverFailures.isEmpty)
        let loadedID = HomeSectionCatalogModel.loadID(libraries: [], accounts: [account], visibility: visibility)
        try visibility.setHomeSectionVisible(true, id: .libraries, catalog: model.catalog)
        XCTAssertEqual(model.catalog.sections(in: visibility.visibility).enabled, [native, .libraries])
        XCTAssertEqual(
            HomeSectionCatalogModel.loadID(libraries: [], accounts: [account], visibility: visibility), loadedID,
            "Freezing a preset during an edit must not restart discovery or disable a lifted row."
        )
    }

    func testLibraryMetadataChangesInvalidateTheCatalogWithoutChangingItsStableKey() throws {
        let suite = "HomeCatalogLibraryMetadata.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let visibility = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults))
        let original = AggregatedLibrary(
            accountID: "account", accountName: "Viewer", serverName: "Server", providerKind: .plex,
            library: .init(id: "movies", title: "Original movies", kind: .movie)
        )
        var updated = original
        updated.library.title = "Updated movies"
        XCTAssertEqual(original.key, updated.key)
        XCTAssertNotEqual(
            HomeSectionCatalogModel.loadID(libraries: [original], accounts: [], visibility: visibility),
            HomeSectionCatalogModel.loadID(libraries: [updated], accounts: [], visibility: visibility)
        )
    }

    func testDiscoveryKeepsChoicesOnFailureAndClearsThemForANewViewer() async throws {
        let suite = "HomeCatalog.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let visibility = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults))
        visibility.useRowDefaults(.combined)
        let provider = HomeCatalogProvider()
        let account = Account(from: provider.session)
        let owner = ResolvedAccount(account: account, provider: provider, plexHomeUserID: "owner")
        let library = AggregatedLibrary(
            accountID: account.id, accountName: "Viewer", serverName: "Server", providerKind: .plex,
            library: .init(id: "movies", title: "Movies", kind: .movie)
        )
        let model = HomeSectionCatalogModel()
        await model.load(libraries: [library], accounts: [owner], visibility: visibility)
        let loaded = model.catalog
        XCTAssertTrue(loaded.choices.contains { $0.id == .library(key: library.key, section: "recommended") })
        XCTAssertTrue(loaded.choices.contains { $0.id == .server(accountID: account.id, section: "native") })
        await provider.setFailure(.serverUnreachable)
        await model.load(libraries: [library], accounts: [owner], visibility: visibility)
        XCTAssertEqual(model.catalog, loaded)
        XCTAssertEqual(model.libraryFailures[library.key], .serverUnreachable)
        XCTAssertEqual(model.serverFailures[account.id], .serverUnreachable)

        let child = ResolvedAccount(
            account: account, provider: provider, plexHomeUserID: "child", credentialRevision: owner.credentialRevision
        )
        await model.load(libraries: [library], accounts: [child], visibility: visibility)
        XCTAssertFalse(model.catalog.choices.contains { $0.id == .library(key: library.key, section: "recommended") })
        XCTAssertFalse(model.catalog.choices.contains { $0.id == .server(accountID: account.id, section: "native") })
        XCTAssertFalse(model.isLoading)
    }

    func testLateCatalogCannotReplaceCurrentProfileOrPublishCancellationAsFailure() async throws {
        let suite = "HomeCatalogCancellation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults, namespace: "first"))
        let second = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults, namespace: "second"))
        first.useRowDefaults(.combined)
        second.useRowDefaults(.combined)
        let provider = HomeCatalogProvider()
        await provider.hold()
        let account = ResolvedAccount(account: Account(from: provider.session), provider: provider)
        let model = HomeSectionCatalogModel()
        let task = Task { await model.load(libraries: [], accounts: [account], visibility: first) }
        await provider.waitUntilRequested()
        task.cancel()
        await model.load(libraries: [], accounts: [], visibility: second)
        let current = model.catalog
        await provider.resume()
        await task.value
        XCTAssertEqual(model.catalog, current)
        XCTAssertTrue(model.serverFailures.isEmpty)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.requestID, HomeSectionCatalogModel.requestID(libraries: [], accounts: [], visibility: second))
    }

    func testSectionWritesAreProfileScopedAndRoundTripExistingStorage() throws {
        let suite = "HomeSectionProfiles.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let aStore = HomeLibraryVisibilityStore(defaults: defaults, namespace: "a")
        let bStore = HomeLibraryVisibilityStore(defaults: defaults, namespace: "b")
        let a = HomeLibraryVisibilityModel(store: aStore)
        let b = HomeLibraryVisibilityModel(store: bStore)
        let catalog = HomeSectionCatalog(libraries: [])
        let before = bStore.load()
        try a.setHomeSectionVisible(false, id: .global(.continueWatching), catalog: catalog)
        XCTAssertFalse(aStore.load().isGlobalRowEnabled(.continueWatching))
        XCTAssertEqual(bStore.load(), before)
        XCTAssertTrue(b.isGlobalRowEnabled(.continueWatching))
        try a.setHomeSectionVisible(true, id: .global(.continueWatching), catalog: catalog)
        let order = Array(catalog.sections(in: a.visibility).enabled.reversed())
        try a.reorderHomeSections(order, catalog: catalog)
        XCTAssertEqual(catalog.sections(in: aStore.load()).enabled, order)
    }

    func testSavedNativeSectionRemainsEditableAfterItStopsBeingPromoted() async throws {
        let suite = "HomeSavedCatalog.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let visibility = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults))
        visibility.useRowDefaults(.combined)
        let provider = HomeCatalogProvider()
        let account = ResolvedAccount(account: Account(from: provider.session), provider: provider)
        let model = HomeSectionCatalogModel()
        await model.load(libraries: [], accounts: [account], visibility: visibility)
        let id = HomeRowID.server(accountID: account.account.id, section: "native")
        try visibility.setHomeSectionVisible(true, id: id, catalog: model.catalog)
        await provider.removePromotedRows()
        await model.load(libraries: [], accounts: [account], visibility: visibility)
        XCTAssertTrue(model.catalog.sections(in: visibility.visibility).enabled.contains(id))
        try visibility.setHomeSectionVisible(false, id: id, catalog: model.catalog)
        XCTAssertTrue(model.catalog.sections(in: visibility.visibility).disabled.contains(id))
    }
}

private actor HomeCatalogProvider: MediaProvider {
    let kind: ProviderKind = .plex
    let session = UserSession(
        server: .init(id: "catalog", name: "Server", baseURL: URL(string: "https://catalog.example.test")!, provider: .plex),
        userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
    )
    private var failure: AppError?
    private var held = false
    private var pending: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var requested = false
    private var hasPromotedRows = true
    private(set) var requestCount = 0
    private(set) var recommendationScopes: [UUID?] = []
    private(set) var recommendationRefreshes: [Bool] = []

    func setFailure(_ value: AppError?) { failure = value }
    func removePromotedRows() { hasPromotedRows = false }
    func hold() { held = true }
    func waitUntilRequested() async {
        if !requested { await withCheckedContinuation { observer = $0 } }
    }
    func resume() {
        held = false
        pending?.resume()
        pending = nil
    }
    func serverHomeLayout() async throws -> ServerHomeLayout? {
        requestCount += 1
        requested = true
        observer?.resume()
        observer = nil
        if held { await withCheckedContinuation { pending = $0 } }
        if let failure { throw failure }
        return .init(
            sections: hasPromotedRows ? [.init(id: "native", kind: .recommendations)] : [],
            source: .promotedHubs
        )
    }
    func homeHubs(libraryID: String, kind: MediaItemKind, limit: Int, includeUnpromoted: Bool) async throws -> [LibrarySection] {
        recommendationScopes.append(HomeRecommendationScope.current?.id)
        recommendationRefreshes.append(HomeRecommendationScope.refreshRequested)
        if let failure { throw failure }
        return [.init(id: "recommended", title: "Recommended", items: [])]
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        .init(items: [], startIndex: page.startIndex, totalCount: 0)
    }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
