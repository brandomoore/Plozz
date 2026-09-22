#if os(iOS)
import CoreModels
@testable import CoreUI
import SwiftUI
import UIKit
import XCTest

@MainActor
final class DetailHeaderMetadataRowTests: XCTestCase {
    private let badges: [MediaBadge] = [
        .init("4K", style: .prominent),
        .init("Dolby Vision", style: .dolby),
        .init("HDR10", style: .hdr),
        .init("Dolby Atmos", style: .dolby)
    ]
    private let widths: [CGFloat] = [180, 250, 280, 320, 354, 393]
    private let jurassicRatings: [ExternalRating] = [
        .init(source: .rottenTomatoesAudience, value: 91, scale: .percent),
        .init(source: .rottenTomatoes, value: 91, scale: .percent),
        .init(source: .imdb, value: 8.2, scale: .outOfTen),
        .init(source: .tmdb, value: 8.0, scale: .outOfTen)
    ]

    private var allRatings: [ExternalRating] {
        jurassicRatings + RatingSource.allCases
            .filter { source in !jurassicRatings.contains { $0.source == source } }
            .map { .init(source: $0, value: 84, scale: .percent) }
    }

    private func environment(_ view: some View, textSize: DynamicTypeSize, direction: LayoutDirection = .leftToRight) -> some View {
        view
            .environment(\.dynamicTypeSize, textSize)
            .environment(\.horizontalSizeClass, .compact)
            .environment(\.themePalette, .dark)
            .environment(\.colorScheme, .dark)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.layoutDirection, direction)
    }

    private func size(of view: some View, width: CGFloat, textSize: DynamicTypeSize = .large) -> CGSize {
        UIHostingController(rootView: environment(view, textSize: textSize))
            .sizeThatFits(in: CGSize(width: width, height: 2_000))
    }

    private var chevron: some View {
        Image(systemName: "chevron.forward")
            .font(.caption.weight(.semibold))
            .plozzForeground(.secondary)
    }

    private func inline(ratings: [ExternalRating], badges: [MediaBadge], age: Double?) -> some View {
        HStack(spacing: 12) {
            if let age { FamilyGuidanceAgeBadge(age: age) }
            ForEach(ratings) { RatingBadge(rating: $0) }
            if !badges.isEmpty {
                HStack(spacing: 10) {
                    ForEach(badges) { MetadataMediaBadgeChip(badge: $0) }
                }
            }
            chevron
        }
        .fixedSize()
    }

    private func referenceButton(_ line: some View) -> some View {
        Button {} label: {
            line.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .lineLimit(1)
        .buttonStyle(.plain)
        .plozzForeground(.primary)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // Deliberately select by independently measured natural widths, not another
    // ViewThatFits/ForEach: the reference must catch a grouped-candidate regression.
    private func expectedLine(
        ratings: [ExternalRating], badges: [MediaBadge], age: Double?,
        width: CGFloat, textSize: DynamicTypeSize
    ) -> AnyView {
        let full = inline(ratings: ratings, badges: badges, age: age)
        if size(of: full, width: 4_000, textSize: textSize).width <= width {
            return AnyView(full)
        }
        for count in stride(from: ratings.count, through: 0, by: -1) {
            let candidate = inline(ratings: Array(ratings.prefix(count)), badges: [], age: age)
            if size(of: candidate, width: 4_000, textSize: textSize).width <= width {
                return AnyView(candidate)
            }
        }
        return AnyView(chevron)
    }

    private func render(
        _ view: some View, width: CGFloat, textSize: DynamicTypeSize = .large,
        direction: LayoutDirection = .leftToRight
    ) throws -> UIImage {
        let renderer = ImageRenderer(content: environment(view, textSize: textSize, direction: direction)
            .frame(width: width)
            .padding(8)
            .background(.black))
        renderer.scale = 3
        return try XCTUnwrap(renderer.uiImage)
    }

    private func pixels(_ image: UIImage) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: cgImage.width, height: cgImage.height,
                bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        }
        return bytes
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertSameRendering(
        _ actual: UIImage, _ expected: UIImage, context: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertEqual(actual.size, expected.size, context, file: file, line: line)
        let actualPixels = try pixels(actual)
        let expectedPixels = try pixels(expected)
        guard actualPixels.count == expectedPixels.count else {
            attach(actual, name: "\(context)-actual")
            attach(expected, name: "\(context)-expected")
            return
        }
        let difference = zip(actualPixels, expectedPixels)
            .reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) }
            / Double(actualPixels.count * 255)
        if difference > 0.001 {
            attach(actual, name: "\(context)-actual")
            attach(expected, name: "\(context)-expected")
        }
        XCTAssertLessThanOrEqual(difference, 0.001, context, file: file, line: line)
    }

    func testGuidanceHeaderFitsNarrowPhonesAndExpandsWithDynamicType() {
        let header = FamilyGuidanceHeader(
            title: "A movie with a longer title",
            summary: .init(recommendedAge: 14, qualityRating: 5,
                           overview: "A brief description of the guidance for this movie.")
        )
        let standard = size(of: header, width: 280)
        let accessible = size(of: header, width: 280, textSize: .accessibility3)
        XCTAssertLessThanOrEqual(standard.width, 280.5)
        XCTAssertLessThanOrEqual(accessible.width, 280.5)
        XCTAssertGreaterThan(accessible.height, standard.height)
    }

    func testGuidanceTileWithInlineDisclosureFitsNarrowTouchColumns() {
        let summary = FamilyGuidanceSummary(recommendedAge: 8, qualityRating: 4,
                                            overview: "Strong heroine and positive messages.")
        let tile = FamilyGuidanceTile(
            item: MediaItem(id: "fixture", title: "Fixture", kind: .series, familyGuidance: summary),
            summary: summary
        )
        for width in [CGFloat(130), 150, 248] {
            for textSize in [DynamicTypeSize.large, .accessibility3] {
                let result = size(of: tile, width: width, textSize: textSize)
                XCTAssertLessThanOrEqual(result.width, width + 0.5)
                XCTAssertGreaterThan(result.height, 0)
            }
        }
    }

    func testSparseKorraMetadataRemainsOneLine() throws {
        let score = ExternalRating(source: .community, value: 8.2, scale: .outOfTen)
        let formats = [
            MediaBadge("1080p", style: .prominent),
            MediaBadge("Dolby Digital", style: .dolby, detail: "5.1"),
            MediaBadge("SDR", style: .sdr)
        ]
        let row = DetailHeaderMetadataRow(ratings: [score], badges: formats)
        let reference = referenceButton(expectedLine(
            ratings: [score], badges: formats, age: nil, width: 320, textSize: .large
        ))
        try assertSameRendering(render(row, width: 320), render(reference, width: 320), context: "Korra")
    }

    func testEveryRatingCountAndAgeCombinationUsesExactlyOneUnscaledLine() throws {
        XCTAssertEqual(allRatings.count, DetailPageSettings.headerRatingCountRange.upperBound)
        for width in widths {
            for textSize in [DynamicTypeSize.large, .accessibility3] {
                for ratingCount in 0...allRatings.count {
                    let scores = Array(allRatings.prefix(ratingCount))
                    for formats in [[], Array(badges.prefix(1)), badges] {
                        for age: Double? in [nil, 11] {
                            let row = DetailHeaderMetadataRow(ratings: scores, badges: formats, familyGuidanceAge: age)
                            let actualSize = size(of: row, width: width, textSize: textSize)
                            let context = "\(Int(width))-\(textSize)-\(ratingCount)ratings-\(formats.count)formats-age\(age != nil)"
                            XCTAssertLessThanOrEqual(actualSize.width, width + 0.5, context)
                            if scores.isEmpty && formats.isEmpty && age == nil {
                                XCTAssertEqual(actualSize.height, 0, accuracy: 0.5, context)
                                continue
                            }
                            let expected = referenceButton(expectedLine(
                                ratings: scores, badges: formats, age: age, width: width, textSize: textSize
                            ))
                            let expectedSize = size(of: expected, width: width, textSize: textSize)
                            XCTAssertEqual(actualSize.height, expectedSize.height, accuracy: 0.5, context)
                            XCTAssertGreaterThanOrEqual(actualSize.height, 44, context)
                            try assertSameRendering(
                                render(row, width: width, textSize: textSize),
                                render(expected, width: width, textSize: textSize), context: context
                            )
                        }
                    }
                }
            }
        }
    }

    func testFormatsYieldBeforeAnyRatingAndNoFormatsLabelIsSubstituted() throws {
        let line = inline(ratings: jurassicRatings, badges: [], age: 11)
        let width = ceil(size(of: line, width: 4_000).width) + 1
        XCTAssertGreaterThan(size(of: inline(ratings: jurassicRatings, badges: badges, age: 11), width: 4_000).width, width)
        try assertSameRendering(
            render(DetailHeaderMetadataRow(ratings: jurassicRatings, badges: badges, familyGuidanceAge: 11), width: width),
            render(referenceButton(line), width: width), context: "all-ratings-before-formats"
        )
    }

    func testWideRowsRetainRealFormatBadgeArtworkWithAndWithoutRatings() throws {
        for scores in [[], jurassicRatings] {
            let line = inline(ratings: scores, badges: badges, age: 11)
            let width = ceil(size(of: line, width: 4_000).width) + 1
            try assertSameRendering(
                render(DetailHeaderMetadataRow(ratings: scores, badges: badges, familyGuidanceAge: 11), width: width),
                render(referenceButton(line), width: width), context: "wide-real-badges-\(scores.count)"
            )
        }
    }

    func testEveryForEachCandidateIsSelectableAndKeepsTheHighestPriorityPrefix() throws {
        for textSize in [DynamicTypeSize.large, .accessibility3] {
            for count in 0...allRatings.count {
                let line = inline(ratings: Array(allRatings.prefix(count)), badges: [], age: 11)
                let width = ceil(size(of: line, width: 4_000, textSize: textSize).width) + 1
                let actual = DetailHeaderMetadataRow(ratings: allRatings, badges: badges, familyGuidanceAge: 11)
                try assertSameRendering(
                    render(actual, width: width, textSize: textSize),
                    render(referenceButton(line), width: width, textSize: textSize),
                    context: "select-prefix-\(count)-\(textSize)"
                )
                if count > 0 {
                    let shorter = referenceButton(inline(ratings: Array(allRatings.prefix(count - 1)), badges: [], age: 11))
                    XCTAssertNotEqual(
                        try pixels(render(actual, width: width, textSize: textSize)),
                        try pixels(render(shorter, width: width, textSize: textSize)),
                        "A chevron-only or prematurely truncated row must not pass."
                    )
                }
            }
        }
    }

    func testChevronOnlyFallbackIsDirectionalAndStillHasATouchTarget() throws {
        let row = DetailHeaderMetadataRow(ratings: allRatings, badges: badges, familyGuidanceAge: 111.5)
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            let actual = try render(row, width: 44, textSize: .accessibility3, direction: direction)
            try assertSameRendering(
                actual, render(referenceButton(chevron), width: 44, textSize: .accessibility3, direction: direction),
                context: "chevron-only-\(direction)"
            )
            XCTAssertGreaterThanOrEqual(size(of: row, width: 44, textSize: .accessibility3).height, 44)
        }
        XCTAssertNotEqual(
            try pixels(render(row, width: 44, textSize: .accessibility3)),
            try pixels(render(row, width: 44, textSize: .accessibility3, direction: .rightToLeft))
        )
    }

    func testJurassicParkPhonePreviewsRetainAllScoresWhenTheyFit() throws {
        for width in widths {
            for textSize in [DynamicTypeSize.large, .accessibility3] {
                let row = DetailHeaderMetadataRow(ratings: jurassicRatings, badges: badges, familyGuidanceAge: 11)
                let expected = referenceButton(expectedLine(
                    ratings: jurassicRatings, badges: badges, age: 11, width: width, textSize: textSize
                ))
                let image = try render(row, width: width, textSize: textSize)
                attach(image, name: "jurassic-\(Int(width))-\(textSize)")
                try assertSameRendering(image, render(expected, width: width, textSize: textSize), context: "Jurassic-\(width)-\(textSize)")
            }
        }
        let line = inline(ratings: jurassicRatings, badges: [], age: 11)
        XCTAssertLessThanOrEqual(size(of: line, width: 4_000).width, 393)
        try assertSameRendering(
            render(DetailHeaderMetadataRow(ratings: jurassicRatings, badges: badges, familyGuidanceAge: 11), width: 393),
            render(referenceButton(line), width: 393), context: "Jurassic-all-four-at-phone-width"
        )
    }

}
#endif
