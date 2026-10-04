import CoreModels
import FeatureHomeCore
import XCTest

@MainActor
final class LibraryFileBrowsingTests: XCTestCase {
    func testIndexedLibraryOffersAccountScopedFileBrowser() {
        let provider = FileBrowsingProvider()
        let model = LibraryBrowseViewModel(
            provider: provider,
            containerID: "share:lib:tv",
            containerKind: .series,
            sourceAccountID: "household-share"
        )

        XCTAssertEqual(model.fileBrowserLibrary?.id, "share:root")
        XCTAssertEqual(model.fileBrowserLibrary?.title, "NAS")
        XCTAssertEqual(model.fileBrowserLibrary?.sourceAccountID, "household-share")
        XCTAssertEqual(
            model.fileBrowserLibrary?.sourceContainerIDByAccount,
            ["household-share": "share:root"]
        )
    }

    func testRootDoesNotOfferNavigationToItself() {
        let model = LibraryBrowseViewModel(
            provider: FileBrowsingProvider(),
            containerID: "share:root",
            containerKind: .folder
        )
        XCTAssertNil(model.fileBrowserLibrary)
    }

    func testNestedFolderCanReturnToFileRoot() {
        let model = LibraryBrowseViewModel(
            provider: FileBrowsingProvider(),
            containerID: "d:TV Shows/Collections",
            containerKind: .folder
        )
        XCTAssertEqual(model.fileBrowserLibrary?.id, "share:root")
    }

    func testProvidersWithoutFileBrowsingKeepExistingLibraryActions() async {
        for kind: ProviderKind in [.jellyfin, .emby, .plex] {
            let model = LibraryBrowseViewModel(
                provider: FakeMediaProvider(allItems: [], kind: kind),
                containerID: "library",
                containerKind: .movie
            )
            XCTAssertNil(model.fileBrowserLibrary)
            XCTAssertEqual(model.contentMode, .recommended)
            XCTAssertTrue(model.availableSortFields.isEmpty)
            await model.setContentMode(.titles)
            XCTAssertEqual(model.availableSortFields, SortField.legacyFields)
        }
    }

    func testSortChoicesFollowProviderCapability() {
        let model = LibraryBrowseViewModel(
            provider: FileBrowsingProvider(sortFields: [.name, .dateAdded]),
            containerID: "share:root",
            containerKind: .folder
        )
        XCTAssertEqual(model.availableSortFields, [.name, .dateAdded])
    }

    func testUnsupportedSavedSortDoesNotRewriteOtherLibrariesPreference() throws {
        let suite = "LibraryFileBrowsingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = CoreModels.SortDescriptor(field: .runtime, direction: .descending)
        defaults.set(try JSONEncoder().encode(saved), forKey: "LibraryBrowse.sort.folder")

        let model = LibraryBrowseViewModel(
            provider: FileBrowsingProvider(sortFields: [.name]),
            containerID: "share:root",
            containerKind: .folder,
            defaults: defaults
        )

        XCTAssertEqual(model.sort, .default)
        let persisted = try XCTUnwrap(defaults.data(forKey: "LibraryBrowse.sort.folder"))
        XCTAssertEqual(try JSONDecoder().decode(CoreModels.SortDescriptor.self, from: persisted), saved)
    }
}

private struct FileBrowsingProvider: MediaProvider, MediaFileBrowsing, MediaSortFieldProviding {
    private let base = FakeMediaProvider(allItems: [], kind: .mediaShare)
    var sortFields: [SortField] = SortField.allCases
    var kind: ProviderKind { base.kind }
    var session: UserSession { base.session }
    var fileBrowserLibrary: MediaLibrary {
        MediaLibrary(id: "share:root", title: "NAS", kind: .folder)
    }
    func supportedSortFields(in containerID: String, kind: MediaItemKind) -> [SortField] {
        sortFields
    }

    func libraries() async throws -> [MediaLibrary] { try await base.libraries() }
    func continueWatching(limit: Int) async throws -> [MediaItem] {
        try await base.continueWatching(limit: limit)
    }
    func latest(limit: Int) async throws -> [MediaItem] { try await base.latest(limit: limit) }
    func item(id: String) async throws -> MediaItem { try await base.item(id: id) }
    func children(of itemID: String) async throws -> [MediaItem] {
        try await base.children(of: itemID)
    }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        try await base.items(in: containerID, kind: kind, page: page)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] {
        try await base.search(query: query, limit: limit)
    }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        try await base.playbackInfo(for: itemID)
    }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {
        try await base.reportPlayback(progress, event: event)
    }
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? {
        base.imageURL(itemID: itemID, kind: kind, maxWidth: maxWidth)
    }
}
