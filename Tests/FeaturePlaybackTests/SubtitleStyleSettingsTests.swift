#if canImport(UIKit)
import CoreModels
import CoreUI
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import FeaturePlayback

@MainActor
final class SubtitleStyleSettingsTests: XCTestCase {
    func testEditorDisplaysEffectiveValuesWithoutWritingUntilTheFirstRealEdit() throws {
        let name = "SubtitleStyleEffectiveEditorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SubtitleStyleStore(defaults: defaults, namespace: "viewer")
        let profile = SubtitleStyleModel(store: store)
        profile.usesSeparateLiveTVStyle = true
        let appearance = SystemCaptionAppearance(
            textColor: .init(red: 0.31, green: 0.43, blue: 0.57, alpha: 0.67),
            fontFamilyName: "Courier", fontDescriptor: UIFont(name: "Courier", size: 30)!.fontDescriptor,
            allowsSourceFont: false, isBold: false, relativeSize: 0.73, edge: .uniform,
            background: .init(red: 0.17, green: 0.29, blue: 0.41, alpha: 0.59),
            windowColor: .init(red: 0.13, green: 0.23, blue: 0.37, alpha: 0.47),
            windowCornerRadius: 3.75
        )
        let system = SystemCaptionStyle(readAppearance: { appearance }, notifications: NotificationCenter())
        let controls = PlayerControlsModel()
        controls.subtitleStyle = profile.style
        var writes = 0
        let context = SubtitleStyleEditingContext(
            controls: controls,
            style: Binding(get: { profile.style }, set: { writes += 1; profile.style = $0 }),
            secondaryPreview: .constant(false), systemCaptionStyle: system
        )
        XCTAssertTrue(context.effectiveStyle.followsSystemStyle)
        XCTAssertEqual(context.effectiveStyle.fontScale, 0.73)
        XCTAssertEqual(context.effectiveStyle.textColor, appearance.textColor)
        XCTAssertEqual(context.effectiveStyle.background.cornerRadius, 3.75)
        XCTAssertEqual(context.effectiveStyle.glyphBackground, appearance.background)
        let fontName = try XCTUnwrap(context.effectiveStyle.fontDescriptor).displayName
        XCTAssertTrue(fontName.contains("Courier"))
        XCTAssertEqual(context.effectiveStyle.fontDisplayName, Text(verbatim: fontName))
        XCTAssertEqual(writes, 0)
        context.editSubtitleStyle { $0.fontScale = 0.73 }
        XCTAssertEqual(writes, 0)
        context.editSubtitleStyle { $0.fontScale = 0.74 }
        XCTAssertEqual(writes, 1)
        XCTAssertFalse(profile.style.followsSystemStyle)
        XCTAssertEqual(store.load().base.fontScale, 0.74)
        XCTAssertEqual(store.load().base.textColor, appearance.textColor)
        XCTAssertEqual(store.load().base.fontDescriptor, context.effectiveStyle.fontDescriptor)
        XCTAssertEqual(store.load().liveTV, .profileDefault)
        for value in [0.75, 0.76, 0.78, 0.82] { context.editSubtitleStyle { $0.fontScale = value } }
        XCTAssertEqual(writes, 5)
        XCTAssertEqual(profile.style.fontScale, 0.82)
        XCTAssertEqual(profile.style.glyphBackground, appearance.background)
        context.editSubtitleStyle { $0.followsSystemStyle = true }
        XCTAssertTrue(profile.style.followsSystemStyle)
        XCTAssertEqual(context.effectiveStyle.fontScale, 0.73)
        context.applySubtitleStyle(.default)
        XCTAssertEqual(store.load().base, .default)
        XCTAssertFalse(store.load().base.followsSystemStyle)
        XCTAssertEqual(store.load().base.fontFamily, .atkinson)
        XCTAssertNil(store.load().base.fontDescriptor)
        XCTAssertTrue(SubtitleStyleStore(defaults: defaults, namespace: "other").load().base.followsSystemStyle)
    }

    func testEditingHDRBrightnessEnablesPreviewWithoutChangingTheSavedStyle() {
        let options = SubtitlePreviewOptions()
        var style = SubtitleStyle.default
        options.styleDidChange(from: style, to: style)
        XCTAssertFalse(options.showsHDRBrightness)
        var changed = style
        changed.fontScale = 1.01
        options.styleDidChange(from: style, to: changed)
        XCTAssertFalse(options.showsHDRBrightness)
        changed.hdrLuminanceScale = 0.5
        options.styleDidChange(from: style, to: changed)
        XCTAssertTrue(options.showsHDRBrightness)
        XCTAssertEqual(changed.hdrLuminanceScale, 0.5)
        options.showsHDRBrightness = false
        style = changed
        changed.textColor = .cyan
        options.styleDidChange(from: style, to: changed)
        XCTAssertFalse(options.showsHDRBrightness, "Other edits must respect a manual SDR-preview choice.")
    }

    func testHDRPreviewToggleUsesConfiguredBrightnessOnTheExistingRenderer() async throws {
        let model = HDRSubtitlePreviewFixtureModel()
        let host = UIHostingController(rootView: HDRSubtitlePreviewFixture(model: model))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 960, height: 700))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds

        func firstLine(in view: UIView) -> SubtitleLineView? {
            if let line = view as? SubtitleLineView { return line }
            return view.subviews.lazy.compactMap { firstLine(in: $0) }.first
        }
        func waitForBrightness(_ expected: Double) async throws -> SubtitleLineView {
            let deadline = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < deadline {
                await Task.yield()
                host.view.layoutIfNeeded()
                if let line = firstLine(in: host.view), line.bounds.width > 0,
                   abs(try self.maximumGlyphBrightness(line) - expected) < 3 {
                    return line
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let line = try XCTUnwrap(firstLine(in: host.view))
            XCTAssertEqual(try maximumGlyphBrightness(line), expected, accuracy: 3)
            return line
        }

        let original = try await waitForBrightness(255)
        model.options.showsHDRBrightness = true
        let fullBrightness = try await waitForBrightness(255)
        XCTAssertTrue(fullBrightness === original, "100% deliberately looks identical in SDR and HDR preview.")
        model.style.hdrLuminanceScale = 0.5
        let dimmed = try await waitForBrightness(128)
        XCTAssertTrue(dimmed === original)
        model.options.showsHDRBrightness = false
        let standard = try await waitForBrightness(255)
        XCTAssertTrue(standard === original)
        model.options.showsHDRBrightness = true
        model.style.hdrLuminanceScale = 0.2
        _ = try await waitForBrightness(51)
    }

    private func maximumGlyphBrightness(_ line: SubtitleLineView) throws -> Double {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(bounds: line.bounds, format: format).image { _ in line.draw(line.bounds) }
        let bitmap = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: bitmap.width * bitmap.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: bitmap.width, height: bitmap.height,
                bitsPerComponent: 8, bytesPerRow: bitmap.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(bitmap, in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        }
        let opaque = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0 + 3] > 250 }
        return Double(try XCTUnwrap(opaque.map { pixels[$0] }.max()))
    }

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
        XCTAssertEqual(store.load().liveTV, .profileDefault)
        XCTAssertTrue(context.hasSecondarySubtitle)
        XCTAssertTrue(controls.secondarySubtitleOptions.isEmpty, "Previewing a second line must not invent a playback track.")
    }

    func testTVPreviewScalesTheRenderedTextAndPlacementWithTheWholeCanvas() throws {
        var style = SubtitleStyle.default
        style.fontFamily = .system
        style.verticalPosition = 0.18
        style.secondary = .init(placement: .above)
        for scale in [SubtitleStyle.fontScaleRange.lowerBound, 1, SubtitleStyle.fontScaleRange.upperBound] {
            style.fontScale = scale
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

@MainActor @Observable
private final class HDRSubtitlePreviewFixtureModel {
    var style: SubtitleStyle = {
        var style = SubtitleStyle.default
        style.fontFamily = .system
        style.background.isEnabled = false
        style.border.isEnabled = false
        style.edge.style = .none
        return style
    }()
    let options: SubtitlePreviewOptions = {
        let options = SubtitlePreviewOptions()
        options.animatesBackground = false
        return options
    }()
}

private struct HDRSubtitlePreviewFixture: View {
    let model: HDRSubtitlePreviewFixtureModel

    var body: some View {
        SubtitleStylePreviewCanvas(
            style: model.style, secondaryVisible: false,
            referenceSize: SubtitleStylePreviewMetrics.televisionCanvas,
            showsHDRBrightness: model.options.showsHDRBrightness,
            animate: false
        )
    }
}
#endif
