#if canImport(UIKit)
import CoreModels
@testable import CoreUI
import CoreText
import SwiftUI
import UIKit
import XCTest

@MainActor
final class MediaBadgeSizingTests: XCTestCase {
    private let badges: [MediaBadge] = [
        MediaBadge("4K", style: .prominent),
        MediaBadge("Dolby Vision", style: .dolby),
        MediaBadge("Dolby Vision", style: .dolby, detail: "HDR10+"),
        MediaBadge("Dolby Vision", style: .dolby, detail: "HDR10"),
        MediaBadge("Dolby Vision", style: .dolby, detail: "HLG"),
        MediaBadge("Dolby Atmos", style: .dolby),
        MediaBadge("HDR10", style: .hdr),
        MediaBadge("HDR10+", style: .hdr),
        MediaBadge("SDR", style: .sdr),
        MediaBadge("DTS-HD", style: .dts, detail: "5.1"),
        MediaBadge("Dolby TrueHD", style: .dolby, detail: "7.1"),
        MediaBadge("DTS:X", style: .dts),
        MediaBadge("5.1", style: .audio),
        MediaBadge("1440p", style: .prominent),
        MediaBadge("1080p", style: .prominent),
        MediaBadge("720p", style: .prominent),
        MediaBadge("SD", style: .prominent),
        MediaBadge("HEVC", style: .spec)
    ]

    private func size(of view: some View) -> CGSize {
        UIHostingController(rootView: view).sizeThatFits(
            in: CGSize(width: 2_000, height: 500)
        )
    }

    private func metadataScale(for badge: MediaBadge) -> CGFloat {
        #if os(iOS)
        18 / (badge.style == .prominent ? 22 : 26)
        #else
        0.75
        #endif
    }

    func testFrenchWarningBadgeIsCompactAndUnknownDescriptionsAreBounded() {
        let short = size(of: MediaBadgeChip(badge: .init("TP", style: .rating)))
        let warning = size(of: MediaBadgeChip(badge: .init(
            "FR/Tous publics avec avertissement", style: .rating
        )))
        XCTAssertGreaterThan(warning.width, short.width, "The warning must retain a visible indicator.")
        XCTAssertLessThan(warning.width, 100, "The screenshot's full description must not fill the hero row.")
        XCTAssertEqual(warning.height, short.height)
        let unknown = size(of: MediaBadgeChip(badge: .init(
            String(repeating: "Unrecognized classification ", count: 10), style: .rating
        )))
        XCTAssertLessThanOrEqual(unknown.width, 180, "Unknown descriptions must not recreate the overflow.")
    }

    func testVisibilityRemovesClassificationButKeepsTechnicalBadges() {
        let hidden = size(of: MediaBadgeChip(badge: .init("PG-13", style: .rating))
            .environment(\.plozzShowsContentRatings, false))
        XCTAssertEqual(hidden, .zero)
        let technical = MediaBadge("4K", style: .prominent)
        XCTAssertEqual(
            size(of: MediaBadgeChip(badge: technical).environment(\.plozzShowsContentRatings, false)),
            size(of: MediaBadgeChip(badge: technical))
        )
        var source = EnvironmentValues()
        source.plozzShowsContentRatings = false
        var destination = EnvironmentValues()
        destination.copyHostedPresentation(from: source)
        XCTAssertFalse(destination.plozzShowsContentRatings)
    }

    func testMetadataBadgesUsePlatformCompactScale() {
        for badge in badges {
            let original = size(of: MediaBadgeChip(badge: badge)
                .environment(\.dynamicTypeSize, .large))
            let compact = size(of: MetadataMediaBadgeChip(badge: badge)
                .environment(\.dynamicTypeSize, .large))
            let expected = size(of: MediaBadgeChip(badge: badge)
                .environment(\.mediaBadgeScale, metadataScale(for: badge))
                .environment(\.dynamicTypeSize, .large))
            XCTAssertEqual(compact.width, expected.width, accuracy: 0.5, badge.label)
            // Small system fonts use optical spacing, not a linear transform of larger glyphs.
            XCTAssertLessThan(compact.width, original.width, badge.label)
            XCTAssertEqual(compact.height, original.height * metadataScale(for: badge), accuracy: 1, badge.label)
        }
    }

    func testMetadataBadgesPreserveTheContainerScale() {
        let badge = MediaBadge("4K", style: .prominent)
        let reduced = size(of: MetadataMediaBadgeChip(badge: badge)
            .environment(\.mediaBadgeScale, 0.8)
            .environment(\.dynamicTypeSize, .large))
        let expected = size(of: MediaBadgeChip(badge: badge)
            .environment(\.mediaBadgeScale, 0.8 * metadataScale(for: badge))
            .environment(\.dynamicTypeSize, .large))
        XCTAssertEqual(reduced.width, expected.width, accuracy: 0.5)
        XCTAssertEqual(reduced.height, expected.height, accuracy: 0.5)
    }

    func testPorcelainUsesTheBundledVariableFontAtThePreviewWeights() {
        for weight: CGFloat in [450, 600, 650] {
            let font = PorcelainBadgeFont.uiFont(size: 15, weight: weight)
            XCTAssertTrue(font.familyName.hasPrefix("Outfit"), font.familyName)
            let variation = CTFontCopyVariation(font as CTFont) as? [NSNumber: NSNumber]
            XCTAssertEqual(variation?[NSNumber(value: 0x77676874)]?.doubleValue, Double(weight))
        }
    }

    func testResolutionIs22PointsWhileOtherTechnicalBadgesKeepTheirHeight() {
        for badge in badges {
            for scale: CGFloat in [0.75, 1, 1.5] {
                let expectedHeight: CGFloat = badge.style == .prominent ? 22 : 26
                let actual = size(of: MediaBadgeChip(badge: badge)
                    .environment(\.mediaBadgeScale, scale))
                XCTAssertEqual(actual.height, expectedHeight * scale, accuracy: 0.5, badge.label)
            }
        }
        let plain = size(of: MediaBadgeChip(badge: MediaBadge("Dolby TrueHD", style: .dolby)))
        let channels = size(of: MediaBadgeChip(badge: MediaBadge("Dolby TrueHD", style: .dolby, detail: "7.1")))
        XCTAssertGreaterThan(channels.width, plain.width + 20)
        XCTAssertEqual(channels.height, plain.height, accuracy: 0.5)
    }

    func testCompactNamesPreserveFullSourceAndAccessibilityLabels() {
        for (source, compact) in [
            ("Dolby Vision", "DV"), ("Dolby Digital+", "DD+"),
            ("Dolby Digital", "DD"), ("Dolby TrueHD", "TrueHD"),
            ("Dolby Atmos", "Atmos"), ("HDR10+", "HDR10+"),
            ("DTS-HD", "DTS-HD")
        ] {
            let badge = MediaBadge(source)
            XCTAssertEqual(badge.compactDisplayLabel, compact)
            XCTAssertEqual(badge.label, source)
            XCTAssertEqual(badge.accessibilityText, source)
        }
        XCTAssertEqual(
            MediaBadge("Dolby Digital+", style: .dolby, detail: "5.1").accessibilityText,
            "Dolby Digital+ 5.1"
        )
    }

    func testRefinedCompactMatchesTheApprovedRowWidth() {
        let example = [
            MediaBadge("4K", style: .prominent),
            MediaBadge("Dolby Vision", style: .dolby),
            MediaBadge("HDR10", style: .hdr),
            MediaBadge("Dolby Digital+", style: .dolby, detail: "5.1"),
            MediaBadge("Dolby Atmos", style: .dolby)
        ]
        let row = size(of: MediaBadgeRow(badges: example).fixedSize())
        XCTAssertEqual(row.width, 310, accuracy: 8)
        XCTAssertEqual(row.height, 26, accuracy: 0.5)
        for channels in ["5.1", "7.1"] {
            let plain = size(of: MediaBadgeChip(badge: MediaBadge("Dolby Digital+", style: .dolby)))
            let attached = size(of: MediaBadgeChip(
                badge: MediaBadge("Dolby Digital+", style: .dolby, detail: channels)
            ))
            let channelText = size(of: Text(verbatim: channels)
                .font(PorcelainBadgeFont.font(size: 12.5, weight: 600))
                .monospacedDigit())
            XCTAssertEqual(attached.width - plain.width, channelText.width + 7, accuracy: 0.5)
        }
    }

    func testAdjacentBadgeSpacingPreservesOtherMetadataAndWrapping() {
        let first = MediaBadge("4K", style: .prominent)
        let second = MediaBadge("Dolby Vision", style: .dolby)
        let width = 100 + 16 + size(of: MediaBadgeChip(badge: first)).width
            + 12 + size(of: MediaBadgeChip(badge: second)).width
        let row = WrappingHStackLayout(spacing: 16, lineSpacing: 8) {
            Color.white.frame(width: 100, height: 30)
            MediaBadgeChip(badge: first)
            MediaBadgeChip(badge: second)
        }
        XCTAssertEqual(size(of: row.fixedSize()).width, width, accuracy: 0.5)
        XCTAssertEqual(size(of: row.frame(width: width - 1)).height, 64, accuracy: 0.5)
    }

    func testRatingIconsUseFourPointGapsWithoutChangingTheirSize() {
        #if os(iOS)
        let iconSize: CGFloat = 20
        let font = Font.subheadline.weight(.medium)
        #else
        let iconSize: CGFloat = 24
        let font = Font.system(size: 23, weight: .medium)
        #endif
        for source in RatingSource.allCases {
            let rating = ExternalRating(source: source, value: 84, scale: .percent)
            let icon = size(of: RatingSourceIcon(rating: rating, size: iconSize))
            let value = size(of: Text(rating.displayValue).font(font).monospacedDigit()
                .environment(\.dynamicTypeSize, .large))
            let actual = size(of: RatingBadge(rating: rating)
                .environment(\.horizontalSizeClass, .regular)
                .environment(\.dynamicTypeSize, .large))
            XCTAssertEqual(actual.width, icon.width + 4 + value.width, accuracy: 0.5, "\(source)")
            XCTAssertEqual(actual.height, max(icon.height, value.height), accuracy: 0.5, "\(source)")
        }
    }

    func testBadgeCategoriesUseTheirOwnGapsAndKeepFactsSeparated() {
        let views: [AnyView] = [
            AnyView(FamilyGuidanceAgeBadge(age: 14)),
            AnyView(RatingBadge(rating: .init(source: .imdb, value: 8.2, scale: .outOfTen))),
            AnyView(RatingBadge(rating: .init(source: .rottenTomatoes, value: 91, scale: .percent))),
            AnyView(MediaBadgeChip(badge: .init("PG-13", style: .rating))),
            AnyView(MediaBadgeChip(badge: .init("4K", style: .prominent))),
            AnyView(MediaBadgeChip(badge: .init("Dolby Vision", style: .dolby))),
            AnyView(MediaBadgeChip(badge: .init("Dolby Digital+", style: .dolby, detail: "5.1")))
        ]
        let gaps: [CGFloat] = [14, 14, 14, 12, 12, 12, 12]
        for scale: CGFloat in [0.75, 1, 1.5] {
            for index in views.indices {
                let next = (index + 1) % views.count
                let first = size(of: views[index]
                    .environment(\.mediaBadgeScale, scale).environment(\.dynamicTypeSize, .large))
                let second = size(of: views[next]
                    .environment(\.mediaBadgeScale, scale).environment(\.dynamicTypeSize, .large))
                let row = WrappingHStackLayout(spacing: 16, lineSpacing: 8) {
                    Color.white.frame(width: 100, height: 30)
                    views[index]
                    views[next]
                }
                .environment(\.mediaBadgeScale, scale)
                .environment(\.dynamicTypeSize, .large)
                let width = 100 + 16 + first.width + max(gaps[index], gaps[next]) * scale + second.width
                let naturalSize = size(of: row.fixedSize())
                XCTAssertEqual(naturalSize.width, width, accuracy: 0.5, "\(index), \(scale)")
                // Separately hosted badges round independently; constrain the measured row instead.
                XCTAssertEqual(
                    size(of: row.frame(width: naturalSize.width - 1)).height,
                    max(30, first.height) + 8 + second.height, accuracy: 0.5,
                    "\(index), \(scale), measured width \(naturalSize.width), summed width \(width)"
                )
            }
        }
    }

    func testCompactBadgeGapsDoNotDependOnResolutionOrCapsuleHeight() {
        for scale: CGFloat in [0.75, 1, 1.5] {
            for badge in badges {
                let first = MetadataMediaBadgeChip(badge: badge)
                let second = MetadataMediaBadgeChip(badge: .init("HDR10", style: .hdr))
                let expected = size(of: first.environment(\.mediaBadgeScale, scale)
                    .environment(\.dynamicTypeSize, .large)).width
                    + 12 * scale + size(of: second.environment(\.mediaBadgeScale, scale)
                        .environment(\.dynamicTypeSize, .large)).width
                let row = WrappingHStackLayout(spacing: 16) { first; second }
                    .environment(\.mediaBadgeScale, scale)
                    .environment(\.dynamicTypeSize, .large)
                    .fixedSize()
                XCTAssertEqual(size(of: row).width, expected, accuracy: 0.5, "\(badge.label), \(scale)")
            }
        }
    }

    func testRatingsOnlyRowUsesFourteenPointGaps() {
        let ratings: [ExternalRating] = [
            .init(source: .imdb, value: 8.2, scale: .outOfTen),
            .init(source: .tmdb, value: 8, scale: .outOfTen),
            .init(source: .rottenTomatoes, value: 91, scale: .percent)
        ]
        let expected = HStack(spacing: 14) {
            FamilyGuidanceAgeBadge(age: 14)
            ForEach(ratings) { RatingBadge(rating: $0) }
        }.fixedSize()
        let actual = RatingsBadgeRow(ratings: ratings, familyGuidanceAge: 14).fixedSize()
        XCTAssertEqual(size(of: actual).width, size(of: expected).width, accuracy: 0.5)
        XCTAssertEqual(size(of: actual).height, size(of: expected).height, accuracy: 0.5)
    }

    func testVersionPickerGapsStayIndependentOfArtworkAndTextScale() {
        for (scale, gap): (CGFloat, CGFloat) in [(1.7, 12), (0.85, 8)] {
            for textSize in [DynamicTypeSize.large, .accessibility3] {
                let first = MetadataMediaBadgeChip(
                    badge: .init("4K", style: .prominent), adjacentSpacing: gap
                )
                let second = MetadataMediaBadgeChip(
                    badge: .init("English | +1", style: .audio), adjacentSpacing: gap
                )
                let expected = size(of: HStack(spacing: gap) { first; second }
                    .environment(\.mediaBadgeScale, scale)
                    .environment(\.dynamicTypeSize, textSize).fixedSize())
                let actual = WrappingHStackLayout(spacing: 99, lineSpacing: 6) { first; second }
                    .environment(\.mediaBadgeScale, scale)
                    .environment(\.dynamicTypeSize, textSize)
                XCTAssertEqual(size(of: actual.fixedSize()).width, expected.width, accuracy: 0.5)
                XCTAssertEqual(size(of: actual.fixedSize()).height, expected.height, accuracy: 0.5)
                XCTAssertGreaterThan(size(of: actual.frame(width: expected.width - 1)).height, expected.height)
            }
        }
    }

    func testBalancingRowsRetainsAdjacentSpacing() {
        func row(balanced: Bool) -> some View {
            WrappingHStackLayout(spacing: 16, lineSpacing: 8, balancesLastRow: balanced) {
                ForEach(0..<4) { index in
                    Color.white.frame(width: 80, height: index < 2 ? 20 : 60)
                        .layoutValue(
                            key: WrappingHStackLayout.AdjacentSpacing.self,
                            value: index == 0 ? nil : 8
                        )
                }
            }.frame(width: 264)
        }
        XCTAssertEqual(size(of: row(balanced: false)).height, 128, accuracy: 0.5)
        XCTAssertEqual(size(of: row(balanced: true)).height, 88, accuracy: 0.5)
    }

    func testFractionalBadgeWidthsDoNotWrapAtTheirNaturalWidth() {
        let row = WrappingHStackLayout(spacing: 14, lineSpacing: 8) {
            ForEach([10.1, 10.2, 10.3, 10.4], id: \.self) { width in
                Color.white.frame(width: width, height: 20)
            }
        }
        XCTAssertEqual(size(of: row.fixedSize()).width, 83, accuracy: 0.5)
        XCTAssertEqual(size(of: row.fixedSize()).height, 20, accuracy: 0.5)
        XCTAssertEqual(size(of: row.frame(width: 82)).height, 48, accuracy: 0.5)
    }

    func testVideoCapsulesUseFifteenPercentFillWhileAudioAndLanguagesStayClear() throws {
        let videoBadges = [
            MediaBadge("Dolby Vision", style: .dolby),
            MediaBadge("HDR10", style: .hdr),
            MediaBadge("HDR10+", style: .hdr),
            MediaBadge("HDR", style: .hdr),
            MediaBadge("HLG", style: .hdr),
            MediaBadge("SDR", style: .sdr),
            MediaBadge("HEVC", style: .spec),
            MediaBadge("H.264", style: .spec),
            MediaBadge("AV1", style: .spec)
        ]
        let audioBadges = [
            MediaBadge("Dolby Atmos", style: .dolby),
            MediaBadge("DTS:X", style: .dts),
            MediaBadge("AAC", style: .audio),
            MediaBadge("English | +1", style: .audio),
            MediaBadge("French", style: .audio)
        ]
        for palette in [ThemePalette.dark, .pureBlack, .light] {
            for badge in videoBadges + audioBadges + [MediaBadge("4K", style: .prominent)] {
                let renderer = ImageRenderer(content: MediaBadgeChip(badge: badge)
                    .environment(\.themePalette, palette))
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.uiImage?.cgImage)
                let pixels = try rgbaPixels(in: image)
                let fillAlpha = Double(pixels[(3 * image.width + image.width / 2) * 4 + 3])
                let foregroundAlpha = Double(UIColor(palette.primaryText).cgColor.alpha) * 255
                let opacity = badge.style == .prominent ? 1.0 : badge.isAudio ? 0 : 0.15
                XCTAssertEqual(fillAlpha, foregroundAlpha * opacity, accuracy: 1, badge.label)
                XCTAssertEqual(image.height, badge.style == .prominent ? 22 : 26, badge.label)
                if badge.style != .prominent {
                    XCTAssertEqual(pixels[(3 * image.width + 1) * 4 + 3], 0, badge.label)
                }
            }
        }
    }

    func testPorcelainAndFamilyBadgeRenderInBothThemes() throws {
        for palette in [ThemePalette.light, .dark, .pureBlack] {
            let content = VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 18) {
                    FamilyGuidanceAgeBadge(age: 14)
                    MediaBadgeChip(badge: MediaBadge("PG-13", style: .rating))
                }
                MediaBadgeRow(badges: badges)
                    .frame(width: 900)
            }
            .padding(24)
            .background(palette.backgroundBase)
            .environment(\.themePalette, palette)
            .environment(\.colorScheme, palette.isLight ? .light : .dark)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            let attachment = XCTAttachment(image: image)
            attachment.name = "porcelain-family-\(palette.isLight ? "light" : "dark")"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    #if os(iOS)
    func testMixedMetadataBadgeGapsTrackDynamicTypeTogether() {
        let rating = RatingBadge(rating: .init(source: .imdb, value: 8.2, scale: .outOfTen))
        let age = FamilyGuidanceAgeBadge(age: 14)
        let resolution = MetadataMediaBadgeChip(badge: .init("4K", style: .prominent))
        let range = MetadataMediaBadgeChip(badge: .init("Dolby Vision", style: .dolby))
        for textSize in [DynamicTypeSize.xSmall, .large, .xxxLarge, .accessibility3] {
            let traits = UITraitCollection(preferredContentSizeCategory: textSize.plozzContentSizeCategory)
            let standardTraits = UITraitCollection(preferredContentSizeCategory: .large)
            let textScale = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits).pointSize
                / UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: standardTraits).pointSize
            let row = WrappingHStackLayout(spacing: 16) { age; rating; resolution; range }
                .environment(\.dynamicTypeSize, textSize).fixedSize()
            let expected = HStack(spacing: 14 * textScale) {
                age
                rating
                HStack(spacing: 12 * textScale) { resolution; range }
            }.environment(\.dynamicTypeSize, textSize).fixedSize()
            XCTAssertEqual(size(of: row).width, size(of: expected).width, accuracy: 0.5, "\(textSize)")
        }
    }
    #endif

    func testFamilyGuidanceBadgeUsesCompactUnframedLayout() throws {
        #if os(iOS)
        let iconSlot: CGFloat = 24
        let font = Font.subheadline.weight(.medium)
        #else
        let iconSlot: CGFloat = 32
        let font = Font.system(size: 23, weight: .medium)
        #endif
        #if os(tvOS)
        let iconGap: CGFloat = -1
        #else
        let iconGap: CGFloat = 4
        #endif
        for locale in [Locale(identifier: "en_US"), Locale(identifier: "fr_FR")] {
            for age in [14.0, 14.5] {
                let badge = FamilyGuidanceAgeBadge(age: age)
                    .environment(\.themePalette, .dark)
                    .environment(\.locale, locale)
                    .environment(\.dynamicTypeSize, .large)
                let text = Text(verbatim: age.formatted(
                    .number.locale(locale).precision(.fractionLength(0...1))
                ) + "+")
                    .font(font)
                    .monospacedDigit()
                    .environment(\.dynamicTypeSize, .large)
                let textSize = size(of: text)
                let badgeSize = size(of: badge)
                XCTAssertEqual(badgeSize.width, iconSlot + iconGap + textSize.width, accuracy: 0.5)
                XCTAssertEqual(badgeSize.height, max(iconSlot, textSize.height), accuracy: 0.5)

                let renderer = ImageRenderer(content: badge)
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.uiImage?.cgImage)
                let pixels = try rgbaPixels(in: image)
                for y in [0, image.height - 1] {
                    for x in 0..<image.width {
                        XCTAssertEqual(pixels[(y * image.width + x) * 4 + 3], 0,
                                       "The inline source mark must not acquire another outer frame.")
                    }
                }
            }
        }
    }

    #if os(tvOS)
    func testFamilyGuidanceMarkStaysVisuallyCloseToItsAge() throws {
        for palette in [ThemePalette.dark, .light] {
            let renderer = ImageRenderer(content: FamilyGuidanceAgeBadge(age: 11)
                .environment(\.themePalette, palette)
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.dynamicTypeSize, .large))
            renderer.scale = 4
            let image = try XCTUnwrap(renderer.uiImage?.cgImage)
            let pixels = try rgbaPixels(in: image)
            let iconEnd = Int(32 * renderer.scale)
            func hasInk(at x: Int) -> Bool {
                (0..<image.height).contains { y in
                    pixels[(y * image.width + x) * 4 + 3] > 127
                }
            }
            let markEdge = try XCTUnwrap((0..<iconEnd).last(where: hasInk))
            let ageEdge = try XCTUnwrap((iconEnd..<image.width).first(where: hasInk))
            let visualGap = CGFloat(ageEdge - markEdge - 1) / renderer.scale
            XCTAssertGreaterThanOrEqual(visualGap, 4)
            XCTAssertLessThanOrEqual(visualGap, 6)
            let attachment = XCTAttachment(image: UIImage(cgImage: image, scale: renderer.scale, orientation: .up))
            attachment.name = palette.isLight ? "common-sense-age-light" : "common-sense-age-dark"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
    #endif

    private func rgbaPixels(in image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    func testFormatAndChannelOrderDoesNotReverseInRTL() throws {
        for badge in [
            MediaBadge("Dolby Vision", style: .dolby),
            MediaBadge("Dolby TrueHD", style: .dolby, detail: "7.1")
        ] {
            func render(_ direction: LayoutDirection) throws -> Data {
                let renderer = ImageRenderer(content:
                    MediaBadgeChip(badge: badge)
                        .environment(\.layoutDirection, direction)
                        .environment(\.themePalette, .dark)
                )
                renderer.scale = 2
                return try XCTUnwrap(renderer.uiImage?.pngData())
            }
            XCTAssertEqual(try render(.leftToRight), try render(.rightToLeft), badge.label)
        }
    }

    #if os(iOS)
    func testResolutionAndDolbyMarksAreComparableToMetadataTextHeight() {
        let textHeight = size(of: Text("2025")
            .font(.subheadline)
            .environment(\.dynamicTypeSize, .large)).height
        for badge in badges.prefix(3) {
            let badgeHeight = size(of: MetadataMediaBadgeChip(badge: badge)
                .environment(\.dynamicTypeSize, .large)).height
            XCTAssertGreaterThanOrEqual(badgeHeight, textHeight * 0.85, badge.label)
            XCTAssertLessThanOrEqual(badgeHeight, textHeight * 1.2, badge.label)
        }
    }

    func testBadgeHeightTracksTheMetadataTextSize() {
        let badge = MediaBadge("4K", style: .prominent)
        let normalHeight = size(of: MetadataMediaBadgeChip(badge: badge)
            .environment(\.dynamicTypeSize, .large)).height
        let normalTextHeight = size(of: Text("2025")
            .font(.subheadline)
            .environment(\.dynamicTypeSize, .large)).height
        for category in [DynamicTypeSize.xSmall, .xxxLarge, .accessibility3] {
            let badgeHeight = size(of: MetadataMediaBadgeChip(badge: badge)
                .environment(\.dynamicTypeSize, category)).height
            let textHeight = size(of: Text("2025")
                .font(.subheadline)
                .environment(\.dynamicTypeSize, category)).height
            XCTAssertEqual(
                badgeHeight / normalHeight,
                textHeight / normalTextHeight,
                accuracy: 0.08,
                "\(category)"
            )
        }
    }
    #endif

    func testMetadataRowRendersCompactBadgesInBothThemes() throws {
        for scheme in [ColorScheme.light, .dark] {
            let row = HStack(spacing: 12) {
                Text("2025 \u{00B7} 56m")
                    .font(.subheadline.weight(.medium))
                Label("8.3", systemImage: "star.fill")
                    .font(.subheadline.weight(.medium))
                ForEach(Array(badges.prefix(4))) { badge in
                    MetadataMediaBadgeChip(badge: badge)
                }
            }
            .fixedSize()
            .padding(16)
            .background(scheme == .dark ? Color.black : Color.white)
            .environment(\.themePalette, scheme == .dark ? .dark : .light)
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, .large)
            let renderer = ImageRenderer(content: row)
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertGreaterThan(image.size.width, 0)
            XCTAssertGreaterThan(image.size.height, 0)
            let attachment = XCTAttachment(image: image)
            attachment.name = "compact-metadata-badges-\(scheme)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
#endif
