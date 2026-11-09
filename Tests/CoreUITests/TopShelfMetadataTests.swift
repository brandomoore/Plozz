import CoreModels
import Foundation
@testable import TopShelfKit
import XCTest

final class TopShelfMetadataTests: XCTestCase {
    func testContentRatingPreferenceKeepsReviewsAndOriginalMetadata() {
        let raw = "FR/Tous publics avec avertissement"
        let item = MediaItem(
            id: "film", title: "Fixture", kind: .movie,
            officialRating: raw,
            ratings: [.init(source: .imdb, value: 8, scale: .outOfTen)]
        )
        var snapshot = TopShelfSnapshot.Item(id: item.id, title: item.title)
        TopShelfMetadata.apply(
            to: &snapshot, item: item, details: nil,
            spoilerSettings: .default, locale: Locale(identifier: "en"), showsContentRatings: true
        )
        XCTAssertTrue(snapshot.namedAttributes?.contains {
            $0.name == "Content Rating" && $0.values == [raw]
        } ?? false)
        TopShelfMetadata.apply(
            to: &snapshot, item: item, details: nil,
            spoilerSettings: .default, locale: Locale(identifier: "en"), showsContentRatings: false
        )
        XCTAssertFalse(snapshot.namedAttributes?.contains { $0.name == "Content Rating" } ?? true)
        XCTAssertTrue(snapshot.namedAttributes?.contains { $0.name == "Ratings" } ?? false)
        XCTAssertEqual(item.officialRating, "FR/Tous publics avec avertissement")
    }

    func testFullMetadataPreservesResumeStateAndUsesNativeFields() throws {
        let row = MediaItem(
            id: "1", title: "Curated title", kind: .movie, runtime: 7200, resumePosition: 3600,
            playedPercentage: 0.5, sourceAccountID: "plex"
        )
        var detail = movie()
        detail.resumePosition = 0
        detail.playedPercentage = nil
        let result = metadata(row, details: detail)
        XCTAssertEqual(result.title, row.title)
        XCTAssertEqual(result.summary, detail.overview)
        XCTAssertEqual(result.genre, "Drama · War")
        XCTAssertEqual(result.releaseDate, detail.releaseDate)
        XCTAssertNil(result.subtitle)
        XCTAssertEqual(result.duration, 7200, "Native duration is the full runtime, not time left")
        XCTAssertEqual(result.namedAttributes, [
            .init(name: "Time Left", values: ["1h"]),
            .init(name: "Content Rating", values: ["R"]),
            .init(name: "Cast", values: ["Actor A", "Actor B", "Actor C"]),
            .init(name: "Director", values: ["Director A"])
        ])
        XCTAssertEqual(result.mediaOptions, [.ultraHD, .dolbyVision, .dolbyAtmos, .sdh])
        XCTAssertEqual(result.accountID, row.sourceAccountID)
    }

    func testUnknownFactsStayAbsentAndYearDoesNotInventAReleaseDate() {
        let row = MediaItem(id: "1", title: "Example", kind: .movie, productionYear: 2022)
        let result = metadata(row)
        XCTAssertEqual(result.subtitle, "2022")
        XCTAssertNil(result.releaseDate)
        XCTAssertNil(result.summary)
        XCTAssertNil(result.genre)
        XCTAssertNil(result.duration)
        XCTAssertEqual(result.mediaOptions, [])
        XCTAssertEqual(result.namedAttributes, [])
    }

    func testSpoilersHideEpisodeTextAndGuestCastButKeepSeriesAndNumber() {
        var episode = movie()
        episode.kind = .episode
        episode.parentTitle = "The Series"
        episode.title = "The Killer Revealed"
        episode.seasonNumber = 2
        episode.episodeNumber = 3
        episode.runtime = 3600
        episode.resumePosition = 600
        episode.playedPercentage = 1.0 / 6
        let result = metadata(episode, spoilers: .init(isEnabled: true))
        XCTAssertEqual(result.title, "The Series — Episode 3")
        XCTAssertEqual(result.subtitle, "S2 · E3")
        XCTAssertEqual(result.summary, "The Series · S2 · E3")
        XCTAssertFalse(result.namedAttributes?.contains { $0.name == "Cast" } ?? true)
        XCTAssertEqual(result.namedAttributes?.first, .init(name: "Time Left", values: ["50m"]))

        episode.isPlayed = true
        XCTAssertEqual(metadata(episode, spoilers: .init(isEnabled: true)).summary, episode.overview)
    }

    func testSpoilerSummaryUsesSafeDetailContextWithoutTrustingItsWatchState() {
        let episode = MediaItem(
            id: "episode", title: "Revealing title", kind: .episode,
            overview: "Revealing row synopsis", parentTitle: "  "
        )
        var details = episode
        details.parentTitle = " The Series "
        details.seasonNumber = 2
        details.episodeNumber = 3
        details.overview = "Revealing detailed synopsis"
        details.isPlayed = true

        let result = metadata(episode, details: details, spoilers: .init(isEnabled: true))
        XCTAssertEqual(result.title, "The Series — Episode")
        XCTAssertEqual(result.summary, "The Series · S2 · E3")
    }

    func testSpoilerSummaryWithoutSeriesOrSeasonNeverFallsBackToEpisodeTitle() {
        var episode = MediaItem(
            id: "episode", title: "Revealing title", kind: .episode,
            overview: "Revealing synopsis", episodeNumber: 3
        )
        XCTAssertEqual(
            metadata(episode, spoilers: .init(isEnabled: true)).summary,
            "Episode 3"
        )
        episode.episodeNumber = nil
        XCTAssertEqual(
            metadata(episode, spoilers: .init(isEnabled: true)).summary,
            "Episode"
        )
    }

    func testAttributesUseAvailableStudioAndRatingsWithoutEmptyRows() {
        var item = movie()
        item.people = []
        item.officialRating = "  "
        item.ratings = [.init(source: .imdb, value: 8.5, scale: .outOfTen)]
        let result = metadata(item)
        XCTAssertEqual(result.namedAttributes, [
            .init(name: "Studio", values: ["Studio A"]),
            .init(name: "Ratings", values: ["IMDb 8.5"])
        ])
    }

    func testBadgesDoNotCombineDifferentVersionsOrGuessAtmosFromSurround() {
        var item = movie()
        item.versions = [
            .init(id: "default", height: 1080, isDefault: true, videoRange: "SDR", audioChannels: 8),
            .init(id: "alternate", height: 2160, videoRange: "DOVI", audioProfile: "Dolby Atmos")
        ]
        item.mediaInfo = nil
        XCTAssertEqual(metadata(item).mediaOptions, [.hd])
        item.versions.removeFirst()
        XCTAssertEqual(metadata(item).mediaOptions, [.ultraHD, .dolbyVision, .dolbyAtmos])
        item.kind = .series
        XCTAssertEqual(metadata(item).mediaOptions, [])
    }

    func testHiddenRatingsUseHomeWatchStateIndependentlyOfEpisodeTextProtection() {
        var item = MediaItem(id: "1", title: "Example", kind: .movie)
        var details = item
        details.isPlayed = true
        details.ratings = [.init(source: .imdb, value: 8.5, scale: .outOfTen)]
        let preferences = SpoilerSettings(hideRatingsUntilWatched: true)
        let ratings = [TopShelfSnapshot.NamedAttribute(name: "Ratings", values: ["IMDb 8.5"])]

        XCTAssertEqual(metadata(item, details: details, spoilers: preferences).namedAttributes, [])
        XCTAssertEqual(metadata(item, details: details).namedAttributes, ratings)
        item.isPlayed = true
        details.isPlayed = false
        XCTAssertEqual(metadata(item, details: details, spoilers: preferences).namedAttributes, ratings)
    }

    @MainActor
    func testDetailLookupsAreFullscreenOnlyLimitedAndDeduplicatedByAccount() async throws {
        let first = MediaItem(id: "1", title: "One", kind: .movie, sourceAccountID: "plex")
        let second = first.taggingSource("jellyfin")
        var calls: [String] = []
        let resolver: TopShelfPublisher.MetadataResolver = { item in
            calls.append(item.sourceAccountID ?? "")
            var result = item
            result.overview = "Resolved \(item.sourceAccountID ?? "")"
            return result
        }
        let published = await TopShelfPublisher.makeSnapshot(
            continueWatching: [first, first], latest: [second, first],
            settings: .init(usesFullScreen: true, continueWatchingItems: 1, recentlyAddedItems: 1),
            resolveMetadata: resolver
        )
        let result = try XCTUnwrap(published)
        XCTAssertEqual(calls, ["plex", "jellyfin"])
        XCTAssertEqual(result.sections.map { $0.items.count }, [1, 1])
        calls = []
        _ = await TopShelfPublisher.makeSnapshot(
            continueWatching: [first], latest: [first], settings: .init(usesFullScreen: true),
            resolveMetadata: resolver
        )
        XCTAssertEqual(calls, ["plex"])
        for settings in [TopShelfSettings.default, TopShelfSettings(isEnabled: false, usesFullScreen: true)] {
            _ = await TopShelfPublisher.makeSnapshot(
                continueWatching: [first], latest: [second], settings: settings,
                resolveMetadata: { _ in XCTFail("Unexpected metadata fetch"); return first }
            )
        }
    }

    func testMetadataFailureRetainsKnownFactsButCancellationPublishesNothing() async throws {
        let item = movie()
        let fallback = await TopShelfPublisher.makeSnapshot(
            continueWatching: [item], latest: [], settings: .init(usesFullScreen: true),
            resolveMetadata: { _ in throw AppError.serverUnreachable }
        )
        XCTAssertEqual(fallback?.sections.first?.items.first?.summary, item.overview)
        let cancelled = await TopShelfPublisher.makeSnapshot(
            continueWatching: [item], latest: [], settings: .init(usesFullScreen: true),
            resolveMetadata: { _ in throw CancellationError() }
        )
        XCTAssertNil(cancelled)
        let mismatched = await TopShelfPublisher.makeSnapshot(
            continueWatching: [item], latest: [], settings: .init(usesFullScreen: true),
            resolveMetadata: { _ in MediaItem(id: item.id, title: "Wrong account", kind: .movie,
                                              overview: "Wrong synopsis", sourceAccountID: "other") }
        )
        XCTAssertEqual(mismatched?.sections.first?.items.first?.summary, item.overview)
    }

    private func metadata(
        _ item: MediaItem, details: MediaItem? = nil, spoilers: SpoilerSettings = .default
    ) -> TopShelfSnapshot.Item {
        var snapshot = TopShelfSnapshot.Item(
            id: item.id, accountID: item.sourceAccountID, title: item.title, subtitle: item.subtitle
        )
        TopShelfMetadata.apply(to: &snapshot, item: item, details: details,
                               spoilerSettings: spoilers, locale: Locale(identifier: "en_US"))
        return snapshot
    }

    private func movie() -> MediaItem {
        MediaItem(
            id: "1", title: "Example", kind: .movie, overview: "A synopsis.",
            productionYear: 2022, releaseDate: MediaItem.calendarDayReleaseDate(from: "2022-09-12"),
            officialRating: "R", genres: ["Drama", "War"],
            people: [
                .init(id: "a", name: "Actor A", kind: "Actor"),
                .init(id: "b", name: "Actor B", kind: "Actor"),
                .init(id: "c", name: "Actor C", kind: "Actor"),
                .init(id: "d", name: "Actor D", kind: "GuestStar"),
                .init(id: "director", name: "Director A", kind: "Director")
            ], studios: ["Studio A"], runtime: 7200,
            mediaInfo: .init(
                video: .init(width: 3840, height: 1600, videoRangeType: "DOVIWithHDR10"),
                audio: .init(codec: "eac3", profile: "Dolby Atmos", channels: 8),
                subtitle: .init(codec: "subrip", title: "English SDH")
            ),
            sourceAccountID: "plex"
        )
    }
}
