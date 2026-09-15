import UIKit
import XCTest

@MainActor
final class CastFocusRemoteTests: XCTestCase {
    func testSystemCastFocusStaysCircularAndClearOfTheName() throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--cast-focus-fixture"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["cast-fixture-ready"].waitForExistence(timeout: 15))
        XCUIRemote.shared.press(.left)
        Thread.sleep(forTimeInterval: 1)
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "system-cast-focus"
        attachment.lifetime = .keepAlways
        add(attachment)
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let pixels = try rgbaPixels(image)
        let red = try redBounds(pixels, width: image.width, height: image.height)
        let scale = CGFloat(image.width) / app.frame.width
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        XCTAssertTrue(focused.exists)
        XCTAssertEqual(focused.frame.midX, red.midX / scale, accuracy: 2)
        let name = app.descendants(matching: .any)["cast-name-first"].firstMatch
        XCTAssertTrue(name.exists)
        XCTAssertEqual(red.width, red.height, accuracy: 3 * scale)
        XCTAssertLessThanOrEqual(red.maxY / scale + 8, name.frame.minY, "The portrait must not overlap its caption.")
        for point in [
            CGPoint(x: red.minX + 4, y: red.minY + 4),
            CGPoint(x: red.maxX - 4, y: red.minY + 4)
        ] {
            let index = (Int(point.y) * image.width + Int(point.x)) * 4
            XCTAssertLessThan(pixels[index..<index + 3].max() ?? 255, 20, "Focus must not add a square platter.")
        }
        XCUIRemote.shared.press(.select)
        let opened = app.staticTexts["cast-opened"]
        let predicate = NSPredicate { _, _ in opened.exists && opened.label == "Casey Example" }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 5), .completed)
    }

    private func redBounds(_ bytes: [UInt8], width: Int, height: Int) throws -> CGRect {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                if bytes[index] > 180, bytes[index + 1] < 90, bytes[index + 2] < 90 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        XCTAssertGreaterThan(maxX, minX, "Portrait artwork must actually be loaded.")
        guard maxX > minX, maxY > minY else { throw NSError(domain: "CastFocusFixture", code: 1) }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(
                data: $0.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}
