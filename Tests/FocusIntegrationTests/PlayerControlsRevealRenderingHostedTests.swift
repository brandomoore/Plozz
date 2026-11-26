import CoreModels
import CoreUI
@testable import FeaturePlayback
import SwiftUI
import Synchronization
import UIKit
import XCTest

@MainActor
final class PlayerControlsRevealRenderingHostedTests: XCTestCase {
    func testCardStageMountsOnFirstOpenAndRetainsContentWhileParked() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let probe = InfoCardMountProbe()
        window.rootViewController = UIHostingController(rootView: InfoCardMountHost(probe: probe))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(probe.mounts, 0)
        for _ in 0..<2 {
            probe.presented = true
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(probe.mounts, 1)
            probe.presented = false
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(probe.mounts, 1)
            XCTAssertEqual(probe.unmounts, 0)
        }
    }

    func testFirstInfoRevealKeepsArtworkBelowTheMovingTab() async throws {
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
        window.backgroundColor = .black
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }

        for session in 0..<2 {
            let model = PlayerControlsModel()
            model.title = "Info reveal"
            model.duration = 7_200
            model.infoCard.headline = "Info reveal"
            let input = PlayerInputViewController(engine: DiscHandoffEngine(), model: model, actions: .init())
            input.loadViewIfNeeded()
            input.attachVideoSurface()
            input.attachControls(themePalette: ThemePaletteBox(
                makeControls: { model, actions, exit in
                    AnyView(PlayerControls(model: model, palette: .dark, actions: actions, onExitToSurface: exit)
                        .environment(\.scenePhase, .active)
                        .environment(\.locale, Locale(identifier: "en_US")))
                },
                makeSkipButton: { _, _, _, _ in AnyView(EmptyView()) },
                makeUpNextCard: { _, _, _, _ in AnyView(EmptyView()) }
            ))
            window.rootViewController = input
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(350))

            do {
                input.perform(NSSelectorFromString("handleDown"))
                var samples: [(tabTop: Int, tabBottom: Int, artworkTop: Int)] = []
                var images: [UIImage] = []
                for _ in 0..<12 {
                    try await Task.sleep(for: .milliseconds(20))
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = 1
                    let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                        XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: false))
                    }
                    if let geometry = try infoGeometry(image) {
                        samples.append(geometry)
                        images.append(image)
                    }
                }
                let settled = try XCTUnwrap(samples.last, "The real Info card and native tab must render.")
                let moving = samples.filter { $0.tabTop > settled.tabTop + 8 }
                print("PLAYER_INFO_MOTION session=\(session) samples=\(samples.count) moving=\(moving.count) minGap=\(samples.map { $0.artworkTop - $0.tabBottom }.min() ?? -1) first=\(String(describing: samples.first)) last=\(settled)")
                XCTAssertFalse(moving.isEmpty, "The assertion must observe in-flight frames, not only the endpoint.")
                for (index, sample) in samples.enumerated() where sample.artworkTop < sample.tabBottom {
                    let attachment = XCTAttachment(image: images[index])
                    attachment.name = "Info overlap session \(session) sample \(index)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    XCTFail("Info artwork y=\(sample.artworkTop) overtook its moving tab bottom y=\(sample.tabBottom).")
                }
            }
        }
    }

    private func infoGeometry(_ image: UIImage) throws -> (tabTop: Int, tabBottom: Int, artworkTop: Int)? {
        let source = try XCTUnwrap(image.cgImage)
        func band(x: Int, width: Int) throws -> [UInt8] {
            let crop = try XCTUnwrap(source.cropping(to: CGRect(x: x, y: 400, width: width, height: 680)))
            var pixels = [UInt8](repeating: 0, count: 680)
            try pixels.withUnsafeMutableBytes {
                let context = try XCTUnwrap(CGContext(
                    data: $0.baseAddress, width: 1, height: 680,
                    bitsPerComponent: 8, bytesPerRow: 1,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
                ))
                context.interpolationQuality = .high
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 680))
            }
            return pixels
        }
        func longestBand(_ pixels: [UInt8], threshold: UInt8, minimum: Int) -> Range<Int>? {
            var best = 0..<0
            var start = 0
            for end in 0...pixels.count {
                if end < pixels.count, pixels[end] > threshold { continue }
                if end - start > best.count { best = start..<end }
                start = end + 1
            }
            return best.count >= minimum ? best : nil
        }
        // Sample the solid native Info focus pill and the synthetic artwork
        // rectangle, excluding title glyphs, borders, and the thin seek track.
        guard let tab = longestBand(try band(x: 75, width: 70), threshold: 85, minimum: 25),
              let artwork = longestBand(try band(x: 310, width: 90), threshold: 16, minimum: 140)
        else { return nil }
        return (tab.lowerBound + 400, tab.upperBound + 399, artwork.lowerBound + 400)
    }

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
        XCTAssertGreaterThan(visible, early, "The reveal must render intermediate opacity, not snap to its final state.")
        XCTAssertGreaterThanOrEqual(visible, middle, "Capturing the middle frame may finish after the fade.")
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

@MainActor
private final class InfoCardMountProbe: ObservableObject {
    @Published var presented = false
    var mounts = 0
    var unmounts = 0
}

private struct InfoCardMountHost: View {
    @ObservedObject var probe: InfoCardMountProbe

    var body: some View {
        PlayerControlsCardStage(isPresented: probe.presented) {
            Text(verbatim: "Retained Info content")
                .onAppear { probe.mounts += 1 }
                .onDisappear { probe.unmounts += 1 }
        }
    }
}
