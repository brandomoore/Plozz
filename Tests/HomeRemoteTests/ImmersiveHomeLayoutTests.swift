import XCTest

/// The Immersive Home's geometry beside the pinned sidebar: a row's first card
/// starts under its title, and the loading skeleton is captured next to the
/// loaded rows for comparison.
@MainActor
final class ImmersiveHomeLayoutTests: XCTestCase {
    func testRowTitlesLineUpWithTheirCards() throws {
        #if targetEnvironment(simulator)
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--production-home-fixture", "--pinned-home", "--immersive-home", "--slow-home-load"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 1.5)
        attach(app.screenshot(), "immersive-loading")
        let title = app.staticTexts["Continue Watching"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 2)
        // Rest the first card: focus the second, which doesn't scroll the row.
        XCUIRemote.shared.press(.right)
        Thread.sleep(forTimeInterval: 1)
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Fixture movie 0")).firstMatch
        XCTAssertTrue(card.exists)
        let screenshot = app.screenshot()
        attach(screenshot, "immersive-loaded")
        // A native card's frame includes room for focus growth, so find the
        // artwork's drawn edge instead.
        let edge = try XCTUnwrap(artworkEdge(in: screenshot.image, y: card.frame.midY, from: title.frame.minX - 40))
        // A title's frame starts a hair before its first glyph.
        XCTAssertEqual(edge, title.frame.minX, accuracy: 3, "The row's first card must start under its title.")
        #else
        throw XCTSkip("Uses the isolated host with local fixture data.")
        #endif
    }

    /// The first point along `y`, scanning right from `x`, where the picture
    /// changes sharply from the page behind it.
    private func artworkEdge(in image: UIImage, y: CGFloat, from x: CGFloat) -> CGFloat? {
        guard let cgImage = image.cgImage else { return nil }
        let scale = image.scale
        let width = cgImage.width
        var pixels = [UInt8](repeating: 0, count: width * 4)
        let row = Int(y * scale)
        guard let context = CGContext(
            data: &pixels, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: -CGFloat(cgImage.height - row - 1), width: CGFloat(width), height: CGFloat(cgImage.height)))
        func sum(_ px: Int) -> Int { Int(pixels[px * 4]) + Int(pixels[px * 4 + 1]) + Int(pixels[px * 4 + 2]) }
        let start = Int(x * scale)
        let page = sum(start)
        for px in start..<width where abs(sum(px) - page) > 90 {
            return CGFloat(px) / scale
        }
        return nil
    }

    private func attach(_ screenshot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
