#if canImport(UIKit)
import CoreModels
import CoreUI
import SwiftUI
import UIKit
import XCTest
@testable import FeaturePlayback

@MainActor
final class SubtitleStyleSettingsTests: XCTestCase {
    func testInlineAndFullScreenPreviewShareBackgroundPhaseWithoutDoubleAdvancing() {
        let options = SubtitlePreviewOptions()
        let tick = ContinuousClock.now.advanced(by: .seconds(9))
        options.advanceBackground(at: tick)
        XCTAssertEqual(options.backgroundPhase, 1)
        options.advanceBackground(at: tick)
        XCTAssertEqual(options.backgroundPhase, 1)
        options.animatesBackground = false
        XCTAssertEqual(options.backgroundPhase, 1, "Pausing or changing preview size must retain the current palette.")
    }

    func testEditorUsesTheSameProfileStyleAndKeepsLiveTVSeparate() throws {
        let name = "SubtitleStyleSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SubtitleStyleStore(defaults: defaults, namespace: "viewer")
        let profile = SubtitleStyleModel(store: store)
        profile.usesSeparateLiveTVStyle = true
        let controls = PlayerControlsModel()
        let context = SubtitleStyleEditingContext(
            controls: controls,
            style: Binding(get: { profile.style }, set: { profile.style = $0 }),
            secondaryPreview: .constant(true)
        )
        var style = SubtitleStyle.default
        style.fontScale = 0.4
        style.edge.thickness = 9
        style.border.width = 4
        style.background.cornerRadius = 32
        style.background.horizontalPadding = 24
        style.background.verticalPadding = 18
        style.verticalAnchor = .center
        style.horizontalOffset = -0.3
        style.hdrLuminanceScale = 0.55
        style.secondary = .init(placement: .below, differentiate: true, relativeScale: 0.75, textColor: .cyan, gap: 16)
        context.applySubtitleStyle(style)
        XCTAssertEqual(controls.subtitleStyle, style)
        XCTAssertEqual(store.load().base, style)
        XCTAssertEqual(store.load().liveTV, .default)
        XCTAssertTrue(context.hasSecondarySubtitle)
        XCTAssertTrue(controls.secondarySubtitleOptions.isEmpty, "Previewing a second line must not invent a playback track.")
    }

    func testTVPreviewScalesTheRenderedTextAndPlacementWithTheWholeCanvas() throws {
        var style = SubtitleStyle.default
        style.fontFamily = .system
        style.verticalPosition = 0.18
        style.secondary = .init(placement: .above)
        let full = try subtitleFrames(style: style, width: 1920)
        let half = try subtitleFrames(style: style, width: 960)
        XCTAssertEqual(full.count, 2)
        XCTAssertEqual(half.count, 2)
        for (large, small) in zip(full, half) {
            XCTAssertEqual(small.minX, large.minX / 2, accuracy: 1)
            XCTAssertEqual(small.minY, large.minY / 2, accuracy: 1)
            XCTAssertEqual(small.width, large.width / 2, accuracy: 1)
            XCTAssertEqual(small.height, large.height / 2, accuracy: 1)
        }
    }

    func testBackgroundCycleIncludesLightDarkAndColorfulSurfaces() {
        func luminance(_ color: Color) -> CGFloat {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a))
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        XCTAssertTrue(SubtitlePreviewPalettes.light.allSatisfy { luminance($0) > 0.85 })
        XCTAssertTrue(SubtitlePreviewPalettes.dark.allSatisfy { luminance($0) < 0.2 })
        XCTAssertEqual(SubtitlePreviewPalettes.cycle.count, 3)
        XCTAssertTrue(SubtitlePreviewPalettes.cycle.allSatisfy { $0.count <= 2 })
        XCTAssertEqual(SubtitlePreviewPalettes.comparison.count, 3)
        XCTAssertTrue(SubtitlePreviewPalettes.comparison.contains { luminance($0) > 0.85 })
        XCTAssertTrue(SubtitlePreviewPalettes.comparison.contains { luminance($0) < 0.2 })
    }

    private func subtitleFrames(style: SubtitleStyle, width: CGFloat) throws -> [CGRect] {
        let size = CGSize(width: width, height: width * 9 / 16)
        let host = UIHostingController(rootView: SubtitleStylePreviewCanvas(
            style: style, secondaryVisible: true,
            referenceSize: SubtitleStylePreviewMetrics.televisionCanvas, animate: false
        ))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        func lines(_ view: UIView) -> [SubtitleLineView] {
            if let line = view as? SubtitleLineView { return [line] }
            return view.subviews.flatMap(lines)
        }
        return lines(host.view).map { $0.convert($0.bounds, to: host.view) }
    }
}
#endif
