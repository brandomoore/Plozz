import CoreModels
import CoreUI
@testable import FeaturePlayback
import SwiftUI
import UIKit
import XCTest

@MainActor
final class PlayerSkipMarkerHostedTests: XCTestCase {
    func testSegmentedTracksKeepNativeFillsAndRoundEverySectionWithoutInternalCutouts() async throws {
        XCTAssertEqual(PlayerScrubTrackSurface.glassBackingOpacity, 0.10)
        try await withWindow { window in
            for performance in [false, true] {
                for focused in [false, true] {
                    let background = Color(red: 0.15, green: 0.35, blue: 0.6)
                    let frame = try await render(
                        in: window, focused: focused, performance: performance,
                        background: background
                    )
                    let top = focused ? 580 : 584
                    let bottom = focused ? 600 : 596
                    for y in top..<bottom {
                        for x in [479, 480, 481, 1439, 1440, 1441] {
                            XCTAssertEqual(frame.color(x, y), frame.color(x, 450),
                                           "The entire gap, including the glass backing, reveals the picture.")
                        }
                        for x in [640, 960, 1280] {
                            for channel in 0..<3 {
                                XCTAssertEqual(Int(frame.color(x, y)[channel]), Int(frame.color(x, y - 100)[channel]), accuracy: 1,
                                               "The sections retain the original played, buffered, and unplayed fills.")
                            }
                        }
                    }
                    XCTAssertEqual(frame.color(483, top), frame.color(483, 450), "The new section has rounded corners.")
                    XCTAssertNotEqual(frame.color(483, 590), frame.color(483, 450))
                    XCTAssertEqual(frame.color(832, 590), [255, 255, 255])
                    attach(frame.image, name: "Rounded sections - \(performance ? "flat" : "glass") - \(focused ? "focused" : "normal")")
                    let crossing = try await render(
                        in: window, focused: focused, performance: performance,
                        background: background, segments: [.init(kind: .intro, start: 40, end: 60)]
                    )
                    XCTAssertEqual(crossing.color(832, 590), [255, 255, 255], "A boundary never cuts through the playhead.")
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
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await body(window)
    }

    private func render(
        in window: UIWindow, focused: Bool, performance: Bool,
        background: Color,
        segments: [MediaSegment] = [.init(kind: .intro, start: 12.5, end: 87.5)]
    ) async throws -> Frame {
        func makeModel(_ segments: [MediaSegment]) -> PlayerControlsModel {
            let model = PlayerControlsModel()
            model.duration = 100
            model.currentSeconds = 40
            model.bufferedSeconds = 60
            model.controlsVisible = true
            model.controlBarVisible = !focused
            model.skipSegments.segments = segments
            return model
        }
        let plain = makeModel([])
        let marked = makeModel(segments)
        let host = UIHostingController(rootView:
            background
                .overlay {
                    // Both adaptive materials must be compared in the same frame.
                    VStack(spacing: 56) {
                        ScrubBar(model: plain, palette: .dark)
                            .frame(width: 1280, height: 44)
                        ScrubBar(model: marked, palette: .dark)
                            .frame(width: 1280, height: 44)
                    }
                }
                .ignoresSafeArea()
                .environment(\.plozzReducePanelGlass, performance)
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
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
            context.draw(image, in: window.bounds)
        }
        return Frame(image: snapshot, width: image.width, bytes: bytes)
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
        let bytes: [UInt8]

        func color(_ x: Int, _ y: Int) -> [UInt8] {
            let start = (y * width + x) * 4
            return Array(bytes[start..<(start + 3)])
        }
    }
}
