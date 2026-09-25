#if canImport(UIKit) && canImport(SwiftUI)
import CoreModels
import CoreUI
import CoreText
import SwiftUI
import UIKit
import XCTest
@testable import FeaturePlayback

@MainActor
final class SubtitleLineRenderingTests: XCTestCase {
    func testFreezingSystemStyleAndRoundTripHavePixelIdenticalRenderedAppearance() throws {
        let descriptor = try XCTUnwrap(SubtitleSystemFonts.descriptor(for: .caption(.smallCapitals)))
        let appearance = SystemCaptionAppearance(
            textColor: .init(red: 0.9, green: 0.8, blue: 0.2, alpha: 0.63),
            fontFamilyName: nil, fontDescriptor: descriptor,
            allowsSourceColors: false, allowsSourceOpacity: false, allowsSourceFont: false,
            isBold: false, relativeSize: 1.13, edge: .uniform,
            background: .init(red: 0.1, green: 0.3, blue: 0.6, alpha: 0.51),
            windowColor: .init(red: 0.7, green: 0.2, blue: 0.1, alpha: 0.42),
            windowCornerRadius: 7.25
        )
        let system = SystemCaptionStyle(readAppearance: { appearance }, notifications: NotificationCenter())
        let matching = system.resolved(.profileDefault)
        let frozen = system.editing(.profileDefault) { $0.followsSystemStyle = false }
        let restored = try JSONDecoder().decode(SubtitleStyle.self, from: JSONEncoder().encode(frozen))
        var text = SubtitleText("Small capitals\n日本語 gyp", isItalic: true, isBold: true)
        text.runs = [.init(text.string, color: .cyan)]
        let referenceConfig = styledConfig(matching, text: text)
        XCTAssertFalse(referenceConfig.isBold)
        XCTAssertFalse(referenceConfig.isItalic)
        XCTAssertNotNil(referenceConfig.glyphBackground)
        XCTAssertNotNil(referenceConfig.background)
        XCTAssertNotNil(referenceConfig.outline)
        XCTAssertTrue(referenceConfig.fillSpans.isEmpty)
        let reference = try render(referenceConfig, maxWidth: 400)
        for style in [frozen, restored] {
            let config = styledConfig(style, text: text)
            XCTAssertEqual(config, referenceConfig)
            let result = try render(config, maxWidth: 400)
            XCTAssertEqual(result.size, reference.size)
            XCTAssertEqual(result.pixels, reference.pixels)
        }
    }

    func testEditingOnlySizeKeepsRenderedSystemLayersAndSourcePolicy() throws {
        let appearance = SystemCaptionAppearance(
            textColor: .init(red: 0.7, green: 0.6, blue: 0.2, alpha: 0.7),
            fontFamilyName: "Courier",
            fontDescriptor: try XCTUnwrap(UIFont(name: "Courier-Oblique", size: 30)?.fontDescriptor),
            allowsSourceColors: true, allowsSourceOpacity: false, allowsSourceFont: false,
            isBold: false, relativeSize: 1.17, edge: .raised,
            background: .init(red: 0.2, green: 0.1, blue: 0.5, alpha: 0.27),
            windowColor: .init(red: 0, green: 0, blue: 0, alpha: 0.61),
            windowCornerRadius: 5.5
        )
        let system = SystemCaptionStyle(readAppearance: { appearance }, notifications: NotificationCenter())
        let edited = system.editing(.profileDefault) { $0.fontScale = 1.18 }
        var expected = system.resolved(.profileDefault)
        expected.fontScale = 1.18
        var text = SubtitleText("MMMM", isItalic: false, isBold: true)
        text.runs = [.init("MMMM", color: .init(red: 0.9, green: 0.3, blue: 0.1, alpha: 0.2))]
        let beforeConfig = styledConfig(system.resolved(.profileDefault), text: text)
        let editedConfig = styledConfig(edited, text: text)
        let expectedConfig = styledConfig(expected, text: text)
        XCTAssertEqual(editedConfig, expectedConfig)
        XCTAssertEqual(editedConfig.glyphBackground, beforeConfig.glyphBackground)
        XCTAssertEqual(editedConfig.background, beforeConfig.background)
        XCTAssertEqual(editedConfig.fillSpans, beforeConfig.fillSpans)
        XCTAssertEqual(editedConfig.fillSpans.first?.color.cgColor.alpha, 0.7)
        XCTAssertEqual(try render(editedConfig).pixels, try render(expectedConfig).pixels)
    }

    func testSourceOpacityRemainsIndependentAfterFreezingAForcedTextColor() throws {
        let appearance = SystemCaptionAppearance(
            textColor: .init(red: 1, green: 0, blue: 0, alpha: 0.9),
            fontFamilyName: nil, fontDescriptor: UIFont.systemFont(ofSize: 30).fontDescriptor,
            allowsSourceColors: false, allowsSourceOpacity: true,
            isBold: false, relativeSize: 1, edge: .none, background: nil
        )
        let system = SystemCaptionStyle(readAppearance: { appearance }, notifications: NotificationCenter())
        let frozen = system.editing(.profileDefault) { $0.followsSystemStyle = false }
        var text = SubtitleText("MMMM")
        text.runs = [.init("MMMM", color: .init(red: 0, green: 0, blue: 1, alpha: 0.25))]
        for style in [system.resolved(.profileDefault), frozen] {
            let c = styledConfig(style, text: text)
            XCTAssertEqual(c.fillSpans.first?.color, UIColor.red.withAlphaComponent(0.25))
            let pixels = try render(c).pixels
            XCTAssertEqual(Double(try XCTUnwrap(stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }.max())),
                           64, accuracy: 1)
        }
    }

    private func styledConfig(_ style: SubtitleStyle, text: SubtitleText) -> SubtitleLineView.Config {
        StyledCueText(
            text: text, fontSize: 42 * style.fontScale,
            fillColor: Color(red: style.textColor.red, green: style.textColor.green,
                             blue: style.textColor.blue, opacity: style.textColor.alpha),
            style: style
        ).renderedLine.configuration
    }

    func testSystemCaptionFontKeepsTheActualTypefaceInsteadOfFallingBackToSF() {
        var c = config(family: .system, size: 42, text: "System captions")
        c.systemFontDescriptor = UIFont(name: "Courier", size: 42)?.fontDescriptor
        let font = SubtitleLineView().makeCTFont(c)
        XCTAssertTrue((CTFontCopyFamilyName(font) as String).contains("Courier"))
        XCTAssertEqual(CTFontGetSize(font), 42)
    }

    func testNativeCaptionDescriptorsKeepSmallCapitalFeatures() throws {
        let descriptor = try XCTUnwrap(SubtitleSystemFonts.descriptor(for: .caption(.smallCapitals)))
        var c = config(family: .system, size: 42, text: "Small Capitals")
        c.systemFontDescriptor = descriptor
        let font = SubtitleLineView().makeCTFont(c)
        XCTAssertEqual(CTFontCopyAttribute(font, kCTFontFeatureSettingsAttribute) as? NSArray,
                       descriptor.object(forKey: .featureSettings) as? NSArray)
        XCTAssertGreaterThan(try render(c).ink.width, 0)
    }

    func testSourceColorOpacityIsNotPaintedOverAnOpaqueDefaultFill() throws {
        var c = config(family: .system, size: 80, text: "MMMM")
        c.fillSpans = [.init(location: 0, length: 4, color: UIColor.red.withAlphaComponent(0.5))]
        let pixels = try render(c).pixels
        let maximumAlpha = stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }.max()
        XCTAssertEqual(Double(try XCTUnwrap(maximumAlpha)), 128, accuracy: 1)
    }

    func testColorGlyphsHonorTextOpacityWithoutDimmingTheirBackground() throws {
        var c = config(family: .system, size: 80, text: "🙂")
        c.systemFontDescriptor = UIFont.systemFont(ofSize: 80).fontDescriptor
        let opaque = try render(c).pixels
        c.fill = UIColor.white.withAlphaComponent(0.25)
        let transparent = try render(c).pixels
        func maximumAlpha(_ pixels: [UInt8]) -> Double {
            Double(stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }.max() ?? 0)
        }
        XCTAssertGreaterThan(maximumAlpha(opaque), 0)
        XCTAssertEqual(maximumAlpha(transparent), maximumAlpha(opaque) * 0.25, accuracy: 2)
        c.glyphBackground = .blue
        XCTAssertEqual(maximumAlpha(try render(c).pixels), 255)
    }

    func testGlyphBackgroundAndWindowBothRenderInTheirOwnColors() throws {
        var c = config(family: .system, size: 60, text: "MMMM\nI")
        c.glyphBackground = .red
        c.background = .init(color: .blue, cornerRadius: 0, horizontalPadding: 14, verticalPadding: 6)
        let pixels = try render(c).pixels
        let offsets = stride(from: 0, to: pixels.count, by: 4)
        XCTAssertGreaterThan(offsets.filter { pixels[$0] > 240 && pixels[$0 + 2] < 10 }.count, 100)
        XCTAssertGreaterThan(offsets.filter { pixels[$0 + 2] > 240 && pixels[$0] < 10 }.count, 100)
    }

    func testAvenirNextUsesBuiltInFacesForEveryWeightAndSlant() throws {
        let view = SubtitleLineView()
        let faces: [(SubtitleFontWeight, String, String)] = [
            (.regular, "AvenirNext-Regular", "AvenirNext-Italic"),
            (.medium, "AvenirNext-Medium", "AvenirNext-MediumItalic"),
            (.semibold, "AvenirNext-DemiBold", "AvenirNext-DemiBoldItalic"),
            (.bold, "AvenirNext-Bold", "AvenirNext-BoldItalic")
        ]
        for (weight, upright, italic) in faces {
            for (isItalic, expected) in [(false, upright), (true, italic)] {
                var c = config(family: .avenirNext, size: 42, text: "Avenir Next")
                c.weight = weight
                c.isItalic = isItalic
                let resolved = try XCTUnwrap(view.postScriptName(c))
                XCTAssertEqual(resolved, expected)
                let font = try XCTUnwrap(UIFont(name: resolved, size: c.fontSize))
                XCTAssertEqual(font.fontName, expected)
                XCTAssertEqual(font.familyName, "Avenir Next")
                c.isBold = true
                XCTAssertEqual(view.postScriptName(c), isItalic ? "AvenirNext-BoldItalic" : "AvenirNext-Bold")
            }
        }
        XCTAssertEqual(SubtitleFontFamily.avenirNext.postScriptNameCandidates(), ["AvenirNext-Regular"])
    }

    func testEveryFontHugsItsVisibleBottomAndMatchesCapHeight() throws {
        try registerFonts()
        for size: CGFloat in [25, 42, 105] {
            let reference = try render(config(family: .atkinson, size: size, text: "H"))
            for family in SubtitleFontFamily.allCases {
                for weight in family.availableWeights {
                    for italic in [false, true] {
                        var c = config(family: family, size: size, text: "H")
                        c.weight = weight
                        c.isItalic = italic
                        let result = try render(c)
                        XCTAssertEqual(result.ink.height, reference.ink.height, accuracy: 2,
                                       "\(family) \(weight) italic=\(italic) size=\(size)")
                        XCTAssertEqual(result.ink.maxY, result.size.height, accuracy: 1)
                    }
                }
            }
        }
    }

    func testDescendersAccentsWrappingAndFallbackGlyphsStayInsideMeasuredBounds() throws {
        try registerFonts()
        for family in SubtitleFontFamily.allCases {
            for text in [
                "gypqj", "ÉÅÜ çgj", "日本語 한국어 中文", "مرحبا שלום", "🙂",
                "A long subtitle with accents ÉÅ and descenders gypqj that wraps onto several lines."
            ] {
                var c = config(family: family, size: 42, text: text)
                c.isItalic = true
                let result = try render(c, maxWidth: 360)
                XCTAssertGreaterThan(result.ink.height, 0, "\(family): \(text)")
                XCTAssertGreaterThanOrEqual(result.ink.minX, -1)
                XCTAssertGreaterThanOrEqual(result.ink.minY, -1)
                XCTAssertLessThanOrEqual(result.ink.maxX, result.size.width + 1)
                XCTAssertEqual(result.ink.maxY, result.size.height, accuracy: 1)
                XCTAssertLessThanOrEqual(result.size.width, 360)
            }
        }
    }

    func testFallbackScriptsKeepTheirSizeWhenSwitchingLatinFonts() throws {
        try registerFonts()
        for text in ["日本語 한국어 中文", "مرحبا שלום", "🙂"] {
            let reference = try render(config(family: .atkinson, size: 42, text: text))
            for family in SubtitleFontFamily.allCases {
                let result = try render(config(family: family, size: 42, text: text))
                XCTAssertEqual(result.ink.height, reference.ink.height, accuracy: 2, "\(family): \(text)")
            }
        }
    }

    func testMeasuredWidthDoesNotCauseASecondWrap() throws {
        try registerFonts()
        for family in SubtitleFontFamily.allCases {
            let view = SubtitleLineView()
            view.configure(config(
                family: family, size: 42,
                text: "A subtitle that wraps and must keep the same lines when SwiftUI measures it again."
            ))
            let size = view.measure(maxWidth: 360)
            XCTAssertEqual(view.measure(maxWidth: size.width), size, "\(family)")
        }
    }

    func testBoxAndLargeEffectsFitWithoutFontDependentBottomPadding() throws {
        try registerFonts()
        for family in SubtitleFontFamily.allCases {
            let plain = try render(config(family: family, size: 42, text: "gypÉ"))
            var c = config(family: family, size: 42, text: "gypÉ")
            c.outline = .white
            c.outlineWidth = 10
            let outlined = try render(c)
            XCTAssertEqual(outlined.size.height, plain.size.height + 20, accuracy: 1)
            XCTAssertEqual(outlined.ink.maxY, outlined.size.height, accuracy: 1)
            XCTAssertGreaterThanOrEqual(outlined.ink.minY, -1)

            c.outline = nil
            c.outlineWidth = 0
            c.background = SubtitleBackgroundSpec(
                color: .white, cornerRadius: 0, horizontalPadding: 14, verticalPadding: 6
            )
            let boxed = try render(c)
            XCTAssertEqual(boxed.size.height, plain.size.height + 12, accuracy: 1)
            XCTAssertEqual(boxed.ink.maxY, boxed.size.height, accuracy: 1)

            c.background = nil
            c.shadow = SubtitleShadowSpec(offset: CGSize(width: 6, height: 6), blur: 0, color: .white)
            let hardShadow = try render(c)
            XCTAssertEqual(hardShadow.size.height, plain.size.height + 6, accuracy: 1)
            XCTAssertGreaterThanOrEqual(hardShadow.ink.minY, -1)
            XCTAssertEqual(hardShadow.ink.maxY, hardShadow.size.height, accuracy: 1)

            c.shadow = SubtitleShadowSpec(offset: CGSize(width: 6, height: 6), blur: 10, color: .white)
            let shadowed = try render(c)
            XCTAssertGreaterThanOrEqual(shadowed.ink.minY, -1)
            XCTAssertLessThanOrEqual(shadowed.ink.maxY, shadowed.size.height + 1)
            XCTAssertLessThanOrEqual(shadowed.size.height - shadowed.ink.maxY, 6)
        }
    }

    func testDialogueSpansBothScreenEdgesIncludingDualSubtitles() throws {
        try registerFonts()
        let screen = CGSize(width: 960, height: 540)
        for family in SubtitleFontFamily.allCases {
            for position in [-0.05, -0.005, 0.0, 0.005, 0.06, 0.5, 0.9, 0.995, 1.0] {
                for placement: SubtitleStyle.Secondary.Placement? in [nil, .above, .below] {
                    var style = SubtitleStyle.default
                    style.fontFamily = family
                    style.verticalPosition = position
                    style.secondary = placement.map { .init(placement: $0) }
                    let frames = dialogueFrames(
                        style: style, primary: "A subtitle gyp", secondary: "A subtitle gyp", screen: screen
                    )
                    XCTAssertEqual(frames.count, placement == nil ? 1 : 2)
                    let top = try XCTUnwrap(frames.map(\.minY).min())
                    let bottom = try XCTUnwrap(frames.map(\.maxY).max())
                    let blockHeight = bottom - top
                    let requestedTop = screen.height * (1 - position) - blockHeight
                    let expectedTop = position < 0 ? requestedTop : max(0, requestedTop)
                    XCTAssertEqual(top, expectedTop, accuracy: 1,
                                   "\(family) position=\(position) dual=\(String(describing: placement))")
                }
            }
        }
    }

    func testSelectedAnchorStaysFixedWhenASecondLineAppears() throws {
        try registerFonts()
        let screen = CGSize(width: 960, height: 540)
        for family in SubtitleFontFamily.allCases {
            for anchor in [SubtitleStyle.VerticalAnchor.top, .center, .bottom] {
                for placement: SubtitleStyle.Secondary.Placement? in [nil, .above, .below] {
                    var style = SubtitleStyle.default
                    style.fontFamily = family
                    style.verticalAnchor = anchor
                    style.verticalPosition = anchor == .top ? 0.75 : anchor == .bottom ? 0.06 : 0.5
                    style.secondary = placement.map {
                        .init(placement: $0, differentiate: true, relativeScale: 0.5)
                    }
                    let short = dialogueFrames(style: style, primary: "One line.", secondary: "Second track.", screen: screen)
                    let long = dialogueFrames(style: style, primary: "One line.\nAnother line.", secondary: "Second track.", screen: screen)
                    func anchorY(_ frames: [CGRect]) throws -> CGFloat {
                        let top = try XCTUnwrap(frames.map(\.minY).min())
                        let bottom = try XCTUnwrap(frames.map(\.maxY).max())
                        switch anchor {
                        case .top: return top
                        case .center: return (top + bottom) / 2
                        case .bottom: return bottom
                        }
                    }
                    XCTAssertEqual(try anchorY(short), try anchorY(long), accuracy: 1, "\(family) \(anchor)")
                    XCTAssertEqual(try anchorY(long), screen.height * (1 - style.verticalPosition), accuracy: 1)
                }
            }
        }
    }

    func testNegativePositionsContinuePastTheBottomWithEveryAnchor() throws {
        try registerFonts()
        let screen = CGSize(width: 960, height: 540)
        for anchor in SubtitleStyle.VerticalAnchor.allCases {
            for position in [-0.005, -0.05] {
                var style = SubtitleStyle.default
                style.verticalAnchor = anchor
                style.verticalPosition = position
                let frames = dialogueFrames(style: style, primary: "A subtitle.", secondary: "", screen: screen)
                let frame = try XCTUnwrap(frames.first)
                XCTAssertEqual(frame.maxY, screen.height * (1 - position), accuracy: 1)
            }
        }
    }

    func testBottomAnchoredPrimaryStaysPutWhenUpperSecondaryIsEmpty() throws {
        try registerFonts()
        var style = SubtitleStyle.default
        style.secondary = .init(placement: .above)
        let screen = CGSize(width: 960, height: 540)
        let both = dialogueFrames(style: style, primary: "Primary.", secondary: "Secondary.", screen: screen)
        let primaryOnly = dialogueFrames(style: style, primary: "Primary.", secondary: "", screen: screen)
        XCTAssertEqual(
            try XCTUnwrap(both.map(\.maxY).max()),
            try XCTUnwrap(primaryOnly.map(\.maxY).max()),
            accuracy: 1
        )
    }

    func testWhitespaceHasNoDrawnBox() {
        let view = SubtitleLineView()
        view.configure(config(family: .system, size: 42, text: " \n "))
        XCTAssertEqual(view.measure(maxWidth: 400), .zero)
    }

    func testPositionEditsMoveAnAlreadyDisplayedSRTCue() async throws {
        try await assertLiveSRTPositionUpdates(startingWithBitmap: false)
    }

    func testPositionEditsMoveDownloadedSRTAfterSwitchingFromPGS() async throws {
        try await assertLiveSRTPositionUpdates(startingWithBitmap: true)
    }

    private func assertLiveSRTPositionUpdates(startingWithBitmap: Bool) async throws {
        try registerFonts()
        let screen = CGSize(width: 960, height: 540)
        let model = LiveSubtitleModel()
        let host = UIHostingController(rootView: LiveSubtitleOverlay(model: model, controls: PlayerControlsModel()))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(origin: .zero, size: screen))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.frame = CGRect(origin: .zero, size: screen)
        host.view.layoutIfNeeded()

        var bitmapCues: [SubtitleCue] = []
        if startingWithBitmap {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 30)).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 200, height: 30))
            }
            bitmapCues = [.init(
                id: 0, start: 0, end: 60,
                body: .image(.init(
                    cgImage: try XCTUnwrap(image.cgImage),
                    normalizedRect: CGRect(x: 0.25, y: 0.85, width: 0.5, height: 0.1)
                ))
            )]
            model.beginLiveFeed()
            model.tick(5)
            model.updateLiveCues(bitmapCues)
            await Task.yield()
        }

        let srt = """
        1
        00:00:00,000 --> 00:01:00,000
        A downloaded subtitle that stays on screen.
        """
        model.loadPrimary(SubtitleCueParser.parse(srt, id: 900_000))
        model.tick(5)
        // A late decoder callback from the previous PGS track must not take over.
        model.updateLiveCues(bitmapCues)
        XCTAssertEqual(model.primary.first?.text, "A downloaded subtitle that stays on screen.")

        for position in [0.5, 0.005, 0.75, 0.06] {
            model.style.verticalPosition = position
            let deadline = ContinuousClock.now + .seconds(2)
            var bottom: CGFloat?
            repeat {
                await Task.yield()
                host.view.layoutIfNeeded()
                bottom = subtitleViews(in: host.view).map { $0.convert($0.bounds, to: host.view).maxY }.max()
                if let bottom, abs(bottom - screen.height * (1 - position)) <= 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            } while ContinuousClock.now < deadline
            XCTAssertEqual(try XCTUnwrap(bottom), screen.height * (1 - position), accuracy: 1,
                           "Live position edit to \(position) startingWithBitmap=\(startingWithBitmap)")
        }
    }

    func testMultilineAndDifferentlySizedDualSubtitlesTouchBothEdges() throws {
        try registerFonts()
        let screen = CGSize(width: 960, height: 540)
        for family in SubtitleFontFamily.allCases {
            for scale in [0.6, 1.0, 2.5] {
                for position in [0.0, 1.0] {
                    for anchor in SubtitleStyle.VerticalAnchor.allCases {
                        for placement: SubtitleStyle.Secondary.Placement? in [nil, .above, .below] {
                            var style = SubtitleStyle.default
                            style.fontFamily = family
                            style.fontScale = scale
                            style.verticalPosition = position
                            style.verticalAnchor = anchor
                            style.secondary = placement.map {
                                .init(placement: $0, differentiate: true, relativeScale: 0.5)
                            }
                            let frames = dialogueFrames(
                                style: style, primary: "A subtitle gyp.\nAnother line.",
                                secondary: "Small second language.", screen: screen
                            )
                            XCTAssertEqual(frames.count, placement == nil ? 1 : 2)
                            if position == 0 {
                                XCTAssertEqual(try XCTUnwrap(frames.map(\.maxY).max()), screen.height, accuracy: 1)
                            } else {
                                XCTAssertEqual(try XCTUnwrap(frames.map(\.minY).min()), 0, accuracy: 1)
                            }
                            XCTAssertTrue(frames.allSatisfy { $0.minY >= -1 && $0.maxY <= screen.height + 1 })
                        }
                    }
                }
            }
        }
    }

    func testControlsLiftMeasuredTextAndDualLanesWithoutChangingFontOrSpacing() throws {
        try registerFonts()
        let screen = CGSize(width: 960, height: 540)
        let controls = CGRect(x: 30, y: 410, width: 900, height: 130)
        for family in SubtitleFontFamily.allCases {
            for placement: SubtitleStyle.Secondary.Placement? in [nil, .above, .below] {
                var style = SubtitleStyle.default
                style.fontFamily = family
                style.verticalPosition = 0.06
                style.secondary = placement.map { .init(placement: $0, differentiate: true, relativeScale: 0.7) }
                let normal = dialogueFrames(style: style, primary: "A subtitle gyp.\nAnother line.",
                                            secondary: "Second language.", screen: screen)
                let lifted = dialogueFrames(style: style, primary: "A subtitle gyp.\nAnother line.",
                                            secondary: "Second language.", screen: screen, controls: controls)
                XCTAssertEqual(normal.count, lifted.count)
                XCTAssertEqual(try XCTUnwrap(lifted.map(\.maxY).max()),
                               controls.minY - SubtitleOverlayGeometry.controlsClearance, accuracy: 1, "\(family)")
                let displacement = try XCTUnwrap(lifted.first).minY - XCTUnwrap(normal.first).minY
                for (before, after) in zip(normal, lifted) {
                    XCTAssertEqual(before.size.width, after.size.width, accuracy: 1)
                    XCTAssertEqual(before.size.height, after.size.height, accuracy: 1)
                    XCTAssertEqual(after.minY - before.minY, displacement, accuracy: 1)
                }
                XCTAssertEqual(style.verticalPosition, 0.06)
            }
        }
    }

    func testClearDialogueAndAuthoredTopSignsKeepTheirOriginalPlacement() throws {
        try registerFonts()
        let screen = CGSize(width: 960, height: 540)
        let controls = CGRect(x: 30, y: 410, width: 900, height: 130)
        for layout: SubtitleCueLayout? in [nil, .init(alignment: .topCenter),
                                          .init(alignment: .topLeft, anchor: CGPoint(x: 0.3, y: 0.2))] {
            var style = SubtitleStyle.default
            style.verticalPosition = 0.6
            let original = dialogueFrames(style: style, primary: "Already clear", secondary: "",
                                         screen: screen, primaryLayout: layout)
            let withControls = dialogueFrames(style: style, primary: "Already clear", secondary: "",
                                             screen: screen, controls: controls, primaryLayout: layout)
            XCTAssertEqual(original.count, withControls.count)
            XCTAssertEqual(try XCTUnwrap(original.first).minY, try XCTUnwrap(withControls.first).minY, accuracy: 1)
            XCTAssertEqual(try XCTUnwrap(original.first).minX, try XCTUnwrap(withControls.first).minX, accuracy: 1)
        }
    }

    func testAnEmptyReservedDualLaneDoesNotLiftAlreadyClearVisibleText() throws {
        try registerFonts()
        var style = SubtitleStyle.default
        style.fontFamily = .system
        style.verticalPosition = 0.06
        style.secondary = .init(placement: .below)
        let screen = CGSize(width: 960, height: 540)
        let controls = CGRect(x: 30, y: 475, width: 900, height: 65)
        let original = dialogueFrames(style: style, primary: "Clear primary", secondary: "", screen: screen)
            .filter { $0.height > 0 }
        let lifted = dialogueFrames(style: style, primary: "Clear primary", secondary: "",
                                    screen: screen, controls: controls)
            .filter { $0.height > 0 }
        XCTAssertLessThan(try XCTUnwrap(original.first).maxY, controls.minY)
        XCTAssertEqual(try XCTUnwrap(original.first).maxY, try XCTUnwrap(lifted.first).maxY, accuracy: 1)
    }

    private func dialogueFrames(
        style: SubtitleStyle, primary: String, secondary: String, screen: CGSize,
        controls: CGRect? = nil, primaryLayout: SubtitleCueLayout? = nil
    ) -> [CGRect] {
        let overlay = SubtitleOverlayView(
            primary: [.init(id: 0, start: 0, end: 10, body: .text(SubtitleText(primary, layout: primaryLayout)))],
            secondary: style.secondary == nil ? [] : [
                .init(id: 1, start: 0, end: 10, body: .text(SubtitleText(secondary)))
            ],
            secondaryActive: style.secondary != nil,
            style: style,
            videoRect: CGRect(x: 0, y: 70, width: screen.width, height: screen.height - 140),
            controlsFrame: controls
        )
        let host = UIHostingController(rootView: overlay)
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(origin: .zero, size: screen))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.frame = CGRect(origin: .zero, size: screen)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return subtitleViews(in: host.view).map { $0.convert($0.bounds, to: host.view) }
    }

    private func config(family: SubtitleFontFamily, size: CGFloat, text: String) -> SubtitleLineView.Config {
        .init(
            text: text, family: family, weight: .regular, fontSize: size,
            isBold: false, isItalic: false, fill: .white,
            outline: nil, outlineWidth: 0, shadow: nil, background: nil, alignment: .center
        )
    }

    private func registerFonts() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Resources/Fonts")
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where ["ttf", "otf"].contains(url.pathExtension) {
            let name = url.deletingPathExtension().lastPathComponent
            if UIFont(name: name, size: 12) != nil { continue }
            var error: Unmanaged<CFError>?
            let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            XCTAssertTrue(registered, "\(name): \(String(describing: error?.takeRetainedValue()))")
            XCTAssertNotNil(UIFont(name: name, size: 12), name)
        }
    }

    private func subtitleViews(in view: UIView) -> [SubtitleLineView] {
        if let line = view as? SubtitleLineView { return [line] }
        return view.subviews.flatMap { subtitleViews(in: $0) }
    }

    /// Draw on an oversized canvas so ink outside the measured view is detected,
    /// rather than silently clipped by the snapshot itself.
    private func render(
        _ c: SubtitleLineView.Config, maxWidth: CGFloat = 900
    ) throws -> (size: CGSize, ink: CGRect, pixels: [UInt8]) {
        let view = SubtitleLineView()
        view.configure(c)
        let size = view.measure(maxWidth: maxWidth)
        view.bounds = CGRect(origin: .zero, size: size)
        let margin: CGFloat = 40
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: size.width + margin * 2, height: size.height + margin * 2),
            format: format
        ).image { renderer in
            renderer.cgContext.translateBy(x: margin, y: margin)
            view.draw(view.bounds)
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var ink = CGRect.null
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            for y in 0..<height {
                for x in 0..<width where bytes[(y * width + x) * 4 + 3] > 8 {
                    ink = ink.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        XCTAssertFalse(ink.isNull, "\(c.family): \(c.text)")
        return (size, ink.offsetBy(dx: -margin, dy: -margin), pixels)
    }
}
#endif
