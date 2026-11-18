#if canImport(UIKit)
import CoreModels
import SwiftUI
import UIKit
import XCTest
@testable import CoreUI

@MainActor
final class ChannelLogoArtworkTests: XCTestCase {
    func testIndependentInsetsGiveCompactLogosHeightAndWideLogosSideClearance() throws {
        for sourceSize in [CGSize(width: 20, height: 20), CGSize(width: 32, height: 20), CGSize(width: 80, height: 20)] {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let logo = UIGraphicsImageRenderer(size: sourceSize, format: format).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(origin: .zero, size: sourceSize))
            }
            let renderer = ImageRenderer(content: ChannelLogoPlateContent(
                name: "", image: logo, plate: ChannelLogoPlate(tone: nil),
                size: CGSize(width: 140, height: 72), cornerRadius: 16, artworkInset: 4,
                isTile: true, usesControlBackground: true, horizontalArtworkInset: 20
            ))
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            let pixels = try rgbaPixels(image)
            let ink = stride(from: 0, to: pixels.count, by: 4).filter {
                pixels[$0] > 200 && pixels[$0 + 1] < 50 && pixels[$0 + 3] > 128
            }.map { CGPoint(x: ($0 / 4) % image.width, y: ($0 / 4) / image.width) }
            let width = try XCTUnwrap(ink.map(\.x).max()) - XCTUnwrap(ink.map(\.x).min()) + 1
            let height = try XCTUnwrap(ink.map(\.y).max()) - XCTUnwrap(ink.map(\.y).min()) + 1
            XCTAssertEqual(width / height, sourceSize.width / sourceSize.height, accuracy: 0.05)
            if sourceSize.width == sourceSize.height {
                XCTAssertEqual(height, 64, accuracy: 1)
            } else if sourceSize.width == 32 {
                XCTAssertEqual(width, 81, accuracy: 1)
                XCTAssertEqual(height, 51, accuracy: 1)
            } else {
                XCTAssertEqual(width, 100, accuracy: 1)
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(ink.map(\.x).min()), 20)
            }
        }
    }

    func testNativeControlArtworkKeepsItsFullRestingBackground() throws {
        for id: String? in [nil, "plozz-channel"] {
            for usesControlBackground in [false, true] {
                let renderer = ImageRenderer(content: ChannelLogoArtwork(
                    name: "News", logoURL: nil, size: CGSize(width: 160, height: 72),
                    cornerRadius: 16, artworkInset: 8, plozzChannelID: id,
                    usesControlBackground: usesControlBackground
                ))
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.cgImage)
                let pixels = try rgbaPixels(image)
                for point in [(80, 2), (4, 36), (156, 36)] {
                    let alpha = pixels[(point.1 * image.width + point.0) * 4 + 3]
                    XCTAssertEqual(alpha, 255)
                }
            }
        }
    }

    func testNativeControlUsesTheExistingFullPlateBehindLogoInk() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        for (color, tone, expected) in [
            (UIColor.white, ResolvedLogoTone(luminance: 1, coverage: 0.4, brightInk: 1), [255, 255, 255]),
            (UIColor.black, ResolvedLogoTone(luminance: 0, coverage: 0.4), [0, 0, 0]),
            (UIColor.red, ResolvedLogoTone(luminance: 0.21, coverage: 0.4, red: 1), [255, 0, 0])
        ] {
            let logo = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20), format: format).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
            }
            for prefersLight in [false, true] {
                let plate = ChannelLogoPlate(tone: tone, prefersLight: prefersLight)
                let renderer = ImageRenderer(content: ChannelLogoPlateContent(
                    name: "", image: logo, plate: plate,
                    size: CGSize(width: 160, height: 72), cornerRadius: 16, artworkInset: 8,
                    usesControlBackground: true
                ))
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.cgImage)
                let pixels = try rgbaPixels(image)
                let center = (36 * image.width + 80) * 4
                XCTAssertEqual(pixels[center..<(center + 3)].map(Int.init), expected)
                let side = (36 * image.width + 4) * 4
                XCTAssertEqual(pixels[(2 * image.width + 80) * 4 + 3], 255)
                XCTAssertEqual(pixels[side + 3], 255)
                for (channel, component) in [plate.red, plate.green, plate.blue].enumerated() {
                    XCTAssertEqual(Double(pixels[side + channel]), component * 255, accuracy: 1)
                }
            }
        }
    }

    func testMixedAndBoxedLogosKeepEveryInkColourAcrossFocusSurfaces() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let logo = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
            UIColor.red.setFill()
            context.fill(CGRect(x: 20, y: 0, width: 20, height: 20))
        }
        for tile in [false, true] {
            for prefersLight in [false, true] {
                let tone = ResolvedLogoTone(
                    luminance: 0.6, coverage: tile ? 1 : 0.4,
                    red: 1, green: 0.5, blue: 0.5, brightInk: 0.5
                )
                let renderer = ImageRenderer(content: ChannelLogoPlateContent(
                    name: "", image: logo, plate: ChannelLogoPlate(tone: tone, prefersLight: prefersLight),
                    size: CGSize(width: 160, height: 72), cornerRadius: 16, artworkInset: 8,
                    isTile: tile, usesControlBackground: true
                ))
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.cgImage)
                let pixels = try rgbaPixels(image)
                for (x, expected) in [(60, [255, 255, 255]), (100, [255, 0, 0])] {
                    let offset = (36 * image.width + x) * 4
                    XCTAssertEqual(pixels[offset..<(offset + 3)].map(Int.init), expected)
                }
            }
        }
    }

    func testNativeControlRestoresSourceBackgroundAcrossTheWholePlate() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let logo = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 10, y: 0, width: 20, height: 20))
        }
        let renderer = ImageRenderer(content: ChannelLogoPlateContent(
            name: "", image: logo, plate: ChannelLogoPlate(tone: ResolvedLogoTone(
                luminance: 1, coverage: 0.4,
                backgroundPlate: HeroBackgroundSample(red: 1, green: 0, blue: 0, luminance: 0.21)
            )),
            size: CGSize(width: 160, height: 72), cornerRadius: 16, artworkInset: 8,
            usesControlBackground: true
        ).environment(\.colorScheme, .light))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let pixels = try rgbaPixels(image)
        let center = (36 * image.width + 80) * 4
        XCTAssertEqual(Array(pixels[center..<(center + 4)]), [255, 255, 255, 255])
        let edge = (36 * image.width + 4) * 4
        XCTAssertEqual(Array(pixels[edge..<(edge + 4)]), [255, 0, 0, 255])
        let redPixels = stride(from: 0, to: pixels.count, by: 4).filter {
            pixels[$0] > 250 && pixels[$0 + 1] < 5 && pixels[$0 + 2] < 5 && pixels[$0 + 3] == 255
        }
        XCTAssertGreaterThan(redPixels.count, image.width * image.height / 2)
    }

    func testPlozzWordmarksKeepTheirMoodAcrossSizesAndRespectTheAppTheme() throws {
        for mood in LibraryChannelArtworkMood.allCases {
            var themeLuminances: [Double] = []
            for palette in [ThemePalette.light, .dark, .pureBlack] {
                var referencePixel: [UInt8]?
                for size in [CGSize(width: 200, height: 128), CGSize(width: 112, height: 72)] {
                    let renderer = ImageRenderer(content: ChannelLogoArtwork(
                        name: "Movies", logoURL: nil, size: size, cornerRadius: 12,
                        plozzChannelID: "plozz-test-channel", plozzChannelMood: mood
                    )
                        .environment(\.themePalette, palette)
                        .environment(\.colorScheme, palette.isLight ? .dark : .light))
                    renderer.scale = 1
                    let image = try XCTUnwrap(renderer.cgImage)
                    XCTAssertEqual(image.width, Int(size.width))
                    XCTAssertEqual(image.height, Int(size.height))
                    let pixels = try rgbaPixels(image)
                    let offset = ((image.height - 5) * image.width + image.width / 2) * 4
                    let pixel = Array(pixels[offset..<(offset + 4)])
                    XCTAssertEqual(pixel[3], 255)
                    if let referencePixel { XCTAssertEqual(pixel, referencePixel) }
                    else {
                        referencePixel = pixel
                        themeLuminances.append(luminance(pixel))
                    }
                    XCTAssertEqual(pixels[3], 0)
                    let title = inkPoints(pixels, image: image, background: pixel, yRange: 0.12..<0.62)
                    let signature = inkPoints(pixels, image: image, background: pixel, yRange: 0.65..<0.90)
                    XCTAssertGreaterThan(title.count, signature.count * 2, "The channel name must dominate.")
                    let titleLeft = try XCTUnwrap(title.map(\.x).min())
                    let signatureLeft = try XCTUnwrap(signature.map(\.x).min())
                    XCTAssertGreaterThanOrEqual(titleLeft, size.width * 0.11)
                    XCTAssertGreaterThanOrEqual(signatureLeft, size.width * 0.12)
                    XCTAssertEqual(titleLeft, signatureLeft, accuracy: 3 * size.height / 128)
                    XCTAssertLessThan(try XCTUnwrap(signature.map(\.y).max()), size.height * 0.84)
                    XCTAssertGreaterThan(maxContrast(title, pixels: pixels, image: image, background: pixel), 7)
                    XCTAssertGreaterThan(maxContrast(signature, pixels: pixels, image: image, background: pixel), 4.5)
                }
            }
            XCTAssertGreaterThan(themeLuminances[0], themeLuminances[1])
            XCTAssertGreaterThan(themeLuminances[1], themeLuminances[2])
        }
    }

    func testUnknownChannelsUseNeutralArtworkAndMoodOnlyAppliesToPlozzChannels() throws {
        func render(id: String?, mood: LibraryChannelArtworkMood?, logoURL: URL? = nil) throws -> [UInt8] {
            let renderer = ImageRenderer(content: ChannelLogoArtwork(
                name: "Movies", logoURL: logoURL, size: CGSize(width: 200, height: 128),
                cornerRadius: 12, plozzChannelID: id, plozzChannelMood: mood
            ))
            renderer.scale = 1
            return try rgbaPixels(XCTUnwrap(renderer.cgImage))
        }
        XCTAssertEqual(try render(id: "a", mood: nil), try render(id: "b", mood: .neutral))
        XCTAssertNotEqual(try render(id: "a", mood: .calm), try render(id: "a", mood: .intense))
        XCTAssertEqual(try render(id: nil, mood: nil), try render(id: nil, mood: .playful))
        let url = try XCTUnwrap(URL(string: "https://example.invalid/logo.png"))
        XCTAssertEqual(
            try render(id: "a", mood: .calm, logoURL: url),
            try render(id: nil, mood: nil, logoURL: url),
            "A real source-logo URL must take precedence over generated artwork, even before it loads."
        )
    }

    func testPlozzWordmarksFitLongAndNonLatinChannelNames() {
        for name in ["Movies", "TV Shows", "Documentary & Nature", "Studio Ghibli", "日本のアニメ", "أفلام عربية"] {
            for size in [CGSize(width: 200, height: 128), CGSize(width: 112, height: 72)] {
                let mark = ChannelLogoArtwork(
                    name: name, logoURL: nil, size: size, cornerRadius: 12, plozzChannelID: "channel"
                )
                let measured = UIHostingController(rootView: mark).sizeThatFits(in: CGSize(width: 600, height: 600))
                XCTAssertEqual(measured.width, size.width, accuracy: 0.5)
                XCTAssertEqual(measured.height, size.height, accuracy: 0.5)
            }
        }
    }

    func testPlozzChannelWordmarkContactSheet() throws {
        let names = ["Movies", "TV Shows", "Animation", "Documentary & Nature", "Horror", "Science Fiction"]
        let moods: [LibraryChannelArtworkMood] = [.cinematic, .neutral, .playful, .calm, .mysterious, .imaginative]
        let sheet = VStack(spacing: 20) {
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                HStack(spacing: 20) {
                    ForEach(0..<3) { theme in
                        ChannelLogoArtwork(
                            name: name, logoURL: nil, size: CGSize(width: 200, height: 128), cornerRadius: 26,
                            plozzChannelID: "channel-\(index)", plozzChannelMood: moods[index]
                        )
                        .environment(\.themePalette, [ThemePalette.light, .dark, .pureBlack][theme])
                    }
                    ChannelLogoArtwork(
                        name: name, logoURL: nil, size: CGSize(width: 112, height: 72), cornerRadius: 12,
                        plozzChannelID: "channel-\(index)", plozzChannelMood: moods[index]
                    )
                }
            }
        }
        .padding(24)
        .background(Color.black)
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        let attachment = XCTAttachment(image: image)
        attachment.name = "plozz-byline-light-dark-black-compact"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func inkPoints(
        _ pixels: [UInt8], image: CGImage, background: [UInt8], yRange: Range<Double>
    ) -> [CGPoint] {
        (Int(Double(image.height) * yRange.lowerBound)..<Int(Double(image.height) * yRange.upperBound)).flatMap { y in
            (Int(Double(image.width) * 0.10)..<Int(Double(image.width) * 0.90)).compactMap { x in
                let offset = (y * image.width + x) * 4
                let difference = (0..<3).map { abs(Int(pixels[offset + $0]) - Int(background[$0])) }.max() ?? 0
                return difference > 75 ? CGPoint(x: x, y: y) : nil
            }
        }
    }

    private func luminance(_ pixel: [UInt8]) -> Double {
        let linear = pixel.prefix(3).map { component -> Double in
            let value = Double(component) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
    }

    private func maxContrast(_ points: [CGPoint], pixels: [UInt8], image: CGImage, background: [UInt8]) -> Double {
        let field = luminance(background)
        return points.map { point in
            let offset = (Int(point.y) * image.width + Int(point.x)) * 4
            let ink = luminance(Array(pixels[offset..<(offset + 4)]))
            return (max(field, ink) + 0.05) / (min(field, ink) + 0.05)
        }.max() ?? 0
    }

    func testDarkColouredInkGetsASubtleLightBrandTint() {
        for luminance in [0.08, 0.3, 0.55] {
            let plate = ChannelLogoPlate(tone: ResolvedLogoTone(
                luminance: luminance, coverage: 0.4, red: 0.8, green: 0.15, blue: 0.1
            ), prefersLight: true)
            XCTAssertGreaterThan(min(plate.red, plate.green, plate.blue), 0.93)
            XCTAssertGreaterThan(plate.red, plate.green)
            XCTAssertLessThan(max(plate.red, plate.green, plate.blue) - min(plate.red, plate.green, plate.blue), 0.04)
            XCTAssertTrue(plate.isLight)
        }
    }

    func testSmallWhiteWordmarkUnderAColouredIconKeepsDarkBacking() {
        let plate = ChannelLogoPlate(tone: ResolvedLogoTone(
            luminance: 0.35, coverage: 0.4, red: 0.9, green: 0.3, blue: 0.1, brightInk: 0.06
        ))
        XCTAssertFalse(plate.isLight)
        XCTAssertLessThan(max(plate.red, plate.green, plate.blue), 0.24)
    }

    func testNeutralInkDoesNotInventAChannelColour() {
        let darkInk = ChannelLogoPlate(tone: ResolvedLogoTone(
            luminance: 0.2, coverage: 0.4, red: 0.2, green: 0.2, blue: 0.2
        ), prefersLight: true)
        XCTAssertEqual(darkInk.color, Color(red: 1, green: 1, blue: 1))
        let whiteInk = ChannelLogoPlate(tone: ResolvedLogoTone(
            luminance: 1, coverage: 0.4, red: 1, green: 1, blue: 1, brightInk: 1
        ))
        XCTAssertEqual(whiteInk, ChannelLogoPlate(tone: nil))
    }

    func testMutedBrandTintsRetainStrongBlackOrWhiteInkContrast() {
        for ink in [(1.0, 0.0, 0.0), (0.0, 0.2, 1.0), (1.0, 0.8, 0.0)] {
            for whiteLettering in [false, true] {
                let plate = ChannelLogoPlate(tone: ResolvedLogoTone(
                    luminance: 0.4, coverage: 0.4,
                    red: ink.0, green: ink.1, blue: ink.2, brightInk: whiteLettering ? 0.1 : 0
                ), prefersLight: !whiteLettering)
                func linear(_ value: Double) -> Double {
                    value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
                }
                let luminance = 0.2126 * linear(plate.red)
                    + 0.7152 * linear(plate.green) + 0.0722 * linear(plate.blue)
                let contrast = whiteLettering ? 1.05 / (luminance + 0.05) : (luminance + 0.05) / 0.05
                XCTAssertGreaterThan(contrast, 7)
            }
        }
    }

    func testOriginalWhitePlateWinsEvenWithBrightHighlightsInsideTheLogo() {
        let tone = ResolvedLogoTone(
            luminance: 0.5, coverage: 1, brightInk: 0.6,
            backgroundPlate: HeroBackgroundSample(red: 1, green: 1, blue: 1, luminance: 1)
        )
        XCTAssertEqual(ChannelLogoPlate(tone: tone, prefersLight: true).color, Color(red: 1, green: 1, blue: 1))
        // A dark theme never hands out a white plate, and a boxed logo keeps its own pixels.
        XCTAssertFalse(ChannelLogoPlate(tone: tone).isLight)
        XCTAssertFalse(ChannelLogoPlate.rendersInkLight(tone, prefersLight: false))
    }

    func testOriginalBrandBackingIsNotTintedByTheLogosInk() {
        let original = HeroBackgroundSample(red: 0.1, green: 0.3, blue: 0.8, luminance: 0.3)
        let plate = ChannelLogoPlate(tone: ResolvedLogoTone(
            luminance: 1, coverage: 0.4, red: 1, green: 1, blue: 1,
            brightInk: 1, backgroundPlate: original
        ))
        XCTAssertEqual(plate.red, original.red)
        XCTAssertEqual(plate.green, original.green)
        XCTAssertEqual(plate.blue, original.blue)
    }

    func testLightThemeDefaultsToLightBackingUnlessTheInkIsPale() {
        let coloured = ResolvedLogoTone(luminance: 0.35, coverage: 0.4, red: 0.9, green: 0.3, blue: 0.1, brightInk: 0.06)
        XCTAssertFalse(ChannelLogoPlate(tone: coloured).isLight, "dark theme keeps the wordmark's dark backing")
        XCTAssertTrue(ChannelLogoPlate(tone: coloured, prefersLight: true).isLight)

        let whiteInk = ResolvedLogoTone(luminance: 0.95, coverage: 0.4, red: 1, green: 1, blue: 1, brightInk: 0.9)
        XCTAssertFalse(ChannelLogoPlate(tone: whiteInk, prefersLight: true).isLight, "white ink would vanish on white")

        let blackInk = ResolvedLogoTone(luminance: 0.05, coverage: 0.4)
        XCTAssertFalse(ChannelLogoPlate(tone: blackInk).isLight, "a dark theme never gets a white plate")
        XCTAssertTrue(ChannelLogoPlate.rendersInkLight(blackInk, prefersLight: false), "black ink is drawn light instead")
        XCTAssertFalse(ChannelLogoPlate.rendersInkLight(blackInk, prefersLight: true))
        XCTAssertTrue(ChannelLogoPlate(tone: blackInk, prefersLight: true).isLight)
        let redInk = ResolvedLogoTone(luminance: 0.35, coverage: 0.4, red: 0.9, green: 0.1, blue: 0.1)
        XCTAssertFalse(ChannelLogoPlate.rendersInkLight(redInk, prefersLight: false), "brand colour reads on charcoal")
        for deep in [(0.05, 0.1, 0.45), (0.4, 0.05, 0.08), (0.25, 0.08, 0.35)] {
            let tone = ResolvedLogoTone(luminance: 0.12, coverage: 0.4, red: deep.0, green: deep.1, blue: deep.2)
            XCTAssertFalse(ChannelLogoPlate.rendersInkLight(tone, prefersLight: false), "deep brand colours keep their colour")
        }
        let charcoalInk = ResolvedLogoTone(luminance: 0.25, coverage: 0.4, red: 0.25, green: 0.25, blue: 0.25)
        XCTAssertFalse(ChannelLogoPlate.rendersInkLight(charcoalInk, prefersLight: false), "only near-black ink is redrawn")

        XCTAssertTrue(ChannelLogoPlate(tone: nil, prefersLight: true).isLight)
        XCTAssertFalse(ChannelLogoPlate(tone: nil).isLight)
    }

    func testBoxedLogosShowAsTilesAndCutOutInkDoesNot() {
        XCTAssertTrue(ChannelLogoPlate.showsAsTile(ResolvedLogoTone(luminance: 0.4, coverage: 0.97)))
        XCTAssertFalse(ChannelLogoPlate.showsAsTile(ResolvedLogoTone(luminance: 0.4, coverage: 0.4)))
        XCTAssertFalse(ChannelLogoPlate.showsAsTile(nil), "no logo yet: the name, not a tile")
    }

    func testDarkPlateHasAFirmCharcoalFloorInsteadOfFadingIntoBlack() {
        let plate = ChannelLogoPlate(tone: nil)
        XCTAssertGreaterThanOrEqual(min(plate.red, plate.green, plate.blue), 0.14)
        XCTAssertFalse(plate.isLight)
    }

    func testGuideAndPlayerPlatesStaySolidOpaqueAndTheSameColour() throws {
        for tone in [
            ResolvedLogoTone(luminance: 0.1, coverage: 0.4),
            ResolvedLogoTone(luminance: 0.95, coverage: 0.4, brightInk: 0.9)
        ] {
            let plate = ChannelLogoPlate(tone: tone)
            var referencePixel: [UInt8]?
            for size in [CGSize(width: 200, height: 128), CGSize(width: 112, height: 72)] {
                for scheme in [ColorScheme.light, .dark] {
                    let content = ChannelLogoPlateContent(
                        name: "", image: nil, plate: plate, size: size,
                        cornerRadius: 16, artworkInset: size.height * 20 / 128
                    )
                    .environment(\.colorScheme, scheme)
                    let renderer = ImageRenderer(content: content)
                    renderer.scale = 1
                    let image = try XCTUnwrap(renderer.cgImage)
                    XCTAssertEqual(image.width, Int(size.width))
                    XCTAssertEqual(image.height, Int(size.height))
                    let pixels = try rgbaPixels(image)
                    for y in [4, image.height / 2, image.height - 5] {
                        let offset = (y * image.width + image.width / 2) * 4
                        let pixel = Array(pixels[offset..<(offset + 4)])
                        XCTAssertEqual(pixel[3], 255)
                        if let referencePixel {
                            XCTAssertEqual(pixel, referencePixel)
                        } else {
                            referencePixel = pixel
                        }
                    }
                    XCTAssertEqual(pixels[3], 0)
                }
            }
        }
    }

    func testOriginalLogoColoursAreNotRecolouredOrShadowed() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let logo = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        let content = ChannelLogoPlateContent(
            name: "Brand", image: logo,
            plate: ChannelLogoPlate(tone: ResolvedLogoTone(luminance: 0.2, coverage: 0.4), prefersLight: true),
            size: CGSize(width: 200, height: 128), cornerRadius: 16, artworkInset: 20
        )
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let pixels = try rgbaPixels(image)
        let center = (image.height / 2 * image.width + image.width / 2) * 4
        XCTAssertEqual(Array(pixels[center..<(center + 4)]), [255, 0, 0, 255])
        let background = (4 * image.width + image.width / 2) * 4
        XCTAssertEqual(Array(pixels[background..<(background + 4)]), [255, 255, 255, 255])
    }

    func testMissingArtworkKeepsTheSameFrameForLongChannelNames() {
        for size in [CGSize(width: 200, height: 128), CGSize(width: 112, height: 72)] {
            let logo = ChannelLogoArtwork(
                name: String(repeating: "International News ", count: 8),
                logoURL: nil, size: size, cornerRadius: 16
            )
            let measured = UIHostingController(rootView: logo)
                .sizeThatFits(in: CGSize(width: 600, height: 600))
            XCTAssertEqual(measured.width, size.width, accuracy: 0.5)
            XCTAssertEqual(measured.height, size.height, accuracy: 0.5)
        }
    }

    func testWarmedGuideLogoAndBackingRenderInPlayerOnTheFirstFrame() throws {
        let url = try XCTUnwrap(URL(string: "https://example.invalid/\(UUID()).png"))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        let prepared = PreparedLogo(image: image, luminance: 0.2, red: 1, green: 0, blue: 0, coverage: 1)
        HeroLogoMemo.store(
            HeroLogoAnalysis.analyze(prepared, backgroundSample: nil),
            for: HeroLogoMemo.key(for: [.remote(url)])
        )
        let renderer = ImageRenderer(content: ChannelLogoArtwork(
            name: "", logoURL: url, size: CGSize(width: 112, height: 72), cornerRadius: 12,
            plozzChannelID: "plozz-test-channel"
        ))
        renderer.scale = 1
        let rendered = try XCTUnwrap(renderer.cgImage)
        let pixels = try rgbaPixels(rendered)
        let center = (rendered.height / 2 * rendered.width + rendered.width / 2) * 4
        XCTAssertEqual(Array(pixels[center..<(center + 4)]), [255, 0, 0, 255])
        let background = (4 * rendered.width + rendered.width / 2) * 4
        XCTAssertEqual(pixels[background + 3], 255)
        XCTAssertGreaterThan(pixels[background], pixels[background + 1])
        // The default theme is dark, whose plates are always charcoal.
        XCTAssertLessThan(max(pixels[background], pixels[background + 1], pixels[background + 2]), 70)
    }

    func testPlayerPreservesBoxedSourceCornersWithoutChangingGuideTilesOrLogoSize() throws {
        for sourceSize in [
            CGSize(width: 40, height: 40),
            CGSize(width: 80, height: 40),
            CGSize(width: 40, height: 80)
        ] {
            let url = try XCTUnwrap(URL(string: "https://example.invalid/\(UUID()).png"))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.preferredRange = .standard
            let logo = UIGraphicsImageRenderer(size: sourceSize, format: format).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(origin: .zero, size: sourceSize))
            }
            let prepared = PreparedLogo(image: logo, luminance: 0.2, red: 1, green: 0, blue: 0, coverage: 1)
            HeroLogoMemo.store(
                HeroLogoAnalysis.analyze(prepared, backgroundSample: nil),
                for: HeroLogoMemo.key(for: [.remote(url)])
            )
            var rendered: [[UInt8]] = []
            for preservesCorners in [false, true] {
                let renderer = ImageRenderer(content:
                    ChannelLogoArtwork(name: "", logoURL: url, size: CGSize(width: 200, height: 128), cornerRadius: 18)
                        .environment(\.themePalette, .dark)
                        .environment(\.channelLogoPreservesSourceCorners, preservesCorners)
                )
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.cgImage)
                XCTAssertEqual(image.width, 200)
                XCTAssertEqual(image.height, 128)
                rendered.append(try rgbaPixels(image))
                let attachment = XCTAttachment(image: UIImage(cgImage: image))
                attachment.name = "boxed-logo-\(Int(sourceSize.width))x\(Int(sourceSize.height))-source-corners-\(preservesCorners)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            let aspect = sourceSize.width / sourceSize.height
            let height = min(112, 184 / aspect)
            let width = height * aspect
            let left = Int((200 - width) / 2)
            let top = Int((128 - height) / 2)
            for (x, y) in [(left + 1, top + 1), (199 - left - 1, 127 - top - 1)] {
                let offset = (y * 200 + x) * 4
                XCTAssertLessThan(rendered[0][offset], 100, "Guide tiles must retain their rounded source artwork.")
                XCTAssertEqual(Array(rendered[1][offset..<(offset + 4)]), [255, 0, 0, 255],
                               "Playback must not cut the corners off the boxed source logo.")
            }
            for (x, y) in [(100, top + 1), (100, 64), (100, 4), (0, 0)] {
                let offset = (y * 200 + x) * 4
                XCTAssertEqual(Array(rendered[0][offset..<(offset + 4)]), Array(rendered[1][offset..<(offset + 4)]),
                               "Logo size, colour and the outer plate must not change.")
            }
        }
    }

    private func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }
}
#endif
