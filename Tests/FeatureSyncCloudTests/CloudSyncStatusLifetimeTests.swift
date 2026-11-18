import XCTest
@testable import FeatureSyncCloud

@MainActor
final class CloudSyncStatusLifetimeTests: XCTestCase {
    func testPendingErrorDoesNotRetainStatus() async {
        var status: CloudSyncStatus? = CloudSyncStatus()
        weak var observed = status
        status?.setError("Fixture error", diagnostic: nil)
        await Task.yield()
        status = nil
        XCTAssertNil(observed, "A sleeping error debounce must not own the status model.")
    }

    func testRepeatedErrorCancellationDoesNotRetainStatus() async {
        var status: CloudSyncStatus? = CloudSyncStatus()
        weak var observed = status
        for _ in 0..<128 {
            status?.setError("Fixture error", diagnostic: nil)
            await Task.yield()
            status?.setPhase(.idle)
        }
        XCTAssertEqual(status?.phase, .idle)
        status = nil
        await Task.yield()
        XCTAssertNil(observed)
    }
}
