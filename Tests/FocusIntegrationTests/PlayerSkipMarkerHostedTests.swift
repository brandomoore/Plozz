import CoreModels
import CoreUI
@testable import FeaturePlayback
import SwiftUI
import UIKit
import XCTest

@MainActor
final class PlayerSkipMarkerHostedTests: XCTestCase {
    func testUnplayedGlassDiagonalsRemainVisibleInBothSizesAndFocusStates() async throws {
        try await withWindow { window in
            for treatment in [PlayerSkipMarkerTreatment.halfHatchedCutout, .hatchedCutout] {
                for focused in [false, true] {
                    let frame = try await render(
                        in: window, focused: focused, performance: false, treatment: treatment,
                        background: Color(red: 0.06, green: 0.10, blue: 0.16)
                    )
                    for region in [912..<1040, 1152..<1344] {
                        let values = region.map { frame.red($0, 540) }
                        XCTAssertGreaterThan(try XCTUnwrap(values.max()) - XCTUnwrap(values.min()), 25,
                                             "Glass must not hide the unplayed diagonal strokes.")
                    }
                    XCTAssertGreaterThan(
                        try XCTUnwrap((600..<728).map { frame.red($0, 540) }.max()),
                        try XCTUnwrap((1152..<1344).map { frame.red($0, 540) }.max()),
                        "Played progress remains brighter than the enhanced future marker."
                    )
                    XCTAssertEqual(frame.red(832, 540), 255)
                    attach(frame.image, name: "Unplayed glass markers - \(treatment) - \(focused ? "focused" : "normal")")
                }
            }
        }
    }

    func testRealGlassAndFlatTracksRevealThePictureThroughTheirCutouts() async throws {
        try await withWindow { window in
            for performance in [false, true] {
                for focused in [false, true] {
                    let frame = try await render(
                        in: window, focused: focused, performance: performance, treatment: .cutout,
                        background: Color(red: 0.15, green: 0.35, blue: 0.6)
                    )
                    for x in [640, 960, 1280] {
                        XCTAssertEqual(frame.color(x, 540), frame.color(x, 450),
                                       "The slot must reveal the picture through \(performance ? "flat" : "native glass") fills.")
                        XCTAssertNotEqual(frame.color(x, focused ? 531 : 535), frame.color(x, 450),
                                          "The track must retain visible rails.")
                    }
                    XCTAssertEqual(frame.color(832, 540), [255, 255, 255])
                    attach(frame.image, name: "Skip cutouts - \(performance ? "flat" : "glass") - \(focused ? "focused" : "normal")")
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
        treatment: PlayerSkipMarkerTreatment, background: Color
    ) async throws -> Frame {
        let model = PlayerControlsModel()
        model.duration = 100
        model.currentSeconds = 40
        model.bufferedSeconds = 60
        model.controlsVisible = true
        model.controlBarVisible = !focused
        model.skipSegments.segments = [.init(kind: .intro, start: 12.5, end: 87.5)]
        let host = UIHostingController(rootView:
            background
                .overlay {
                    ScrubBar(model: model, palette: .dark, markerTreatment: treatment)
                        .frame(width: 1280, height: 44)
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

        func red(_ x: Int, _ y: Int) -> Int { Int(bytes[(y * width + x) * 4]) }
        func color(_ x: Int, _ y: Int) -> [UInt8] {
            let start = (y * width + x) * 4
            return Array(bytes[start..<(start + 3)])
        }
    }
}
