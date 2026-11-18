#if canImport(SwiftUI)
import XCTest
import CoreModels
import SeerService
@testable import AppShell

final class SeerRequestResultTests: XCTestCase {
    func testAlternateDestinationConfirmsWithoutChangingAvailability() {
        let result = seerRequestResult(.successElsewhere("Request sent."), actingName: nil)
        XCTAssertNil(result.status)
        XCTAssertNil(result.failureMessage)
        XCTAssertEqual(result.confirmation, "Request sent.")
        XCTAssertFalse(result.isSuccess)
    }

    func testCancelledAccountChoiceDoesNotShowFailure() {
        let result = seerRequestResult(.failure(.cancelled), actingName: nil)
        XCTAssertNil(result.status)
        XCTAssertNil(result.failureMessage)
        XCTAssertNil(result.confirmation)
        XCTAssertFalse(result.isSuccess)
    }

    func testStaleMappingSurfacesRelinkInsteadOfAdministratorRequest() {
        let result = seerRequestResult(.failure(.mappingNeedsRelink), actingName: nil)
        XCTAssertNil(result.status)
        XCTAssertEqual(result.failureTitle, "Relink Seerr User")
        XCTAssertEqual(
            result.failureMessage,
            .copy(SeerRequestFailure.mappingNeedsRelink.userMessage)
        )
        XCTAssertFalse(result.isSuccess)
    }
}
#endif
