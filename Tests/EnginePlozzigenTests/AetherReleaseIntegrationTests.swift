import AetherEngine
import CoreModels
import XCTest

final class AetherReleaseIntegrationTests: XCTestCase {
    func testResolvedEngineAndSourceCreditIdentifyReleasedProbeControls() throws {
        XCTAssertEqual(AetherEngine.version, "7.10.0")
        let credit = try XCTUnwrap(PlozzAttributions.entries.first { $0.title == "AetherEngine" })
        XCTAssertTrue(credit.detail.contains(
            "https://github.com/superuser404notfound/AetherEngine/tree/\(AetherEngine.version)"
        ))
    }

    func testReleasedProbeCancellationAPIIsAvailable() {
        let cancellation = ProbeCancellation()
        XCTAssertFalse(cancellation.isCancelled)
        cancellation.cancel()
        XCTAssertTrue(cancellation.isCancelled)
    }
}
