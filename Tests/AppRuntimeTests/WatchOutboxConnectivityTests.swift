import XCTest
@testable import AppRuntime

@MainActor
final class WatchOutboxConnectivityTests: XCTestCase {
    func testInitialConnectionAndReconnectTriggerButDuplicateUpdatesDoNot() {
        var retries = 0
        let connectivity = WatchOutboxConnectivity(monitor: nil) { retries += 1 }
        XCTAssertFalse(connectivity.isConnected)
        connectivity.update(isConnected: false)
        XCTAssertEqual(retries, 0)
        connectivity.update(isConnected: true)
        XCTAssertTrue(connectivity.isConnected)
        XCTAssertEqual(retries, 1)
        connectivity.update(isConnected: true)
        XCTAssertEqual(retries, 1)
        connectivity.update(isConnected: false)
        XCTAssertFalse(connectivity.isConnected)
        connectivity.update(isConnected: true)
        XCTAssertEqual(retries, 2)
    }
}
