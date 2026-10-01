import CoreModels
import CoreUI
@testable import FeaturePlayback
import SwiftUI
import UIKit
import XCTest

@MainActor
final class PlayerSkipMarkerHostedTests: XCTestCase {
    func testRealGlassAndFlatTracksRevealThePictureThroughTheirCutouts() async throws {
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
        for performance in [false, true] {
            for focused in [false, true] {
                let model = PlayerControlsModel()
                model.duration = 100
                model.currentSeconds = 40
                model.bufferedSeconds = 60
                model.controlsVisible = true
                model.controlBarVisible = !focused
                model.skipSegments.segments = [.init(kind: .intro, start: 12.5, end: 87.5)]
                let host = UIHostingController(rootView:
                    Color(red: 0.15, green: 0.35, blue: 0.6)
                        .overlay {
                            ScrubBar(model: model, palette: .dark)
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
                func color(_ x: Int, _ y: Int) -> [UInt8] {
                    let start = (y * image.width + x) * 4
                    return Array(bytes[start..<(start + 3)])
                }
                for x in [640, 960, 1280] {
                    XCTAssertEqual(color(x, 540), color(x, 450),
                                   "The slot must reveal the picture through \(performance ? "flat" : "native glass") fills.")
                    XCTAssertNotEqual(color(x, focused ? 531 : 535), color(x, 450),
                                      "The track must retain visible rails.")
                }
                XCTAssertEqual(color(832, 540), [255, 255, 255])
                let attachment = XCTAttachment(image: snapshot)
                attachment.name = "Skip cutouts - \(performance ? "flat" : "glass") - \(focused ? "focused" : "normal")"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}
