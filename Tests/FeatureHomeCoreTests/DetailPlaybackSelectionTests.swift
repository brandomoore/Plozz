import XCTest
import CoreModels
@testable import FeatureHomeCore

/// An episode's preference key is its SERIES', so a per-file id stored there can
/// only ever match the one episode it was saved from.
final class DetailPlaybackSelectionTests: XCTestCase {
    func testResolvedPickerAndPlayKeepCollidingFilesScopedToAccountAndEdition() throws {
        let item = selectionItem()
        let sources = [
            selectionSource(item, account: "plex", id: "10"),
            selectionSource(item, account: "jellyfin", id: "10"),
            selectionSource(item, account: "jellyfin", id: "20")
        ]
        let chosen = sources[2].selectableVersions[0]
        let result = resolve(item, sources: sources, source: "jellyfin", version: chosen.id)

        XCTAssertEqual(result.serverChoices.map(\.accountID), ["plex", "jellyfin"])
        XCTAssertEqual(result.source?.accountID, "jellyfin")
        XCTAssertEqual(Set(result.versions.compactMap(\.sourceItemID)), ["10", "20"])
        XCTAssertTrue(result.versions.allSatisfy { $0.sourceAccountID == "jellyfin" })
        XCTAssertEqual(result.selectedVersionID, chosen.id)
        XCTAssertEqual(result.playItem.id, "20")
        XCTAssertEqual(result.playItem.sourceAccountID, "jellyfin")
        XCTAssertEqual(result.playItem.selectedVersionID, "file-small")
        XCTAssertTrue(result.playItem.explicitSourceSelection)
        XCTAssertTrue(result.playItem.explicitVersionSelection)
    }

    func testResolutionPreservesOpeningEditionUntilAnExplicitVersionChoice() {
        var item = selectionItem()
        item.editionOpeningSource = .init(accountID: "plex", itemID: "10")
        let sources = [
            selectionSource(item, account: "plex", id: "20"),
            selectionSource(item, account: "plex", id: "10")
        ]
        let opened = resolve(item, sources: sources)
        XCTAssertEqual(opened.source?.itemID, "10")
        XCTAssertEqual(opened.playItem.id, "10")
        XCTAssertTrue(opened.playItem.explicitSourceSelection)
        XCTAssertFalse(opened.playItem.explicitVersionSelection)

        let alternate = sources[0].selectableVersions[0]
        let picked = resolve(item, sources: sources, version: alternate.id)
        XCTAssertEqual(picked.playItem.id, "20")
        XCTAssertEqual(picked.playItem.selectedVersionID, "file-small")
    }

    func testResolutionRecomputesAfterAnUnavailableSourceIsRemoved() {
        let item = selectionItem()
        let primary = selectionSource(item, account: "plex", id: "10")
        let alternate = selectionSource(item, account: "jellyfin", id: "20")
        let selected = resolve(item, sources: [primary, alternate], source: "jellyfin")
        XCTAssertEqual(selected.playItem.sourceAccountID, "jellyfin")
        XCTAssertEqual(selected.playItem.id, "20")

        let remaining = resolve(item, sources: [primary], source: "jellyfin")
        XCTAssertEqual(remaining.serverChoices.map(\.accountID), ["plex"])
        XCTAssertNil(remaining.source, "One source retains the version-only path.")
        XCTAssertEqual(remaining.playItem.sourceAccountID, "plex")
        XCTAssertEqual(remaining.playItem.id, "10")
    }

    func testEpisodeResolutionDoesNotUseSeriesVersionsOrWatchState() {
        var episode = selectionItem()
        episode.kind = .episode
        episode.seriesID = "series"
        episode.resumePosition = 180
        let containers = ["plex", "jellyfin"].map {
            MediaSourceRef(accountID: $0, itemID: "series", kind: .series,
                           versions: [MediaVersion(id: "container-file")], resumePosition: 900)
        }
        let result = resolve(episode, sources: containers)
        XCTAssertEqual(result.playItem.id, episode.id)
        XCTAssertEqual(result.playItem.kind, .episode)
        XCTAssertEqual(result.playItem.resumePosition, 180)
        XCTAssertEqual(result.versions.map(\.id), episode.versions.sortedForPicker().map(\.id))
        XCTAssertNotEqual(result.playItem.selectedVersionID, "container-file")
    }

    func testResolutionMatchesExistingCompositionAcrossModesAndExplicitChoices() {
        let item = selectionItem()
        let sources = [
            selectionSource(item, account: "plex", id: "10"),
            selectionSource(item, account: "jellyfin", id: "20")
        ]
        for mode in [PlaybackVersionSelectionMode.automatic, .serverOrder] {
            let preferences = SelectionPreferences(selectionMode: mode)
            for available in [[], [sources[0]], sources] {
                for sourceOverride in [String?.none, "jellyfin", "removed"] {
                    for versionOverride in [String?.none, "file-small", "missing"] {
                        for pinned in [false, true] {
                            let source = DetailPlaybackSelection.preferredSource(
                                sourceOverride: sourceOverride, libraryOrigin: "plex",
                                itemSourceAccountID: item.sourceAccountID, sources: available,
                                capabilities: .detected(), openingSource: item.editionOpeningSource
                            )
                            let versions = DetailPlaybackSelection.versions(
                                for: item, sources: available, activeAccountID: source?.accountID
                            )
                            let versionID = DetailPlaybackSelection.preferredVersionID(
                                for: item, versions: versions, versionOverride: versionOverride,
                                preferences: preferences, capabilities: .detected(), sources: available
                            )
                            let expected = DetailPlaybackSelection.playItem(
                                for: item, sources: available, activeAccountID: source?.accountID,
                                versionID: versionID,
                                explicit: pinned || sourceOverride != nil || versionOverride != nil,
                                explicitVersion: versionOverride != nil || item.explicitVersionSelection
                            )
                            let actual = DetailPlaybackSelection.resolve(
                                for: item, sources: available, sourceOverride: sourceOverride,
                                versionOverride: versionOverride, libraryOrigin: "plex",
                                isLibraryOriginPinned: pinned, preferences: preferences,
                                capabilities: .detected()
                            )
                            XCTAssertEqual(actual.source, source)
                            XCTAssertEqual(actual.versions, versions)
                            XCTAssertEqual(actual.selectedVersionID, versionID)
                            XCTAssertEqual(actual.playItem, expected)
                        }
                    }
                }
            }
        }
    }

    private func selectionItem() -> MediaItem {
        MediaItem(
            id: "10", title: "Movie", kind: .movie, sourceAccountID: "plex",
            versions: [
                MediaVersion(id: "file-small", height: 720, videoCodec: "h264"),
                MediaVersion(id: "file-large", height: 1080, videoCodec: "h264")
            ]
        )
    }

    private func selectionSource(_ item: MediaItem, account: String, id: String) -> MediaSourceRef {
        MediaSourceRef(accountID: account, itemID: id, kind: item.kind, versions: item.versions)
    }

    private struct SelectionPreferences: VersionPreferenceStoring {
        var selectionMode: PlaybackVersionSelectionMode = .automatic
        func preferredVersionID(forTitle titleID: String) -> String? { nil }
        func setPreferredVersionID(_ versionID: String?, forTitle titleID: String) {}
    }

    private func resolve(
        _ item: MediaItem,
        sources: [MediaSourceRef],
        source: String? = nil,
        version: String? = nil
    ) -> DetailPlaybackSelection.Resolution {
        DetailPlaybackSelection.resolve(
            for: item, sources: sources, sourceOverride: source, versionOverride: version,
            libraryOrigin: nil, isLibraryOriginPinned: false,
            preferences: SelectionPreferences(), capabilities: .detected()
        )
    }

    func testPlayPlaceholderIsOnlyForAnUnresolvedOwnedContainer() {
        let show = MediaItem(id: "show", title: "Show", kind: .series)
        XCTAssertTrue(DetailPlaybackSelection.showsPlayPlaceholder(
            for: show, hasPlayTarget: false, childrenLoaded: false, seasonLoadState: nil
        ))
        XCTAssertTrue(DetailPlaybackSelection.showsPlayPlaceholder(
            for: show, hasPlayTarget: false, childrenLoaded: true, seasonLoadState: .notLoaded
        ))
        XCTAssertFalse(DetailPlaybackSelection.showsPlayPlaceholder(
            for: show, hasPlayTarget: true, childrenLoaded: false, seasonLoadState: .notLoaded
        ))
        for state in [SeasonLoadState?.none, .some(.loaded([])), .some(.failed)] {
            XCTAssertFalse(DetailPlaybackSelection.showsPlayPlaceholder(
                for: show, hasPlayTarget: false, childrenLoaded: true, seasonLoadState: state
            ))
        }

        var external = show
        external.locallyValidatedPlayableSource = false
        XCTAssertFalse(DetailPlaybackSelection.showsPlayPlaceholder(
            for: external, hasPlayTarget: false, childrenLoaded: false, seasonLoadState: nil
        ))
        let movie = MediaItem(id: "movie", title: "Movie", kind: .movie)
        XCTAssertFalse(DetailPlaybackSelection.showsPlayPlaceholder(
            for: movie, hasPlayTarget: true, childrenLoaded: false, seasonLoadState: nil
        ))
    }

    func testEpisodeMetadataEnrichmentKeepsTheContinueWatchingProgress() {
        let resume = MediaItem(
            id: "episode", title: "Episode", kind: .episode,
            runtime: 3_000, resumePosition: 867, playedPercentage: 0.289,
            sourceAccountID: "plex"
        )
        var loaded = resume
        loaded.resumePosition = nil
        loaded.playedPercentage = nil
        loaded.overview = "Full episode overview"
        let enriched = DetailPlaybackSelection.applyingResumeItem(resume, to: loaded)
        XCTAssertEqual(enriched.overview, "Full episode overview")
        XCTAssertEqual(enriched.resumePosition, 867)
        XCTAssertEqual(enriched.resumeProgressFraction, 0.289)
    }

    func testContinueWatchingLookupIsScopedToTheSelectedSourceAndTitle() {
        let show = MediaItem(id: "show", title: "Show", kind: .series, sourceAccountID: "plex")
        let episode = MediaItem(
            id: "episode", title: "Episode", kind: .episode,
            seriesID: show.id, sourceAccountID: "plex"
        )
        var otherAccount = episode
        otherAccount.sourceAccountID = "other"
        var otherSeries = episode
        otherSeries.seriesID = "other-show"
        var external = episode
        external.locallyValidatedPlayableSource = false
        XCTAssertNil(DetailPlaybackSelection.resumeItem(for: show, in: [otherAccount, otherSeries, external]))
        XCTAssertEqual(DetailPlaybackSelection.resumeItem(for: show, in: [episode])?.id, episode.id)
    }

    func testAnEpisodeIgnoresAStoredFileIDAndUsesTheRememberedKind() {
        // The bug this guards: picking a version on episode 3 stored that file's
        // id under the series key, so replaying episode 3 returned it while every
        // other episode matched the remembered shape — one show behaving two ways.
        var hevc = MediaVersion(id: "ep3-hevc", height: 1080)
        hevc.videoCodec = "hevc"
        var av1 = MediaVersion(id: "ep3-av1", height: 1080)
        av1.videoCodec = "av1"

        let store = VersionPreferenceStore(
            defaults: UserDefaults(suiteName: "plozz.tests.episode-id-\(UUID().uuidString)")!
        )
        // A stale explicit pick, plus the shape the viewer actually wants.
        store.setPreferredVersionID("ep3-hevc", forTitle: "series-1")
        store.setPreferredVersionDescriptor(
            MediaVersionDescriptor(version: av1),
            forTitle: "series-1"
        )

        var episode = MediaItem(id: "ep3", title: "Episode 3", kind: .episode)
        episode.seriesID = "series-1"

        XCTAssertEqual(
            DetailPlaybackSelection.preferredVersionID(
                for: episode,
                versions: [hevc, av1],
                versionOverride: nil,
                preferences: store,
                capabilities: .detected()
            ),
            "ep3-av1"
        )
    }

    func testAMovieStillHonoursItsExactFile() {
        // The id remains right where the key IS the item's own: same title, same
        // files, and the viewer picked that one.
        var small = MediaVersion(id: "movie-1080", height: 1080)
        small.videoCodec = "h264"
        var large = MediaVersion(id: "movie-2160", height: 2160)
        large.videoCodec = "hevc"

        let store = VersionPreferenceStore(
            defaults: UserDefaults(suiteName: "plozz.tests.movie-id-\(UUID().uuidString)")!
        )
        store.setPreferredVersionID("movie-1080", forTitle: "movie-1")

        let movie = MediaItem(id: "movie-1", title: "A Film", kind: .movie)

        XCTAssertEqual(
            DetailPlaybackSelection.preferredVersionID(
                for: movie,
                versions: [small, large],
                versionOverride: nil,
                preferences: store,
                capabilities: .detected()
            ),
            "movie-1080"
        )
    }
}
