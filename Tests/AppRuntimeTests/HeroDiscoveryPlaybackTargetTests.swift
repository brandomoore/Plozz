import CoreModels
import FeatureHomeCore
import Foundation
import XCTest
@testable import AppRuntime

final class HeroDiscoveryPlaybackTargetTests: XCTestCase {
    func testProductionResolutionRejectsContradictoryHydratedParentBeforeReadingChildren() async {
        let original = verifiedRoot(kind: .series)
        var wrongID = original
        wrongID.id = "wrong-parent"
        var wrongKind = original
        wrongKind.kind = .movie
        var conflict = original
        conflict.providerIDs["Tmdb"] = "99"
        var foreign = original
        foreign.sourceAccountID = "b"
        var unplayable = original
        unplayable.locallyValidatedPlayableSource = false
        let sparseEpisode = MediaItem(id: "wrong-episode", title: "Episode", kind: .episode)

        for response in [wrongID, wrongKind, conflict, foreign, unplayable] {
            let probe = PlaybackChildrenProbe()
            let account = accounts(
                kind: .jellyfin,
                children: [original.id: [sparseEpisode], "wrong-parent": [sparseEpisode]],
                hydration: response, probe: probe
            )[0]
            let result = await HeroDiscoveryPlaybackTarget.resolve(
                original: original, selected: original, provider: account.provider
            )
            XCTAssertNil(result)
            let requests = await probe.requests
            XCTAssertTrue(requests.isEmpty, "Rejected metadata must never become a children-request context.")
        }
    }

    func testProductionResolutionAllowsSparseVerifiedParentButRetainsOriginalParentIdentityChecks() async throws {
        let original = verifiedRoot(kind: .series)
        let sparseParent = MediaItem(id: original.id, title: "Series", kind: .series)
        for seriesID in ["42", "99"] {
            let probe = PlaybackChildrenProbe()
            let episode = MediaItem(
                id: "episode-a", title: "Episode", kind: .episode,
                providerIDs: ["SeriesTmdb": seriesID]
            )
            let account = accounts(
                kind: .plex, children: [original.id: [episode]],
                hydration: sparseParent, probe: probe
            )[0]
            let result = await HeroDiscoveryPlaybackTarget.resolve(
                original: original, selected: original, provider: account.provider
            )
            if seriesID == "42" {
                let target = try XCTUnwrap(result)
                XCTAssertEqual(target.id, episode.id)
                XCTAssertEqual(target.sourceAccountID, "a")
                XCTAssertEqual(target.discoverySources, original.discoverySources)
            } else {
                XCTAssertNil(result)
            }
            let requests = await probe.requests
            XCTAssertEqual(requests, [original.id])
        }
    }

    func testMovieProjectionPreservesProviderStateAndPreventsIndexRetargeting() throws {
        for kind in [ProviderKind.plex, .jellyfin] {
            var original = verifiedRoot(kind: .movie)
            original.discoverySources = [.tmdb, .tvmaze]
            original.discoveryURLs = [
                "tmdb": URL(string: "https://www.themoviedb.org/movie/42")!,
                "tvmaze": URL(string: "https://foreign.example/title")!,
                "unrecognized": URL(string: "https://www.themoviedb.org/movie/42")!
            ]
            let accounts = accounts(kind: kind)
            let hints = [MediaSourceRef(accountID: "b", itemID: "wrong-local-movie", kind: .movie)]
            let selected = PlaybackSourceSelection.bestPlayItem(
                original, accounts: accounts, identitySources: { _ in hints }
            )
            let version = MediaVersion(id: "file-a", container: "mkv")
            let raw = MediaItem(
                id: selected.id, title: "Provider movie", kind: .movie,
                resumePosition: 123, playedPercentage: 0.2, hasBeenPlayed: true,
                discoverySources: [.anilist], versions: [version], isFavorite: true,
                selectedVersionID: version.id, lastPlayedAt: Date(timeIntervalSince1970: 50)
            )
            let projected = try XCTUnwrap(HeroDiscoveryPlaybackTarget.project(
                resolved: raw, original: original, selected: selected
            ))
            let routed = route(projected, accounts: accounts, hints: hints)

            XCTAssertEqual(projected.discoverySources, [.tmdb, .tvmaze])
            XCTAssertEqual(projected.discoveryURLs, ["tmdb": original.discoveryURLs["tmdb"]!])
            XCTAssertEqual(projected.title, raw.title)
            XCTAssertEqual(projected.providerIDs, raw.providerIDs, "Sparse same-physical payloads need not repeat catalog IDs.")
            XCTAssertEqual(projected.resumePosition, raw.resumePosition)
            XCTAssertEqual(projected.playedPercentage, raw.playedPercentage)
            XCTAssertEqual(projected.hasBeenPlayed, raw.hasBeenPlayed)
            XCTAssertEqual(projected.lastPlayedAt, raw.lastPlayedAt)
            XCTAssertEqual(projected.isFavorite, raw.isFavorite)
            XCTAssertEqual(projected.versions, [version])
            XCTAssertEqual(projected.selectedVersionID, version.id)
            XCTAssertEqual(projected.sources.map(\.id), ["a:root-a"])
            XCTAssertEqual(projected.sources.first?.resumePosition, raw.resumePosition)
            XCTAssertEqual(routed.sourceAccountID, "a")
            XCTAssertEqual(routed.id, selected.id)
            XCTAssertTrue(routed.locallyValidatedPlayableSource)
        }
    }

    func testResolvedEpisodeKeepsChosenAccountWithoutInventingAlternateSeriesCopies() async throws {
        for kind in [ProviderKind.plex, .jellyfin] {
            for carriesParent in [false, true] {
                var original = verifiedRoot(kind: .series)
                original.sources.append(.init(accountID: "c", itemID: "series-c", kind: .series))
                let episode = MediaItem(
                    id: "episode-a", title: "Episode", kind: .episode,
                    seasonNumber: 1, episodeNumber: 3,
                    seriesID: carriesParent ? original.id : nil,
                    resumePosition: 150, providerIDs: ["Tmdb": "9001"]
                )
                let accounts = accounts(kind: kind, children: [original.id: [episode]])
                let selected = PlaybackSourceSelection.bestPlayItem(
                    original, accounts: accounts, identitySources: { _ in [] }
                )
                let resolved = await HeroPlayTargetResolver.playbackTarget(
                    for: selected, provider: accounts[0].provider
                )
                let projected = try XCTUnwrap(HeroDiscoveryPlaybackTarget.project(
                    resolved: try XCTUnwrap(resolved), original: original, selected: selected
                ))
                let hints = [
                    MediaSourceRef(accountID: "b", itemID: "wrong-local-episode", kind: .episode),
                    MediaSourceRef(accountID: "c", itemID: "series-c", kind: .series)
                ]
                let routed = route(projected, accounts: accounts, hints: hints)

                XCTAssertEqual(projected.discoverySources, original.discoverySources)
                XCTAssertEqual(projected.kind, .episode)
                XCTAssertEqual(projected.providerIDs, episode.providerIDs)
                XCTAssertEqual(projected.sources.map(\.id), ["a:episode-a"])
                XCTAssertEqual(projected.sources.first?.kind, .episode)
                XCTAssertTrue(projected.additionalSourceAccountIDs.isEmpty)
                XCTAssertEqual(projected.resumePosition, 150)
                XCTAssertEqual(routed.sourceAccountID, "a")
                XCTAssertEqual(routed.id, "episode-a")
                XCTAssertEqual(routed.kind, .episode)
            }
        }
    }

    func testForeignRefsAndBackingVersionsCannotEscapeActualResolvedTarget() throws {
        let original = verifiedRoot(kind: .series)
        let accounts = accounts(kind: .plex)
        let selected = PlaybackSourceSelection.bestPlayItem(original, accounts: accounts, identitySources: { _ in [] })
        let intrinsic = MediaVersion(id: "intrinsic", container: "mkv")
        let selfBacked = MediaVersion(id: "self", sourceItemID: "episode-a", sourceAccountID: "a")
        let foreign = MediaVersion(id: "foreign", sourceItemID: "episode-b", sourceAccountID: "b")
        let wrongPhysical = MediaVersion(id: "wrong-physical", sourceItemID: "another-a", sourceAccountID: "a")
        let foreignAccountOnly = MediaVersion(id: "foreign-account", sourceAccountID: "b")
        let raw = MediaItem(
            id: "episode-a", title: "Episode", kind: .episode,
            seriesID: selected.id, resumePosition: 123, playedPercentage: 0.2,
            sourceAccountID: "a", additionalSourceAccountIDs: ["b", "c"],
            versions: [intrinsic, selfBacked, foreign, wrongPhysical, foreignAccountOnly],
            selectedVersionID: foreign.id,
            sources: [
                .init(accountID: "b", itemID: "episode-b", kind: .episode, versions: [foreign], isPlayed: true),
                .init(accountID: "a", itemID: "another-a", kind: .episode, isPlayed: true)
            ],
            explicitSourceSelection: true
        )
        let projected = try XCTUnwrap(HeroDiscoveryPlaybackTarget.project(
            resolved: raw, original: original, selected: selected
        ))
        let hints = [MediaSourceRef(accountID: "b", itemID: "episode-b", kind: .episode)]
        let routed = route(projected, accounts: accounts, hints: hints)
        let staleVersionRoute = MediaItem.retargetedForPlayback(
            item: projected, sources: projected.sources, activeAccountID: "a", versionID: foreign.id
        )

        XCTAssertEqual(projected.sources.map(\.id), ["a:episode-a"])
        XCTAssertEqual(projected.versions, [intrinsic, selfBacked])
        XCTAssertEqual(projected.sources.first?.versions, [intrinsic, selfBacked])
        XCTAssertNil(projected.selectedVersionID)
        XCTAssertFalse(projected.explicitSourceSelection)
        XCTAssertTrue(projected.additionalSourceAccountIDs.isEmpty)
        XCTAssertFalse(projected.hasBeenPlayed)
        XCTAssertFalse(projected.isPlayed)
        XCTAssertEqual(projected.resumePosition, 123)
        XCTAssertEqual(routed.sourceAccountID, "a")
        XCTAssertEqual(routed.id, raw.id)
        XCTAssertEqual(staleVersionRoute.sourceAccountID, "a")
        XCTAssertEqual(staleVersionRoute.id, raw.id)
    }

    func testKnownEpisodeParentCatalogConflictCannotHideBehindSparsePhysicalParent() throws {
        let original = verifiedRoot(kind: .series)
        for parentID in [nil, original.id] as [String?] {
            var episode = MediaItem(
                id: "episode-a", title: "Episode", kind: .episode,
                seriesID: parentID, providerIDs: ["SeriesTmdb": "99", "Tmdb": "9001"]
            )
            XCTAssertNil(HeroDiscoveryPlaybackTarget.project(
                resolved: episode, original: original, selected: original
            ))
            episode.providerIDs["SeriesTmdb"] = "42"
            let projected = try XCTUnwrap(HeroDiscoveryPlaybackTarget.project(
                resolved: episode, original: original, selected: original
            ))
            XCTAssertEqual(projected.id, episode.id)
            XCTAssertNil(projected.seasonNumber)
            XCTAssertNil(projected.episodeNumber)
        }
    }

    func testMovieRejectsPositiveIdentityConflictsForeignAccountsAndUnusableTargets() {
        let original = verifiedRoot(kind: .movie)
        let valid = MediaItem(id: original.id, title: "Movie", kind: .movie)
        var wrongID = valid
        wrongID.id = "another-movie"
        var conflict = valid
        conflict.providerIDs = ["Tmdb": "42", "Imdb": "tt9999"]
        var foreignAccount = valid
        foreignAccount.sourceAccountID = "b"
        var foreignSelection = valid
        foreignSelection.selectedSourceAccountID = "b"
        var unplayable = valid
        unplayable.locallyValidatedPlayableSource = false
        var wrongKind = valid
        wrongKind.kind = .episode
        var emptyID = valid
        emptyID.id = " "
        var unaired = valid
        unaired.scheduledAirDate = Date(timeIntervalSince1970: 4_000_000_000)
        for target in [wrongID, conflict, foreignAccount, foreignSelection, unplayable, wrongKind, emptyID, unaired] {
            XCTAssertNil(HeroDiscoveryPlaybackTarget.project(resolved: target, original: original, selected: original))
        }
    }

    func testSeriesEpisodeRejectsWrongPhysicalParentOrContainerIdentity() {
        let original = verifiedRoot(kind: .series)
        let valid = MediaItem(id: "episode-a", title: "Episode", kind: .episode)
        var wrongParent = valid
        wrongParent.seriesID = "another-series"
        var containerID = valid
        containerID.id = original.id
        var wrongKind = valid
        wrongKind.kind = .movie
        for target in [wrongParent, containerID, wrongKind] {
            XCTAssertNil(HeroDiscoveryPlaybackTarget.project(resolved: target, original: original, selected: original))
        }
    }

    func testSameEpisodeRejectsConflictingPositionButAcceptsSparsePayload() {
        var original = verifiedRoot(kind: .episode)
        original.seasonNumber = 1
        original.episodeNumber = 2
        original.seriesID = "series-a"
        let sparse = MediaItem(id: original.id, title: "Episode", kind: .episode)
        XCTAssertNotNil(HeroDiscoveryPlaybackTarget.project(resolved: sparse, original: original, selected: original))
        var wrongSeason = sparse
        wrongSeason.seasonNumber = 3
        var wrongEpisode = sparse
        wrongEpisode.episodeNumber = 5
        var wrongParent = sparse
        wrongParent.seriesID = "another-series"
        var wrongCatalogIDWithoutPosition = sparse
        wrongCatalogIDWithoutPosition.providerIDs["Tmdb"] = "9999"
        for target in [wrongSeason, wrongEpisode, wrongParent, wrongCatalogIDWithoutPosition] {
            XCTAssertNil(HeroDiscoveryPlaybackTarget.project(resolved: target, original: original, selected: original))
        }
    }

    func testSeasonResolutionUsesPhysicalParentContextWithoutRequiringCatalogIDs() throws {
        var original = verifiedRoot(kind: .season)
        original.seriesID = "series-a"
        let episode = MediaItem(id: "episode-a", title: "Episode", kind: .episode, seriesID: "series-a")
        let projected = try XCTUnwrap(HeroDiscoveryPlaybackTarget.project(
            resolved: episode, original: original, selected: original
        ))
        XCTAssertEqual(projected.sources.map(\.id), ["a:episode-a"])
        var wrongSeason = episode
        wrongSeason.seasonID = "another-season"
        var wrongSeries = episode
        wrongSeries.seriesID = "another-series"
        for target in [wrongSeason, wrongSeries] {
            XCTAssertNil(HeroDiscoveryPlaybackTarget.project(resolved: target, original: original, selected: original))
        }
    }

    func testRevokedOrUnverifiedSelectedRootFailsClosed() {
        let original = verifiedRoot(kind: .series)
        let raw = MediaItem(id: "episode-a", title: "Episode", kind: .episode)
        var revoked = original
        revoked.locallyValidatedPlayableSource = false
        var noProof = original
        noProof.sources = []
        noProof.sourceAccountID = nil
        var foreign = original
        foreign.sourceAccountID = "b"
        var missingAccount = original
        missingAccount.sourceAccountID = nil
        var unknownCopy = original
        unknownCopy.id = "unverified-series"
        var conflicted = original
        conflicted.providerIDs["Tmdb"] = "9999"
        var wrongSelection = original
        wrongSelection.selectedSourceAccountID = "b"
        let cases = [
            (revoked, original), (original, revoked), (noProof, original),
            (original, foreign), (original, missingAccount), (original, unknownCopy),
            (original, conflicted), (original, wrongSelection)
        ]
        for (displayed, selected) in cases {
            XCTAssertNil(HeroDiscoveryPlaybackTarget.project(resolved: raw, original: displayed, selected: selected))
        }
    }

    func testOrdinaryUntaggedTargetsRemainExactlyUnchanged() {
        let original = MediaItem(id: "ordinary", title: "Ordinary", kind: .series)
        let raw = MediaItem(
            id: "target", title: "Target", kind: .episode,
            sourceAccountID: "b", sources: [.init(accountID: "c", itemID: "alternate")],
            selectedSourceAccountID: "c", explicitSourceSelection: true
        )
        XCTAssertEqual(
            HeroDiscoveryPlaybackTarget.project(
                resolved: raw, original: original, selected: original.removingDiscoveryOwnership()
            ),
            raw
        )
    }

    private func verifiedRoot(kind: MediaItemKind) -> MediaItem {
        MediaItem(
            id: "root-a", title: "Title", kind: kind,
            providerIDs: ["Tmdb": "42", "Imdb": "tt0042"], discoverySources: [.tmdb],
            sourceAccountID: "a", libraryID: "library-a",
            sources: [.init(accountID: "a", itemID: "root-a", libraryID: "library-a", kind: kind)]
        )
    }

    private func accounts(
        kind: ProviderKind, children: [String: [MediaItem]] = [:],
        hydration: MediaItem? = nil, probe: PlaybackChildrenProbe? = nil
    ) -> [ResolvedAccount] {
        [("a", kind, SourceLocality.remote), ("b", kind == .plex ? .jellyfin : .plex, .local), ("c", kind, .remote)]
            .map { id, providerKind, locality in
                let session = UserSession(
                    server: MediaServer(
                        id: "server-\(id)", name: id, baseURL: URL(string: "https://server.example")!,
                        provider: providerKind
                    ),
                    userID: id, userName: "Viewer", deviceID: "fixture", accessToken: "TEST-ONLY"
                )
                return ResolvedAccount(
                    account: Account(id: id, from: session),
                    provider: PlaybackProjectionProvider(
                        kind: providerKind, session: session, connectionLocality: locality,
                        childrenByID: id == "a" ? children : [:],
                        hydratedRoot: id == "a" ? hydration : nil,
                        probe: id == "a" ? probe : nil
                    )
                )
            }
    }

    private func route(_ target: MediaItem, accounts: [ResolvedAccount], hints: [MediaSourceRef]) -> MediaItem {
        PlaybackSourceSelection.bestPlayItem(target, accounts: accounts, identitySources: { _ in
            XCTFail("A projected discovery play target must not consult unrestricted index hints.")
            return hints
        })
    }
}

private actor PlaybackChildrenProbe {
    private(set) var requests: [String] = []
    func record(_ id: String) { requests.append(id) }
}

private struct PlaybackProjectionProvider: MediaProvider {
    let kind: ProviderKind
    let session: UserSession
    let connectionLocality: SourceLocality
    let childrenByID: [String: [MediaItem]]
    let hydratedRoot: MediaItem?
    let probe: PlaybackChildrenProbe?

    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem {
        guard id == "root-a", let hydratedRoot else { throw AppError.notFound }
        return hydratedRoot
    }
    func children(of itemID: String) async throws -> [MediaItem] {
        await probe?.record(itemID)
        return childrenByID[itemID] ?? []
    }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        throw AppError.notFound
    }

    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
