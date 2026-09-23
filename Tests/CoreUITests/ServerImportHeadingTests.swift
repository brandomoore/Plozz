#if os(iOS)
import CoreUI
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class ServerImportHeadingTests: XCTestCase {
    func testHeadingConnectsImportToNamedDeviceWithoutAnExtraSubtitle() throws {
        for width in [CGFloat(280), 380, 560] {
            let image = try render(.server, name: "Brando TV", width: width)
            let text = try recognize(image)
            XCTAssertTrue(text.contains("Import your server from"), text)
            XCTAssertTrue(text.contains("Brando TV"), text)
            XCTAssertFalse(text.contains("We found"), text)
            XCTAssertFalse(text.contains("Use the same"), text)
            XCTAssertLessThan(image.height, 600, "The heading must wrap without a fixed-height crop")
            let attachment = XCTAttachment(image: UIImage(cgImage: image))
            attachment.name = "Import heading \(Int(width))"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testPluralAccountAndMixedSetupCopyMatchesItsAction() throws {
        let cases: [(ServerImportHeading.Content, String, String)] = [
            (.server, "server", "Import server"),
            (.servers, "servers", "Import servers"),
            (.account, "account", "Import account"),
            (.accounts, "accounts", "Import accounts"),
            (.setup, "setup", "Import setup")
        ]
        for (content, noun, action) in cases {
            let text = try recognize(render(content, name: "Living Room TV", width: 380))
            XCTAssertTrue(text.contains("Import your \(noun) from"), text)
            for word in ["Living", "Room", "TV"] {
                XCTAssertTrue(text.contains(word), text)
            }
            var label = content.primaryAction
            label.locale = Locale(identifier: "en_US")
            XCTAssertEqual(String(localized: label), action)
        }
        let missing = try recognize(render(.server, name: nil, width: 380))
        XCTAssertTrue(missing.contains("another device"), missing)
    }

    func testLongDeviceNamesWrapAtAccessibilitySize() throws {
        let image = try render(.servers, name: "Living Room Family Television", width: 280, textSize: .accessibility3)
        let text = try recognize(image)
        for word in ["Import", "servers", "Living", "Room", "Family", "Television"] {
            XCTAssertTrue(text.contains(word), text)
        }
        XCTAssertGreaterThan(image.height, 250)
        XCTAssertLessThan(image.height, 1800)
    }

    func testDeviceAndIconKeepTheHeadingsQuietMonochromeColorInBothThemes() throws {
        for palette in [ThemePalette.dark, .light] {
            let image = try render(.server, name: "Brando TV", width: 380, palette: palette)
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            let coloredPixels = stride(from: 0, to: bytes.count, by: 4).filter { i in
                Int(bytes[i + 2]) > Int(bytes[i]) + 50 && Int(bytes[i + 1]) > Int(bytes[i]) + 30
            }.count
            XCTAssertEqual(coloredPixels, 0, "The origin must not become a bright blue callout")
        }
    }

    private func render(
        _ content: ServerImportHeading.Content, name: String?, width: CGFloat,
        textSize: DynamicTypeSize = .large, palette: ThemePalette = .dark
    ) throws -> CGImage {
        let renderer = ImageRenderer(content:
            ServerImportHeading(content: content, deviceName: name, deviceIcon: "appletv.fill")
                .environment(\.themePalette, palette)
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.dynamicTypeSize, textSize)
                .frame(width: width)
                .padding(12)
                .background(palette.backgroundBase)
        )
        renderer.scale = 2
        return try XCTUnwrap(renderer.cgImage)
    }

    private func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}
#endif
