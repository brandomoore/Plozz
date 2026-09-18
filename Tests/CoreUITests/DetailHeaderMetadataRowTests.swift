#if os(iOS)
import CoreModels
@testable import CoreUI
import SwiftUI
import UIKit
import XCTest

@MainActor
final class DetailHeaderMetadataRowTests: XCTestCase {
    private let ratings: [ExternalRating] = [
        .init(source: .rottenTomatoesAudience, value: 89, scale: .percent),
        .init(source: .rottenTomatoes, value: 96, scale: .percent)
    ]
    private let badges: [MediaBadge] = [
        .init("4K", style: .prominent),
        .init("Dolby Vision", style: .dolby),
        .init("HDR10", style: .hdr),
        .init("Dolby Atmos", style: .dolby)
    ]

    private func size(of view: some View, width: CGFloat, textSize: DynamicTypeSize = .large) -> CGSize {
        UIHostingController(rootView: view
            .environment(\.dynamicTypeSize, textSize)
            .environment(\.horizontalSizeClass, .compact)
        ).sizeThatFits(in: CGSize(width: width, height: 2_000))
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

    func testAgeAndReviewsFitOrWrapWithoutClippingAtLargeTextSizes() {
        for width in [CGFloat(180), 280, 393] {
            for textSize in [DynamicTypeSize.large, .xxxLarge, .accessibility3] {
                let result = size(
                    of: DetailHeaderMetadataRow(ratings: ratings, badges: badges, familyGuidanceAge: 14),
                    width: width, textSize: textSize
                )
                XCTAssertGreaterThan(result.height, 0)
                XCTAssertLessThanOrEqual(result.width, width + 0.5)
                let ageSize = size(of: FamilyGuidanceAgeBadge(age: 14), width: width, textSize: textSize)
                XCTAssertGreaterThanOrEqual(result.height, ageSize.height)
            }
        }
        let ageOnly = size(
            of: DetailHeaderMetadataRow(ratings: [], badges: [], familyGuidanceAge: 14), width: 280
        )
        XCTAssertGreaterThan(ageOnly.height, 0)
    }

    func testSparseKorraMetadataRemainsOneLine() {
        let score = ExternalRating(source: .community, value: 8.2, scale: .outOfTen)
        let formats = [
            MediaBadge("1080p", style: .prominent),
            MediaBadge("Dolby Digital", style: .dolby, detail: "5.1"),
            MediaBadge("SDR", style: .sdr)
        ]
        let row = DetailHeaderMetadataRow(ratings: [score], badges: formats)
        let reference = size(of: HStack(spacing: 12) {
            RatingBadge(rating: score)
            HStack(spacing: 10) {
                ForEach(formats) { MetadataMediaBadgeChip(badge: $0) }
            }
        }.fixedSize(), width: 2_000)
        let actual = size(of: row, width: 320)
        XCTAssertEqual(actual.height, reference.height, accuracy: 1)
        XCTAssertLessThanOrEqual(actual.width, 320)
    }

    func testEveryCombinationStaysWithinOneLineAtEveryTextSize() {
        for width in [CGFloat(180), 280, 393] {
            for textSize in [DynamicTypeSize.large, .xxxLarge, .accessibility3] {
                let reference = size(of: RatingBadge(rating: ratings[0]), width: 2_000, textSize: textSize)
                let badgeHeight = badges.map {
                    size(of: MetadataMediaBadgeChip(badge: $0), width: 2_000, textSize: textSize).height
                }.max() ?? 0
                for scores in [[], Array(ratings.prefix(1)), ratings] {
                    for formats in [[], Array(badges.prefix(1)), badges] {
                        let result = size(
                            of: DetailHeaderMetadataRow(ratings: scores, badges: formats),
                            width: width, textSize: textSize
                        )
                        XCTAssertLessThanOrEqual(result.width, width + 0.5)
                        XCTAssertLessThanOrEqual(result.height, max(44, reference.height, badgeHeight) + 1)
                        if scores.isEmpty && formats.isEmpty {
                            XCTAssertEqual(result.height, 0, accuracy: 0.5)
                        }
                    }
                }
            }
        }
    }

    func testFormatBadgesYieldToTheDetailsButtonBeforeWrapping() {
        let actual = size(of: DetailHeaderMetadataRow(ratings: ratings, badges: badges), width: 250)
        let expected = size(of: HStack(spacing: 12) {
            ForEach(ratings) { RatingBadge(rating: $0) }
            Label("Formats", systemImage: "info.circle").font(.subheadline.weight(.medium))
        }.fixedSize(), width: 2_000)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5)
        XCTAssertLessThanOrEqual(actual.width, 250)
    }

    func testFormatOnlyRowRetainsTheExistingBadgePresentation() {
        let expected = size(of: HStack(spacing: 10) {
            ForEach(badges) { MetadataMediaBadgeChip(badge: $0) }
        }.fixedSize(), width: 2_000)
        let actual = size(of: DetailHeaderMetadataRow(ratings: [], badges: badges), width: 393)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5)
        let plainText = size(of: Text("4K · DV · HDR10 · Atmos").font(.subheadline), width: 393)
        XCTAssertGreaterThan(actual.height, plainText.height, "Render the badge components, not text substitutions.")
    }

    func testExtraRatingsWrapInsteadOfDisappearingBehindTheDetailsButton() {
        let extraRatings = ratings + [
            .init(source: .imdb, value: 8.6, scale: .outOfTen),
            .init(source: .tmdb, value: 8.3, scale: .outOfTen),
            .init(source: .metacritic, value: 84, scale: .percent)
        ]
        for width in [CGFloat(180), 250] {
            for textSize in [DynamicTypeSize.large, .xxxLarge] {
                let expected = size(of: WrappingHStackLayout(
                    alignment: .center, spacing: 12, lineSpacing: 8, balancesLastRow: true
                ) {
                    ForEach(extraRatings) { RatingBadge(rating: $0) }
                    Label("Formats", systemImage: "info.circle").font(.subheadline.weight(.medium))
                }.lineLimit(1), width: width, textSize: textSize)
                let actual = size(
                    of: DetailHeaderMetadataRow(ratings: extraRatings, badges: badges),
                    width: width, textSize: textSize
                )
                let singleRating = size(of: RatingBadge(rating: extraRatings[0]), width: width, textSize: textSize)
                XCTAssertGreaterThan(actual.height, singleRating.height)
                XCTAssertEqual(actual.height, expected.height, accuracy: 1)
                XCTAssertLessThanOrEqual(actual.width, width + 0.5)
            }
        }
    }

    func testExtraRatingsRemainInlineWhenTheyFit() {
        let extraRatings = ratings + [.init(source: .imdb, value: 8.6, scale: .outOfTen)]
        let expected = size(of: HStack(spacing: 12) {
            ForEach(extraRatings) { RatingBadge(rating: $0) }
        }.fixedSize(), width: 1_000)
        let actual = size(of: DetailHeaderMetadataRow(ratings: extraRatings, badges: []), width: 1_000)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1)
    }
}
#endif
