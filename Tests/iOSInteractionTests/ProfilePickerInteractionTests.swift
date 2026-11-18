import UIKit
import XCTest

@MainActor
final class ProfilePickerInteractionTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
    }

    override func tearDown() async throws {
        if app.state == .runningForeground {
            let image = XCTAttachment(screenshot: app.screenshot())
            image.lifetime = .keepAlways
            add(image)
        }
        app.terminate()
        app = nil
        try await super.tearDown()
    }

    func testSelectionCancelAndFreshPresentation() {
        launch()
        XCTAssertFalse(app.staticTexts["Choose a profile to continue."].exists)
        app.buttons["Alex"].tap()
        XCTAssertTrue(app.staticTexts["fixture-profile-result"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["fixture-profile-result"].label, "Alex")
        app.buttons["Open picker"].tap()
        XCTAssertTrue(app.buttons["Sam"].waitForExistence(timeout: 3))
        app.buttons["profile-picker-close"].tap()
        XCTAssertEqual(app.staticTexts["fixture-profile-result"].label, "Cancelled")
    }

    func testEditModeAndLongPressPushOneProfilePage() {
        launch()
        app.buttons["profile-picker-options"].tap()
        app.buttons["profile-picker-edit"].tap()
        XCTAssertFalse(app.buttons["Add Profile"].exists)
        XCTAssertFalse(app.buttons["profile-picker-close"].exists)
        app.buttons["Alex"].tap()
        XCTAssertTrue(app.navigationBars["Alex"].waitForExistence(timeout: 3), app.debugDescription)
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(app.buttons["profile-picker-edit"].waitForExistence(timeout: 3))
        app.buttons["profile-picker-edit"].tap()
        XCTAssertTrue(app.buttons["Add Profile"].waitForExistence(timeout: 3))
        app.buttons["Sam"].press(forDuration: 1)
        app.buttons["Edit Profile"].tap()
        XCTAssertTrue(app.navigationBars["Sam"].waitForExistence(timeout: 3))
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(app.buttons["Alex"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.navigationBars.buttons["BackButton"].exists)
    }

    func testAdultAndKidsCreationRemainSeparateEntryPoints() {
        for title in ["Add Profile", "Add Kids Profile"] {
            launch()
            app.buttons[title].tap()
            XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 3), app.debugDescription)
            XCTAssertTrue(app.textFields.firstMatch.exists, app.debugDescription)
            app.buttons["Cancel"].tap()
            if app.alerts["Discard changes?"].waitForExistence(timeout: 1) {
                app.alerts.buttons["Discard"].tap()
            }
            XCTAssertTrue(app.staticTexts["fixture-profile-result"].waitForExistence(timeout: 3))
            XCTAssertEqual(app.staticTexts["fixture-profile-result"].label, "Cancelled")
        }
    }

    func testRestrictedLaunchPickerExposesNoManagementOrDismissal() {
        launch(["--restricted-picker", "--launch-picker"])
        XCTAssertFalse(app.buttons["profile-picker-edit"].exists)
        XCTAssertFalse(app.buttons["profile-picker-close"].exists)
        XCTAssertFalse(app.buttons["Add Profile"].exists)
        XCTAssertFalse(app.buttons["Add Kids Profile"].exists)
        app.buttons["Jamie"].tap()
        XCTAssertTrue(app.staticTexts["fixture-profile-result"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["fixture-profile-result"].label, "Jamie")
    }

    func testPlexPINStaysInsidePickerAndCancelReturnsToProfiles() throws {
        app.launchArguments = ["--profile-selection-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["Protected"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["Protected"].value as? String, "Profile Lock")
        let pickerTitleHeight = app.staticTexts["Who’s watching?"].frame.height
        app.buttons["Protected"].tap()
        XCTAssertTrue(app.staticTexts["Plex PIN"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(
            app.staticTexts["profile-pin-name"].frame.height, pickerTitleHeight, accuracy: 1,
            "The profile name must become the PIN screen's primary heading."
        )
        XCTAssertEqual(app.staticTexts["profile-pin-name"].label, "Protected")
        XCTAssertFalse(app.staticTexts["Server identity"].exists)
        XCTAssertLessThan(app.staticTexts["pin-entry-title"].frame.height, pickerTitleHeight)
        try assertHomeIsCovered()
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Protected"].waitForExistence(timeout: 5), app.debugDescription)
        try assertHomeIsCovered()
        app.buttons["Protected"].tap()
        XCTAssertTrue(app.buttons["2"].waitForExistence(timeout: 5))
        for digit in ["2", "4", "6", "8"] { app.buttons[digit].tap() }
        let result = app.staticTexts["fixture-selection-result"]
        XCTAssertTrue(result.wait(for: \.isHittable, toEqual: true, timeout: 8), app.debugDescription)
        XCTAssertEqual(result.label, "Selected")
    }

    func testProfilePINFlowsDirectlyIntoPlexPINBeforeCompletion() throws {
        app.launchArguments = ["--profile-selection-fixture", "--two-pins"]
        app.launch()
        XCTAssertTrue(app.buttons["Protected"].waitForExistence(timeout: 10))
        app.buttons["Protected"].tap()
        XCTAssertTrue(app.buttons["1"].waitForExistence(timeout: 5))
        try assertHomeIsCovered()
        for digit in ["1", "2", "3", "4"] { app.buttons[digit].tap() }
        XCTAssertTrue(app.staticTexts["Plex PIN"].waitForExistence(timeout: 5), app.debugDescription)
        try assertHomeIsCovered()
        for digit in ["2", "4", "6", "8"] { app.buttons[digit].tap() }
        let result = app.staticTexts["fixture-selection-result"]
        XCTAssertTrue(result.wait(for: \.isHittable, toEqual: true, timeout: 8), app.debugDescription)
        XCTAssertEqual(result.label, "Selected")
    }

    func testDisabledPlexSourceDoesNotAdvertiseOrAskForPIN() {
        app.launchArguments = ["--profile-selection-fixture", "--disabled-plex-source"]
        app.launch()
        let profile = app.buttons["Protected"]
        XCTAssertTrue(profile.waitForExistence(timeout: 10))
        XCTAssertEqual(profile.value as? String ?? "", "")
        profile.tap()
        let result = app.staticTexts["fixture-selection-result"]
        XCTAssertTrue(result.wait(for: \.isHittable, toEqual: true, timeout: 5))
        XCTAssertEqual(result.label, "Selected")
        XCTAssertFalse(app.buttons["1"].exists)
        XCTAssertFalse(app.staticTexts["Plex PIN"].exists)
    }

    func testDisabledPlexSourceStillAdvertisesAndRequiresMatchingLocalPIN() {
        app.launchArguments = ["--profile-selection-fixture", "--disabled-plex-source", "--matched-plex-pin"]
        app.launch()
        let profile = app.buttons["Protected"]
        XCTAssertTrue(profile.waitForExistence(timeout: 10))
        XCTAssertEqual(profile.value as? String, "Profile Lock")
        profile.tap()
        enterPIN(["2", "4", "6", "8"])
        XCTAssertTrue(app.staticTexts["fixture-selection-result"].wait(
            for: \.isHittable, toEqual: true, timeout: 5
        ))
        XCTAssertFalse(app.staticTexts["Plex PIN"].exists)
    }

    func testLocalToPlexAndBackRequiresTheLocalPINAgain() throws {
        app.launchArguments = ["--profile-selection-fixture", "--local-profile"]
        app.launch()
        XCTAssertTrue(app.buttons["Local"].waitForExistence(timeout: 10))
        app.buttons["Local"].tap()
        enterPIN(["1", "3", "5", "7"])
        let result = app.staticTexts["fixture-selection-result"]
        XCTAssertTrue(result.wait(for: \.isHittable, toEqual: true, timeout: 5))
        app.buttons["Open picker"].tap()
        XCTAssertTrue(app.buttons["Protected"].waitForExistence(timeout: 5))
        app.buttons["Protected"].tap()
        enterPIN(["2", "4", "6", "8"])
        XCTAssertTrue(result.wait(for: \.isHittable, toEqual: true, timeout: 5))
        app.buttons["Open picker"].tap()
        XCTAssertTrue(app.buttons["Local"].waitForExistence(timeout: 5))
        app.buttons["Local"].tap()
        XCTAssertTrue(app.buttons["1"].waitForExistence(timeout: 5), app.debugDescription)
        try assertHomeIsCovered()
        enterPIN(["1", "3", "5", "7"])
        XCTAssertTrue(result.wait(for: \.isHittable, toEqual: true, timeout: 5))
    }

    func testMatchingPINCompletesWithoutAnEmptyOrSecondPINPage() {
        app.launchArguments = [
            "--profile-selection-fixture", "--matched-plex-pin", "--slow-plex-authentication"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["Protected"].waitForExistence(timeout: 10))
        app.buttons["Protected"].tap()
        enterPIN(["2", "4", "6", "8"])
        XCTAssertTrue(app.staticTexts["Enter your PIN"].exists, app.debugDescription)
        XCTAssertTrue(app.buttons["1"].exists, "Keep the entered PIN surface while authentication finishes.")
        XCTAssertFalse(app.staticTexts["Plex PIN"].exists)
        XCTAssertTrue(app.staticTexts["fixture-selection-result"].wait(
            for: \.isHittable, toEqual: true, timeout: 6
        ))
    }

    private func enterPIN(_ digits: [String]) {
        XCTAssertTrue(app.buttons[digits[0]].wait(for: \.isHittable, toEqual: true, timeout: 5))
        for digit in digits { app.buttons[digit].tap() }
    }

    func testPlexVerificationMovesProfileIdentityBeforeRevealingPIN() throws {
        app.launchArguments = ["--profile-selection-fixture", "--slow-plex-check"]
        app.launch()
        let profile = app.buttons["Protected"]
        XCTAssertTrue(profile.waitForExistence(timeout: 10))
        let originalFrame = profile.frame
        profile.tap()
        XCTAssertTrue(app.staticTexts["profile-pin-name"].waitForExistence(timeout: 2), app.debugDescription)
        XCTAssertEqual(app.staticTexts["profile-pin-name"].label, "Protected")
        XCTAssertFalse(app.progressIndicators["profile-picker-verifying"].exists)
        XCTAssertFalse(app.otherElements["pin-requirement-check"].exists)
        XCTAssertFalse(app.buttons["1"].exists)
        XCTAssertFalse(app.staticTexts["Plex PIN"].exists)
        XCTAssertFalse(app.buttons["Alex"].isHittable)
        XCTAssertFalse(app.buttons["profile-picker-edit"].exists)
        try assertHomeIsCovered()
        XCTAssertTrue(app.staticTexts["Plex PIN"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["profile-picker-close"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "Cancel").count, 1)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(profile.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        XCTAssertEqual(profile.frame.midX, originalFrame.midX, accuracy: 1)
        XCTAssertEqual(profile.frame.midY, originalFrame.midY, accuracy: 1)
        try assertHomeIsCovered()
    }

    func testCancellingPlexVerificationReturnsToPickerWithoutALatePIN() throws {
        app.launchArguments = ["--profile-selection-fixture", "--slow-plex-check"]
        app.launch()
        XCTAssertTrue(app.buttons["Protected"].waitForExistence(timeout: 10))
        app.buttons["Protected"].tap()
        XCTAssertTrue(app.staticTexts["profile-pin-name"].waitForExistence(timeout: 2), app.debugDescription)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Alex"].wait(for: \.isEnabled, toEqual: true, timeout: 5))
        XCTAssertFalse(app.staticTexts["Plex PIN"].waitForExistence(timeout: 6))
        try assertHomeIsCovered()
        app.buttons["Alex"].tap()
        XCTAssertTrue(app.staticTexts["fixture-selection-result"].wait(for: \.isHittable, toEqual: true, timeout: 5))
    }

    func testUnprotectedPlexVerificationCompletesWithoutAPINPage() throws {
        app.launchArguments = [
            "--profile-selection-fixture", "--slow-plex-check", "--unprotected-plex-check"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["Protected"].waitForExistence(timeout: 10))
        app.buttons["Protected"].tap()
        XCTAssertTrue(app.staticTexts["profile-pin-name"].waitForExistence(timeout: 2), app.debugDescription)
        XCTAssertFalse(app.buttons["1"].exists)
        XCTAssertFalse(app.otherElements["pin-requirement-check"].exists)
        try assertHomeIsCovered()
        XCTAssertTrue(app.staticTexts["fixture-selection-result"].wait(for: \.isHittable, toEqual: true, timeout: 8))
        XCTAssertEqual(app.staticTexts["fixture-selection-result"].label, "Selected")
        XCTAssertFalse(app.staticTexts["Plex PIN"].exists)
    }

    func testLaunchPickerCancellationStaysInsideSelectionUntilAnotherProfileIsChosen() throws {
        app.launchArguments = ["--profile-selection-fixture", "--launch-selection"]
        app.launch()
        XCTAssertTrue(app.buttons["Protected"].waitForExistence(timeout: 10))
        app.buttons["Protected"].tap()
        XCTAssertTrue(app.staticTexts["Plex PIN"].waitForExistence(timeout: 5), app.debugDescription)
        try assertHomeIsCovered()
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Alex"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["profile-picker-close"].exists)
        try assertHomeIsCovered()
        app.buttons["Alex"].tap()
        let result = app.staticTexts["fixture-selection-result"]
        XCTAssertTrue(result.wait(for: \.isHittable, toEqual: true, timeout: 8), app.debugDescription)
        XCTAssertEqual(result.label, "Selected")
    }

    func testInitialProfileLockWaitsForTapThenContinuesToPlex() throws {
        app.launchArguments = [
            "--profile-selection-fixture", "--launch-selection", "--two-pins",
            "--initial-profile-lock"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["Protected"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["1"].exists, "An existing lock must wait for an explicit profile tap.")
        XCTAssertFalse(app.buttons["profile-picker-close"].exists)
        try assertHomeIsCovered()
        app.buttons["Protected"].tap()
        XCTAssertTrue(app.buttons["1"].waitForExistence(timeout: 5), app.debugDescription)
        try assertHomeIsCovered()
        for digit in ["1", "2", "3", "4"] { app.buttons[digit].tap() }
        XCTAssertTrue(app.staticTexts["Plex PIN"].waitForExistence(timeout: 5), app.debugDescription)
        try assertHomeIsCovered()
        for digit in ["2", "4", "6", "8"] { app.buttons[digit].tap() }
        let result = app.staticTexts["fixture-selection-result"]
        XCTAssertTrue(result.wait(for: \.isHittable, toEqual: true, timeout: 8), app.debugDescription)
        XCTAssertEqual(result.label, "Selected")
    }

    func testPendingPlexRequestWaitsForAnExplicitProfileTap() throws {
        for launchArguments in [[], ["--launch-selection"]] {
            if app.state != .notRunning { app.terminate() }
            app.launchArguments = ["--profile-selection-fixture", "--initial-plex-pin"] + launchArguments
            app.launch()
            XCTAssertTrue(app.buttons["Protected"].waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertFalse(app.staticTexts["Plex PIN"].exists)
            XCTAssertFalse(app.buttons["1"].exists)
            try assertHomeIsCovered()
            app.buttons["Protected"].tap()
            XCTAssertTrue(app.staticTexts["Plex PIN"].waitForExistence(timeout: 5))
            try assertHomeIsCovered()
            app.buttons["Cancel"].tap()
            XCTAssertTrue(app.buttons["Alex"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["1"].exists)
            app.buttons["Alex"].tap()
            let result = app.staticTexts["fixture-selection-result"]
            XCTAssertTrue(result.wait(for: \.isHittable, toEqual: true, timeout: 8), app.debugDescription)
            XCTAssertEqual(result.label, "Selected")
        }
    }

    func testPendingProfileLockDoesNotPreventChoosingADifferentProfile() throws {
        app.launchArguments = [
            "--profile-selection-fixture", "--launch-selection", "--two-pins",
            "--initial-profile-lock"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["Alex"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["1"].exists)
        try assertHomeIsCovered()
        app.buttons["Alex"].tap()
        let result = app.staticTexts["fixture-selection-result"]
        XCTAssertTrue(result.wait(for: \.isHittable, toEqual: true, timeout: 8), app.debugDescription)
        XCTAssertEqual(result.label, "Selected")
        XCTAssertFalse(app.buttons["1"].exists)
    }

    func testCancellingPlexWithLockedFallbackAllowsANewSelection() throws {
        app.launchArguments = ["--profile-selection-fixture", "--locked-fallback"]
        app.launch()
        XCTAssertTrue(app.buttons["Protected"].waitForExistence(timeout: 10))
        app.buttons["Protected"].tap()
        XCTAssertTrue(app.staticTexts["Plex PIN"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Protected"].waitForExistence(timeout: 5), app.debugDescription)
        try assertHomeIsCovered()
        app.buttons["Protected"].tap()
        XCTAssertTrue(app.staticTexts["Plex PIN"].waitForExistence(timeout: 5), app.debugDescription)
        try assertHomeIsCovered()
        for digit in ["2", "4", "6", "8"] { app.buttons[digit].tap() }
        let result = app.staticTexts["fixture-selection-result"]
        XCTAssertTrue(result.wait(for: \.isHittable, toEqual: true, timeout: 8), app.debugDescription)
        XCTAssertEqual(result.label, "Selected")
    }

    func testFailedPlexVerificationRetainsProfileIdentityAndAllowsRetry() throws {
        app.launchArguments = ["--profile-selection-fixture", "--failed-plex-check"]
        app.launch()
        XCTAssertTrue(app.buttons["Protected"].waitForExistence(timeout: 10))
        app.buttons["Protected"].tap()
        XCTAssertTrue(app.buttons["Try Again"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["profile-pin-name"].label, "Protected")
        XCTAssertFalse(app.buttons["1"].exists)
        try assertHomeIsCovered()
        app.buttons["Try Again"].tap()
        XCTAssertTrue(app.buttons["Try Again"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["profile-pin-name"].label, "Protected")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Protected"].waitForExistence(timeout: 5))
    }

    private func assertHomeIsCovered(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(app.staticTexts["fixture-selection-result"].isHittable, file: file, line: line)
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "picker-or-pin-covered"
        attachment.lifetime = .keepAlways
        add(attachment)
        let image = try XCTUnwrap(screenshot.image.cgImage)
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &rgba, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let exposedHome = stride(from: 0, to: rgba.count, by: 4).filter {
            rgba[$0] > 180 && rgba[$0 + 1] < 80 && rgba[$0 + 2] > 180
        }.count
        XCTAssertLessThan(exposedHome, 10, "The magenta Home backdrop must remain covered.", file: file, line: line)
    }

    private func launch(_ arguments: [String] = []) {
        if app.state != .notRunning { app.terminate() }
        app.launchArguments = ["--profile-picker-fixture"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["Alex"].waitForExistence(timeout: 10), app.debugDescription)
    }
}
