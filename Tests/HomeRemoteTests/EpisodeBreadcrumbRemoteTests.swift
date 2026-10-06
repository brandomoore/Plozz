import UIKit
import XCTest

@MainActor
final class EpisodeBreadcrumbRemoteTests: XCTestCase {
    func testEpisodeOpenedFromHomeCanOpenItsShow() throws {
        try verifyBreadcrumb(fromShow: false)
    }

    func testEpisodeOpenedFromShowCanOpenItsShow() throws {
        try verifyBreadcrumb(fromShow: true)
    }

    func testUpcomingEpisodeCanOpenItsShowWithoutAPlayButton() throws {
        try verifyBreadcrumb(fromShow: false, upcoming: true)
    }

    private func verifyBreadcrumb(fromShow: Bool, upcoming: Bool = false) throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--episode-breadcrumb-fixture"] + (fromShow ? ["--from-show"] : [])
        if upcoming { app.launchArguments.append("--upcoming") }
        app.launch()
        defer { app.terminate() }
        let play = app.buttons["detail-hero-play"]
        let breadcrumb = app.buttons["Go to Fixture Show"]
        XCTAssertTrue(breadcrumb.waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons.matching(identifier: "Go to Fixture Show").count, 1)
        if upcoming {
            XCTAssertFalse(play.exists)
        } else {
            XCTAssertTrue(play.waitForExistence(timeout: 15))
            waitFor { play.hasFocus }
            let before = app.screenshot()
            attach(before, name: "episode-breadcrumb-before-focus")
            XCTAssertGreaterThan(try brightPixels(in: before, frame: breadcrumb.frame), 100,
                                 "The show title must be visible before it is focused.")
            XCUIRemote.shared.press(.up)
        }
        waitFor { breadcrumb.hasFocus }
        attach(app.screenshot(), name: "episode-breadcrumb-focused")
        XCUIRemote.shared.press(.select)
        waitFor { app.staticTexts["breadcrumb-route"].label == "show|season-2|breadcrumb-account" }
        attach(app.screenshot(), name: "episode-breadcrumb-opened-show")
        XCUIRemote.shared.press(.menu)
        waitFor { app.staticTexts["breadcrumb-route"].label == "episode|season-2|breadcrumb-account" }
    }

    private func waitFor(file: StaticString = #filePath, line: UInt = #line, _ condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 8), .completed, file: file, line: line)
    }

    private func attach(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func brightPixels(in screenshot: XCUIScreenshot, frame: CGRect) throws -> Int {
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let crop = try XCTUnwrap(image.cropping(to: frame))
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        try bytes.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(
                data: $0.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        return stride(from: 0, to: bytes.count, by: 4).filter {
            bytes[$0] > 140 && bytes[$0 + 1] > 140 && bytes[$0 + 2] > 140
        }.count
    }
}
