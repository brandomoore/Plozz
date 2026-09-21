import AetherEngine
import CoreModels
import XCTest

final class AetherReleaseIntegrationTests: XCTestCase {
    func testResolvedEngineAndSourceCreditIdentifyMergedProbeSnapshot() throws {
        XCTAssertEqual(AetherEngine.version, "7.9.0")
        let credit = try XCTUnwrap(PlozzAttributions.entries.first { $0.title == "AetherEngine" })
        XCTAssertTrue(credit.detail.contains(
            "https://github.com/superuser404notfound/AetherEngine/tree/f55789d746a723665ed9e096ef06102d248ae2a4"
        ))
    }

    func testMergedProbeCancellationAPIIsAvailable() {
        let cancellation = ProbeCancellation()
        XCTAssertFalse(cancellation.isCancelled)
        cancellation.cancel()
        XCTAssertTrue(cancellation.isCancelled)
    }
}
