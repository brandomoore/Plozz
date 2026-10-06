import XCTest
@testable import CoreModels

final class ExternalRatingTests: XCTestCase {
    func testHydratedSelectedEmptyRatingsReplaceStaleScoresAndBlockLaterGapFills() {
        let score = ExternalRating(source: .imdb, value: 8, scale: .outOfTen)
        var seed = MediaItem(id: "movie", title: "Movie", kind: .movie, ratings: [score])
        var full = seed
        full.ratings = []
        full.usesProviderRatings = true
        seed.mergeHydratedRatings(from: full)
        XCTAssertTrue(seed.ratings.isEmpty)
        XCTAssertTrue(seed.usesProviderRatings)
        var stale = full
        stale.usesProviderRatings = false
        stale.ratings = [score]
        seed.mergeHydratedRatings(from: stale)
        XCTAssertTrue(seed.ratings.isEmpty)
        seed.fillingMissingPresentation(from: stale)
        XCTAssertTrue(seed.ratings.isEmpty)
    }

    func testProviderSourcesKeepDistinctIdentityAndDisplayOrder() throws {
        let entries = ["a", "b"].enumerated().map { index, source in
            ExternalRating(source: .provider, value: 84, scale: .outOfHundred,
                           providerDisplay: .init(sourceID: source, name: source, value: "4.2", order: index))
        }
        let merged = entries.mergedWithAuthoritative([])
        XCTAssertEqual(merged.map(\.id), ["a", "b"])
        XCTAssertEqual(merged.map(\.displayValue), ["4.2", "4.2"])
        XCTAssertEqual(merged.first?.normalized ?? 0, 0.84, accuracy: 0.001)
        let encoded = try JSONEncoder().encode(entries)
        XCTAssertEqual(try JSONDecoder().decode([ExternalRating].self, from: encoded), entries)
    }

    func testPresentationDonorCannotRestoreServerHiddenRatings() {
        var item = MediaItem(id: "silo", title: "Title", kind: .movie, usesProviderRatings: true)
        let donor = MediaItem(
            id: "plex", title: "Title", kind: .movie,
            ratings: [.init(source: .rottenTomatoes, value: 90, scale: .percent)]
        )
        item.fillingMissingPresentation(from: donor)
        XCTAssertTrue(item.ratings.isEmpty)
        XCTAssertTrue(item.usesProviderRatings)
    }

    // MARK: Normalization

    func testNormalizedOutOfTen() {
        let rating = ExternalRating(source: .imdb, value: 8.8, scale: .outOfTen)
        XCTAssertEqual(rating.normalized, 0.88, accuracy: 0.0001)
    }

    func testNormalizedPercent() {
        let rating = ExternalRating(source: .rottenTomatoes, value: 74, scale: .percent)
        XCTAssertEqual(rating.normalized, 0.74, accuracy: 0.0001)
    }

    func testNormalizedOutOfHundred() {
        let rating = ExternalRating(source: .metacritic, value: 74, scale: .outOfHundred)
        XCTAssertEqual(rating.normalized, 0.74, accuracy: 0.0001)
    }

    func testNormalizedOutOfFive() {
        let rating = ExternalRating(source: .letterboxd, value: 4.1, scale: .outOfFive)
        XCTAssertEqual(rating.normalized, 0.82, accuracy: 0.0001)
    }

    func testNormalizedClampsAboveMaximum() {
        let rating = ExternalRating(source: .imdb, value: 12, scale: .outOfTen)
        XCTAssertEqual(rating.normalized, 1.0, accuracy: 0.0001)
    }

    // MARK: Display formatting

    func testDisplayValueOutOfTenTrimsWholeNumbers() {
        XCTAssertEqual(ExternalRating(source: .imdb, value: 8.0, scale: .outOfTen).displayValue, "8.0")
        XCTAssertEqual(ExternalRating(source: .imdb, value: 8.8, scale: .outOfTen).displayValue, "8.8")
    }

    func testDisplayValuePercent() {
        XCTAssertEqual(ExternalRating(source: .rottenTomatoes, value: 74, scale: .percent).displayValue, "74%")
    }

    func testDisplayValueOutOfHundred() {
        XCTAssertEqual(ExternalRating(source: .metacritic, value: 74, scale: .outOfHundred).displayValue, "74/100")
    }

    func testDisplayValueOutOfFive() {
        XCTAssertEqual(ExternalRating(source: .letterboxd, value: 4.1, scale: .outOfFive).displayValue, "4.1/5")
    }

    // MARK: Iconography & freshness

    func testIcons() {
        XCTAssertEqual(RatingSource.rottenTomatoes.icon, .tomato)
        XCTAssertEqual(RatingSource.critic.icon, .critic)
        XCTAssertEqual(RatingSource.rottenTomatoesAudience.icon, .popcorn)
        XCTAssertEqual(RatingSource.imdb.icon, .imdb)
        XCTAssertEqual(RatingSource.tmdb.icon, .tmdb)
        XCTAssertEqual(RatingSource.community.icon, .star)
        XCTAssertEqual(RatingSource.letterboxd.icon, .star)
        // AniList carries its own mark rather than a generic star, so a score from
        // it is attributable at a glance instead of looking like the server's own.
        XCTAssertEqual(RatingSource.anilist.icon, .anilist)
        XCTAssertEqual(RatingSource.metacritic.icon, .metacritic)
    }

    func testFreshnessFreshAtThreshold() {
        XCTAssertEqual(ExternalRating(source: .rottenTomatoes, value: 60, scale: .percent).freshness, .fresh)
        XCTAssertEqual(ExternalRating(source: .rottenTomatoes, value: 89, scale: .percent).freshness, .fresh)
    }

    func testFreshnessRottenBelowThreshold() {
        XCTAssertEqual(ExternalRating(source: .rottenTomatoes, value: 42, scale: .percent).freshness, .rotten)
    }

    func testFreshnessNoneForNonFreshnessSources() {
        XCTAssertEqual(ExternalRating(source: .imdb, value: 9, scale: .outOfTen).freshness, .none)
        XCTAssertEqual(ExternalRating(source: .metacritic, value: 90, scale: .outOfHundred).freshness, .none)
        XCTAssertEqual(ExternalRating(source: .critic, value: 90, scale: .outOfHundred).freshness, .none)
    }

    func testExplicitRottenTomatoesVerdictWinsOverThreshold() {
        let rating = ExternalRating(
            source: .rottenTomatoesAudience,
            value: 90,
            scale: .percent,
            verdict: .stale
        )
        XCTAssertEqual(rating.freshness, .rotten)
    }

    func testNewOptionalFieldsDecodeFromLegacyPayload() throws {
        let data = Data(#"{"source":"imdb","value":8.8,"scale":"outOfTen"}"#.utf8)
        let rating = try JSONDecoder().decode(ExternalRating.self, from: data)
        XCTAssertNil(rating.ratingCount)
        XCTAssertNil(rating.verdict)
    }

    // MARK: OMDb value parsing

    func testParseOMDbOutOfTen() {
        let rating = ExternalRating.parseOMDb(source: .imdb, value: "8.8/10")
        XCTAssertEqual(rating?.value, 8.8)
        XCTAssertEqual(rating?.scale, .outOfTen)
    }

    func testParseOMDbPercent() {
        let rating = ExternalRating.parseOMDb(source: .rottenTomatoes, value: "74%")
        XCTAssertEqual(rating?.value, 74)
        XCTAssertEqual(rating?.scale, .percent)
    }

    func testParseOMDbOutOfHundred() {
        let rating = ExternalRating.parseOMDb(source: .metacritic, value: "74/100")
        XCTAssertEqual(rating?.value, 74)
        XCTAssertEqual(rating?.scale, .outOfHundred)
    }

    func testParseOMDbBarePlainNumberAssumesOutOfTen() {
        let rating = ExternalRating.parseOMDb(source: .imdb, value: "8.8")
        XCTAssertEqual(rating?.value, 8.8)
        XCTAssertEqual(rating?.scale, .outOfTen)
    }

    func testParseOMDbRejectsGarbage() {
        XCTAssertNil(ExternalRating.parseOMDb(source: .imdb, value: "N/A"))
        XCTAssertNil(ExternalRating.parseOMDb(source: .imdb, value: ""))
    }

    // MARK: Merge

    func testMergeAuthoritativeReplacesSameSourceAndSorts() {
        let native = [
            ExternalRating(source: .community, value: 7.2, scale: .outOfTen),
            ExternalRating(source: .rottenTomatoes, value: 50, scale: .percent)
        ]
        let authoritative = [
            ExternalRating(source: .imdb, value: 8.8, scale: .outOfTen),
            ExternalRating(source: .rottenTomatoes, value: 74, scale: .percent),
            ExternalRating(source: .metacritic, value: 74, scale: .outOfHundred)
        ]
        let merged = native.mergedWithAuthoritative(authoritative)

        // Authoritative RT overrides the native one.
        let rt = merged.first { $0.source == .rottenTomatoes }
        XCTAssertEqual(rt?.value, 74)
        // Native-only source is preserved.
        XCTAssertTrue(merged.contains { $0.source == .community })
        // Ordered by sortRank: the Rotten Tomatoes scores lead, then IMDb, then
        // the remaining sources.
        XCTAssertEqual(merged.map(\.source), [.rottenTomatoes, .imdb, .metacritic, .community])
    }

    func testMergePreservesNativeCountWhenAuthoritativeScoreHasNone() {
        let native = [ExternalRating(
            source: .imdb,
            value: 8.1,
            scale: .outOfTen,
            ratingCount: 12_345
        )]
        let merged = native.mergedWithAuthoritative([
            ExternalRating(source: .imdb, value: 8.8, scale: .outOfTen)
        ])
        XCTAssertEqual(merged.first?.value, 8.8)
        XCTAssertEqual(merged.first?.ratingCount, 12_345)
    }
}
