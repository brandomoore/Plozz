import CoreModels
import CoreUI
@testable import FeaturePlayback
import SwiftUI
import UIKit
import XCTest

@MainActor
final class PlayerSkipMarkerHostedTests: XCTestCase {
    func testCapturePreservesKnownTransparentGaps() async throws {
        try await withWindow { window in
            let host = UIHostingController(rootView:
                Color(red: 0.15, green: 0.35, blue: 0.6)
                    .overlay {
                        HStack(spacing: 4) {
                            Capsule().fill(.white).frame(width: 158)
                            Capsule().fill(.white).frame(width: 956)
                            Capsule().fill(.white).frame(width: 158)
                        }
                        .frame(width: 1280, height: 12)
                    }
                    .ignoresSafeArea()
            )
            window.rootViewController = host
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            let frame = try await render(in: window)
            for y in frame.pixels(534..<546) {
                for x in [479, 480, 481, 1439, 1440, 1441].flatMap({ frame.pixels($0..<($0 + 1)) }) {
                    XCTAssertEqual(frame.colorAtPixel(x, y), frame.colorAtPixel(x, frame.pixel(450)))
                }
            }
            attach(frame.image, name: "Known transparent gaps")
        }
    }

    func testSegmentedTracksKeepNativeFillsWithSoftVerticalInternalCuts() async throws {
        XCTAssertEqual(PlayerScrubTrackSurface.glassBackingOpacity, 0.10)
        try await withWindow { window in
            for performance in [false, true] {
                for focused in [false, true] {
                    let background = Color(red: 0.15, green: 0.35, blue: 0.6)
                    let model = showTrack(
                        in: window, focused: focused, performance: performance,
                        background: background
                    )
                    let unmarked = try await render(in: window)
                    model.skipSegments.segments = [
                        .init(kind: .intro, start: 12.5, end: 37.5),
                        .init(kind: .credits, start: 62.5, end: 87.5)
                    ]
                    let frame = try await render(in: window)
                    let top = focused ? 580 : 584
                    let bottom = focused ? 600 : 596
                    for y in frame.pixels(top..<bottom) {
                        for x in [479, 480, 481, 799, 800, 801, 1119, 1120, 1121, 1439, 1440, 1441]
                            .flatMap({ frame.pixels($0..<($0 + 1)) }) {
                            XCTAssertEqual(frame.colorAtPixel(x, y), frame.colorAtPixel(x, frame.pixel(450)),
                                           "The entire gap, including the glass backing, reveals the picture.")
                        }
                        for x in [640, 960, 1280].flatMap({ frame.pixels($0..<($0 + 1)) }) {
                            for channel in 0..<3 {
                                XCTAssertEqual(
                                    Int(frame.colorAtPixel(x, y)[channel]),
                                    Int(unmarked.colorAtPixel(x, y)[channel]), accuracy: 1,
                                               "The sections retain the original played, buffered, and unplayed fills. flat=\(performance) focused=\(focused)")
                            }
                        }
                    }
                    XCTAssertNotEqual(frame.color(482, top), frame.color(482, 590),
                                      "The internal cut retains a small rounded corner.")
                    XCTAssertNotEqual(frame.color(483, top + 3), frame.color(483, 450),
                                      "The cut is straight below its corner, not fully pill-shaped.")
                    XCTAssertNotEqual(frame.color(483, 590), frame.color(483, 450))
                    XCTAssertEqual(frame.color(832, 590), [255, 255, 255])
                    attach(frame.image, name: "Rounded sections - \(performance ? "flat" : "glass") - \(focused ? "focused" : "normal")")
                    model.skipSegments.segments = [.init(kind: .intro, start: 40, end: 60)]
                    let crossing = try await render(in: window)
                    XCTAssertEqual(crossing.color(832, 590), [255, 255, 255], "A boundary never cuts through the playhead.")
                }
            }
        }
    }

    func testTinyOpeningCutIsSuppressedButRoomyBoundaryRemains() async throws {
        try await withWindow { window in
            for performance in [false, true] {
                for focused in [false, true] {
                    let background = Color(red: 0.15, green: 0.35, blue: 0.6)
                    let model = showTrack(
                        in: window, focused: focused, performance: performance, background: background
                    )
                    let plain = try await render(in: window)
                    model.skipSegments.segments = [.init(kind: .intro, start: 0.5, end: 25)]
                    let frame = try await render(in: window)
                    let top = focused ? 580 : 584
                    for y in frame.pixels(588..<592) {
                        for x in frame.pixels(326..<330) {
                            XCTAssertEqual(frame.colorAtPixel(x, y), plain.colorAtPixel(x, y),
                                           "A tiny opening must not become a detached cap.")
                        }
                    }
                    XCTAssertEqual(frame.color(640, 590), frame.color(640, 450),
                                   "The isolated boundary remains at its actual timestamp.")
                    XCTAssertNotEqual(frame.color(642, top), frame.color(642, 590),
                                      "The roomy internal edge uses the same small corner.")
                    XCTAssertNotEqual(frame.color(643, 590), frame.color(643, 450))
                    attach(frame.image, name: "Suppressed opening cut - \(performance ? "flat" : "glass") - \(focused ? "focused" : "normal")")
                }
            }
        }
    }

    func testCrowdedCreditsStayContinuousAcrossPlaybackScrubbingAndFocus() async throws {
        let credits: [MediaSegment] = [
            .init(kind: .credits, start: 7_754.39, end: 7_784.39),
            .init(kind: .credits, start: 7_816.39, end: 7_852.39),
            .init(kind: .credits, start: 7_962.39, end: 8_032.39),
            .init(kind: .credits, start: 8_072.39, end: 8_110.39)
        ]
        try await withWindow { window in
            for performance in [false, true] {
                for (focused, scrubbing) in [(false, false), (true, false), (true, true)] {
                    let model = showTrack(
                        in: window, focused: focused, performance: performance,
                        background: Color(red: 0.15, green: 0.35, blue: 0.6)
                    )
                    model.duration = 8_142.656
                    model.isScrubbing = scrubbing
                    for fraction in [0.4, 0.98] {
                        model.currentSeconds = model.duration * fraction
                        model.scrubSeconds = model.currentSeconds
                        model.bufferedSeconds = model.currentSeconds
                        model.skipSegments.segments = []
                        let plain = try await render(in: window)
                        model.skipSegments.segments = credits
                        let marked = try await render(in: window)
                        XCTAssertTrue(marked.bytes == plain.bytes,
                                      "Dense cuts must stay absent as progress, focus, and scrubbing change.")
                        XCTAssertEqual(model.skipSegments.segments, credits,
                                       "The display must not rewrite actual skip ranges.")
                    }
                }
            }
        }
    }

    private func withWindow(_ body: (UIWindow) async throws -> Void) async throws {
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
        window.overrideUserInterfaceStyle = .dark
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await body(window)
    }

    private func showTrack(
        in window: UIWindow, focused: Bool, performance: Bool,
        background: Color
    ) -> PlayerControlsModel {
        let marked = PlayerControlsModel()
        marked.duration = 100
        marked.currentSeconds = 40
        marked.bufferedSeconds = 60
        marked.controlsVisible = true
        marked.controlBarVisible = !focused
        let host = UIHostingController(rootView:
            background
                .overlay {
                    ScrubBar(model: marked, palette: .dark)
                        .frame(width: 1280, height: 44)
                        .offset(y: 50)
                }
                .ignoresSafeArea()
                .environment(\.colorScheme, .dark)
                .environment(\.plozzReducePanelGlass, performance)
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return marked
    }

    private func render(in window: UIWindow) async throws -> Frame {
        // Native glass can still be transitioning after the first completed layout.
        let deadline = ContinuousClock.now + .seconds(6)
        var frame = try capture(in: window)
        var stableFrames = 0
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            let next = try capture(in: window)
            stableFrames = next.bytes == frame.bytes ? stableFrames + 1 : 0
            frame = next
            if stableFrames >= 3 { return frame }
        }
        XCTFail("The native scrub-track material did not settle before the snapshot deadline.")
        return frame
    }

    private func capture(in window: UIWindow) throws -> Frame {
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.preferredRange = .extended
        let snapshot = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let image = try XCTUnwrap(snapshot.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Frame(image: snapshot, width: image.width, scale: snapshot.scale, bytes: bytes)
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private struct Frame {
        let image: UIImage
        let width: Int
        let scale: CGFloat
        let bytes: [UInt8]

        func color(_ x: Int, _ y: Int) -> [UInt8] {
            colorAtPixel(pixel(x), pixel(y))
        }

        func pixel(_ point: Int) -> Int {
            Int((CGFloat(point) * scale).rounded())
        }

        func pixels(_ points: Range<Int>) -> Range<Int> {
            pixel(points.lowerBound)..<pixel(points.upperBound)
        }

        func colorAtPixel(_ x: Int, _ y: Int) -> [UInt8] {
            let start = (y * width + x) * 4
            return Array(bytes[start..<(start + 3)])
        }
    }
}
