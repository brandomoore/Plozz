import XCTest
import CoreModels

/// The pure hero CTA decision that drives Play vs. Request vs. download status vs.
/// no-button for featured (Seerr) titles, and Play/Resume for ordinary library
/// items. Kept exhaustive so the UI's button choice can never drift.
final class HeroCTATests: XCTestCase {
    func testServerAvailabilityWithoutVerifiedAccessNeverOffersDuplicateRequestOrPlay() {
        for availability in [MediaAvailabilityStatus.available, .partiallyAvailable] {
            var movie = item(availability)
            movie.locallyValidatedPlayableSource = false
            XCTAssertEqual(movie.heroCTA(seerConnected: true), .unavailable)
            XCTAssertEqual(movie.heroCTA(seerConnected: false), .unavailable)
            movie.locallyValidatedPlayableSource = true
            XCTAssertEqual(movie.heroCTA(seerConnected: true), .play)
        }
    }

    func testApprovedFutureMovieMatchesUnreleasedSeasonWording() throws {
        let release = try XCTUnwrap(MediaItem.calendarDayReleaseDate(from: "2099-10-20"))
        var movie = item(.processing)
        movie.releaseDate = release
        let now = release.addingTimeInterval(-7 * 86_400)
        let cta = movie.heroCTA(seerConnected: true, now: now)
        XCTAssertEqual(cta, .awaitingRelease)
        var title = cta.requestStatusTitle
        title.locale = Locale(identifier: "en")
        XCTAssertEqual(String(localized: title), "Requested · Unreleased")
        XCTAssertEqual(cta.requestStatusSystemImage, "calendar")
        let season = MediaSeasonRequestState(
            number: 1, title: "Season 1", status: .processing, premiereDate: release
        )
        var seasonTitle = season.statusTitle(now: now)
        seasonTitle.locale = title.locale
        XCTAssertEqual(String(localized: title), String(localized: seasonTitle))
    }

    func testFutureMovieDoesNotOverrideApprovalOwnershipOrDownloadEvidence() throws {
        let release = try XCTUnwrap(MediaItem.calendarDayReleaseDate(from: "2099-10-20"))
        let now = release.addingTimeInterval(-7 * 86_400)
        for (availability, expected) in [
            (MediaAvailabilityStatus.pending, HeroCTA.requested),
            (.unknown, .request), (.deleted, .request),
            (.available, .play), (.partiallyAvailable, .play)
        ] {
            var movie = item(availability)
            movie.releaseDate = release
            XCTAssertEqual(movie.heroCTA(seerConnected: true, now: now), expected)
        }
        var movie = item(.processing)
        movie.releaseDate = release
        XCTAssertEqual(movie.heroCTA(seerConnected: false, now: now), .unavailable)
        movie.hasRequestDownloadActivity = true
        XCTAssertEqual(movie.heroCTA(seerConnected: true, now: now), .requested)
        movie.downloadProgress = 0.42
        XCTAssertEqual(movie.heroCTA(seerConnected: true, now: now), .downloading(progress: 0.42))
        movie.hasRequestDownloadActivity = false
        XCTAssertEqual(movie.heroCTA(seerConnected: true, now: now), .downloading(progress: 0.42))
        movie.locallyValidatedPlayableSource = true
        XCTAssertEqual(movie.heroCTA(seerConnected: true, now: now), .play)
    }

    func testMovieReleaseWaitEndsOnLocalReleaseDayAndNeverGuessesMissingDates() throws {
        var movie = item(.processing)
        XCTAssertEqual(movie.heroCTA(seerConnected: true), .requested)
        movie.releaseDate = try XCTUnwrap(MediaItem.calendarDayReleaseDate(from: "2099-10-20"))
        var calendar = Calendar(identifier: .gregorian)
        for offset in [-8 * 3_600, 14 * 3_600] {
            calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: offset))
            let releaseDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2099, month: 10, day: 20)))
            XCTAssertEqual(movie.heroCTA(
                seerConnected: true, now: releaseDay.addingTimeInterval(-1), calendar: calendar
            ), .awaitingRelease)
            for now in [releaseDay, releaseDay.addingTimeInterval(86_400)] {
                XCTAssertEqual(movie.heroCTA(seerConnected: true, now: now, calendar: calendar), .requested)
            }
        }
    }

    func testRequestQueueEvidenceSurvivesCodingAndLegacyItemsRemainReadable() throws {
        var movie = item(.processing)
        movie.hasRequestDownloadActivity = true
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        XCTAssertEqual(
            try decoder.decode(MediaItem.self, from: encoder.encode(movie)).hasRequestDownloadActivity, true
        )
        movie.hasRequestDownloadActivity = nil
        XCTAssertNil(try decoder.decode(MediaItem.self, from: encoder.encode(movie)).hasRequestDownloadActivity)
        movie.hasRequestDownloadActivity = true
        var current = item(.processing)
        current.hasRequestDownloadActivity = false
        current.fillingMissingPresentation(from: movie)
        XCTAssertEqual(current.hasRequestDownloadActivity, false)
    }

    func testFreshFirstEpisodesUseStartWatching() {
        for season in [1, 4] {
            let episode = MediaItem(
                id: "episode", title: "Episode", kind: .episode,
                seasonNumber: season, episodeNumber: 1
            )
            XCTAssertTrue(episode.startsWatching)
            var title = episode.playActionTitle
            title.locale = Locale(identifier: "en")
            XCTAssertEqual(String(localized: title), "Start watching")
        }
    }

    func testResumeRewatchSpecialsAndUnknownEpisodesDoNotClaimAFreshStart() {
        let first = MediaItem(
            id: "episode", title: "Episode", kind: .episode,
            seasonNumber: 1, episodeNumber: 1
        )
        var variants: [MediaItem] = []
        var item = first
        item.resumePosition = 867
        variants.append(item)
        item = first
        item.playedPercentage = 0.2
        variants.append(item)
        item = first
        item.isPlayed = true
        variants.append(item)
        item = first
        item.hasBeenPlayed = true
        variants.append(item)
        item = first
        item.seasonNumber = 0
        variants.append(item)
        item = first
        item.seasonNumber = nil
        variants.append(item)
        item = first
        item.episodeNumber = 2
        variants.append(item)
        item = first
        item.locallyValidatedPlayableSource = false
        variants.append(item)
        item = first
        item.kind = .movie
        variants.append(item)
        for variant in variants {
            XCTAssertFalse(variant.startsWatching)
            var title = variant.playActionTitle
            title.locale = Locale(identifier: "en")
            XCTAssertEqual(String(localized: title), "Play")
        }
    }

    private func item(_ availability: MediaAvailabilityStatus?, download: Double? = nil) -> MediaItem {
        let isOwned = availability == nil
            || availability == .available
            || availability == .partiallyAvailable
        return MediaItem(
            id: "x",
            title: "T",
            kind: .movie,
            availability: availability,
            locallyValidatedPlayableSource: isOwned,
            downloadProgress: download
        )
    }

    func testOrdinaryLibraryItemIsAlwaysPlay() {
        XCTAssertEqual(item(nil).heroCTA(seerConnected: false), .play)
        XCTAssertEqual(item(nil).heroCTA(seerConnected: true), .play)
    }

    func testOwnedFeaturedIsPlayRegardlessOfConnection() {
        XCTAssertEqual(item(.available).heroCTA(seerConnected: false), .play)
        XCTAssertEqual(item(.available).heroCTA(seerConnected: true), .play)
        XCTAssertEqual(item(.partiallyAvailable).heroCTA(seerConnected: true), .play)
    }

    func testRequestableOnlyWhenConnected() {
        XCTAssertEqual(item(.unknown).heroCTA(seerConnected: true), .request)
        XCTAssertEqual(item(.deleted).heroCTA(seerConnected: true), .request)
        // Not connected → no Play/Request button (still shown in the carousel).
        XCTAssertEqual(item(.unknown).heroCTA(seerConnected: false), .unavailable)
        XCTAssertEqual(item(.deleted).heroCTA(seerConnected: false), .unavailable)
    }

    func testPendingShowsRequestedOnlyWhenConnected() {
        XCTAssertEqual(item(.pending).heroCTA(seerConnected: true), .requested)
        XCTAssertEqual(item(.pending).heroCTA(seerConnected: false), .unavailable)
    }

    func testProcessingShowsDownloadingOnlyWithActiveProgress() {
        // Actively downloading (a real queue item reports progress) → Downloading %.
        XCTAssertEqual(item(.processing, download: 0.42).heroCTA(seerConnected: true), .downloading(progress: 0.42))
        // Approved but not downloading yet (no queue item / size) → still Requested,
        // NOT "Downloading".
        XCTAssertEqual(item(.processing, download: nil).heroCTA(seerConnected: true), .requested)
        XCTAssertEqual(item(.processing, download: 0.42).heroCTA(seerConnected: false), .unavailable)
    }

    // MARK: - isNotInLibraryDiscovery

    func testNotInLibraryDiscoveryIsFalseForLibraryAndOwnedTitles() {
        // Ordinary library item (no availability) and owned featured titles must
        // NOT be treated as discovery — they resolve to a real library copy, so
        // their Play/Watchlist/etc. actions stay live.
        XCTAssertFalse(item(nil).isNotInLibraryDiscovery)
        XCTAssertFalse(item(.available).isNotInLibraryDiscovery)
        XCTAssertFalse(item(.partiallyAvailable).isNotInLibraryDiscovery)
    }

    func testNotInLibraryDiscoveryIsTrueForRequestableAndInFlightTitles() {
        XCTAssertTrue(item(.unknown).isNotInLibraryDiscovery)
        XCTAssertTrue(item(.pending).isNotInLibraryDiscovery)
        XCTAssertTrue(item(.processing).isNotInLibraryDiscovery)
        XCTAssertTrue(item(.deleted).isNotInLibraryDiscovery)
    }

    func testPlexDiscoverWatchlistStubHasNoPlayableLibraryTarget() {
        let discover = MediaItem(
            id: "5d7768342ec6b5001f6bbacd",
            title: "13 Going on 30",
            kind: .movie,
            providerIDs: ["PlexGuid": "plex://movie/5d7768342ec6b5001f6bbacd"],
            locallyValidatedPlayableSource: false
        )

        XCTAssertFalse(discover.hasPlayableLibraryTarget())
    }

    func testPlexDiscoverWatchlistStubBecomesPlayableWithLibrarySource() {
        let discover = MediaItem(
            id: "5d7768342ec6b5001f6bbacd",
            title: "13 Going on 30",
            kind: .movie,
            providerIDs: ["PlexGuid": "plex://movie/5d7768342ec6b5001f6bbacd"],
            locallyValidatedPlayableSource: false
        )
        let librarySource = MediaSourceRef(
            accountID: "plex-account",
            itemID: "48291",
            providerKind: .plex
        )

        XCTAssertTrue(discover.hasPlayableLibraryTarget(additionalSources: [librarySource]))
    }

    func testOrdinaryAndOwnedPlexItemsHavePlayableLibraryTargets() {
        XCTAssertTrue(item(nil).hasPlayableLibraryTarget())

        let owned = MediaItem(
            id: "48291",
            title: "13 Going on 30",
            kind: .movie,
            providerIDs: ["PlexGuid": "plex://movie/5d7768342ec6b5001f6bbacd"]
        )
        XCTAssertTrue(owned.hasPlayableLibraryTarget())
    }

    func testAccountMetadataAndGlobalGuidDoNotProveOwnership() {
        let external = MediaItem(
            id: "global",
            title: "The Legend of Hei",
            kind: .movie,
            providerIDs: ["PlexGuid": "plex://movie/global"],
            locallyValidatedPlayableSource: false,
            sourceAccountID: "plex-account"
        )

        XCTAssertFalse(external.hasPlayableLibraryTarget())
        XCTAssertEqual(
            external.ownershipPresentation(),
            MediaOwnershipPresentation(hasValidatedPlayableSource: false)
        )
        XCTAssertEqual(external.heroCTA(seerConnected: true), .request)
        XCTAssertEqual(external.heroCTA(seerConnected: false), .unavailable)
    }

    func testLegacyCachedDiscoverRecordMigratesToUnowned() throws {
        let legacyJSON = """
        {
          "id":"abc123",
          "title":"The Legend of Hei",
          "kind":"movie",
          "providerIDs":{"PlexGuid":"plex://movie/abc123"},
          "sourceAccountID":"plex-account"
        }
        """

        let decoded = try JSONDecoder().decode(
            MediaItem.self,
            from: Data(legacyJSON.utf8)
        )

        XCTAssertFalse(decoded.locallyValidatedPlayableSource)
        XCTAssertFalse(decoded.hasPlayableLibraryTarget())
    }

    func testSeasonRequestAvailabilityKeepsOnlyMissingAndInFlightSeasons() {
        let availability = MediaRequestAvailability(
            status: .partiallyAvailable,
            seasons: [
                MediaSeasonRequestState(number: 1, title: "Season 1", status: .available),
                MediaSeasonRequestState(number: 2, title: "Season 2", status: .unknown),
                MediaSeasonRequestState(number: 3, title: "Season 3", status: .pending),
                MediaSeasonRequestState(number: 4, title: "Season 4", status: .processing),
                MediaSeasonRequestState(number: 5, title: "Season 5", status: .partiallyAvailable),
                MediaSeasonRequestState(number: 6, title: "Season 6", status: .pending, requestFailed: true)
            ]
        )

        XCTAssertEqual(availability.requestableSeasonNumbers, [2])
        XCTAssertEqual(availability.requestPickerSeasons.map(\.number), [2, 3, 4, 6])
        XCTAssertTrue(availability.hasSeasonRequestContent)
    }

    func testMarkingSeasonsRequestedOnlyChangesRequestableSelections() {
        let availability = MediaRequestAvailability(
            status: .partiallyAvailable,
            seasons: [
                MediaSeasonRequestState(number: 1, title: "Season 1", status: .available),
                MediaSeasonRequestState(number: 2, title: "Season 2", status: .unknown),
                MediaSeasonRequestState(number: 3, title: "Season 3", status: .pending)
            ]
        )

        let updated = availability.markingRequested([1, 2, 3])

        XCTAssertEqual(updated.seasons.map(\.status), [.available, .pending, .pending])
    }

    func testMarkingOwnedSeasonsAvailableRemovesThemFromRequestPicker() {
        let availability = MediaRequestAvailability(
            status: .partiallyAvailable,
            seasons: [
                MediaSeasonRequestState(number: 1, title: "Season 1", status: .unknown),
                MediaSeasonRequestState(number: 2, title: "Season 2", status: .pending),
                MediaSeasonRequestState(number: 3, title: "Season 3", status: .unknown)
            ]
        )

        let updated = availability.markingAvailable([1, 2])

        XCTAssertEqual(updated.seasons.map(\.status), [.available, .available, .unknown])
        XCTAssertEqual(updated.requestPickerSeasons.map(\.number), [3])
    }
}
