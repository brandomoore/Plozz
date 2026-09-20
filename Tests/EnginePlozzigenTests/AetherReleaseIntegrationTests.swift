import AetherEngine
import CoreModels
import XCTest

final class AetherReleaseIntegrationTests: XCTestCase {
    func testResolvedEngineAndSourceCreditIdentifyReleaseContainingMergedFixes() throws {
        XCTAssertEqual(AetherEngine.version, "7.8.1")
        let credit = try XCTUnwrap(PlozzAttributions.entries.first { $0.title == "AetherEngine" })
        XCTAssertTrue(credit.detail.contains(
            "https://github.com/superuser404notfound/AetherEngine/tree/\(AetherEngine.version)"
        ))
    }
}
