import XCTest
@testable import CoreModels

final class UpcomingEpisodeTests: XCTestCase {
    func testAgendaGroupsSameDaySeasonBatchWithoutChangingDetailIdentity() {
        let series = MediaItem(id: "library-show", title: "Show", kind: .series, providerIDs: ["Tvdb": "42"])
        var first = sample()
        first.seasonNumber = 2
        first.episodeNumber = 1
        first.absoluteEpisodeNumber = nil
        var second = first
        second.episodeNumber = 2
        var refreshed = first
        refreshed.refreshedAt = first.refreshedAt.addingTimeInterval(10)
        let releases = UpcomingReleaseBuilder.episodes([second, first, refreshed], for: series)
        XCTAssertEqual(releases.count, 1)
        XCTAssertEqual(releases.first?.episodes.map(\.episodeNumber), [1, 2])
        XCTAssertEqual(releases.first?.item.id, "library-show")
        XCTAssertEqual(releases.first?.interests, [.watching])
        XCTAssertEqual(releases.first?.datePrecision, .dateOnly)
    }

    func testAgendaDoesNotInventSeasonForAbsoluteEpisodes() throws {
        let release = try XCTUnwrap(UpcomingReleaseBuilder.episodes(
            [sample()], for: MediaItem(id: "anime", title: "Anime", kind: .series)
        ).first)
        XCTAssertNil(release.episodes.first?.seasonNumber)
        XCTAssertNil(release.episodes.first?.episodeNumber)
        XCTAssertEqual(release.episodes.first?.absoluteEpisodeNumber, 1075)
        XCTAssertEqual(release.datePrecision, .dateAndTime)
    }

    func testMoviesKeepRegionalReleaseKindsAndMergeDuplicateCinemaEvents() {
        let date = sample().airDate
        let movie = MediaItem(id: "film", title: "Film", kind: .movie)
        let events = [
            TitleReleaseEvent(kind: .theatricalLimited, date: date, regionCode: "US"),
            TitleReleaseEvent(kind: .theatrical, date: date, regionCode: "US"),
            TitleReleaseEvent(kind: .digital, date: date, regionCode: "US"),
            TitleReleaseEvent(kind: .digital, date: date, regionCode: "GB")
        ]
        let releases = UpcomingReleaseBuilder.movies(
            events, for: movie, interests: [.watchlist, .requested], regionCode: "US"
        )
        XCTAssertEqual(Set(releases.map(\.kind)), [.theatrical, .digital])
        XCTAssertEqual(releases.count, 2)
        XCTAssertTrue(releases.allSatisfy { $0.regionCode == "US" && $0.item == movie })
    }

    func testHomeKeepsOneFutureReleasePerTitleWhileAgendaRetainsYesterday() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.startOfDay(for: sample().airDate)
        let movie = MediaItem(id: "film", title: "Film", kind: .movie)
        let events = [-1, 1, 2].map {
            TitleReleaseEvent(
                kind: .digital, date: calendar.date(byAdding: .day, value: $0, to: now)!,
                regionCode: "US"
            )
        }
        let releases = UpcomingReleaseBuilder.movies(
            events, for: movie, interests: [.watchlist], regionCode: "US", calendar: calendar
        )
        XCTAssertEqual(releases.count, 3)
        let home = UpcomingReleaseBuilder.home(releases, now: now, calendar: calendar)
        XCTAssertEqual(home.map(\.date), [events[1].date])
        XCTAssertTrue(UpcomingReleaseBuilder.home(
            releases, hiddenTitles: [UpcomingRelease.titleKey(for: movie)], now: now, calendar: calendar
        ).isEmpty)
    }

    func testInterestAndMediaFiltersSelectOnlyMatchingReleases() throws {
        let release = try XCTUnwrap(UpcomingReleaseBuilder.movies(
            [.init(kind: .digital, date: sample().airDate, regionCode: "US")],
            for: MediaItem(id: "saved-film", title: "Saved", kind: .movie),
            interests: [.watchlist], regionCode: "US"
        ).first)
        var filters = UpcomingFilters()
        XCTAssertTrue(filters.includes(release))
        filters.interests = [.requested]
        XCTAssertFalse(filters.includes(release))
        filters.interests = [.watchlist]
        filters.mediaType = .shows
        XCTAssertFalse(filters.includes(release))
    }

    private func sample() -> UpcomingEpisode {
        UpcomingEpisode(
            seriesIdentity: .external(source: "anilist", value: "21"),
            absoluteEpisodeNumber: 1075,
            title: nil,
            airDate: Date(timeIntervalSince1970: 1_900_000_000),
            datePrecision: .dateAndTime,
            source: .anilist,
            sourceURL: URL(string: "https://anilist.co/anime/21"),
            refreshedAt: Date(timeIntervalSince1970: 1_000_000)
        )
    }

    func testUpcomingEpisodeCodableRoundTrip() throws {
        let original = sample()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UpcomingEpisode.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.seriesIdentity, .external(source: "anilist", value: "21"))
        XCTAssertNil(decoded.seasonNumber)
        XCTAssertEqual(decoded.absoluteEpisodeNumber, 1075)
    }

    func testReleaseStateExposesUpcomingExceptWhenPresent() {
        let up = sample()
        XCTAssertEqual(EpisodeReleaseState.upcoming(up).upcomingEpisode, up)
        XCTAssertEqual(EpisodeReleaseState.airedGracePeriod(up).upcomingEpisode, up)
        XCTAssertEqual(EpisodeReleaseState.airedMissing(up).upcomingEpisode, up)
        XCTAssertEqual(EpisodeReleaseState.requested(up).upcomingEpisode, up)

        var item = MediaItem(id: "x", title: "Ep", kind: .episode)
        item.seasonNumber = 1
        item.episodeNumber = 2
        XCTAssertNil(EpisodeReleaseState.present(item: item).upcomingEpisode)
        XCTAssertFalse(EpisodeReleaseState.present(item: item).isAbsent)
        XCTAssertTrue(EpisodeReleaseState.upcoming(up).isAbsent)
    }

    func testNextAiringEpisodeCapabilityCoversField() {
        XCTAssertEqual(MetadataCapability.covering(.nextAiringEpisode), .nextAiringEpisode)
        XCTAssertTrue(MetadataCapability.nextAiringEpisode.coveredFields.contains(.nextAiringEpisode))
    }
}
