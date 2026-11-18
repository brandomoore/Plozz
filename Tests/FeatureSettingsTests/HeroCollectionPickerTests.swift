import CoreModels
import Foundation
import XCTest
@testable import FeatureSettings

final class HeroCollectionPickerTests: XCTestCase {
    func testLegacyViewerUnqualifiedChoiceRemainsCheckedAndCanBeRemoved() {
        var selected = [HeroCollectionSelection(accountID: "a", libraryID: "movies", collectionID: "c", title: "Favorites")]
        let current = HeroCollectionSelection(
            accountID: "a", libraryID: "movies", collectionID: "c", title: "Favorites", serverUserID: "viewer"
        )
        XCTAssertTrue(HeroCollectionPickerSelection.contains(current, in: selected))
        HeroCollectionPickerSelection.toggle(current, in: &selected)
        XCTAssertTrue(selected.isEmpty)
    }

    func testSelectionsAccumulateAcrossLibrariesAccountsAndViewersAndToggleIndependently() {
        let choices: [HeroCollectionSelection] = [
            .init(accountID: "a", libraryID: "movies", collectionID: "same-id", title: "Favorites", serverUserID: "viewer"),
            .init(accountID: "a", libraryID: "shows", collectionID: "same-id", title: "Favorites", serverUserID: "viewer"),
            .init(accountID: "b", libraryID: "movies", collectionID: "same-id", title: "Favorites", serverUserID: "viewer"),
            .init(accountID: "a", collectionID: "same-id", title: "Favorites", serverUserID: "viewer"),
            .init(accountID: "a", libraryID: "movies", collectionID: "same-id", title: "Favorites", serverUserID: "child")
        ]
        var selected: [HeroCollectionSelection] = []
        for choice in choices { HeroCollectionPickerSelection.toggle(choice, in: &selected) }
        XCTAssertEqual(selected, choices)
        HeroCollectionPickerSelection.toggle(choices[1], in: &selected)
        XCTAssertEqual(selected, [choices[0]] + Array(choices.dropFirst(2)))
        XCTAssertEqual(Set(choices.map { $0.pickerFocusID(isSummary: false) }).count, choices.count)
        XCTAssertTrue(Set(choices.map { $0.pickerFocusID(isSummary: false) }).isDisjoint(
            with: choices.map { $0.pickerFocusID(isSummary: true) }
        ))
        HeroCollectionPickerSelection.toggle(.init(
            accountID: "a", libraryID: "movies", collectionID: "same-id", title: "Renamed", serverUserID: "viewer"
        ), in: &selected)
        XCTAssertFalse(selected.contains { $0.id == choices[0].id })
    }

    func testPersonalSourceDoesNotRequirePublicationInALibrary() {
        let provider = PickerProvider()
        let account = ResolvedAccount(account: Account(id: "a", from: provider.session), provider: provider)
        let library = AggregatedLibrary(
            accountID: "a", accountName: "Viewer", serverName: "Server", providerKind: .silo,
            library: MediaLibrary(id: "movies", title: "Movies", kind: .movie)
        )
        XCTAssertEqual(
            HeroCollectionPickerSource.available(libraries: [], accounts: [account]).map(\.id),
            [.init(accountID: "a", libraryID: nil)]
        )
        XCTAssertEqual(
            HeroCollectionPickerSource.available(libraries: [library], accounts: [account]).map(\.id),
            [.init(accountID: "a", libraryID: nil), .init(accountID: "a", libraryID: "movies")]
        )
        XCTAssertTrue(HeroCollectionPickerSource.available(libraries: [library], accounts: []).isEmpty)
        XCTAssertEqual(
            HeroCollectionPickerSource.available(libraries: [library], accounts: [account]).map(\.providerKind),
            [.plex, .plex],
            "Every library and account-only source uses the active account's brand."
        )
    }

    @MainActor
    func testVideoPlaylistModeDiscoversAndLoadsPlaylistsWithoutCollectionRequests() async {
        let provider = PickerProvider()
        let account = ResolvedAccount(account: Account(id: "a", from: provider.session), provider: provider)
        let library = AggregatedLibrary(
            accountID: "a", accountName: "Viewer", serverName: "Server", providerKind: .plex,
            library: MediaLibrary(id: "movies", title: "Movies", kind: .movie)
        )
        XCTAssertEqual(
            HeroCollectionPickerSource.available(libraries: [library], accounts: [account], playlists: true).map(\.id),
            [.init(accountID: "a", libraryID: "movies")]
        )
        let model = HeroCollectionListModel(provider: provider, libraryID: "movies", playlists: true)
        await model.loadNextPage()
        XCTAssertEqual(model.items.map(\.id), ["video-playlist"])
        XCTAssertFalse(model.hasMore)
        XCTAssertNil(model.error)
    }

    @MainActor
    func testPersonalSourceUsesNativePersonalList() async {
        let model = HeroCollectionListModel(provider: PickerProvider(), libraryID: nil)
        await model.loadNextPage()
        XCTAssertEqual(model.items.map(\.id), ["personal"])
        XCTAssertFalse(model.hasMore)
        XCTAssertNil(model.error)
    }

    @MainActor
    func testPaginatesAndReportsRetryableErrorsWithoutLosingRows() async {
        let provider = PickerProvider()
        let model = HeroCollectionListModel(provider: provider, libraryID: "library")
        await model.loadNextPage()
        XCTAssertEqual(model.items.map(\.id), ["0", "1"])
        XCTAssertTrue(model.hasMore)
        await model.loadNextPage()
        XCTAssertEqual(model.error, .serverUnreachable)
        XCTAssertEqual(model.items.count, 2)
        await provider.setFailure(false)
        await model.loadNextPage()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.items.map(\.id), ["0", "1", "2"])
        XCTAssertFalse(model.hasMore)
    }

    @MainActor
    func testCancelledResponseCannotPopulatePicker() async {
        let provider = PickerProvider()
        let model = HeroCollectionListModel(provider: provider, libraryID: "library")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.loadNextPage()
        }
        await task.value
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.error)
    }
}

private actor PickerProvider: MediaProvider, CapabilityReporting {
    nonisolated let kind: ProviderKind = .plex
    nonisolated let session = UserSession(
        server: MediaServer(id: "server", name: "Server", baseURL: URL(string: "https://example.com")!, provider: .plex),
        userID: "user", userName: "Viewer", deviceID: "device", accessToken: "test-token"
    )
    private var fails = true
    nonisolated var capabilities: ProviderCapability { [.libraryCollections, .personalCollections, .videoPlaylists] }
    func setFailure(_ value: Bool) { fails = value }

    func personalCollections(page: PageRequest) async throws -> MediaPage {
        .init(items: [.init(id: "personal", title: "Personal", kind: .collection)], startIndex: 0, totalCount: 1)
    }

    func videoPlaylists(in libraryID: String, page: PageRequest) async throws -> MediaPage {
        .init(items: [.init(id: "video-playlist", title: "Playlist", kind: .playlist)], startIndex: 0, totalCount: 1)
    }

    func collections(in libraryID: String, page: PageRequest) async throws -> MediaPage {
        if fails, page.startIndex == 2 { throw AppError.serverUnreachable }
        let items = (0..<3).map { MediaItem(id: "\($0)", title: "\($0)", kind: .collection) }
        return .init(
            items: Array(items.dropFirst(page.startIndex).prefix(2)),
            startIndex: page.startIndex, totalCount: items.count
        )
    }

    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage { throw AppError.notFound }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
