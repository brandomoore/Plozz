import CoreModels
import Observation
import XCTest
@testable import FeaturePlayback

@MainActor
final class ContinueWatchingSelectionTests: XCTestCase {
    func testOptionalTabsRespectVisibilityAndAvailabilityWithoutDisablingSequencePlayback() async {
        let provider = ContinueWatchingTestProvider()
        let episode = MediaItem(id: "episode", title: "Episode", kind: .episode, seriesID: "series")
        let context = VideoPlaylistPlaybackContext(
            origin: .init(playlistID: "playlist", accountID: "account", index: 0, totalCount: 1, item: episode),
            provider: provider
        )
        for mask in 0..<(1 << PlayerOptionalTab.allCases.count) {
            var settings = PlaybackSettings.default
            var expected: [PlayerControls.Category] = [.info]
            for (index, tab) in PlayerOptionalTab.allCases.enumerated() {
                let enabled = mask & (1 << index) != 0
                settings[keyPath: tab.visibilityKeyPath] = enabled
                if enabled { expected.append(.init(tab)) }
            }
            let player = PlayerViewModel(
                provider: provider, itemID: episode.id, episodeItem: episode,
                playbackSettings: settings, playlistContext: context
            )
            let controls = PlayerControlsModel()
            controls.infoCard.chapters = [.init(start: 0, title: "Chapter")]
            controls.infoCard.cast = [.init(id: "person", name: "Person", role: "Character")]
            player.continueWatchingSnapshot = { [MediaItem(id: "other", title: "Other", kind: .movie)] }
            XCTAssertEqual(PlayerControls.Category.visibleCardTabs(model: controls, player: player), expected)
            XCTAssertNotNil(player.episodeBrowser, "Hiding Episodes must not disable its playback context.")
            XCTAssertTrue(player.playlistContext === context)
            controls.infoCard.chapters = []
            controls.infoCard.cast = []
            player.continueWatchingSnapshot = { [] }
            XCTAssertEqual(
                PlayerControls.Category.visibleCardTabs(model: controls, player: player),
                expected.filter { [.info, .episodes, .playlist].contains($0) }
            )
            await player.stop()
        }
        XCTAssertEqual(PlayerControls.Category.visibleCardTabs(model: .init(), player: nil), [.info])
    }

    func testSnapshotIsDerivedOnceAndObservesHomeUpdates() async throws {
        let home = ContinueWatchingHomeSnapshot()
        let first = MediaItem(id: "first", title: "First", kind: .movie)
        home.items = [first, first]
        var reads = 0
        let model = PlayerViewModel(provider: ContinueWatchingTestProvider(), itemID: "current")
        model.continueWatchingSnapshot = { reads += 1; return home.items }
        for _ in 0..<100 {
            XCTAssertEqual(model.continueWatchingItems, [first])
        }
        XCTAssertEqual(reads, 1, "Focus and clock updates must not re-filter Home.")
        let next = MediaItem(id: "next", title: "Next", kind: .movie, resumePosition: 300)
        home.items = [next, first]
        let deadline = ContinuousClock.now + .seconds(1)
        while model.continueWatchingItems != [next, first], ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.continueWatchingItems, [next, first])
        XCTAssertEqual(reads, 2)
        home.items = []
        while !model.continueWatchingItems.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(model.continueWatchingItems.isEmpty)
        XCTAssertEqual(reads, 3)
        await model.stop()
    }

    func testReplacedAndStoppedSnapshotsCannotRearmOldObservations() async throws {
        let oldHome = ContinueWatchingHomeSnapshot()
        let currentHome = ContinueWatchingHomeSnapshot()
        let item = MediaItem(id: "new", title: "New", kind: .movie)
        currentHome.items = [item]
        var oldReads = 0
        var currentReads = 0
        var model: PlayerViewModel? = PlayerViewModel(provider: ContinueWatchingTestProvider(), itemID: "current")
        model?.continueWatchingSnapshot = { oldReads += 1; return oldHome.items }
        oldHome.items = [item]
        model?.continueWatchingSnapshot = { currentReads += 1; return currentHome.items }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model?.continueWatchingItems, [item])
        XCTAssertEqual(oldReads, 1)
        XCTAssertEqual(currentReads, 1)
        await model?.stop()
        currentHome.items = []
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model?.continueWatchingItems, [])
        XCTAssertEqual(currentReads, 1)
        weak var released = model
        model = nil
        XCTAssertNil(released, "Home observation must not retain an outgoing player.")
    }

    func testDisabledContinueWatchingDoesNotReadHome() async {
        var settings = PlaybackSettings()
        settings.continueWatchingInPlayer = false
        let model = PlayerViewModel(
            provider: ContinueWatchingTestProvider(), itemID: "current", playbackSettings: settings
        )
        var reads = 0
        model.continueWatchingSnapshot = { reads += 1; return [] }
        for _ in 0..<100 { XCTAssertTrue(model.continueWatchingItems.isEmpty) }
        XCTAssertEqual(reads, 0)
        await model.stop()
    }

    func testSelectionCanRetryButCannotRaceAnotherHandoffOrOutliveStop() async {
        let model = PlayerViewModel(provider: ContinueWatchingTestProvider(), itemID: "current")
        let first = MediaItem(id: "first", title: "First", kind: .movie)
        let second = MediaItem(id: "second", title: "Second", kind: .movie)
        model.playFromContinueWatching(first)
        model.playEpisode(second)
        model.playFromContinueWatching(second)
        XCTAssertEqual(model.pendingContinueWatching?.id, first.id)
        XCTAssertNil(model.pendingNextEpisode)
        model.cancelContinueWatchingSelection()
        model.playFromContinueWatching(second)
        XCTAssertEqual(model.pendingContinueWatching?.id, second.id)
        await model.stop()
        model.cancelContinueWatchingSelection()
        model.playFromContinueWatching(first)
        XCTAssertNil(model.pendingContinueWatching)
    }

    @MainActor @Observable
    fileprivate final class ContinueWatchingHomeSnapshot {
        var items: [MediaItem] = []
    }

    func testExcludesCurrentTitleAndSeriesOnlyOnTheSameAccount() {
        var current = MediaItem(id: "1", title: "Current", kind: .episode)
        current.sourceAccountID = "first"
        current.seriesID = "show"
        var sibling = current
        sibling.id = "2"
        var otherAccount = current
        otherAccount.sourceAccountID = "second"
        var otherShow = sibling
        otherShow.id = "3"
        otherShow.seriesID = "other-show"
        let actual = PlayerViewModel.continueWatchingItems(
            in: [current, sibling, otherAccount, otherShow], excluding: current
        )
        XCTAssertEqual(actual.map(\.stablePresentationID), [otherAccount, otherShow].map(\.stablePresentationID))
    }

    func testProviderMetadataWithoutAccountUsesPlaybackOrigin() {
        var current = MediaItem(id: "1", title: "Current", kind: .episode)
        current.seriesID = "show"
        var homeCurrent = current
        homeCurrent.sourceAccountID = "first"
        var sibling = homeCurrent
        sibling.id = "2"
        var otherAccount = homeCurrent
        otherAccount.sourceAccountID = "second"
        let actual = PlayerViewModel.continueWatchingItems(
            in: [homeCurrent, sibling, otherAccount], excluding: current, accountFallbackID: "first"
        )
        XCTAssertEqual(actual.map(\.stablePresentationID), [otherAccount.stablePresentationID])

        current.kind = .movie
        current.seriesID = nil
        homeCurrent.kind = .movie
        homeCurrent.seriesID = nil
        otherAccount.kind = .movie
        otherAccount.seriesID = nil
        let movies = PlayerViewModel.continueWatchingItems(
            in: [homeCurrent, otherAccount], excluding: current, accountFallbackID: "first"
        )
        XCTAssertEqual(movies.map(\.stablePresentationID), [otherAccount.stablePresentationID])
    }

    func testExplicitPlaybackAccountTakesPrecedenceOverFallback() {
        var current = MediaItem(id: "1", title: "Current", kind: .movie)
        current.sourceAccountID = "second"
        var otherAccount = current
        otherAccount.sourceAccountID = "first"
        let actual = PlayerViewModel.continueWatchingItems(
            in: [current, otherAccount], excluding: current, accountFallbackID: "first"
        )
        XCTAssertEqual(actual.map(\.stablePresentationID), [otherAccount.stablePresentationID])
    }

    private struct ContinueWatchingTestProvider: MediaProvider {
        let kind = ProviderKind.jellyfin
        let session = UserSession(
            server: .init(id: "fixture", name: "Fixture", baseURL: URL(string: "https://fixture.invalid")!, provider: .jellyfin),
            userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
        )
        func libraries() async throws -> [MediaLibrary] { [] }
        func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
        func latest(limit: Int) async throws -> [MediaItem] { [] }
        func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage { throw AppError.notFound }
        func item(id: String) async throws -> MediaItem { throw AppError.notFound }
        func children(of itemID: String) async throws -> [MediaItem] { [] }
        func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
        func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
        func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
        func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
    }

    func testDeduplicatesSourceQualifiedIdentityWithoutReorderingHome() {
        var first = MediaItem(id: "1", title: "First", kind: .movie)
        first.sourceAccountID = "first"
        var second = first
        second.sourceAccountID = "second"
        let actual = PlayerViewModel.continueWatchingItems(in: [second, first, second], excluding: nil)
        XCTAssertEqual(actual.map(\.stablePresentationID), [second, first].map(\.stablePresentationID))
    }
}
