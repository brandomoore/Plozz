import UIKit
import XCTest

@MainActor
final class PosterCaptionRemoteTests: XCTestCase {
    func testRapidFocusDoesNotLeaveCaptionsBrightOrDisplaced() throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--poster-caption-fixture"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["poster-captions-ready"].waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 1)
        let baseline = try captions(in: app)
        XCTAssertGreaterThan(baseline[0].titleBrightness, 0.85)
        for index in 1..<8 {
            XCTAssertLessThan(baseline[index].titleBrightness, baseline[0].titleBrightness - 0.15)
            XCTAssertLessThan(baseline[index].yearBrightness, baseline[0].yearBrightness - 0.15)
        }
        for _ in 0..<4 {
            XCUIRemote.shared.press(.right, forDuration: 0.7)
            XCUIRemote.shared.press(.left, forDuration: 0.7)
        }
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.right, forDuration: 0.7)
        XCUIRemote.shared.press(.left, forDuration: 0.7)
        XCUIRemote.shared.press(.up)
        for _ in 0..<3 {
            XCUIRemote.shared.press(.right)
            XCUIRemote.shared.press(.playPause)
            XCUIRemote.shared.press(.left)
        }
        Thread.sleep(forTimeInterval: 1)
        let after = try captions(in: app, revision: 3)
        XCTAssertGreaterThan(after[0].titleBrightness, 0.85)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "poster-captions-after-rapid-focus"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        for index in 1..<8 {
            XCTAssertEqual(after[index].titleY, baseline[index].titleY, accuracy: 1, "Poster \(index) title position")
            XCTAssertEqual(after[index].yearY, baseline[index].yearY, accuracy: 1, "Poster \(index) year position")
            XCTAssertEqual(after[index].titleHeight, baseline[index].titleHeight, accuracy: 1, "Poster \(index) title height")
            XCTAssertEqual(after[index].yearHeight, baseline[index].yearHeight, accuracy: 1, "Poster \(index) year height")
            XCTAssertEqual(after[index].titleBrightness, baseline[index].titleBrightness, accuracy: 0.04, "Poster \(index) title brightness")
            XCTAssertEqual(after[index].yearBrightness, baseline[index].yearBrightness, accuracy: 0.04, "Poster \(index) year brightness")
        }
    }

    private struct Caption {
        let titleY: CGFloat
        let yearY: CGFloat
        let titleHeight: CGFloat
        let yearHeight: CGFloat
        let titleBrightness: Double
        let yearBrightness: Double
    }

    private func captions(in app: XCUIApplication, revision: Int = 0) throws -> [Caption] {
        let image = try XCTUnwrap(app.screenshot().image.cgImage)
        let scale = CGFloat(image.width) / app.frame.width
        return try (0..<8).map { index in
            let name = revision == 0 ? "Poster \(index)" : "Poster \(index) v\(revision)"
            let title = app.staticTexts[name].firstMatch.frame
            let year = app.staticTexts["\(2000 + index)"].firstMatch.frame
            return Caption(
                titleY: title.minY, yearY: year.minY, titleHeight: title.height, yearHeight: year.height,
                titleBrightness: try brightness(in: title, image: image, scale: scale),
                yearBrightness: try brightness(in: year, image: image, scale: scale)
            )
        }
    }

    private func brightness(in frame: CGRect, image: CGImage, scale: CGFloat) throws -> Double {
        let region = CGRect(
            x: frame.minX * scale, y: frame.minY * scale,
            width: frame.width * scale, height: frame.height * scale
        ).integral
        let crop = try XCTUnwrap(image.cropping(to: region))
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        try bytes.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(
                data: $0.baseAddress, width: crop.width, height: crop.height, bitsPerComponent: 8,
                bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        let luminance = stride(from: 0, to: bytes.count, by: 4).map {
            (Double(bytes[$0]) + Double(bytes[$0 + 1]) + Double(bytes[$0 + 2])) / (3 * 255)
        }.sorted()
        return luminance[min(luminance.count - 1, Int(Double(luminance.count) * 0.98))]
    }
}
