import CoreModels
@testable import CoreUI
@testable import FeaturePlayback
import SwiftUI
import UIKit
import XCTest
import Observation

@MainActor
final class SubtitleHDRPreviewHostedTests: XCTestCase {
    func testActualHDRAssetProducesAFrameAndReleasesItsDisplayRequest() async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let options = SubtitlePreviewOptions()
        options.animatesBackground = false
        let presentation = HDRPreviewPresentationFixture()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let host = UIHostingController(rootView: HDRPreviewTransferFixture(options: options, presentation: presentation)
        .padding(80)
        .background(.black)
        .environment(\.scenePhase, .active)
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            options.showsHDRBrightness = false
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        options.showsHDRBrightness = true
        try await waitUntil(seconds: 18) {
            options.hdrPreview.state == .ready || {
                if case .failed = options.hdrPreview.state { return true }
                return false
            }()
        }
        XCTAssertEqual(options.hdrPreview.state, .ready)
        let surface = options.hdrPreview.makeSurface()
        XCTAssertTrue(surface.playerLayer.isReadyForDisplay)
        XCTAssertNotNil(window.playbackDisplayCriteria, "The asset's display-matching criteria must actually be requested.")
        XCTAssertEqual(surface.playerLayer.player?.rate, 0, "A paused preview decodes one frame, then pauses.")
        let player = surface.playerLayer.player
        let criteria = window.playbackDisplayCriteria
        presentation.presented = true
        try await waitUntil {
            guard let fullscreen = host.presentedViewController, !fullscreen.isBeingPresented else { return false }
            return surface.isDescendant(of: fullscreen.view) && surface.playerLayer.isReadyForDisplay
        }
        XCTAssertTrue(surface.playerLayer.player === player)
        XCTAssertEqual(window.playbackDisplayCriteria, criteria)
        let attachment = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
        attachment.name = "HDR10 scene - simulator frame (not HDMI verification)"
        attachment.lifetime = .keepAlways
        add(attachment)
        host.presentedViewController?.dismiss(animated: false)
        try await waitUntil {
            host.presentedViewController == nil && surface.isDescendant(of: host.view)
                && surface.playerLayer.isReadyForDisplay
        }
        XCTAssertTrue(surface.playerLayer.player === player)
        XCTAssertEqual(window.playbackDisplayCriteria, criteria)
        options.showsHDRBrightness = false
        XCTAssertNil(surface.playerLayer.player)
        XCTAssertNil(window.playbackDisplayCriteria)
    }

    @MainActor @Observable
    fileprivate final class HDRPreviewPresentationFixture {
        var presented = false
    }

    private struct HDRPreviewTransferFixture: View {
        let options: SubtitlePreviewOptions
        let presentation: HDRPreviewPresentationFixture
        @FocusState private var focus: SubtitlePreviewControl?
        private let style = SubtitleStyle(fontFamily: .system)

        var body: some View {
            @Bindable var presentation = presentation
            HStack(spacing: 40) {
                SubtitlePreviewControls(
                    style: style, secondaryVisible: false, options: options,
                    fullscreenPresented: $presentation.presented, focus: $focus
                )
                .frame(width: SubtitleStylePanel.panelWidth)
                SubtitleStylePreview(
                    style: style, secondaryVisible: false,
                    referenceSize: SubtitleStylePreviewMetrics.televisionCanvas, options: options
                )
            }
            .onAppear { focus = .header }
        }
    }

    private func waitUntil(seconds: Double = 5, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "The HDR preview did not complete its actual render transition.")
    }
}
