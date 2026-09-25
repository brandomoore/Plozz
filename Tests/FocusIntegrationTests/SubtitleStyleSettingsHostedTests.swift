import CoreModels
@testable import CoreUI
@testable import FeaturePlayback
import Observation
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class SubtitleStyleSettingsHostedTests: XCTestCase {
    func testFullEditorReceivesNativeFocusBesideThePreviewInLightAndDarkThemes() async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let appearances: [(String, ThemePalette, ColorScheme)] = [
            ("dark", .dark, .dark), ("light", .light, .light)
        ]
        var previewSamples: [[UInt8]] = []
        for (name, palette, scheme) in appearances {
            let model = SubtitleStyleSettingsFixture()
            model.style.fontFamily = .system
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
            window.rootViewController = UIHostingController(rootView: NavigationStack {
                SubtitleStyleSettingsView(style: Binding(get: { model.style }, set: { model.style = $0 }))
            }
            .environment(\.themePalette, palette)
            .environment(\.colorScheme, scheme)
            .environment(\.scenePhase, .inactive))
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKeyAndVisible()
            }
            try await waitUntil {
                guard let frame = self.focusFrame(in: window) else { return false }
                return abs(frame.width - (SubtitleStylePanel.panelWidth - 28)) < 1
                    && frame.midX < window.bounds.midX
            }
            try await Task.sleep(for: .milliseconds(300))
            let image = DetailTransitionSnapshot.image(of: window)
            let bitmap = try XCTUnwrap(image.cgImage)
            let pixels = try rgbaPixels(bitmap)
            let focused = try XCTUnwrap(focusFrame(in: window))
            XCTAssertEqual(focused.width, SubtitleStylePanel.panelWidth - 28, accuracy: 1,
                           "Settings must use the player's panel width and shared row insets.")
            let focusFill = rgb(pixels, x: Int(focused.maxX - 12), y: Int(focused.midY), width: bitmap.width)
            let menuFill = rgb(pixels, x: Int(focused.minX - 10), y: Int(focused.midY), width: bitmap.width)
            let pageFill = rgb(pixels, x: bitmap.width - 10, y: bitmap.height / 2, width: bitmap.width)
            for channel in 0..<3 {
                XCTAssertEqual(Double(focusFill[channel]), scheme == .dark ? 255 : 0, accuracy: 8)
                XCTAssertTrue(scheme == .dark ? menuFill[channel] < 90 : menuFill[channel] > 180,
                              "The menu must use the current theme, not a forced dark surface.")
                XCTAssertTrue(scheme == .dark ? pageFill[channel] < 90 : pageFill[channel] > 180,
                              "The page background must use the current theme.")
            }
            previewSamples.append(rgb(pixels, x: Int(Double(bitmap.width) * 0.72),
                                      y: bitmap.height / 2, width: bitmap.width))
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([text])
            let strings = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            XCTAssertTrue(strings.contains { $0.contains("Use System Caption Style") }, strings.joined(separator: "\n"))
            XCTAssertTrue(strings.contains { $0.contains("Preview") }, strings.joined(separator: "\n"))
            XCTAssertTrue(strings.contains { $0.contains("almost there") || $0.contains("train leaves") },
                          "The preview must draw actual subtitle glyphs.")
            let selected = try XCTUnwrap(text.results?.first {
                $0.topCandidates(1).first?.string.contains("Use System Caption Style") == true
            })
            let center = CGPoint(x: selected.boundingBox.midX * window.bounds.width,
                                 y: (1 - selected.boundingBox.midY) * window.bounds.height)
            XCTAssertTrue(try XCTUnwrap(focusFrame(in: window)).contains(center))
            let attachment = XCTAttachment(image: image)
            attachment.name = "Subtitle customization - \(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        for channel in 0..<3 {
            XCTAssertEqual(Double(previewSamples[0][channel]), Double(previewSamples[1][channel]), accuracy: 2,
                           "The preview's background must not change with the page theme.")
        }
    }

    private func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    private func rgb(_ pixels: [UInt8], x: Int, y: Int, width: Int) -> [UInt8] {
        let offset = (y * width + x) * 4
        return Array(pixels[offset..<(offset + 3)])
    }

    private func focusFrame(in window: UIWindow) -> CGRect? {
        guard let item = UIFocusSystem(for: window)?.focusedItem else { return nil }
        var environment: (any UIFocusEnvironment)? = item
        while let current = environment {
            if let container = current.focusItemContainer {
                return container.coordinateSpace.convert(item.frame, to: window)
            }
            environment = current.parentFocusEnvironment
        }
        return nil
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "The shared editor must receive actual native focus.")
    }
}

@MainActor @Observable
private final class SubtitleStyleSettingsFixture {
    var style = SubtitleStyle.default
}
