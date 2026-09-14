import UIKit
import XCTest

@MainActor
final class PosterCaptionRemoteTests: XCTestCase {
    func testLongNativeCaptionStillScrollsAndResetsWhenFocusLeaves() throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--poster-caption-fixture", "--poster-caption-long-title"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["poster-captions-ready"].waitForExistence(timeout: 15))
        let title = "A long poster title with enough words to scroll across the artwork"
        let poster = app.descendants(matching: .any).matching(identifier: title).firstMatch
        XCTAssertTrue(poster.waitForExistence(timeout: 5))
        XCTAssertLessThan(poster.frame.width, 250, "Overflow must not widen the artwork.")
        let resting = try titlePixels(in: app, below: poster)
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(poster.hasFocus)
        let focused = try titlePixels(in: app, below: poster)
        let deadline = Date().addingTimeInterval(6)
        var movement = 0.0
        repeat {
            Thread.sleep(forTimeInterval: 0.25)
            movement = try pixelDifference(focused, titlePixels(in: app, below: poster))
        } while movement < 0.02 && Date() < deadline
        XCTAssertGreaterThan(movement, 0.02, "The focused long caption must visibly scroll.")
        XCUIRemote.shared.press(.left)
        XCTAssertFalse(poster.hasFocus)
        XCTAssertLessThan(
            try pixelDifference(resting, titlePixels(in: app, below: poster)), 0.005,
            "Leaving focus must restore the same dim, unscrolled caption."
        )
    }

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
        XCUIRemote.shared.press(.right)
        let moved = try captions(in: app)
        XCTAssertGreaterThan(moved[1].titleBrightness, 0.85)
        XCTAssertLessThan(moved[0].titleBrightness, moved[1].titleBrightness - 0.15)
        for index in 0..<8 {
            XCTAssertEqual(moved[index].titleY, baseline[index].titleY, accuracy: 1, "Focus must not move title \(index)")
            XCTAssertEqual(moved[index].yearY, baseline[index].yearY, accuracy: 1, "Focus must not move year \(index)")
        }
        XCUIRemote.shared.press(.left)
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

    private func titlePixels(in app: XCUIApplication, below poster: XCUIElement) throws -> [UInt8] {
        let image = try XCTUnwrap(app.screenshot().image.cgImage)
        let scale = CGFloat(image.width) / app.frame.width
        let title = try captionBands(below: poster.frame, image: image, scale: scale)[0]
        let region = CGRect(x: title.minX * scale, y: title.minY * scale,
                            width: title.width * scale, height: title.height * scale).integral
        return try pixels(XCTUnwrap(image.cropping(to: region)))
    }

    private func pixelDifference(_ lhs: [UInt8], _ rhs: [UInt8]) throws -> Double {
        XCTAssertEqual(lhs.count, rhs.count, "Scrolling must not resize the caption.")
        guard !lhs.isEmpty, lhs.count == rhs.count else {
            throw NSError(domain: "PosterCaptionFixture", code: 2)
        }
        let difference = zip(lhs, rhs).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) }
        return difference / Double(lhs.count) / 255
    }

    private func captions(in app: XCUIApplication, revision: Int = 0) throws -> [Caption] {
        let image = try XCTUnwrap(app.screenshot().image.cgImage)
        let scale = CGFloat(image.width) / app.frame.width
        return try (0..<8).map { index in
            let name = revision == 0 ? "Poster \(index)" : "Poster \(index) v\(revision)"
            let artwork = app.descendants(matching: .any).matching(identifier: name).firstMatch.frame
            let bands = try captionBands(below: artwork, image: image, scale: scale)
            let title = bands[0]
            let year = bands[1]
            return Caption(
                titleY: title.minY, yearY: year.minY, titleHeight: title.height, yearHeight: year.height,
                titleBrightness: try brightness(in: title, image: image, scale: scale),
                yearBrightness: try brightness(in: year, image: image, scale: scale)
            )
        }
    }

    private func captionBands(below artwork: CGRect, image: CGImage, scale: CGFloat) throws -> [CGRect] {
        let region = CGRect(
            x: artwork.minX * scale, y: (artwork.maxY + 8) * scale,
            width: artwork.width * scale, height: 100 * scale
        ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let crop = try XCTUnwrap(image.cropping(to: region))
        let bytes = try pixels(crop)
        var bands: [Range<Int>] = []
        var start: Int?
        for y in 0..<crop.height {
            let ink = (0..<crop.width).filter { x in
                let offset = (y * crop.width + x) * 4
                return bytes[offset] > 80 && bytes[offset + 1] > 80 && bytes[offset + 2] > 80
            }.count
            if ink >= 2, start == nil { start = y }
            if ink < 2, let beginning = start {
                bands.append(beginning..<y)
                start = nil
            }
        }
        if let start { bands.append(start..<crop.height) }
        XCTAssertEqual(bands.count, 2, "Both caption lines must be painted below the native artwork.")
        guard bands.count == 2 else { throw NSError(domain: "PosterCaptionFixture", code: 1) }
        return bands.map {
            CGRect(x: region.minX / scale, y: (region.minY + CGFloat($0.lowerBound)) / scale,
                   width: region.width / scale, height: CGFloat($0.count) / scale)
        }
    }

    private func brightness(in frame: CGRect, image: CGImage, scale: CGFloat) throws -> Double {
        let region = CGRect(
            x: frame.minX * scale, y: frame.minY * scale,
            width: frame.width * scale, height: frame.height * scale
        ).integral
        let crop = try XCTUnwrap(image.cropping(to: region))
        let bytes = try pixels(crop)
        let luminance = stride(from: 0, to: bytes.count, by: 4).map {
            (Double(bytes[$0]) + Double(bytes[$0 + 1]) + Double(bytes[$0 + 2])) / (3 * 255)
        }.sorted()
        return luminance[min(luminance.count - 1, Int(Double(luminance.count) * 0.98))]
    }

    private func pixels(_ crop: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        try bytes.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(
                data: $0.baseAddress, width: crop.width, height: crop.height, bitsPerComponent: 8,
                bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        return bytes
    }
}
