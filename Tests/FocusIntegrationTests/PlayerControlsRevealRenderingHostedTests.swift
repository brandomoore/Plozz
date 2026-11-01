import CoreModels
import CoreUI
@testable import FeaturePlayback
import SwiftUI
import Synchronization
import UIKit
import XCTest

@MainActor
final class PlayerControlsRevealRenderingHostedTests: XCTestCase {
    func testControlsFadeWhileSystemPreferencesAreStillBlocked() async throws {
        let gate = DispatchSemaphore(value: 0)
        let reads = Mutex((started: 0, completed: 0))
        let audio = SystemPlaybackAudio(backend: SystemPlaybackAudioPreferences(readState: {
            let count = reads.withLock {
                $0.started += 1
                return $0.started
            }
            if count > 1 { _ = gate.wait(timeout: .now() + 3) }
            reads.withLock { $0.completed += 1 }
            return .init(values: [.reduceLoudSounds: false])
        }))
        defer { gate.signal() }
        await audio.refresh().value
        let model = PlayerControlsModel(systemAudio: audio)
        model.title = "Smooth controls reveal"
        model.duration = 7_200
        model.currentSeconds = 1_800
        model.engineCapabilities = [.playbackSpeed]
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
        window.rootViewController = UIHostingController(rootView:
            PlayerControls(model: model, palette: .dark, actions: .init(), onExitToSurface: {})
                .environment(\.scenePhase, .active)
                .environment(\.locale, Locale(identifier: "en_US"))
                .background(.black)
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(500))
        let hidden = try brightness(of: window, name: "Hidden controls")
        model.controlsVisible = true
        try await Task.sleep(for: .milliseconds(70))
        let early = try brightness(of: window, name: "Early reveal")
        try await Task.sleep(for: .milliseconds(80))
        let middle = try brightness(of: window, name: "Mid reveal")
        try await Task.sleep(for: .milliseconds(200))
        let visible = try brightness(of: window, name: "Visible controls")
        XCTAssertEqual(reads.withLock { $0.started }, 2)
        XCTAssertEqual(reads.withLock { $0.completed }, 1, "The controls must finish fading before preferences return.")
        XCTAssertGreaterThan(early, hidden)
        XCTAssertGreaterThan(middle, early)
        XCTAssertGreaterThan(visible, middle, "The reveal must render intermediate opacity, not snap to its final state.")
        gate.signal()
        await audio.refresh().value
    }

    private func brightness(of window: UIWindow, name: String) throws -> Int {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: false))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        var pixels = [UInt8](repeating: 0, count: 192 * 108 * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let bitmap = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: 192, height: 108, bitsPerComponent: 8, bytesPerRow: 192 * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            bitmap.draw(try XCTUnwrap(image.cgImage), in: CGRect(x: 0, y: 0, width: 192, height: 108))
        }
        return stride(from: 0, to: pixels.count, by: 4).reduce(0) {
            $0 + Int(pixels[$1]) + Int(pixels[$1 + 1]) + Int(pixels[$1 + 2])
        }
    }
}
