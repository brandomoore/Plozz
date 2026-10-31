#if canImport(SwiftUI)
import CoreModels
@testable import FeatureSettings
import XCTest

@MainActor
final class DiscoveredLibrariesStoreTests: XCTestCase {
    func testRefreshRetainsLoadedRowsAndTracksChangedAccount() {
        let existing = AggregatedLibrary(
            accountID: "existing",
            accountName: "Existing",
            serverName: "Server",
            providerKind: .jellyfin,
            library: MediaLibrary(id: "movies", title: "Movies", kind: .movie)
        )
        let store = DiscoveredLibrariesStore()
        store.state = .loaded([existing])

        store.beginRefresh(accountIDs: ["new"])

        XCTAssertEqual(store.state.value, [existing])
        XCTAssertEqual(store.refreshingAccountIDs, ["new"])
    }

    func testFinishingRefreshReplacesRowsAndClearsRefreshMarkers() {
        let store = DiscoveredLibrariesStore()
        store.beginRefresh(accountIDs: ["new"])
        XCTAssertTrue(store.state.isLoading)

        store.finishRefresh(with: [])

        XCTAssertEqual(store.state, .empty)
        XCTAssertTrue(store.refreshingAccountIDs.isEmpty)
    }

    func testAuthenticationFailureRemainsDistinctFromOfflineAndClearsAfterRecovery() {
        let store = DiscoveredLibrariesStore()
        store.finishRefresh(
            with: [], unreachableAccountIDs: ["server"],
            failures: ["server": .unauthorized]
        )
        XCTAssertEqual(store.failures["server"], .unauthorized)
        XCTAssertTrue(store.failures["server"]?.requiresSignIn == true)
        XCTAssertFalse(AppError.serverUnreachable.requiresSignIn)
        store.finishRefresh(with: [])
        XCTAssertTrue(store.failures.isEmpty)
        XCTAssertTrue(store.unreachableAccountIDs.isEmpty)
    }

    func testCancellationClearsOnlyItsOwnRefreshAndRestoresPreviousState() {
        let store = DiscoveredLibrariesStore()
        store.state = .failed(.unauthorized)
        let first = store.beginRefresh(accountIDs: ["first"])
        let second = store.beginRefresh(accountIDs: ["second"])
        store.cancelRefresh(second)
        XCTAssertTrue(store.state.isLoading)
        XCTAssertEqual(store.refreshingAccountIDs, ["first"])
        store.cancelRefresh(first)
        XCTAssertEqual(store.state, .failed(.unauthorized))
        XCTAssertTrue(store.refreshingAccountIDs.isEmpty)
    }

    func testOldCancellationCannotClearNewRefreshOrReplacePublishedRows() {
        let store = DiscoveredLibrariesStore()
        let first = store.beginRefresh(accountIDs: ["first"])
        let second = store.beginRefresh(accountIDs: ["second"])
        store.finishRefresh(with: [], request: second)
        XCTAssertEqual(store.state, .empty)
        XCTAssertEqual(store.refreshingAccountIDs, ["first"])
        let third = store.beginRefresh(accountIDs: ["third"])
        store.cancelRefresh(first)
        XCTAssertEqual(store.refreshingAccountIDs, ["third"])
        store.cancelRefresh(third)
        XCTAssertEqual(store.state, .empty)
        XCTAssertTrue(store.refreshingAccountIDs.isEmpty)
    }
}
#endif
