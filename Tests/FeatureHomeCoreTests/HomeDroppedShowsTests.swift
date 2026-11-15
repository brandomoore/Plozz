import CoreModels
import XCTest
@testable import FeatureHomeCore

/// A dropped show leaves Continue Watching, Next Up and Upcoming — including a
/// server's own versions of those rows — and nothing else.
@MainActor
final class HomeDroppedShowsTests: XCTestCase {
    private func episode(_ id: String, series: String) -> MediaItem {
        var item = MediaItem(id: id, title: id, kind: .episode, sourceAccountID: "jellyfin")
        item.seriesID = series
        return item
    }

    private func model() -> DroppedShowsModel {
        DroppedShowsModel(store: DroppedShowsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!))
    }

    private func serverRow(_ kind: ServerHomeSection.Kind, _ items: [MediaItem]) -> HomeServerRow {
        HomeServerRow(
            definition: HomeServerRowDefinition(
                accountID: "jellyfin", serverName: "Home", providerKind: .jellyfin,
                section: ServerHomeSection(id: "web:\(kind.rawValue)", kind: kind)
            ),
            items: items
        )
    }

    private var content: HomeViewModel.Content {
        HomeViewModel.Content(
            continueWatching: [episode("cw-dropped", series: "dropped"), episode("cw-kept", series: "kept")],
            latest: [episode("latest-dropped", series: "dropped")],
            serverRows: [
                serverRow(.nextUp, [episode("next-dropped", series: "dropped"), episode("next-kept", series: "kept")]),
                serverRow(.recentlyAdded, [episode("added-dropped", series: "dropped")])
            ]
        )
    }

    func testDroppedShowsLeaveTheRowsADropClears() {
        let dropped = model()
        dropped.drop(episode("any", series: "dropped"))
        let visible = content.excludingDroppedShows(dropped)

        XCTAssertEqual(visible.continueWatching.map(\.id), ["cw-kept"])
        XCTAssertEqual(visible.serverRows[0].items.map(\.id), ["next-kept"])
    }

    /// Dropping is about what Home suggests watching next, not about hiding that
    /// the show exists.
    func testDiscoveryRowsAreLeftAlone() {
        let dropped = model()
        dropped.drop(episode("any", series: "dropped"))
        let visible = content.excludingDroppedShows(dropped)

        XCTAssertEqual(visible.latest.map(\.id), ["latest-dropped"])
        XCTAssertEqual(visible.serverRows[1].items.map(\.id), ["added-dropped"])
    }

    func testNothingDroppedLeavesContentUntouched() {
        XCTAssertEqual(content.excludingDroppedShows(model()), content)
    }

    /// Every write to Home's state is filtered — here a cached snapshot — and a
    /// drop made later takes effect at once, without a reload.
    func testHomeStateLeavesOutDroppedShowsAndFollowsNewDrops() {
        let dropped = model()
        dropped.drop(episode("any", series: "dropped"))
        let store = InMemoryHomeContentStore()
        store.save(content)
        let viewModel = HomeViewModel(accounts: [], contentStore: store, droppedShows: dropped)

        XCTAssertEqual(viewModel.state.value?.serverRows[0].items.map(\.id), ["next-kept"])

        dropped.drop(episode("any", series: "kept"))
        XCTAssertEqual(viewModel.state.value?.serverRows[0].items.map(\.id), [])
    }
}
