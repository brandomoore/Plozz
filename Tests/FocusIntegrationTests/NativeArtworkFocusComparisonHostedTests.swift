import CoreModels
import TVUIKit
import UIKit
import XCTest
@testable import CoreUI
@testable import PlozzFocusHost

@MainActor
final class NativeArtworkFocusComparisonHostedTests: XCTestCase {
    func testNativeFocusSeparatesOuterGrowthFromArtworkCropping() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let controller = NativeArtworkFocusComparisonController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        try await focus(controller.restingTarget, using: system, controller: controller)
        try await waitForArtworkLayout(controller, in: window)
        let restingImage = capture(window, name: "native-artwork-focus-resting")
        var measurements: [[String: Any]] = []
        for sample in controller.samples {
            try await focus(controller.restingTarget, using: system, controller: controller)
            try await waitForArtworkLayout(controller, in: window)
            let rest = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: sample.artwork, in: window))
            let overlayRest = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: sample.overlay, in: window))
            let frame = sample.control.frame
            try await focus(sample.control, using: system, controller: controller)
            var maximumWidth = rest.width
            var maximumHeight = rest.height
            for _ in 0..<40 {
                let current = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: sample.artwork, in: window))
                maximumWidth = max(maximumWidth, current.width)
                maximumHeight = max(maximumHeight, current.height)
                try await Task.sleep(for: .milliseconds(16))
            }
            try await waitForArtworkLayout(controller, in: window)
            let focused = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: sample.artwork, in: window))
            let overlayFocused = try XCTUnwrap(NativeFocusProjection.artworkFrame(of: sample.overlay, in: window))
            let screenshot = capture(window, name: "native-artwork-focus-focused-\(sample.variant.rawValue)")
            let region = rest.insetBy(dx: -80, dy: -80)
            let restingMarkers = try markerBounds(in: restingImage, region: region, marker: .overlay)
            let focusedMarkers = try markerBounds(in: screenshot, region: region, marker: .overlay)
            let restingArtworkMarkers = try markerBounds(in: restingImage, region: landmarkRegion(in: rest), marker: .artwork)
            let focusedArtworkMarkers = try markerBounds(in: screenshot, region: landmarkRegion(in: focused), marker: .artwork)
            let outerScale = focused.width / rest.width
            let internalScale = focusedArtworkMarkers.width / restingArtworkMarkers.width / outerScale
            let highlightDelta = try highlightBrightness(in: screenshot, frame: focused)
                - highlightBrightness(in: restingImage, frame: rest)
            measurements.append([
                "variant": sample.variant.rawValue, "actualFocusedItem": sample.control.isFocused,
                "configuredGrowth": "\(sample.control.focusSizeIncrease)",
                "masksFocusEffectToContents": sample.artwork.masksFocusEffectToContents,
                "imageSize": "\(String(describing: sample.artwork.image?.size))",
                "restingArtwork": NSCoder.string(for: rest), "focusedArtwork": NSCoder.string(for: focused),
                "maximumArtworkScaleX": maximumWidth / rest.width, "maximumArtworkScaleY": maximumHeight / rest.height,
                "restingOverlay": NSCoder.string(for: overlayRest), "focusedOverlay": NSCoder.string(for: overlayFocused),
                "restingMarkerPixels": NSCoder.string(for: restingMarkers),
                "focusedMarkerPixels": NSCoder.string(for: focusedMarkers),
                "restingArtworkMarkerPixels": NSCoder.string(for: restingArtworkMarkers),
                "focusedArtworkMarkerPixels": NSCoder.string(for: focusedArtworkMarkers),
                "internalArtworkScale": internalScale,
                "nativeHighlightBrightnessDelta": highlightDelta
            ])
            XCTAssertTrue(system.focusedItem === sample.control)
            XCTAssertEqual(sample.control.frame, frame, "Focus must not rearrange the row's layout.")
            XCTAssertGreaterThan(focused.width, rest.width + 2, "Keep native outer enlargement.")
            if sample.variant == .card || sample.variant == .compositedPoster {
                XCTAssertEqual(internalScale, 1, accuracy: 0.01, "The image must not zoom inside its enlarged bounds.")
                XCTAssertEqual(focusedMarkers.width, restingMarkers.width * outerScale, accuracy: 1)
                XCTAssertEqual(focusedMarkers.height, restingMarkers.height * outerScale, accuracy: 2)
                XCTAssertEqual(focusedMarkers.minX - focused.minX, (restingMarkers.minX - rest.minX) * outerScale, accuracy: 1)
                XCTAssertEqual(focusedMarkers.minY - focused.minY, (restingMarkers.minY - rest.minY) * outerScale, accuracy: 1)
            } else if sample.variant == .maskedPoster {
                XCTAssertEqual(internalScale, 1, accuracy: 0.01, "Masking transparent artwork must preserve its composition.")
            } else if sample.variant == .poster {
                XCTAssertGreaterThan(
                    focusedArtworkMarkers.width, restingArtworkMarkers.width * outerScale + 1,
                    "The current poster must reproduce the additional internal zoom."
                )
            }
            if sample.variant != .card {
                XCTAssertTrue(sample.artwork.adjustsImageWhenAncestorFocused)
                XCTAssertGreaterThan(highlightDelta, 10, "Keep the visible native image highlight, not only its focus state.")
            }
            let before = controller.activations
            sample.control.sendActions(for: .primaryActionTriggered)
            XCTAssertEqual(controller.activations, before + 1)
        }
        let data = try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "native-artwork-focus-measurements"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitForArtworkLayout(
        _ controller: NativeArtworkFocusComparisonController, in window: UIWindow
    ) async throws {
        // Native highlights can keep animating after the artwork geometry has settled.
        let deadline = ContinuousClock.now + .seconds(4)
        var previous: [CGRect] = []
        var stableSamples = 0
        repeat {
            try await Task.sleep(for: .milliseconds(16))
            window.layoutIfNeeded()
            let frames = controller.samples.flatMap { sample in
                [sample.artwork, sample.overlay].compactMap { NativeFocusProjection.artworkFrame(of: $0, in: window) }
            }
            stableSamples = frames == previous && frames.count == controller.samples.count * 2 ? stableSamples + 1 : 0
            if stableSamples >= 4 { return }
            previous = frames
        } while ContinuousClock.now < deadline
        XCTFail("Artwork and overlay geometry did not settle: \(previous)")
        throw ComparisonLayoutError.didNotSettle
    }

    private enum ComparisonLayoutError: Error { case didNotSettle }

    private func focus(
        _ target: UIView, using system: UIFocusSystem, controller: NativeArtworkFocusComparisonController
    ) async throws {
        controller.focusTarget = target
        system.requestFocusUpdate(to: controller)
        system.updateFocusIfNeeded()
        let deadline = ContinuousClock.now + .seconds(3)
        while !target.isFocused, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTAssertTrue(target.isFocused, "Native focus must reach the requested control.")
    }

    private func capture(_ window: UIWindow, name: String) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }

    private enum Marker {
        case artwork, overlay

        func matches(red: UInt8, green: UInt8, blue: UInt8) -> Bool {
            switch self {
            case .artwork: red > 180 && green < 125 && blue < 125
            case .overlay: red > 180 && green < 90 && blue > 180
            }
        }
    }

    private func landmarkRegion(in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY + frame.height * 0.2, width: frame.width, height: frame.height * 0.35)
    }

    private func highlightBrightness(in image: UIImage, frame: CGRect) throws -> Int {
        let source = try XCTUnwrap(image.cgImage)
        let region = CGRect(x: floor(frame.midX), y: floor(frame.minY + frame.height * 0.15), width: 1, height: 1)
        let pixel = try XCTUnwrap(source.cropping(to: region))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return Int(bytes[0]) + Int(bytes[1]) + Int(bytes[2])
    }

    private func markerBounds(in image: UIImage, region: CGRect, marker: Marker) throws -> CGRect {
        let image = try XCTUnwrap(image.cgImage)
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var result = CGRect.null
        for y in max(0, Int(region.minY))..<min(height, Int(region.maxY)) {
            for x in max(0, Int(region.minX))..<min(width, Int(region.maxX)) {
                let offset = (y * width + x) * 4
                if marker.matches(red: bytes[offset], green: bytes[offset + 1], blue: bytes[offset + 2]) {
                    result = result.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        XCTAssertFalse(result.isNull, "The \(marker) pixel markers must be visible.")
        return result
    }
}
