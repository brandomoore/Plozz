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
}
#endif
