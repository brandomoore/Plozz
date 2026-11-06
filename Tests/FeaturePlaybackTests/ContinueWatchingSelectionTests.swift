import CoreModels
import XCTest
@testable import FeaturePlayback

@MainActor
final class ContinueWatchingSelectionTests: XCTestCase {
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
