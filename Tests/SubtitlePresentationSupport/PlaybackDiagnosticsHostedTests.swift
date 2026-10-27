import CoreModels
import CoreUI
import Observation
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import FeaturePlayback

@MainActor
final class PlaybackDiagnosticsHostedTests: XCTestCase {
    func testAvailableSpaceClearsCardsTabsAndMenusInTheSameCoordinateSpace() {
        let bounds = CGRect(x: 40, y: 30, width: 1920, height: 1080)
        for top: CGFloat in [650, 420, 60] {
            let controls = CGRect(x: 80, y: top, width: 1800, height: 400)
            let space = TelevisionDiagnosticsPlacement<EmptyView>.availableRect(in: bounds, avoiding: [controls])
            XCTAssertEqual(space.minX, 88)
            XCTAssertEqual(space.minY, 62)
            XCTAssertTrue(space.isEmpty || !space.intersects(controls))
            if space.height > 0 { XCTAssertLessThanOrEqual(space.maxY, top - 24) }
        }
        let unobstructed = TelevisionDiagnosticsPlacement<EmptyView>.availableRect(
            in: bounds, avoiding: [.null, CGRect(x: 3000, y: 0, width: 100, height: 100)]
        )
        XCTAssertEqual(unobstructed, CGRect(x: 88, y: 62, width: 1280, height: 1016))
        let rightMenu = CGRect(x: 1450, y: 100, width: 450, height: 800)
        XCTAssertEqual(
            TelevisionDiagnosticsPlacement<EmptyView>.availableRect(in: bounds, avoiding: [rightMenu]),
            unobstructed, "A menu outside the narrower panel must not hide diagnostics"
        )
        let smallBounds = CGRect(x: 0, y: 0, width: 1280, height: 720)
        XCTAssertEqual(
            TelevisionDiagnosticsPlacement<EmptyView>.availableRect(in: smallBounds, avoiding: []).width,
            1184
        )
    }

    #if os(tvOS)
    func testFullDiagnosticsClearRealTransportAndInfoCardWithoutShrinkingText() async throws {
        try await assertControlClearance(diagnostics: fixture, expectedTokens: [
            "AetherEngine", "v7.44.0", "APAC", "7.1.4", "HDMI", "Thermal", "engines 2", "Stalls", "Dropped",
            "33.2", "82.0", "45.0", "10.0", "24.00", "23 fps live", "P8", "10-bit", "DOVIWITHHDR10",
            "Playback cache", "512 MB", "Encoding", "Lossy encoding"
        ])
    }

    func testLiveDiagnosticsRetainAllSectionsWithinTheCompactPanel() async throws {
        var diagnostics = fixture
        diagnostics.liveStream = .init(
            route: "Native HLS", playlistType: "LIVE", behindLiveSeconds: 12, windowSeconds: 300,
            programDate: Date(timeIntervalSince1970: 1_790_000_000), startupSeconds: 1.5,
            tuneToFirstFrameSeconds: 2, variantSwitches: 3, segmentRequests: 123,
            bytesTransferred: 45_000_000, overdueSegments: 2, errorCount: 1, lastErrorStatus: 503
        )
        diagnostics.liveStream?.variantWidth = 1920
        diagnostics.liveStream?.variantHeight = 1080
        diagnostics.liveStream?.variantBitrate = 8_000_000
        try await assertControlClearance(diagnostics: diagnostics, expectedTokens: [
            "Native HLS", "Rewind", "Segments", "123 req", "503", "1080", "HDMI",
            "Thermal", "engines 2", "Stalls", "Dropped", "82.0"
        ])
    }

    private func assertControlClearance(diagnostics: PlaybackDiagnostics, expectedTokens: [String]) async throws {
        let scene = try await activeScene()
        let previous = scene.windows.first(where: \.isKeyWindow)
        let model = PlayerControlsModel()
        model.title = "Diagnostics layout fixture"
        model.infoCard.headline = "Visible Info card"
        model.infoCard.overview = "The full diagnostic panel must clear this card and its Info and Cast tabs."
        let measurement = PanelMeasurement()
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        root.view.backgroundColor = .black
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let diagnostics = PlaybackDiagnosticsOverlay(diagnostics: diagnostics)
        let panel = UIHostingController(rootView:
            TelevisionDiagnosticsPlacement(controlsLayout: model.subtitleLayout) { width in
                diagnostics.televisionPanel(width: width)
                    .environment(\.themePalette, .dark)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .reportSubtitleControlsFrame { measurement.frame = $0 }
            }
        )
        let controls = UIHostingController(rootView: PlayerControls(
            model: model, palette: .dark, actions: PlayerOptionsActions(), onExitToSurface: {}
        ).transaction { $0.disablesAnimations = true; $0.animation = nil })
        for host in [panel as UIViewController, controls as UIViewController] {
            root.addChild(host)
            host.view.frame = root.view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.view.backgroundColor = .clear
            root.view.addSubview(host.view)
            host.didMove(toParent: root)
        }
        panel.safeAreaRegions = []
        controls.safeAreaRegions = []
        for info in [false, true] {
            model.controlsVisible = true
            model.controlBar.entry = info ? .info : .trackControls
            model.controlBarVisible = true
            try await waitUntil {
                window.layoutIfNeeded()
                let controlFrame = model.subtitleLayout.frame(for: info ? .card : .transport)
                guard controlFrame != nil, let frame = measurement.frame else { return false }
                return frame.height > 100 && model.subtitleLayout.frames.allSatisfy {
                    !frame.intersects($0) && frame.maxY <= $0.minY - 23
                }
            }
            let frame = try XCTUnwrap(measurement.frame)
            XCTAssertEqual(frame.width, 1280, accuracy: 1, "The panel must use at most two-thirds of a 1920-point viewport")
            XCTAssertLessThan(frame.height, 580, "All sections should fit above the Info card")
            let format = UIGraphicsImageRendererFormat()
            format.scale = 3
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let text = try recognizedPanelText(image, frame: frame)
            for token in expectedTokens {
                XCTAssertTrue(text.contains(token), "Missing '\(token)' from the complete panel: \(text)")
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = info ? "Diagnostics above Info card" : "Diagnostics above transport"
            attachment.lifetime = .keepAlways
            add(attachment)
            model.controlBarVisible = false
            model.controlsVisible = false
            try await waitUntil { model.subtitleLayout.frames.isEmpty }
        }
        try await waitUntil { measurement.frame != nil }
        model.subtitleLayout.setFrame(CGRect(x: 0, y: 100, width: 1920, height: 980), for: .menu)
        try await waitUntil { measurement.frame == nil }
        model.subtitleLayout.setFrame(nil, for: .menu)
        try await waitUntil { measurement.frame != nil }
    }

    private func recognizedPanelText(_ image: UIImage, frame: CGRect) throws -> String {
        let cgImage = try XCTUnwrap(image.cgImage)
        let panel = try XCTUnwrap(cgImage.cropping(to: CGRect(
            x: frame.minX * image.scale, y: frame.minY * image.scale,
            width: frame.width * image.scale, height: frame.height * image.scale
        )))
        var lines: [String] = []
        // Full columns keep wrapped values together when overlapping tiles split a line.
        for column in 0..<3 {
            let x = panel.width * column / 3
            let end = panel.width * (column + 1) / 3
            let image = try XCTUnwrap(panel.cropping(to: CGRect(
                x: x, y: 0, width: end - x, height: panel.height
            )))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: image).perform([request])
            lines += (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        }
        for y in stride(from: 0, to: panel.height, by: 1000) {
            for x in stride(from: 0, to: panel.width, by: 1200) {
                let tile = try XCTUnwrap(panel.cropping(to: CGRect(
                    x: x, y: y, width: min(1800, panel.width - x), height: min(1200, panel.height - y)
                )))
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                try VNImageRequestHandler(cgImage: tile).perform([request])
                lines += (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            }
        }
        return lines.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private var fixture: PlaybackDiagnostics {
        var value = PlaybackDiagnostics(
            resolution: .init(width: 3840, height: 2160), indicatedBitrate: 33_200_000, observedBitrate: 82_000_000,
            videoCodec: "HEVC", videoBitrate: 29_000_000,
            audioCodec: "Dolby Atmos", audioChannels: 8, audioSampleRate: 48_000, audioBitrate: 4_200_000,
            audioPipelineDescription: "TRUEHD Atmos → APAC 7.1.4",
            audioOutput: .init(renderingMode: .format("Dolby Atmos"), connections: [.format("HDMI")]),
            subtitleDescription: "SubRip · English", container: "mkv", mode: .plozzigen,
            hdr: .dolbyVision, engineName: "AetherEngine v7.44.0", bufferedSecondsAhead: 10, engineBufferedSecondsAhead: 45,
            sessionCache: .init(residentBytes: 536_870_912, effectiveBudgetBytes: 2_147_483_648),
            stallCount: 0, droppedVideoFrames: 0, frameRate: 24, observedFps: 23,
            deviceModel: "Apple TV 4K (2nd gen)", deviceMemoryBytes: 3_000_000_000,
            freeDiskBytes: 600_000_000, totalDiskBytes: 32_000_000_000,
            memoryFootprintBytes: 950_000_000, thermalState: .nominal, liveViewModels: 1, liveNativeEngines: 2,
            sourceFileName: String(repeating: "A long media filename [2160p][Dolby Vision][TrueHD Atmos 7.1] ", count: 5) + ".mkv",
            sourceFileSizeBytes: 28_000_000_000, videoCodecTag: "hvc1", videoBitDepth: 10,
            dolbyVisionProfile: 8, colorTransfer: "smpte2084",
            videoRangeType: "DOVIWITHHDR10", durationSeconds: 7488, positionSeconds: 87,
            seekableStartSeconds: 0, seekableEndSeconds: 7488, playbackState: "Ready · Playing"
        )
        value.sourceProvider = .plex
        value.serverName = "Fixture server"
        value.streamTransport = PlaybackDiagnostics.streamTransportFacts(url: URL(string: "http://127.0.0.1:12345/master.m3u8"))
        return value
    }

    private func activeScene() async throws -> UIWindowScene {
        try await waitUntil { UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive } }
        return try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first {
            $0.activationState == .foregroundActive
        })
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Diagnostics and control geometry did not settle")
    }
    #endif
}

@MainActor
@Observable
private final class PanelMeasurement {
    var frame: CGRect?
}
