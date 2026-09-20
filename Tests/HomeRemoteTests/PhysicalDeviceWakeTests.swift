import XCTest

/// Explicitly approved wake only. A completed call does not prove active rendering.
@MainActor
final class PhysicalDeviceWakeTests: XCTestCase {
    func testWakePhysicalAppleTVWithOneHomePress() throws {
        #if !os(tvOS) || targetEnvironment(simulator)
        throw XCTSkip("Physical Apple TV wake only.")
        #else
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["PLOZZ_HOME_TARGET_DEVICE"]?.isEmpty == false
                && environment["PLOZZ_APPROVED_WAKE_DEVICE"] == environment["PLOZZ_HOME_TARGET_DEVICE"],
            "Requires explicit approval to wake the selected Apple TV and possibly its HDMI display."
        )
        continueAfterFailure = false
        executionTimeAllowance = 30
        print("PLZREMOTE_WAKE home.begin count=1")
        XCUIRemote.shared.press(.home)
        print("PLZREMOTE_WAKE home.returned count=1")
        #endif
    }

}
