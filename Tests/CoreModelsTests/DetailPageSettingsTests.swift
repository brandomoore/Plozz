import XCTest
@testable import CoreModels

final class DetailPageSettingsTests: XCTestCase {
    private let audience = ExternalRating(source: .rottenTomatoesAudience, value: 89, scale: .percent)
    private let critics = ExternalRating(source: .rottenTomatoes, value: 96, scale: .percent)
    private let imdb = ExternalRating(source: .imdb, value: 8.6, scale: .outOfTen)
    private let tmdb = ExternalRating(source: .tmdb, value: 8.3, scale: .outOfTen)
    private let anilist = ExternalRating(source: .anilist, value: 90, scale: .percent)

    func testDefaultAddsAnAgeRecommendationWithoutConsumingEitherReviewSlot() {
        let settings = DetailPageSettings.default
        XCTAssertEqual(settings.headerFamilyGuidanceAge(from: 14, hidesRatings: false), 14)
        XCTAssertNil(settings.headerFamilyGuidanceAge(from: nil, hidesRatings: false))
        XCTAssertEqual(settings.headerRatings(
            from: [imdb, audience, critics], isAnime: false, hidesRatings: false
        ), [audience, critics])
    }

    func testAgeVisibilityIsIndependentOfReviewScoresAndHonorsSpoilers() {
        var settings = DetailPageSettings.default
        XCTAssertNil(settings.headerFamilyGuidanceAge(from: 14, hidesRatings: true))
        settings.showsHeaderFamilyGuidance = false
        XCTAssertNil(settings.headerFamilyGuidanceAge(from: 14, hidesRatings: false))
        XCTAssertEqual(settings.headerRatings(
            from: [imdb], isAnime: false, hidesRatings: false
        ), [imdb])
        settings.showsHeaderFamilyGuidance = true
        settings.showsHeaderRatings = false
        XCTAssertEqual(settings.headerFamilyGuidanceAge(from: 14, hidesRatings: false), 14)
        XCTAssertTrue(settings.headerRatings(from: [imdb], isAnime: false, hidesRatings: false).isEmpty)
        XCTAssertNil(settings.headerFamilyGuidanceAge(from: 14, hidesRatings: true))
        settings.showsHeaderFamilyGuidance = false
        XCTAssertNil(settings.headerFamilyGuidanceAge(from: 14, hidesRatings: false))
    }

    func testReviewCountDoesNotChangeAgeVisibilityOrStoredPreference() throws {
        for count in DetailPageSettings.headerRatingCountRange {
            let settings = DetailPageSettings(showsHeaderRatings: false, maxHeaderRatings: count)
            let restored = try JSONDecoder().decode(
                DetailPageSettings.self, from: JSONEncoder().encode(settings)
            )
            XCTAssertEqual(restored, settings)
            XCTAssertEqual(restored.headerFamilyGuidanceAge(from: 12, hidesRatings: false), 12)
            XCTAssertTrue(restored.headerRatings(
                from: [audience, critics, imdb, tmdb], isAnime: false, hidesRatings: false
            ).isEmpty)
        }
    }

    func testLegacyAgePreferenceDoesNotResetExistingReviewChoices() throws {
        let data = Data("""
        {"showsHeaderRatings":true,"maxHeaderRatings":4,"ratingSourceOrder":["imdb"],"enabledRatingSources":["imdb"]}
        """.utf8)
        let settings = try JSONDecoder().decode(DetailPageSettings.self, from: data)
        XCTAssertTrue(settings.showsHeaderFamilyGuidance)
        XCTAssertEqual(settings.maxHeaderRatings, 4)
        XCTAssertEqual(settings.ratingSourceOrder, [.imdb])
        XCTAssertEqual(settings.enabledRatingSources, [.imdb])
    }

    func testHomeHasIndependentPersistedPreviewPreferences() throws {
        var home = HeroSettings.default
        XCTAssertEqual(home.ratingPreferences, .default)
        home.ratingPreferences.showsHeaderFamilyGuidance = false
        home.ratingPreferences.maxHeaderRatings = 4
        let data = try JSONEncoder().encode(home)
        XCTAssertEqual(try JSONDecoder().decode(HeroSettings.self, from: data), home)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "ratingPreferences")
        let restored = try JSONDecoder().decode(
            HeroSettings.self, from: JSONSerialization.data(withJSONObject: legacy)
        )
        XCTAssertEqual(restored.ratingPreferences, .default)
        XCTAssertEqual(restored.showsRatings, home.showsRatings)
    }

    func testDefaultPrefersAudienceAndCriticsRatherThanServerOrder() {
        XCTAssertEqual(DetailPageSettings.default.maxHeaderRatings, 2)
        XCTAssertEqual(DetailPageSettings.default.headerRatings(
            from: [tmdb, imdb, critics, audience], isAnime: false, hidesRatings: false
        ), [audience, critics])
    }

    func testChosenMaximumAllowsMoreRatingsWithoutChangingPriorityOrFiltering() {
        var settings = DetailPageSettings(maxHeaderRatings: 4)
        let available = [tmdb, anilist, imdb, critics, audience]
        XCTAssertEqual(settings.headerRatings(
            from: available, isAnime: false, hidesRatings: false
        ), [audience, critics, imdb, tmdb])
        XCTAssertEqual(settings.headerRatings(
            from: available, isAnime: true, hidesRatings: false
        ), [audience, critics, imdb, anilist])
        settings.enabledRatingSources.remove(.rottenTomatoes)
        XCTAssertEqual(settings.headerRatings(
            from: available, isAnime: false, hidesRatings: false
        ), [audience, imdb, tmdb])
        XCTAssertTrue(settings.headerRatings(
            from: available, isAnime: true, hidesRatings: true
        ).isEmpty)
    }

    func testRatingMaximumIsBoundedOnInitializationAndMutation() {
        var settings = DetailPageSettings(maxHeaderRatings: -1)
        XCTAssertEqual(settings.maxHeaderRatings, 1)
        XCTAssertEqual(settings.headerRatings(
            from: [audience, critics, imdb], isAnime: false, hidesRatings: false
        ), [audience])
        settings.maxHeaderRatings = 100
        XCTAssertEqual(settings.maxHeaderRatings, RatingSource.allCases.count)
        settings.maxHeaderRatings = 0
        XCTAssertEqual(settings.maxHeaderRatings, 1)
    }

    func testEightEnabledSourcesCanShowOnlyTheirTopTwoAvailableScores() {
        var settings = DetailPageSettings(
            maxHeaderRatings: 2,
            ratingSourceOrder: [.metacritic, .imdb, .rottenTomatoesAudience, .rottenTomatoes, .tmdb],
            enabledRatingSources: Set(RatingSource.allCases).subtracting([.community])
        )
        let available = [tmdb, audience, imdb, critics]
        XCTAssertEqual(settings.enabledRatingSources.count, 8)
        XCTAssertEqual(settings.headerRatings(
            from: available, isAnime: false, hidesRatings: false
        ), [imdb, audience], "Skip the unavailable higher-priority source, not the enabled sources below it.")
        settings.maxHeaderRatings = 3
        XCTAssertEqual(settings.headerRatings(
            from: available, isAnime: false, hidesRatings: false
        ), [imdb, audience, critics])
        XCTAssertEqual(settings.enabledRatingSources.count, 8)
    }

    func testCodablePreservesCountAndReadsLegacySettingsWithoutResettingChoices() throws {
        let selected = DetailPageSettings(
            showsHeaderRatings: false, maxHeaderRatings: 5,
            ratingSourceOrder: [.imdb, .tmdb], enabledRatingSources: [.tmdb]
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(DetailPageSettings.self, from: encoder.encode(selected)), selected)
        var legacy = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(selected)) as? [String: Any]
        )
        legacy.removeValue(forKey: "maxHeaderRatings")
        let decoded = try decoder.decode(
            DetailPageSettings.self, from: JSONSerialization.data(withJSONObject: legacy)
        )
        XCTAssertEqual(decoded.maxHeaderRatings, 2)
        XCTAssertFalse(decoded.showsHeaderRatings)
        XCTAssertEqual(decoded.ratingSourceOrder, [.imdb, .tmdb])
        XCTAssertEqual(decoded.enabledRatingSources, [.tmdb])
    }

    func testMissingSourcesFallThroughAndSparseTitlesStaySparse() {
        for (available, expected) in [
            ([imdb, tmdb], [imdb, tmdb]),
            ([tmdb, critics], [critics, tmdb]),
            ([imdb], [imdb]),
            ([], [])
        ] {
            XCTAssertEqual(DetailPageSettings.default.headerRatings(
                from: available, isAnime: false, hidesRatings: false
            ), expected)
        }
    }

    func testPreferencesAndAnimeApplicabilityControlSelection() {
        let settings = DetailPageSettings(
            ratingSourceOrder: [.anilist, .tmdb, .imdb],
            enabledRatingSources: [.anilist, .imdb, .tmdb]
        )
        let available = [audience, critics, imdb, tmdb, anilist]
        XCTAssertEqual(settings.headerRatings(from: available, isAnime: true, hidesRatings: false), [anilist, tmdb])
        XCTAssertEqual(settings.headerRatings(from: available, isAnime: false, hidesRatings: false), [tmdb, imdb])
    }

    func testHiddenOrDisabledRatingsNeverFillTheHeader() {
        let available = [audience, critics, imdb, tmdb]
        XCTAssertTrue(DetailPageSettings.default.headerRatings(
            from: available, isAnime: false, hidesRatings: true
        ).isEmpty)
        XCTAssertTrue(DetailPageSettings(showsHeaderRatings: false).headerRatings(
            from: available, isAnime: false, hidesRatings: false
        ).isEmpty)
        XCTAssertTrue(DetailPageSettings(enabledRatingSources: []).headerRatings(
            from: available, isAnime: false, hidesRatings: false
        ).isEmpty)
    }

    func testDuplicateSourcesCannotTakeBothSlots() {
        let settings = DetailPageSettings(ratingSourceOrder: [.imdb, .imdb, .tmdb])
        XCTAssertEqual(settings.headerRatings(
            from: [imdb, imdb, tmdb], isAnime: false, hidesRatings: false
        ), [imdb, tmdb])
        XCTAssertEqual(Set(settings.orderedSources), Set(RatingSource.allCases))
        XCTAssertEqual(settings.orderedSources.count, RatingSource.allCases.count)
    }

    func testSettingsPersistPerProfileAndTransferWithoutChangingOtherProfiles() throws {
        let suite = "DetailPageSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = DetailPageSettingsStore(defaults: defaults, namespace: "first")
        let second = DetailPageSettingsStore(defaults: defaults, namespace: "second")
        let selected = DetailPageSettings(
            showsHeaderRatings: false,
            showsHeaderFamilyGuidance: false,
            maxHeaderRatings: 4,
            ratingSourceOrder: [.imdb, .community] + DetailPageSettings.defaultRatingOrder.filter {
                $0 != .imdb && $0 != .community
            },
            enabledRatingSources: [.imdb, .community]
        )
        first.save(selected)
        XCTAssertEqual(first.load(), selected)
        XCTAssertEqual(second.load(), .default)
        let snapshot = ProfileSettingsTransfer.capture(namespace: "first", defaults: defaults)
        XCTAssertNotNil(snapshot[DetailPageSettingsStore.baseKey])
        ProfileSettingsTransfer.apply(snapshot, namespace: "second", defaults: defaults)
        XCTAssertEqual(second.load(), selected)
        ProfileSettingsTransfer.removeOne(
            baseKey: DetailPageSettingsStore.baseKey, namespace: "second", defaults: defaults
        )
        XCTAssertEqual(second.load(), .default)
        XCTAssertEqual(first.load(), selected)
    }

    func testEmptySavedSelectionSurvivesReload() throws {
        let suite = "DetailPageSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DetailPageSettingsStore(defaults: defaults)
        store.save(DetailPageSettings(enabledRatingSources: []))
        XCTAssertTrue(store.load().enabledRatingSources.isEmpty)
    }

    func testLegacyStoreDefaultsCountWithoutResettingSourceChoices() throws {
        let suite = "DetailPageSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([
            "showsHeaderRatings": false,
            "ratingSourceOrder": [RatingSource.imdb.rawValue],
            "enabledRatingSources": [RatingSource.imdb.rawValue]
        ], forKey: DetailPageSettingsStore.baseKey)
        let settings = DetailPageSettingsStore(defaults: defaults).load()
        XCTAssertEqual(settings.maxHeaderRatings, 2)
        XCTAssertFalse(settings.showsHeaderRatings)
        XCTAssertEqual(settings.ratingSourceOrder, [.imdb])
        XCTAssertEqual(settings.enabledRatingSources, [.imdb])
    }

}
