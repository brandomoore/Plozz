import Foundation
import XCTest
@testable import CoreModels

final class TrackerHistoryImportTests: XCTestCase {
    private func account(_ provider: ProviderKind = .jellyfin, id: String = "account", userID: String = "viewer") -> Account {
        Account(
            id: id, server: .init(id: "server", name: "Test server", baseURL: URL(string: "https://example.test")!, provider: provider),
            userID: userID, userName: "Test viewer", deviceID: "device"
        )
    }

    private func scope(_ provider: ProviderKind = .jellyfin, userID: String = "viewer") -> WatchMutationServerScope {
        .init(profile: .init(id: "profile", name: "Test"), accounts: [account(provider, userID: userID)])
    }

    private func observation(id: String = "watch1", fact: TrackerHistoryObservation.Fact = .watched(at: nil)) throws -> TrackerHistoryObservation {
        try .init(recordID: id, kind: .movie, identities: [.external(source: "tmdb", value: "550")], fact: fact)
    }

    private func item(played: Bool = false, position: TimeInterval? = nil) -> MediaItem {
        MediaItem(
            id: "server-item", title: "Movie", kind: .movie, runtime: 1_000, resumePosition: position,
            isPlayed: played, providerIDs: ["Tmdb": "550"], sourceAccountID: "account"
        )
    }

    private func plan(
        observations: [TrackerHistoryObservation], items: [MediaItem],
        provider: ProviderKind = .jellyfin, playing: Bool = false
    ) throws -> TrackerHistoryImportPlan {
        let snapshot = try TrackerHistorySnapshot(
            trackerID: "test-tracker", connectionID: "connection", observations: observations, expectedCount: observations.count
        )
        return .init(
            snapshot: snapshot, serverScope: scope(provider),
            candidates: items.map {
                .init(accountID: "account", item: $0, canWriteWatched: true, canWriteResume: true, isPlaying: playing)
            }
        )
    }

    func testSnapshotRejectsPartialReadsAndDuplicateIDs() throws {
        XCTAssertThrowsError(try TrackerHistorySnapshot(
            trackerID: "tracker", connectionID: "connection", observations: [observation()], expectedCount: 2
        ))
        XCTAssertThrowsError(try TrackerHistorySnapshot(
            trackerID: "tracker", connectionID: "connection", observations: [observation(), observation()], expectedCount: 2
        ))
    }

    func testAbsenceProducesNoUnwatchOrResumeClear() throws {
        let plan = try plan(observations: [], items: [item(played: true, position: 300)])
        XCTAssertTrue(plan.rows.isEmpty)
        XCTAssertThrowsError(try plan.approve(rowIDs: []))
    }

    func testListStatesNeverAuthorizeWatchResumeOrDestructiveServerChanges() throws {
        for state in TrackerHistoryListState.allCases {
            let evidence = try observation(fact: .listState(state))
            let exportState = try TrackerHistoryExportState(observations: [evidence])
            XCTAssertFalse(exportState.isWatched)
            XCTAssertFalse(exportState.containsWatch(at: nil))
            XCTAssertTrue(TrackerHistorySyncCategory.allCases.allSatisfy { !$0.includes(evidence.fact) })
            for provider in [ProviderKind.jellyfin, .plex] {
                let result = try plan(observations: [evidence], items: [item()], provider: provider)
                XCTAssertEqual(result.rows.first?.comparison, .unsupported)
                XCTAssertNil(result.rows.first?.change)
                let ids = Set(result.rows.map(\.id))
                XCTAssertThrowsError(try result.approve(
                    rowIDs: ids, overridingConflicts: ids, confirmsDestructiveChanges: true
                ))
            }
        }
    }

    func testCompletedAnimeMovieRequiresExactIdentityAndExplicitServerApproval() throws {
        let progress = try TrackerAnimeListProgress(
            status: .completed, episodesWatched: 1, repeats: 4, score: 8.5, updatedAt: Date()
        )
        let observation = try TrackerHistoryObservation(
            recordID: "anime", kind: .movie, identities: [.external(source: "anilist", value: "100")],
            fact: .animeList(progress)
        )
        var movie = item()
        movie.providerIDs = ["AniList": "100"]
        for provider in [ProviderKind.jellyfin, .plex] {
            let plan = try plan(observations: [observation], items: [movie], provider: provider)
            XCTAssertEqual(plan.rows.first?.comparison, .ready)
            XCTAssertEqual(plan.rows.first?.change, .watched(true))
            XCTAssertThrowsError(try plan.approve(rowIDs: []))
            XCTAssertNoThrow(try plan.approve(rowIDs: Set(plan.rows.map(\.id))))
        }
        movie.resumePosition = 50
        let conflict = try plan(observations: [observation], items: [movie])
        XCTAssertEqual(conflict.rows.first?.comparison, .serverConflict)
        XCTAssertThrowsError(try conflict.approve(rowIDs: Set(conflict.rows.map(\.id))))
        movie.isPlayed = true
        XCTAssertEqual(try plan(observations: [observation], items: [movie]).rows.first?.comparison, .alreadyMatches)
        movie.providerIDs = ["AniList": "99"]
        XCTAssertEqual(try plan(observations: [observation], items: [movie]).rows.first?.comparison, .unmatched)
    }

    func testAnimeSeriesAndNonCompletedMoviesNeverGenerateServerMutations() throws {
        let states: [TrackerAnimeListProgress.Status?] = [nil, .planning, .watching, .paused, .dropped, .rewatching, .completed]
        for kind in [MediaItemKind.movie, .series] {
            for status in states where kind == .series || status != .completed {
                let observation = try TrackerHistoryObservation(
                    recordID: "anime", kind: kind, identities: [.external(source: "myanimelist", value: "200")],
                    fact: .animeList(try .init(
                        status: status, episodesWatched: 25, repeats: 2, score: 9, updatedAt: Date()
                    ))
                )
                let server = MediaItem(id: "anime", title: "Fixture", kind: kind, providerIDs: ["Mal": "200"])
                let plan = try plan(observations: [observation], items: [server])
                XCTAssertEqual(plan.rows.first?.comparison, .unsupported)
                XCTAssertNil(plan.rows.first?.change)
                XCTAssertThrowsError(try plan.approve(rowIDs: Set(plan.rows.map(\.id))))
            }
        }
    }

    func testAnimeEvidenceRejectsInvalidValuesAndCannotDescribeIndividualEpisodes() throws {
        for (watched, repeats, score, date) in [
            (-1, 0, 1.0, Date()), (0, -1, 1, Date()), (0, 0, -.infinity, Date()),
            (0, 0, Double.nan, Date()), (0, 0, 10.1, Date()),
            (0, 0, 1, Date(timeIntervalSince1970: .infinity))
        ] {
            XCTAssertThrowsError(try TrackerAnimeListProgress(
                status: .completed, episodesWatched: watched, repeats: repeats, score: score, updatedAt: date
            ))
        }
        XCTAssertThrowsError(try TrackerHistoryObservation(
            recordID: "episode", kind: .episode, identities: [.external(source: "anilist:s1e1", value: "100")],
            season: 1, episode: 1, fact: .animeList(try .init(
                status: .completed, episodesWatched: 1, repeats: nil, score: nil, updatedAt: nil
            ))
        ))
        XCTAssertThrowsError(try TrackerHistorySnapshot(
            trackerID: "anime", connectionID: "connection", observations: [observation(), observation()],
            completeness: .exhaustedPagination
        ))
    }

    func testCompleteResponseEvidenceStillRejectsDuplicatesAndMissingScope() throws {
        let snapshot = try TrackerHistorySnapshot(
            trackerID: "tracker", connectionID: "connection", observations: [observation()],
            completeness: .completeResponse
        )
        XCTAssertEqual(snapshot.observations.count, 1)
        for (tracker, connection, observations) in [
            ("tracker", "connection", try [observation(), observation()]),
            ("", "connection", []), ("tracker", "", [])
        ] {
            XCTAssertThrowsError(try TrackerHistorySnapshot(
                trackerID: tracker, connectionID: connection, observations: observations,
                completeness: .completeResponse
            ))
        }
        XCTAssertThrowsError(try TrackerHistorySnapshot(
            trackerID: "tracker", connectionID: "connection", observations: [], completeness: .apiCount(-1)
        ))
    }

    func testServerWatchedStateWinsWithoutAnotherWriteForBothProviders() throws {
        for provider in [ProviderKind.jellyfin, .plex] {
            let plan = try plan(observations: [observation()], items: [item(played: true)], provider: provider)
            XCTAssertEqual(plan.rows.first?.comparison, .alreadyMatches)
            XCTAssertThrowsError(try plan.approve(rowIDs: Set(plan.rows.map(\.id))))
        }
    }

    func testRewatchesProduceOneFlagChangeRatherThanMultipleServerPlays() throws {
        let plan = try plan(
            observations: [observation(id: "watch1"), observation(id: "watch2")], items: [item()]
        )
        XCTAssertEqual(plan.rows.count, 1)
        XCTAssertEqual(plan.rows[0].recordIDs, ["watch1", "watch2"])
        XCTAssertEqual(plan.rows[0].comparison, .ready)
    }

    func testInProgressServerNeedsExplicitConflictSelection() throws {
        let plan = try plan(observations: [observation()], items: [item(position: 100)])
        let ids = Set(plan.rows.map(\.id))
        XCTAssertEqual(plan.rows.first?.comparison, .serverConflict)
        XCTAssertThrowsError(try plan.approve(rowIDs: ids))
        XCTAssertNoThrow(try plan.approve(rowIDs: ids, overridingConflicts: ids))
    }

    func testPriorServerPlayIsNotOverriddenByOlderTrackerHistory() throws {
        var serverItem = item()
        serverItem.lastPlayedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let plan = try plan(observations: [observation()], items: [serverItem])
        XCTAssertEqual(plan.rows.first?.comparison, .serverConflict)
        XCTAssertThrowsError(try plan.approve(rowIDs: Set(plan.rows.map(\.id))))
    }

    func testExplicitUnwatchRequiresSeparateDestructiveConsent() throws {
        let plan = try plan(observations: [observation(fact: .explicitlyUnwatched)], items: [item(played: true)])
        let ids = Set(plan.rows.map(\.id))
        XCTAssertThrowsError(try plan.approve(rowIDs: ids, overridingConflicts: ids))
        XCTAssertNoThrow(try plan.approve(rowIDs: ids, overridingConflicts: ids, confirmsDestructiveChanges: true))
    }

    func testOpposingTrackerFactsCannotBothBeSelected() throws {
        let plan = try plan(
            observations: [
                observation(id: "watch", fact: .watched(at: nil)),
                observation(id: "resume", fact: .resume(seconds: 200, runtime: 1_000, updatedAt: nil))
            ], items: [item()]
        )
        let ids = Set(plan.rows.map(\.id))
        XCTAssertTrue(plan.rows.allSatisfy { $0.comparison == .trackerConflict })
        XCTAssertThrowsError(try plan.approve(rowIDs: ids, overridingConflicts: ids))
        let selected = Set([try XCTUnwrap(plan.rows.first).id])
        XCTAssertNoThrow(try plan.approve(rowIDs: selected, overridingConflicts: selected))
    }

    func testDifferentEditionsAndActivePlaybackCannotBeImported() throws {
        let resume = try observation(fact: .resume(seconds: 200, runtime: 1_100, updatedAt: nil))
        XCTAssertEqual(try plan(observations: [resume], items: [item()]).rows.first?.comparison, .incompatibleRuntime)
        XCTAssertEqual(try plan(observations: [observation()], items: [item()], playing: true).rows.first?.comparison, .playing)
    }

    func testAmbiguousMoviesAndOtherAccountsAreNotSelected() throws {
        var second = item()
        second.id = "second-copy"
        XCTAssertEqual(try plan(observations: [observation()], items: [item(), second]).rows.first?.comparison, .ambiguous)
        second = item()
        second.sourceAccountID = "other-account"
        XCTAssertEqual(try plan(observations: [observation()], items: [second]).rows.first?.comparison, .unmatched)
    }

    func testEpisodeIdentityRequiresConfirmedOrderAndSingleEpisodeFile() throws {
        let observation = try TrackerHistoryObservation(
            recordID: "episode", kind: .episode,
            identities: [.external(source: "series-tmdb:s0e1", value: "1")],
            season: 0, episode: 1, episodeOrdering: .tmdb, fact: .watched(at: nil)
        )
        var episode = MediaItem(
            id: "episode", title: "Special", kind: .episode, seasonNumber: 0, episodeNumber: 1,
            episodeOrdering: .tmdb, providerIDs: ["SeriesTmdb": "1"]
        )
        XCTAssertTrue(observation.matches(episode))
        episode.episodeOrdering = .dvd
        XCTAssertFalse(observation.matches(episode))
        episode.episodeOrdering = nil
        XCTAssertFalse(observation.matches(episode))
        episode.episodeOrdering = .tmdb
        episode.episodeNumberEnd = 2
        XCTAssertFalse(observation.matches(episode))
    }

    func testExactEpisodeEvidenceDoesNotAcceptParentOnlyConflictingOrCombinedEpisodes() throws {
        let observed = try TrackerHistoryObservation(
            recordID: "episode", kind: .episode,
            identities: [.external(source: "tmdb:s1e2", value: "200"), .external(source: "series-tmdb:s1e2", value: "100")],
            season: 1, episode: 2, requiresExactEpisodeIdentity: true, fact: .watched(at: nil)
        )
        let episode = MediaItem(
            id: "episode", title: "Episode", kind: .episode, seasonNumber: 1, episodeNumber: 2,
            providerIDs: ["Tmdb": "200", "SeriesTmdb": "100"]
        )
        XCTAssertTrue(observed.matches(episode))
        for provider in [ProviderKind.plex, .jellyfin] {
            XCTAssertEqual(try plan(observations: [observed], items: [episode], provider: provider).rows.first?.comparison, .ready)
        }
        for ids in [["SeriesTmdb": "100"], ["Tmdb": "200"], ["Tmdb": "100", "SeriesTmdb": "100"],
                    ["Tmdb": "201", "SeriesTmdb": "100"], ["Tmdb": "200", "SeriesTmdb": "101"]] {
            var changed = episode
            changed.providerIDs = ids
            XCTAssertFalse(observed.matches(changed))
        }
        var changed = episode
        changed.episodeNumberEnd = 3
        XCTAssertFalse(observed.matches(changed))
        changed = episode
        changed.episodeNumber = 3
        XCTAssertFalse(observed.matches(changed))
    }

    func testPercentOnlyProgressCannotBecomeASelectedServerMutation() throws {
        for percent in [0.0, 25, 100] {
            let observation = try observation(fact: .resumePercentage(percent: percent, updatedAt: nil))
            let plan = try plan(observations: [observation], items: [item(position: 50)])
            XCTAssertEqual(plan.rows.first?.comparison, .incompatibleRuntime)
            XCTAssertNil(plan.rows.first?.change)
            XCTAssertThrowsError(try plan.approve(rowIDs: Set(plan.rows.map(\.id))))
        }

        for percent in [-1.0, 101, .infinity, .nan] {
            XCTAssertThrowsError(try observation(fact: .resumePercentage(percent: percent, updatedAt: nil)))
        }
    }

    func testPausedPercentageUsesEachShareFileDurationButNeverTargetsManagedServers() throws {
        let pause = try observation(fact: .pausedPercentage(percent: 40, updatedAt: Date()))
        for runtime in [750.0, 1_000] {
            var copy = item()
            copy.runtime = runtime
            let row = try XCTUnwrap(plan(observations: [pause], items: [copy], provider: .mediaShare).rows.first)
            XCTAssertEqual(row.comparison, .ready)
            XCTAssertEqual(row.change, .resume(runtime * 0.4))
            for provider in [ProviderKind.plex, .jellyfin] {
                XCTAssertNil(try plan(observations: [pause], items: [copy], provider: provider).rows.first?.change)
            }
            copy.runtime = nil
            XCTAssertNil(try plan(observations: [pause], items: [copy], provider: .mediaShare).rows.first?.change)
        }
    }

    @MainActor
    func testVerifiedEpisodeMatchingDoesNotTurnOldTrackerEvidenceIntoNewActivity() throws {
        let parent = MediaIdentity.external(source: "series-tmdb:s1e2", value: "100")
        let ids = [parent, .external(source: "tmdb:s1e2", value: "200")]
        let original = try TrackerHistoryObservation(
            recordID: "episode", kind: .episode, identities: [parent],
            season: 1, episode: 2, episodeOrdering: .tmdb, fact: .watched(at: nil)
        )
        let verified = try TrackerHistoryObservation(
            recordID: original.recordID, kind: original.kind, identities: original.identities,
            season: 1, episode: 2, episodeOrdering: .tmdb, verifiedEpisodeIdentities: ids,
            fact: original.fact
        )
        var episode = MediaItem(
            id: "episode", title: "Episode", kind: .episode, seasonNumber: 1, episodeNumber: 2,
            providerIDs: ["Tmdb": "200", "SeriesTmdb": "100"]
        )
        XCTAssertFalse(original.matches(episode))
        XCTAssertTrue(verified.matches(episode))
        XCTAssertEqual(
            try TrackerHistorySyncController.fingerprint(original),
            try TrackerHistorySyncController.fingerprint(verified)
        )
        XCTAssertNotEqual(original, verified, "A reviewed preview must notice changed matching evidence")
        XCTAssertEqual(try plan(observations: [verified], items: [episode]).rows.first?.comparison, .ready)
        episode.providerIDs["Tmdb"] = "201"
        episode.episodeOrdering = .tmdb
        XCTAssertFalse(verified.matches(episode), "Known order cannot override conflicting verified identity")
        XCTAssertThrowsError(try TrackerHistoryObservation(
            recordID: original.recordID, kind: original.kind, identities: original.identities,
            season: 1, episode: 2, verifiedEpisodeIdentities: [.external(source: "tmdb:s1e2", value: "200")],
            fact: original.fact
        ))
    }

    func testApprovedMutationsHaveExactScopeNoExpansionAndNoTrackerMirrors() throws {
        let plan = try plan(observations: [observation()], items: [item()])
        let approval = try plan.approve(rowIDs: Set(plan.rows.map(\.id)))
        let owner = ImportOwner()
        let current = item()
        let mutations = try approval.mutations(
            currentScope: scope(), currentTrackerID: "test-tracker", currentConnectionID: "connection", owner: owner,
            validate: { _, _, _, _, _ in true }, loadCurrentItem: { _, _, _ in current }
        )
        let mutation = try XCTUnwrap(mutations.first)
        XCTAssertEqual(mutation.targets.map(\.accountID), ["account"])
        XCTAssertEqual(mutation.targets.map(\.itemID), ["server-item"])
        XCTAssertEqual(mutation.serverScope, scope())
        XCTAssertNotNil(mutation.authorization)
        XCTAssertFalse(mutation.expansionPending)
        XCTAssertFalse(mutation.clearResume)
        XCTAssertNil(mutation.episodeOrigin)
        XCTAssertNil(mutation.trakt)
        XCTAssertNil(mutation.traktProgress)
        XCTAssertFalse(mutation.traktPending)
        XCTAssertFalse(mutation.simklPending)
        XCTAssertFalse(mutation.wetrakrPending)
        XCTAssertFalse(mutation.anilistPending)
        XCTAssertFalse(mutation.malPending)
        XCTAssertThrowsError(try approval.mutations(
            currentScope: scope(userID: "different-viewer"), currentTrackerID: "test-tracker",
            currentConnectionID: "connection", owner: owner,
            validate: { _, _, _, _, _ in true }, loadCurrentItem: { _, _, _ in current }
        ))
        XCTAssertThrowsError(try approval.mutations(
            currentScope: scope(), currentTrackerID: "other-tracker", currentConnectionID: "connection", owner: owner,
            validate: { _, _, _, _, _ in true }, loadCurrentItem: { _, _, _ in current }
        ))
    }

    func testBaselineChangeAndRelaunchCannotRestoreImportPermission() async throws {
        let plan = try plan(observations: [observation()], items: [item()])
        let approval = try plan.approve(rowIDs: Set(plan.rows.map(\.id)))
        let owner = ImportOwner()
        let changed = item(position: 500)
        let mutation = try XCTUnwrap(approval.mutations(
            currentScope: scope(), currentTrackerID: "test-tracker", currentConnectionID: "connection", owner: owner,
            validate: { _, _, _, _, _ in true }, loadCurrentItem: { _, _, _ in changed }
        ).first)
        do {
            try await mutation.authorization?.requireSourcePrecondition(
                provider: ImportProvider(), target: try XCTUnwrap(mutation.targets.first)
            )
            XCTFail("Stale preview authorized a write")
        } catch { XCTAssertEqual(error as? TrackerHistoryError, .stalePreview) }
        let restored = try JSONDecoder().decode(WatchMutation.self, from: JSONEncoder().encode(mutation))
        do { try await restored.authorization?.require(); XCTFail("Decoded approval became a runtime grant") }
        catch { XCTAssertEqual(error as? WatchMutationAuthorizationError, .capabilityUnavailable) }
    }

    @MainActor
    private func session(
        provider: ImportProvider, isAuthorized: @escaping @MainActor @Sendable () -> Bool = { true },
        readSnapshot: (@MainActor @Sendable () async throws -> TrackerHistorySnapshot)? = nil
    ) throws -> (TrackerHistoryImportSession, WatchStateReconciler) {
        let snapshot = try TrackerHistorySnapshot(
            trackerID: "test-tracker", connectionID: "connection", observations: [observation()], expectedCount: 1
        )
        let index = IdentityIndexSnapshot(byIdentity: [
            .external(source: "tmdb", value: "550"): [
                .init(accountID: "account", itemID: "server-item", providerKind: provider.kind, kind: .movie)
            ]
        ])
        let reconciler = WatchStateReconciler(
            store: InMemoryWatchMutationStore(), applier: ImportApplier(provider: provider)
        )
        return (
            TrackerHistoryImportSession(
                scope: scope(provider.kind), destinations: [], reconciler: reconciler,
                readSnapshot: readSnapshot ?? { snapshot }, index: { index }, resolveProvider: { _ in provider },
                isAuthorized: isAuthorized
            ),
            reconciler
        )
    }

    @MainActor
    func testComparisonDoesNotWriteAndApprovedImportIsReadBack() async throws {
        let provider = ImportProvider(item: item())
        let (session, _) = try session(provider: provider)
        await session.compare()
        let row = try XCTUnwrap(session.plan?.rows.first)
        XCTAssertEqual(row.comparison, .ready)
        let before = await provider.writes
        XCTAssertEqual(before, 0)
        await session.apply(rowIDs: [row.id], overridingConflicts: [], confirmsDestructiveChanges: false)
        XCTAssertNil(session.error)
        XCTAssertEqual(session.outcomes[row.id], .confirmed)
        let after = await provider.writes
        XCTAssertEqual(after, 1)
        await session.compare()
        XCTAssertEqual(session.plan?.rows.first?.comparison, .alreadyMatches)
    }

    @MainActor
    private func episodeSession(
        accountIDs: [String] = ["account"],
        isAuthorized: @escaping @MainActor @Sendable () -> Bool = { true }
    ) throws -> (TrackerHistoryImportSession, [String: ImportProvider]) {
        let observations = try (1...2).map { number in
            let parent = MediaIdentity.external(source: "series-tmdb:s1e\(number)", value: "100")
            return try TrackerHistoryObservation(
                recordID: "episode-\(number)", kind: .episode, identities: [parent],
                season: 1, episode: number, episodeOrdering: .tmdb,
                verifiedEpisodeIdentities: [parent, .external(source: "tmdb:s1e\(number)", value: "\(200 + number)")],
                fact: .watched(at: nil)
            )
        }
        let snapshot = try snapshot(observations)
        let providers = Dictionary(uniqueKeysWithValues: accountIDs.map { accountID in
            let episodes = (1...2).map { number in
                MediaItem(
                    id: "episode-\(number)", title: "Episode \(number)", kind: .episode,
                    seasonNumber: 1, episodeNumber: number, seriesID: "series",
                    providerIDs: ["Tmdb": "\(200 + number)"], sourceAccountID: accountID
                )
            }
            let series = MediaItem(
                id: "series", title: "Series", kind: .series,
                episodeOrdering: .tmdb, providerIDs: ["Tmdb": "100"], sourceAccountID: accountID
            )
            return (accountID, ImportProvider(item: episodes[0], relatedItems: [episodes[1], series]))
        })
        let index = IdentityIndexSnapshot(byIdentity: [
            .external(source: "tmdb", value: "100"): accountIDs.map {
                .init(accountID: $0, itemID: "series", providerKind: .jellyfin, kind: .series)
            }
        ])
        let provider = try XCTUnwrap(providers[accountIDs[0]])
        let reconciler = WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: ImportApplier(provider: provider))
        let session = TrackerHistoryImportSession(
            scope: .init(profile: .init(id: "profile", name: "Test"), accounts: accountIDs.map { account(id: $0) }),
            destinations: [], reconciler: reconciler, readSnapshot: { snapshot }, index: { index },
            resolveProvider: { accountID in
                guard let provider = providers[accountID] else { throw TrackerHistoryError.scopeChanged }
                return provider
            },
            isAuthorized: isAuthorized
        )
        return (session, providers)
    }

    @MainActor
    func testEpisodeComparisonReadsEachParentOncePerAccountAndComparison() async throws {
        let (session, providers) = try episodeSession(accountIDs: ["account", "another"])
        for comparison in 1...2 {
            await session.compare()
            XCTAssertNil(session.error)
            let rows = try XCTUnwrap(session.plan?.rows)
            XCTAssertEqual(rows.count, 4)
            XCTAssertTrue(rows.allSatisfy { $0.comparison == .ready })
            for provider in providers.values {
                let reads = await provider.itemReads
                XCTAssertEqual(reads["series"], comparison)
                XCTAssertEqual(reads["episode-1"], comparison)
                XCTAssertEqual(reads["episode-2"], comparison)
                let writes = await provider.writes
                XCTAssertEqual(writes, 0)
            }
        }
    }

    @MainActor
    func testEpisodeComparisonParentCannotAuthorizeAChangedParentAtDispatch() async throws {
        let (session, providers) = try episodeSession()
        let provider = try XCTUnwrap(providers["account"])
        await session.compare()
        let row = try XCTUnwrap(session.plan?.rows.first { $0.target?.itemID == "episode-1" })
        XCTAssertEqual(row.comparison, .ready)
        await provider.replace(item: .init(
            id: "series", title: "Different series", kind: .series,
            episodeOrdering: .tmdb, providerIDs: ["Tmdb": "999"], sourceAccountID: "account"
        ))
        await session.apply(rowIDs: [row.id], overridingConflicts: [], confirmsDestructiveChanges: false)
        XCTAssertEqual(session.outcomes[row.id], .unconfirmed)
        let writes = await provider.writes
        XCTAssertEqual(writes, 0)
        let reads = await provider.itemReads
        XCTAssertGreaterThan(try XCTUnwrap(reads["series"]), 1)
    }

    @MainActor
    func testEpisodeComparisonChecksPermissionAfterAParentRead() async throws {
        let permission = ImportPermission()
        let (session, providers) = try episodeSession(isAuthorized: { permission.allowed })
        let provider = try XCTUnwrap(providers["account"])
        await provider.onNextRead {
            await provider.onNextRead { await MainActor.run { permission.allowed = false } }
        }
        await session.compare()
        XCTAssertNil(session.plan)
        XCTAssertEqual(session.error as? TrackerHistoryError, .scopeChanged)
        let writes = await provider.writes
        XCTAssertEqual(writes, 0)
        let reads = await provider.itemReads
        XCTAssertEqual(reads["series"], 1)
        XCTAssertNil(reads["episode-2"])
    }

    @MainActor
    func testLostReplyUsesReadbackWithoutRepeatingTheWrite() async throws {
        let provider = ImportProvider(item: item(), losesWriteReply: true)
        let (session, reconciler) = try session(provider: provider)
        await session.compare()
        let row = try XCTUnwrap(session.plan?.rows.first)
        await session.apply(rowIDs: [row.id], overridingConflicts: [], confirmsDestructiveChanges: false)
        XCTAssertEqual(session.outcomes[row.id], .confirmed)
        await reconciler.drain()
        let writes = await provider.writes
        XCTAssertEqual(writes, 1)
    }

    @MainActor
    func testFailedReadbackDoesNotLeaveARevokedImportQueued() async throws {
        let provider = ImportProvider(item: item(), failsReadback: true)
        let (session, reconciler) = try session(provider: provider)
        await session.compare()
        let row = try XCTUnwrap(session.plan?.rows.first)
        await session.apply(rowIDs: [row.id], overridingConflicts: [], confirmsDestructiveChanges: false)
        XCTAssertEqual(session.error as? AppError, .serverUnreachable)
        XCTAssertEqual(session.outcomes[row.id], .unconfirmed)
        await reconciler.drain()
        let writes = await provider.writes
        XCTAssertEqual(writes, 1)
    }

    @MainActor
    func testChangedBaselineAndCancelledComparisonNeverWrite() async throws {
        let provider = ImportProvider(item: item())
        let (session, _) = try session(provider: provider)
        await session.compare()
        let row = try XCTUnwrap(session.plan?.rows.first)
        await provider.replace(item: item(position: 50))
        await session.apply(rowIDs: [row.id], overridingConflicts: [], confirmsDestructiveChanges: false)
        XCTAssertEqual(session.outcomes[row.id], .unconfirmed)
        let changedBaselineWrites = await provider.writes
        XCTAssertEqual(changedBaselineWrites, 0)
        await session.compare()
        session.cancel()
        await session.apply(rowIDs: [row.id], overridingConflicts: [], confirmsDestructiveChanges: false)
        XCTAssertEqual(session.error as? TrackerHistoryError, .scopeChanged)
        let cancelledWrites = await provider.writes
        XCTAssertEqual(cancelledWrites, 0)
    }

    @MainActor
    func testPermissionRevokedDuringFreshReadCannotReachWriter() async throws {
        let permission = ImportPermission()
        let provider = ImportProvider(item: item())
        let (session, _) = try session(provider: provider, isAuthorized: { permission.allowed })
        await session.compare()
        let row = try XCTUnwrap(session.plan?.rows.first)
        await provider.onNextRead { await MainActor.run { permission.allowed = false } }
        await session.apply(rowIDs: [row.id], overridingConflicts: [], confirmsDestructiveChanges: false)
        let writes = await provider.writes
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(session.error as? TrackerHistoryError, .scopeChanged)
    }

    @MainActor
    func testChangedTrackerEvidencePreventsQueueingSelectedImports() async throws {
        let original = try observation()
        for kind in 0..<6 {
            let evidence = ImportEvidence(try .init(
                trackerID: "test-tracker", connectionID: "connection", observations: [original], expectedCount: 1
            ))
            let provider = ImportProvider(item: item())
            let (session, reconciler) = try session(provider: provider, readSnapshot: { evidence.snapshot })
            await session.compare()
            let row = try XCTUnwrap(session.plan?.rows.first)
            var changed = [original]
            switch kind {
            case 0: changed = []
            case 1:
                changed = [try .init(
                    recordID: original.recordID, kind: .movie, identities: original.identities,
                    fact: .watched(at: Date(timeIntervalSince1970: 100))
                )]
            case 2:
                changed += [try .init(
                    recordID: "new-resume", kind: .movie, identities: original.identities,
                    fact: .resume(seconds: 200, runtime: 1_000, updatedAt: nil)
                )]
            case 3:
                changed = [try .init(
                    recordID: original.recordID, kind: .movie,
                    identities: [.external(source: "tmdb", value: "999")], fact: original.fact
                )]
            case 4: break
            default:
                changed += [try .init(
                    recordID: "unrelated", kind: .movie,
                    identities: [.external(source: "tmdb", value: "999")], fact: .watched(at: nil)
                )]
            }
            evidence.snapshot = try .init(
                trackerID: "test-tracker", connectionID: kind == 4 ? "replacement" : "connection",
                observations: changed, expectedCount: changed.count
            )
            await session.apply(rowIDs: [row.id], overridingConflicts: [], confirmsDestructiveChanges: false)
            let writes = await provider.writes
            if kind == 5 {
                XCTAssertNil(session.error)
                XCTAssertEqual(writes, 1, "An unrelated title must not invalidate the selected evidence")
            } else {
                XCTAssertEqual(session.error as? TrackerHistoryError, kind == 4 ? .scopeChanged : .stalePreview)
                XCTAssertEqual(writes, 0)
                XCTAssertTrue(session.outcomes.isEmpty)
                let pending = await reconciler.snapshot().pending
                XCTAssertTrue(pending.isEmpty)
            }
        }
    }

    @MainActor
    func testFailedTrackerRecheckNeverQueuesAnImport() async throws {
        let original = try TrackerHistorySnapshot(
            trackerID: "test-tracker", connectionID: "connection", observations: [observation()], expectedCount: 1
        )
        let evidence = ImportEvidence(original)
        let provider = ImportProvider(item: item())
        let (session, _) = try session(provider: provider, readSnapshot: {
            if evidence.failRead { throw AppError.serverUnreachable }
            return evidence.snapshot
        })
        await session.compare()
        let row = try XCTUnwrap(session.plan?.rows.first)
        evidence.failRead = true
        await session.apply(rowIDs: [row.id], overridingConflicts: [], confirmsDestructiveChanges: false)
        XCTAssertEqual(session.error as? AppError, .serverUnreachable)
        let writes = await provider.writes
        XCTAssertEqual(writes, 0)
    }

    @MainActor
    func testTrackerRecheckIncludesAliasesOfEveryCoalescedPlay() async throws {
        let alias: [MediaIdentity] = [.external(source: "imdb", value: "tt0137523")]
        let second = try TrackerHistoryObservation(recordID: "alias-play", kind: .movie, identities: alias, fact: .watched(at: nil))
        let observations = try [observation(), second]
        let evidence = ImportEvidence(try .init(
            trackerID: "test-tracker", connectionID: "connection", observations: observations, expectedCount: 2
        ))
        var item = item()
        item.providerIDs["Imdb"] = "tt0137523"
        let provider = ImportProvider(item: item)
        let (session, _) = try session(provider: provider, readSnapshot: { evidence.snapshot })
        await session.compare()
        let row = try XCTUnwrap(session.plan?.rows.first)
        XCTAssertEqual(row.recordIDs.count, 2)
        let resume = try TrackerHistoryObservation(
            recordID: "new-resume", kind: .movie, identities: alias,
            fact: .resume(seconds: 200, runtime: 1_000, updatedAt: nil)
        )
        evidence.snapshot = try .init(
            trackerID: "test-tracker", connectionID: "connection", observations: observations + [resume], expectedCount: 3
        )
        await session.apply(rowIDs: [row.id], overridingConflicts: [], confirmsDestructiveChanges: false)
        XCTAssertEqual(session.error as? TrackerHistoryError, .stalePreview)
        let writes = await provider.writes
        XCTAssertEqual(writes, 0)
    }

    @MainActor
    private func syncController(
        provider: ImportProvider, evidence: ImportEvidence, store: DurableLocalStateStore,
        permission: ImportPermission? = nil, connection: String = "connection",
        serverScope: WatchMutationServerScope? = nil, reconciler existingReconciler: WatchStateReconciler? = nil,
        supportedCategories: Set<TrackerHistorySyncCategory> = [.watched, .resume],
        allowsForegroundChecks: Bool = true, indexSnapshot: IdentityIndexSnapshot? = nil,
        otherProviders: [String: ImportProvider] = [:]
    ) -> TrackerHistorySyncController {
        let scope = serverScope ?? self.scope(provider.kind)
        let permission = permission ?? ImportPermission()
        let index = indexSnapshot ?? IdentityIndexSnapshot(byIdentity: [
            .external(source: "tmdb", value: "550"): [
                .init(accountID: "account", itemID: "server-item", providerKind: provider.kind, kind: .movie)
            ]
        ])
        let reconciler = existingReconciler ?? WatchStateReconciler(
            store: InMemoryWatchMutationStore(), applier: ImportApplier(provider: provider, otherProviders: otherProviders)
        )
        return TrackerHistorySyncController(
            identity: .init(
                trackerID: "test-tracker", connectionID: connection, allowsForegroundChecks: allowsForegroundChecks
            ), scope: scope, store: store, supportedCategories: supportedCategories,
            isAuthorized: { permission.allowed },
            makeSession: { scope, allowed in
                TrackerHistoryImportSession(
                    scope: scope, destinations: [], reconciler: reconciler,
                    readSnapshot: {
                        if evidence.failRead { throw TrackerHistoryError.incompleteSnapshot }
                        let action = evidence.nextRead
                        evidence.nextRead = nil
                        action?()
                        return evidence.snapshot
                    },
                    index: { index }, resolveProvider: { otherProviders[$0] ?? provider },
                    isAuthorized: { permission.allowed && allowed() }
                )
            }
        )
    }

    private func snapshot(_ observations: [TrackerHistoryObservation]) throws -> TrackerHistorySnapshot {
        try .init(
            trackerID: "test-tracker", connectionID: "connection",
            observations: observations, expectedCount: observations.count
        )
    }

    @MainActor
    private func enable(
        _ sync: TrackerHistorySyncController, evidence: ImportEvidence,
        categories: Set<TrackerHistorySyncCategory> = [.watched]
    ) async {
        let plan = TrackerHistoryImportPlan(snapshot: evidence.snapshot, serverScope: sync.contextScope, candidates: [])
        await sync.enable(afterReview: plan, accountIDs: ["account"], categories: categories)
        XCTAssertNil(sync.error)
        XCTAssertTrue(sync.isEnabled)
    }

    @MainActor
    private func restoreLegacySkip(_ sync: TrackerHistorySyncController, store: DurableLocalStateStore) throws {
        var legacy = try XCTUnwrap(sync.grant)
        legacy.includesExistingWatched = nil
        legacy.includesExistingResumes = nil
        try store.save(legacy, for: DurableLocalStateKey(
            collection: .trackerDeliveryReceipt, scope: .source(profileID: legacy.scope.profileID, sourceID: legacy.identity.trackerID),
            recordID: "history-sync"
        ))
        sync.reload()
    }

    @MainActor
    func testSelectionEditPreservesUnprocessedResumeAndProofWithoutBackfillingNewPairs() async throws {
        let context = WatchMutationServerScope(
            profile: .init(id: "profile", name: "Test"), accounts: [account(.mediaShare), account(.mediaShare, id: "second")]
        )
        let evidence = ImportEvidence(try snapshot([]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let first = ImportProvider(.mediaShare, item: item())
        var otherItem = item()
        otherItem.sourceAccountID = "second"
        let second = ImportProvider(.mediaShare, item: otherItem)
        let index = IdentityIndexSnapshot(byIdentity: [
            .external(source: "tmdb", value: "550"): context.accounts.map {
                .init(accountID: $0.accountID, itemID: "server-item", providerKind: .mediaShare, kind: .movie)
            }
        ])
        func controller() -> TrackerHistorySyncController {
            syncController(
                provider: first, evidence: evidence, store: store, serverScope: context,
                indexSnapshot: index, otherProviders: ["second": second]
            )
        }
        let sync = controller()
        await enable(sync, evidence: evidence, categories: [.resume])
        let settled = try observation(id: "settled", fact: .resume(seconds: 100, runtime: 1_000, updatedAt: nil))
        evidence.snapshot = try snapshot([settled])
        await sync.synchronize()
        XCTAssertEqual(sync.confirmedCount, 1)

        evidence.snapshot = try snapshot([
            settled, observation(fact: .resume(seconds: 200, runtime: 1_000, updatedAt: nil)),
            observation(id: "existing-watch")
        ])
        await sync.updateSelection(accountIDs: ["account", "second"], categories: [.resume, .watched])
        XCTAssertNil(sync.error)
        let restored = controller()
        await restored.synchronize()
        XCTAssertNil(restored.error)
        XCTAssertEqual(restored.grant?.reviewCount, 0)
        let continued = try await first.item(id: "server-item")
        XCTAssertEqual(continued.resumePosition, 200, "The existing share still processes its unconsumed resume")
        XCTAssertFalse(continued.isPlayed)
        var secondWrites = await second.writes
        XCTAssertEqual(secondWrites, 0, "Neither category may backfill the new share")

        await first.replace(item: item())
        evidence.snapshot = try snapshot([settled])
        await restored.synchronize()
        let firstWrites = await first.writes
        XCTAssertEqual(firstWrites, 2, "Resetting a share must not replay settled history")
        evidence.snapshot = try snapshot([observation(id: "new-watch")])
        await restored.synchronize()
        XCTAssertEqual(restored.confirmedCount, 2)
        secondWrites = await second.writes
        XCTAssertEqual(secondWrites, 1)
    }

    @MainActor
    func testSelectionEditRejectsInvalidOrStalePermissionBeforeReadingHistory() async throws {
        let context = WatchMutationServerScope(
            profile: .init(id: "profile", name: "Test"), accounts: [account(.mediaShare), account(.plex, id: "managed")]
        )
        let evidence = ImportEvidence(try snapshot([]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(.mediaShare, item: item())
        let sync = syncController(
            provider: provider, evidence: evidence, store: store, serverScope: context, supportedCategories: [.watched]
        )
        await enable(sync, evidence: evidence)
        let original = try XCTUnwrap(sync.grant)
        evidence.failRead = true
        let invalid: [(Set<String>, Set<TrackerHistorySyncCategory>)] = [
            ([], [.watched]), (["account"], []), (["account"], [.resume]),
            (["account", "managed"], [.watched]), (["unknown"], [.watched])
        ]
        for (accounts, categories) in invalid {
            await sync.updateSelection(accountIDs: accounts, categories: categories)
            XCTAssertEqual(sync.error as? TrackerHistoryError, .invalidSelection)
            XCTAssertEqual(sync.grant, original)
        }
        await sync.updateSelection(accountIDs: ["account"], categories: [.watched])
        XCTAssertNil(sync.error)
        XCTAssertEqual(sync.grant, original, "A no-op must not replace the grant")

        evidence.failRead = false
        let replacement = syncController(provider: provider, evidence: evidence, store: store, connection: "other")
        await enable(replacement, evidence: evidence)
        evidence.failRead = true
        await sync.updateSelection(accountIDs: ["account"], categories: [.watched])
        XCTAssertEqual(sync.error as? TrackerHistorySyncError, .permissionChanged)
        replacement.reload()
        XCTAssertTrue(replacement.isEnabled)
        XCTAssertEqual(sync.grant, replacement.grant)
    }

    @MainActor
    func testReaddedShareCannotInheritPreviousViewersContinuationProof() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(.mediaShare, item: item())
        func controller(viewer: String) -> TrackerHistorySyncController {
            syncController(provider: provider, evidence: evidence, store: store, serverScope: .init(
                profile: .init(id: "profile", name: "Test"),
                accounts: [account(.mediaShare, userID: viewer), account(.mediaShare, id: "second")]
            ))
        }
        let first = controller(viewer: "original")
        await enable(first, evidence: evidence, categories: [.resume])
        evidence.snapshot = try snapshot([observation(fact: .resume(seconds: 100, runtime: 1_000, updatedAt: nil))])
        await first.synchronize()
        XCTAssertEqual(first.confirmedCount, 1)
        await first.updateSelection(accountIDs: ["second"], categories: [.resume])
        XCTAssertNil(first.error)
        let replacement = controller(viewer: "replacement")
        await replacement.updateSelection(accountIDs: ["account", "second"], categories: [.resume])
        XCTAssertNil(replacement.error)
        evidence.snapshot = try snapshot([observation(fact: .resume(seconds: 200, runtime: 1_000, updatedAt: nil))])
        // The extra share isn't indexed in this fixture; check only the re-added destination.
        evidence.failRead = true
        await replacement.updateSelection(accountIDs: ["account"], categories: [.resume])
        XCTAssertNil(replacement.error, "Removing a share needs no tracker read")
        evidence.failRead = false
        await replacement.synchronize()
        XCTAssertNil(replacement.error)
        let writes = await provider.writes
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(replacement.grant?.reviewCount, 1)
    }

    @MainActor
    func testSelectionEditCannotPublishOverRevocationOrPartialLedger() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let secure = HistorySyncSecureStore()
        let store = try DurableLocalStateStore(secureStore: secure)
        let provider = ImportProvider(.mediaShare, item: item())
        let sync = syncController(provider: provider, evidence: evidence, store: store)
        await enable(sync, evidence: evidence)
        let original = sync.grant
        evidence.snapshot = try snapshot([observation()])
        secure.failWrites(afterSuccessfulWrites: 2)
        await sync.updateSelection(accountIDs: ["account"], categories: [.watched, .resume])
        XCTAssertEqual(sync.error as? DurableLocalStateError, .storageUnavailable)
        secure.allowWrites()
        let restored = syncController(provider: provider, evidence: evidence, store: store)
        XCTAssertEqual(restored.grant, original)
        await restored.synchronize()
        XCTAssertEqual(restored.confirmedCount, 1)

        evidence.nextRead = { restored.disable() }
        await sync.updateSelection(accountIDs: ["account"], categories: [.watched, .resume])
        XCTAssertEqual(sync.error as? TrackerHistorySyncError, .permissionChanged)
        XCTAssertFalse(sync.isEnabled)
        XCTAssertEqual(sync.grant?.id, original?.id)
        XCTAssertEqual(sync.grant?.categories, [.watched])
    }

    @MainActor
    func testSelectionEditFencesPendingDispatchEvenFromAnotherController() async throws {
        for useSameController in [true, false] {
            let evidence = ImportEvidence(try snapshot([]))
            let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
            let provider = ImportProvider(.mediaShare, item: item())
            let sync = syncController(provider: provider, evidence: evidence, store: store)
            await enable(sync, evidence: evidence, categories: [.watched, .resume])
            let editor = useSameController ? sync : syncController(provider: provider, evidence: evidence, store: store)
            evidence.snapshot = try snapshot([observation()])
            await provider.onNextRead {
                await provider.onNextRead {
                    await Task { await editor.updateSelection(accountIDs: ["account"], categories: [.resume]) }.value
                }
            }
            await sync.synchronize()
            let writes = await provider.writes
            XCTAssertEqual(writes, 0)
            editor.reload()
            XCTAssertEqual(editor.grant?.categories, [.resume])
            XCTAssertEqual(editor.grant?.reviewCount, 1, "An uncertain delivery must stay held, not disappear")
        }
    }

    @MainActor
    func testOngoingSyncRejectsUnsupportedCategoriesAndOldBroaderGrants() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(.mediaShare, item: item())
        let sync = syncController(
            provider: provider, evidence: evidence, store: store, supportedCategories: [.watched]
        )
        let reviewed = TrackerHistoryImportPlan(snapshot: evidence.snapshot, serverScope: sync.contextScope, candidates: [])
        await sync.enable(afterReview: reviewed, accountIDs: ["account"], categories: [.resume])
        XCTAssertFalse(sync.isEnabled)
        XCTAssertEqual(sync.error as? TrackerHistoryError, .scopeChanged)
        await enable(sync, evidence: evidence)
        XCTAssertEqual(sync.grant?.categories, [.watched])

        let broader = syncController(provider: provider, evidence: evidence, store: store)
        await enable(broader, evidence: evidence, categories: [.watched, .resume])
        sync.reload()
        XCTAssertFalse(sync.isEnabled)
        evidence.failRead = true
        await sync.synchronize()
        XCTAssertNil(sync.error, "An unsupported grant must not even read the tracker")
    }

    @MainActor
    func testManualOnlySyncNeverChecksOnForeground() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let sync = syncController(
            provider: ImportProvider(.mediaShare, item: item()), evidence: evidence, store: store, allowsForegroundChecks: false
        )
        await enable(sync, evidence: evidence)
        evidence.failRead = true
        await sync.synchronize(manual: false)
        XCTAssertNil(sync.error)
        XCTAssertNil(sync.grant?.lastAttemptAt)
        await sync.synchronize()
        XCTAssertEqual(sync.error as? TrackerHistoryError, .incompleteSnapshot)
        XCTAssertNotNil(sync.grant?.lastAttemptAt)
    }

    @MainActor
    func testRevokingStoredPermissionPreventsRestoredConnectionFromResuming() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(.mediaShare, item: item())
        let sync = syncController(provider: provider, evidence: evidence, store: store)
        await enable(sync, evidence: evidence)
        try TrackerHistorySyncController.revokePermission(
            store: store, profileID: sync.contextScope.profileID, trackerID: "test-tracker"
        )
        let restored = syncController(provider: provider, evidence: evidence, store: store)
        XCTAssertFalse(restored.isEnabled)
        evidence.failRead = true
        await restored.synchronize()
        XCTAssertNil(restored.error)
    }

    @MainActor
    func testAnimeRatingAndCountEditsDoNotBecomeNewMovieCompletions() async throws {
        func movie(_ status: TrackerAnimeListProgress.Status, edited: Bool) throws -> TrackerHistoryObservation {
            try .init(
                recordID: "anime/movie", kind: .movie, identities: [.external(source: "tmdb", value: "550")],
                fact: .animeList(try .init(
                    status: status, episodesWatched: edited ? 2 : 1, repeats: edited ? 1 : 0,
                    score: edited ? 9 : 8, updatedAt: Date(timeIntervalSince1970: edited ? 200 : 100)
                ))
            )
        }
        for initiallyCompleted in [false, true] {
            let evidence = ImportEvidence(try snapshot([movie(initiallyCompleted ? .completed : .planning, edited: false)]))
            let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
            let provider = ImportProvider(.mediaShare, item: item())
            let sync = syncController(provider: provider, evidence: evidence, store: store)
            await enable(sync, evidence: evidence)
            await sync.synchronize(manual: false)
            XCTAssertEqual(sync.confirmedCount, initiallyCompleted ? 1 : 0)
            evidence.snapshot = try snapshot([movie(.completed, edited: true)])
            await sync.synchronize()
            XCTAssertNil(sync.error)
            let writes = await provider.writes
            XCTAssertEqual(sync.confirmedCount, initiallyCompleted ? 0 : 1)
            XCTAssertEqual(writes, 1)
        }
    }

    @MainActor
    func testOngoingSyncImportsReviewedHistoryWithoutReplayingAfterRestart() async throws {
        let evidence = ImportEvidence(try snapshot([observation()]))
        let secure = HistorySyncSecureStore()
        let store = try DurableLocalStateStore(secureStore: secure)
        let provider = ImportProvider(.mediaShare, item: item())
        let sync = syncController(provider: provider, evidence: evidence, store: store)
        await enable(sync, evidence: evidence)
        await sync.synchronize()
        var writes = await provider.writes
        XCTAssertEqual(writes, 1)
        evidence.snapshot = try snapshot([observation(), observation(id: "new-play")])
        await sync.synchronize()
        XCTAssertNil(sync.error)
        XCTAssertEqual(sync.confirmedCount, 0)
        writes = await provider.writes
        XCTAssertEqual(writes, 1)
        await provider.replace(item: item())
        let restored = syncController(
            provider: provider, evidence: evidence, store: try DurableLocalStateStore(secureStore: secure)
        )
        await restored.synchronize()
        writes = await provider.writes
        XCTAssertEqual(writes, 1, "Resetting share watch state must not resurrect previously imported history")
        XCTAssertTrue(restored.isEnabled)
    }

    @MainActor
    func testOngoingSyncKeepsUncertainTargetsBlockedAcrossRestartAndNewRecords() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(.mediaShare, item: item(), losesWriteReply: true, failsReadback: true)
        let sync = syncController(provider: provider, evidence: evidence, store: store)
        await enable(sync, evidence: evidence)
        evidence.snapshot = try snapshot([observation()])
        await sync.synchronize()
        XCTAssertNotNil(sync.error)
        let initialWrites = await provider.writes
        XCTAssertEqual(initialWrites, 1)
        let recoveredProvider = ImportProvider(.mediaShare, item: item())
        let restored = syncController(provider: recoveredProvider, evidence: evidence, store: store)
        await restored.synchronize()
        evidence.snapshot = try snapshot([observation(), observation(id: "another-record")])
        await restored.synchronize()
        let retryWrites = await recoveredProvider.writes
        XCTAssertEqual(retryWrites, 0)
        XCTAssertGreaterThan(try XCTUnwrap(restored.grant).reviewCount, 0)
    }

    @MainActor
    func testOngoingSyncConnectionShareUserAndProfileChangesRequireNewConsent() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(.mediaShare, item: item())
        let sync = syncController(provider: provider, evidence: evidence, store: store)
        await enable(sync, evidence: evidence)
        let otherProfile = WatchMutationServerScope(
            profile: .init(id: "another-profile", name: "Another"), accounts: [account(.mediaShare)]
        )
        for (connection, scope) in [
            ("reconnected", sync.contextScope), ("connection", scope(.mediaShare, userID: "another-viewer")),
            ("connection", otherProfile), ("connection", scope(.jellyfin))
        ] {
            let changed = syncController(
                provider: provider, evidence: evidence, store: store, connection: connection, serverScope: scope
            )
            XCTAssertFalse(changed.isEnabled)
            await changed.synchronize()
        }
        let writes = await provider.writes
        XCTAssertEqual(writes, 0)
    }

    @MainActor
    func testOngoingSyncRevocationDuringReadPreventsAllWritesAndPersists() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(.mediaShare, item: item())
        let sync = syncController(provider: provider, evidence: evidence, store: store)
        await enable(sync, evidence: evidence)
        evidence.snapshot = try snapshot([observation()])
        evidence.nextRead = { sync.disable() }
        await sync.synchronize()
        XCTAssertFalse(sync.isEnabled)
        let restored = syncController(provider: provider, evidence: evidence, store: store)
        XCTAssertFalse(restored.isEnabled)
        await restored.synchronize()
        let writes = await provider.writes
        XCTAssertEqual(writes, 0)
    }

    @MainActor
    func testOngoingSyncStorageFailureCannotReachWriter() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let secure = HistorySyncSecureStore()
        let store = try DurableLocalStateStore(secureStore: secure)
        let provider = ImportProvider(.mediaShare, item: item())
        let sync = syncController(provider: provider, evidence: evidence, store: store)
        await enable(sync, evidence: evidence)
        evidence.snapshot = try snapshot([observation()])
        evidence.nextRead = { secure.failWrites() }
        await sync.synchronize()
        XCTAssertEqual(sync.error as? DurableLocalStateError, .storageUnavailable)
        let writes = await provider.writes
        XCTAssertEqual(writes, 0)
    }

    @MainActor
    func testOngoingSyncMissingLedgerCannotBecomeAnEmptyBaseline() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(.mediaShare, item: item())
        let sync = syncController(provider: provider, evidence: evidence, store: store)
        await enable(sync, evidence: evidence)
        let grant = try XCTUnwrap(sync.grant)
        try store.remove(.init(
            collection: .trackerDeliveryReceipt, scope: .source(profileID: "profile", sourceID: "test-tracker"),
            recordID: "history-sync/\(grant.id.uuidString)/0"
        ))
        evidence.snapshot = try snapshot([observation()])
        await sync.synchronize()
        XCTAssertEqual(sync.error as? DurableLocalStateError, .malformedPayload)
        let writes = await provider.writes
        XCTAssertEqual(writes, 0)
    }

    @MainActor
    func testOngoingSyncPreservesConflictsAndIgnoresUnapprovedCategoriesAndAbsence() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(.mediaShare, item: item(position: 100))
        let sync = syncController(provider: provider, evidence: evidence, store: store)
        await enable(sync, evidence: evidence)
        evidence.snapshot = try snapshot([observation()])
        await sync.synchronize()
        XCTAssertGreaterThan(try XCTUnwrap(sync.grant).reviewCount, 0)
        await provider.replace(item: item())
        await sync.synchronize()
        evidence.snapshot = try snapshot([
            observation(id: "resume", fact: .resume(seconds: 200, runtime: 1_000, updatedAt: nil))
        ])
        await sync.synchronize()
        evidence.snapshot = try snapshot([])
        await sync.synchronize()
        let writes = await provider.writes
        XCTAssertEqual(writes, 0)
    }

    @MainActor
    func testOngoingResumeOnlyImportDefersExistingWatchedHistoryConflict() async throws {
        let watched = try observation(id: "existing-watch")
        let evidence = ImportEvidence(try snapshot([watched]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let original = item()
        let provider = ImportProvider(.mediaShare, item: original)
        let sync = syncController(provider: provider, evidence: evidence, store: store)
        await enable(sync, evidence: evidence, categories: [.resume])
        evidence.snapshot = try snapshot([
            watched,
            observation(id: "new-resume", fact: .resume(seconds: 200, runtime: 1_000, updatedAt: nil))
        ])

        await sync.synchronize(manual: false)
        XCTAssertNil(sync.error)
        XCTAssertEqual(sync.grant?.reviewCount, 1)
        XCTAssertEqual(sync.confirmedCount, 0)
        let actual = try await provider.item(id: "server-item")
        XCTAssertEqual(TrackerServerHistoryBaseline(item: actual), .init(item: original))
        let writes = await provider.writes
        XCTAssertEqual(writes, 0)
    }

    @MainActor
    func testDirectEnrollmentImportsExistingWatchOnFirstAutomaticCheck() async throws {
        let provider = ImportProvider(.mediaShare, item: item())
        let evidence = ImportEvidence(try snapshot([observation()]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let sync = syncController(provider: provider, evidence: evidence, store: store)
        let (entry, _) = try session(provider: provider, readSnapshot: { evidence.snapshot })
        await sync.enable(from: entry, accountIDs: ["account"], categories: [.watched])
        XCTAssertNil(sync.error)
        XCTAssertTrue(sync.isEnabled)
        XCTAssertNil(entry.plan)
        let reads = await provider.itemReads
        XCTAssertTrue(reads.isEmpty)
        await sync.synchronize(manual: false)
        let writes = await provider.writes
        XCTAssertEqual(writes, 1)
    }

    @MainActor
    func testExistingHistoryImportsWatchesAndPausedProgressOnlyOnSelectedShare() async throws {
        func record(_ id: String, _ tmdb: String, _ fact: TrackerHistoryObservation.Fact = .watched(at: nil)) throws -> TrackerHistoryObservation {
            try .init(recordID: id, kind: .movie, identities: [.external(source: "tmdb", value: tmdb)], fact: fact)
        }
        let context = WatchMutationServerScope(
            profile: .init(id: "profile", name: "Test"), accounts: [account(.mediaShare), account(.plex, id: "managed")]
        )
        let second = MediaItem(id: "second-item", title: "Second", kind: .movie, providerIDs: ["Tmdb": "551"])
        let resume = MediaItem(id: "resume-item", title: "Resume", kind: .movie, runtime: 1_000, providerIDs: ["Tmdb": "552"])
        let share = ImportProvider(.mediaShare, item: item(), relatedItems: [second, resume])
        let managed = ImportProvider(.plex, item: item())
        let index = IdentityIndexSnapshot(byIdentity: [
            .external(source: "tmdb", value: "550"): [
                .init(accountID: "account", itemID: "server-item", providerKind: .mediaShare, kind: .movie),
                .init(accountID: "managed", itemID: "server-item", providerKind: .plex, kind: .movie)
            ],
            .external(source: "tmdb", value: "551"): [
                .init(accountID: "account", itemID: second.id, providerKind: .mediaShare, kind: .movie)
            ],
            .external(source: "tmdb", value: "552"): [
                .init(accountID: "account", itemID: resume.id, providerKind: .mediaShare, kind: .movie)
            ]
        ])
        // Put the second real write beyond the 25-record batch.
        let watches = try (1...24).map { try record("missing-\($0)", String(1_000 + $0)) }
            + [record("first", "550"), record("z-last", "551")]
        let evidence = ImportEvidence(try snapshot(watches + [
            record("progress", "552", .pausedPercentage(percent: 10, updatedAt: nil))
        ]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        func controller() -> TrackerHistorySyncController {
            syncController(
                provider: share, evidence: evidence, store: store, serverScope: context,
                indexSnapshot: index, otherProviders: ["managed": managed]
            )
        }
        let sync = controller()
        await enable(sync, evidence: evidence, categories: [.watched, .resume])
        await sync.synchronize(manual: false)
        XCTAssertNil(sync.error)
        let result = try XCTUnwrap(sync.grant?.lastCompletedResult)
        XCTAssertEqual(result.confirmedCount, 3)
        XCTAssertFalse(result.hasMoreChanges)
        XCTAssertEqual(result.libraries?.map(\.accountID), ["account"])
        XCTAssertEqual(result.libraries?.first?.counts, [.updated: 3, .noMatch: 24])
        XCTAssertEqual(sync.grant?.reviewCount, 24)
        let historicalResume = try await share.item(id: resume.id)
        XCTAssertEqual(historicalResume.resumePosition, 100)
        let managedReads = await managed.itemReads
        let managedWrites = await managed.writes
        XCTAssertTrue(managedReads.isEmpty)
        XCTAssertEqual(managedWrites, 0)

        let reopened = controller()
        evidence.nextRead = { XCTFail("Repeated index callbacks in one foreground must not start another check") }
        await sync.synchronize(manual: false)
        XCTAssertEqual(reopened.grant?.lastCheckStatus, .completed)
        XCTAssertEqual(reopened.grant?.lastCompletedResult, result)
        evidence.nextRead = nil
        await share.replace(item: item())
        evidence.snapshot = try snapshot(watches + [record("progress", "552", .resume(seconds: 200, runtime: 1_000, updatedAt: nil))])
        await reopened.synchronize(manual: false)
        XCTAssertNil(reopened.error)
        XCTAssertEqual(reopened.confirmedCount, 1)
        let futureResume = try await share.item(id: resume.id)
        let oldWatch = try await share.item(id: "server-item")
        XCTAssertEqual(futureResume.resumePosition, 200)
        XCTAssertFalse(oldWatch.isPlayed, "Confirmed historical receipts still prevent replay")
    }

    @MainActor
    func testForegroundReturnChecksForNewActivityWithoutBroadeningLegacySkip() async throws {
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(.mediaShare, item: item())
        let evidence = ImportEvidence(try snapshot([observation()]))
        let sync = syncController(provider: provider, evidence: evidence, store: store)
        await enable(sync, evidence: evidence)
        try restoreLegacySkip(sync, store: store)
        await sync.synchronize(manual: false)
        XCTAssertEqual(sync.grant?.lastCompletedResult?.confirmedCount, 0)
        sync.stop() // Background, then foreground again well within fifteen minutes.
        evidence.snapshot = try snapshot([observation(), observation(id: "new")])
        await sync.synchronize(manual: false)
        XCTAssertEqual(sync.grant?.lastCompletedResult?.confirmedCount, 1)
    }

    @MainActor
    func testFailedAndInterruptedChecksKeepLastSuccessUntilSelectionChanges() async throws {
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(.mediaShare, item: item())
        let evidence = ImportEvidence(try snapshot([observation()]))
        func controller() -> TrackerHistorySyncController { syncController(provider: provider, evidence: evidence, store: store) }
        let sync = controller()
        await enable(sync, evidence: evidence)
        XCTAssertNil(sync.grant?.lastCheckStatus)
        evidence.failRead = true
        await sync.synchronize()
        XCTAssertNotNil(sync.error)
        XCTAssertEqual(controller().grant?.lastCheckStatus, .failed)
        XCTAssertNil(controller().grant?.lastCompletedResult)
        evidence.failRead = false
        await sync.synchronize()
        let completed = try XCTUnwrap(sync.grant?.lastCompletedResult)
        XCTAssertEqual(completed.confirmedCount, 1)

        evidence.nextRead = { sync.stop() }
        await sync.synchronize()
        let restored = controller()
        XCTAssertEqual(restored.grant?.lastCheckStatus, .incomplete)
        XCTAssertEqual(restored.grant?.lastCompletedResult, completed)
        await restored.updateSelection(accountIDs: ["account"], categories: [.resume])
        await restored.updateSelection(accountIDs: ["account"], categories: [.resume, .watched])
        let edited = controller()
        XCTAssertNil(edited.grant?.lastCheckStatus)
        XCTAssertNil(edited.grant?.lastCompletedResult)
        await edited.synchronize()
        XCTAssertEqual(edited.grant?.lastCheckStatus, .completed)
        XCTAssertEqual(edited.grant?.lastCompletedResult?.confirmedCount, 0)
    }

    @MainActor
    func testHistoricalWatchDeferredByPlaybackDoesNotTransferToNewShareOrReaddedCategory() async throws {
        let context = WatchMutationServerScope(
            profile: .init(id: "profile", name: "Test"), accounts: [account(.mediaShare), account(.mediaShare, id: "second")]
        )
        let evidence = ImportEvidence(try snapshot((0..<26).map { try observation(id: "watch-\($0)") }))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let first = ImportProvider(.mediaShare, item: item())
        var secondItem = item()
        secondItem.sourceAccountID = "second"
        let second = ImportProvider(.mediaShare, item: secondItem)
        let reconciler = WatchStateReconciler(
            store: InMemoryWatchMutationStore(), applier: ImportApplier(provider: first, otherProviders: ["second": second])
        )
        let sync = syncController(
            provider: first, evidence: evidence, store: store, serverScope: context, reconciler: reconciler,
            indexSnapshot: IdentityIndexSnapshot(byIdentity: [.external(source: "tmdb", value: "550"): context.accounts.map {
                .init(accountID: $0.accountID, itemID: "server-item", providerKind: .mediaShare, kind: .movie)
            }]), otherProviders: ["second": second]
        )
        await enable(sync, evidence: evidence)
        await reconciler.beginLiveSession(accountID: "account", itemID: "server-item", serverScope: context)
        await sync.synchronize(manual: false)
        XCTAssertEqual(sync.grant?.lastCompletedResult?.confirmedCount, 0)
        XCTAssertTrue(sync.hasMoreChanges)
        XCTAssertEqual(sync.grant?.lastCompletedResult?.libraries?.first?.counts, [.playing: 26])
        await sync.updateSelection(accountIDs: ["account", "second"], categories: [.watched])
        XCTAssertNil(sync.grant?.lastCompletedResult)
        await sync.synchronize()
        let secondWrites = await second.writes
        XCTAssertEqual(secondWrites, 0)
        await sync.updateSelection(accountIDs: ["account"], categories: [.resume])
        await sync.updateSelection(accountIDs: ["account"], categories: [.resume, .watched])
        await reconciler.endLiveSession(accountID: "account", itemID: "server-item", serverScope: context)
        await sync.synchronize()
        let firstWrites = await first.writes
        XCTAssertEqual(firstWrites, 0)
        XCTAssertEqual(sync.grant?.lastCompletedResult?.hasMoreChanges, false)
    }

    @MainActor
    func testDirectEnrollmentRejectsChangedBaselineAndClosedSession() async throws {
        let provider = ImportProvider(.mediaShare, item: item())
        let reviewed = try snapshot([])
        let evidence = ImportEvidence(try snapshot([observation()]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let sync = syncController(provider: provider, evidence: evidence, store: store)
        let (entry, _) = try session(provider: provider, readSnapshot: { reviewed })
        await sync.enable(from: entry, accountIDs: ["account"], categories: [.watched])
        XCTAssertEqual(sync.error as? TrackerHistoryError, .stalePreview)
        XCTAssertNil(sync.grant)
        entry.cancel()
        await sync.enable(from: entry, accountIDs: ["account"], categories: [.watched])
        XCTAssertEqual(sync.error as? TrackerHistoryError, .scopeChanged)
        XCTAssertNil(sync.grant)
    }

    @MainActor
    func testOngoingSyncEnrollmentRejectsChangedReviewAndEmptySelections() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(.mediaShare, item: item())
        let sync = syncController(provider: provider, evidence: evidence, store: store)
        let plan = TrackerHistoryImportPlan(snapshot: evidence.snapshot, serverScope: sync.contextScope, candidates: [])
        evidence.snapshot = try snapshot([observation()])
        await sync.enable(afterReview: plan, accountIDs: ["account"], categories: [.watched])
        XCTAssertEqual(sync.error as? TrackerHistoryError, .stalePreview)
        XCTAssertFalse(sync.isEnabled)
        evidence.snapshot = try snapshot([])
        await sync.enable(afterReview: plan, accountIDs: [], categories: [.watched])
        XCTAssertEqual(sync.error as? TrackerHistoryError, .invalidSelection)
        XCTAssertFalse(sync.isEnabled)
        await sync.enable(afterReview: plan, accountIDs: ["account"], categories: [])
        XCTAssertFalse(sync.isEnabled)
    }

    @MainActor
    func testOngoingEnrollmentRejectsServerAndMixedSelectionsWithoutReadingHistory() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(.mediaShare, item: item())
        let servers = ProviderKind.allCases.filter { $0 != .mediaShare }.map { account($0, id: $0.rawValue) }
        let mixedScope = WatchMutationServerScope(
            profile: .init(id: "profile", name: "Test"),
            accounts: servers + [account(.mediaShare), account(.mediaShare, id: "another-share")]
        )
        let sync = syncController(provider: provider, evidence: evidence, store: store, serverScope: mixedScope)
        XCTAssertEqual(sync.eligibleAccountIDs, ["account", "another-share"])
        let reviewed = TrackerHistoryImportPlan(snapshot: evidence.snapshot, serverScope: mixedScope, candidates: [])
        evidence.nextRead = { XCTFail("Reject ineligible destinations before reading tracker history") }
        for server in servers {
            for selection: Set<String> in [[server.id], [server.id, "account"]] {
                await sync.enable(afterReview: reviewed, accountIDs: selection, categories: [.watched])
                XCTAssertEqual(sync.error as? TrackerHistoryError, .invalidSelection, "\(selection)")
                XCTAssertFalse(sync.isEnabled)
                XCTAssertNil(sync.grant)
            }
        }
        sync.reload()
        XCTAssertNil(sync.grant, "A rejected selection must not persist a partial grant")
        evidence.nextRead = nil
        await enable(sync, evidence: evidence)
        XCTAssertEqual(sync.grant?.scope.accounts, try mixedScope.selectingAccounts(["account"]).accounts)
    }

    @MainActor
    func testOlderConsentCannotSyncOnForegroundOrManuallyUntilNewEnrollment() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(.mediaShare, item: item())
        let sync = syncController(provider: provider, evidence: evidence, store: store)
        await enable(sync, evidence: evidence)
        var older = try XCTUnwrap(sync.grant)
        let key = try DurableLocalStateKey(
            collection: .trackerDeliveryReceipt, scope: .source(profileID: older.scope.profileID, sourceID: older.identity.trackerID),
            recordID: "history-sync"
        )
        older.betaConsentVersion = nil
        try store.save(older, for: key)
        evidence.snapshot = try snapshot([observation()])
        evidence.nextRead = { XCTFail("Old consent must not even read tracker history") }
        let reopened = syncController(provider: provider, evidence: evidence, store: store)
        XCTAssertFalse(reopened.isEnabled)
        await reopened.synchronize(manual: false)
        await reopened.synchronize()
        XCTAssertEqual(reopened.grant, older)
        evidence.nextRead = nil
        reopened.disable()
        await enable(reopened, evidence: evidence)
        XCTAssertTrue(reopened.isEnabled)
        await reopened.synchronize()
        XCTAssertNil(reopened.error)
        let writes = await provider.writes
        XCTAssertEqual(writes, 1, "Only fresh enrollment authorizes importing existing history")
    }

    @MainActor
    func testOngoingSyncRejectsLegacyServerAndMixedGrantsOnReload() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(.mediaShare, item: item())
        let context = WatchMutationServerScope(
            profile: .init(id: "profile", name: "Test"), accounts: [account(.mediaShare), account(.plex, id: "server")]
        )
        let sync = syncController(provider: provider, evidence: evidence, store: store, serverScope: context)
        await enable(sync, evidence: evidence)
        let valid = try XCTUnwrap(sync.grant)
        let key = try DurableLocalStateKey(
            collection: .trackerDeliveryReceipt, scope: .source(profileID: context.profileID, sourceID: valid.identity.trackerID),
            recordID: "history-sync"
        )
        evidence.snapshot = try snapshot([observation()])
        evidence.nextRead = { XCTFail("A legacy grant must not read the tracker, even for its share subset") }
        for selection: Set<String> in [["server"], ["account", "server"]] {
            // Keep the valid baseline and receipts, changing only the persisted destination list.
            let legacy = TrackerHistorySyncGrant(
                id: valid.id, identity: valid.identity, scope: try context.selectingAccounts(selection),
                categories: valid.categories, createdAt: valid.createdAt, enabled: true, reviewCount: 0,
                betaConsentVersion: valid.betaConsentVersion
            )
            try store.save(legacy, for: key)
            let reopened = syncController(provider: provider, evidence: evidence, store: store, serverScope: context)
            XCTAssertFalse(reopened.isEnabled, "\(selection)")
            await reopened.synchronize(manual: false)
            await reopened.synchronize()
            XCTAssertNil(reopened.grant?.lastAttemptAt)
            XCTAssertFalse(reopened.isEnabled)
            let writes = await provider.writes
            XCTAssertEqual(writes, 0)
        }
    }

    @MainActor
    func testOngoingSyncDefersLivePlaybackWithFullViewerScopeAndSelectedShareGrant() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(.mediaShare, item: item())
        let fullScope = WatchMutationServerScope(
            profile: .init(id: "profile", name: "Test"), accounts: [account(.mediaShare), account(.plex, id: "plex")]
        )
        let reconciler = WatchStateReconciler(
            store: InMemoryWatchMutationStore(), applier: ImportApplier(provider: provider)
        )
        let sync = syncController(
            provider: provider, evidence: evidence, store: store, serverScope: fullScope, reconciler: reconciler
        )
        await sync.enable(
            afterReview: .init(snapshot: evidence.snapshot, serverScope: fullScope, candidates: []),
            accountIDs: ["account"], categories: [.watched]
        )
        XCTAssertTrue(sync.isEnabled)
        XCTAssertEqual(sync.grant?.scope.accounts.map(\.accountID), ["account"])
        await reconciler.beginLiveSession(accountID: "account", itemID: "server-item", serverScope: fullScope)
        evidence.snapshot = try snapshot([observation()])
        await sync.synchronize()
        var writes = await provider.writes
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(sync.grant?.reviewCount, 0)
        await reconciler.endLiveSession(accountID: "account", itemID: "server-item", serverScope: fullScope)
        await sync.synchronize()
        XCTAssertNil(sync.error)
        writes = await provider.writes
        XCTAssertEqual(writes, 1)
    }

    @MainActor
    func testOngoingSyncContinuesConfirmedResumeAfterRestartAndImportsCompletion() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(.mediaShare, item: item())
        let sync = syncController(provider: provider, evidence: evidence, store: store)
        await enable(sync, evidence: evidence, categories: [.resume, .watched])
        evidence.snapshot = try snapshot([
            observation(id: "resume", fact: .resume(seconds: 200, runtime: 1_000, updatedAt: nil))
        ])
        await sync.synchronize()
        XCTAssertNil(sync.error)
        XCTAssertEqual(sync.confirmedCount, 1)
        var server = try await provider.item(id: "server-item")
        XCTAssertEqual(server.resumePosition, 200)
        evidence.snapshot = try snapshot([
            observation(id: "resume", fact: .resume(seconds: 400, runtime: 1_000, updatedAt: nil))
        ])
        let restored = syncController(provider: provider, evidence: evidence, store: store)
        await restored.synchronize()
        server = try await provider.item(id: "server-item")
        XCTAssertEqual(server.resumePosition, 400)
        XCTAssertNil(restored.error)
        XCTAssertEqual(restored.confirmedCount, 1)
        XCTAssertEqual(restored.grant?.reviewCount, 0)
        evidence.snapshot = try snapshot([observation()])
        await restored.synchronize()
        server = try await provider.item(id: "server-item")
        XCTAssertTrue(server.isPlayed)
        XCTAssertEqual(restored.confirmedCount, 1)
        await restored.synchronize()
        let writes = await provider.writes
        XCTAssertEqual(writes, 3)
    }

    @MainActor
    func testOngoingContinuationPreservesIndependentDestinationChanges() async throws {
        let edits: [(inout MediaItem) -> Void] = [
            { $0.resumePosition = 250 }, { $0.isPlayed = true }, { $0.hasBeenPlayed = true },
            { $0.lastPlayedAt = Date(timeIntervalSince1970: 200) }, { $0.runtime = 1_000.5 },
            { $0.providerIDs["Imdb"] = "tt0137523" }
        ]
        for edit in edits {
            let evidence = ImportEvidence(try snapshot([]))
            let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
            let provider = ImportProvider(.mediaShare, item: item())
            let sync = syncController(provider: provider, evidence: evidence, store: store)
            await enable(sync, evidence: evidence, categories: [.resume])
            evidence.snapshot = try snapshot([observation(fact: .resume(seconds: 200, runtime: 1_000, updatedAt: nil))])
            await sync.synchronize()
            var changed = try await provider.item(id: "server-item")
            edit(&changed)
            await provider.replace(item: changed)
            evidence.snapshot = try snapshot([observation(fact: .resume(seconds: 400, runtime: 1_000, updatedAt: nil))])
            await sync.synchronize()
            let actual = try await provider.item(id: "server-item")
            XCTAssertEqual(TrackerServerHistoryBaseline(item: actual), .init(item: changed))
            XCTAssertEqual(sync.grant?.reviewCount, 1)
            let writes = await provider.writes
            XCTAssertEqual(writes, 1)
        }
    }

    @MainActor
    func testOngoingContinuationRejectsRewindsClearsRuntimeAndTrackerConflicts() async throws {
        let changes: [[TrackerHistoryObservation]] = try [
            [observation(fact: .resume(seconds: 100, runtime: 1_000, updatedAt: nil))],
            [observation(fact: .explicitlyClearedResume)],
            [observation(fact: .explicitlyUnwatched)],
            [observation(fact: .resume(seconds: 400, runtime: 1_100, updatedAt: nil))],
            [observation(id: "resume", fact: .resume(seconds: 400, runtime: 1_000, updatedAt: nil)), observation()]
        ]
        for observations in changes {
            let evidence = ImportEvidence(try snapshot([]))
            let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
            let provider = ImportProvider(.mediaShare, item: item())
            let sync = syncController(provider: provider, evidence: evidence, store: store)
            await enable(sync, evidence: evidence, categories: [.watched, .resume])
            evidence.snapshot = try snapshot([observation(fact: .resume(seconds: 200, runtime: 1_000, updatedAt: nil))])
            await sync.synchronize()
            evidence.snapshot = try snapshot(observations)
            await sync.synchronize()
            let actual = try await provider.item(id: "server-item")
            XCTAssertEqual(actual.resumePosition, 200)
            XCTAssertFalse(actual.isPlayed)
            let writes = await provider.writes
            XCTAssertEqual(writes, 1)
        }
    }

    @MainActor
    func testOngoingContinuationStillRechecksLivePlaybackAndDispatchBaseline() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(.mediaShare, item: item())
        let reconciler = WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: ImportApplier(provider: provider))
        let sync = syncController(provider: provider, evidence: evidence, store: store, reconciler: reconciler)
        await enable(sync, evidence: evidence, categories: [.resume])
        evidence.snapshot = try snapshot([observation(fact: .resume(seconds: 200, runtime: 1_000, updatedAt: nil))])
        await sync.synchronize()
        evidence.snapshot = try snapshot([observation(fact: .resume(seconds: 400, runtime: 1_000, updatedAt: nil))])
        await reconciler.beginLiveSession(accountID: "account", itemID: "server-item", serverScope: sync.contextScope)
        await sync.synchronize()
        var writes = await provider.writes
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(sync.grant?.reviewCount, 0)
        await reconciler.endLiveSession(accountID: "account", itemID: "server-item", serverScope: sync.contextScope)
        let changed = item(position: 250)
        await provider.onNextRead {
            await provider.onNextRead { await provider.replace(item: changed) }
        }
        await sync.synchronize()
        let actual = try await provider.item(id: "server-item")
        XCTAssertEqual(actual.resumePosition, 250)
        writes = await provider.writes
        XCTAssertEqual(writes, 1, "Continuation must not bypass the dispatch-time baseline guard")
        XCTAssertGreaterThan(try XCTUnwrap(sync.grant).reviewCount, 0)
    }

    @MainActor
    func testLegacyLedgerDoesNotInventContinuationProof() async throws {
        struct LegacyBucket: DurableLocalStateValue {
            static let durableLocalStateSchemaID = "tracker-history-sync-ledger.v1"
            var baseline: Set<String>
            var receipts: [String: String]
            var blockedTargets: Set<String>
        }
        let evidence = ImportEvidence(try snapshot([]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(.mediaShare, item: item())
        let sync = syncController(provider: provider, evidence: evidence, store: store)
        await enable(sync, evidence: evidence, categories: [.resume])
        evidence.snapshot = try snapshot([observation(fact: .resume(seconds: 200, runtime: 1_000, updatedAt: nil))])
        await sync.synchronize()
        let grant = try XCTUnwrap(sync.grant)
        for index in 0..<64 {
            let key = try DurableLocalStateKey(
                collection: .trackerDeliveryReceipt, scope: .source(profileID: "profile", sourceID: "test-tracker"),
                recordID: "history-sync/\(grant.id.uuidString)/\(index)"
            )
            let legacy: LegacyBucket = try XCTUnwrap(store.load(for: key))
            try store.save(legacy, for: key)
        }
        let restored = syncController(provider: provider, evidence: evidence, store: store)
        evidence.snapshot = try snapshot([observation(fact: .resume(seconds: 400, runtime: 1_000, updatedAt: nil))])
        await restored.synchronize()
        XCTAssertNil(restored.error)
        XCTAssertEqual(restored.grant?.reviewCount, 1)
        let actual = try await provider.item(id: "server-item")
        XCTAssertEqual(actual.resumePosition, 200)
        let writes = await provider.writes
        XCTAssertEqual(writes, 1)
    }

    @MainActor
    func testManualReviewedImportResolvesHoldAndEstablishesContinuationForStableAccount() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(.mediaShare, item: item(position: 100))
        let sync = syncController(provider: provider, evidence: evidence, store: store, connection: "stable-account")
        await enable(sync, evidence: evidence, categories: [.resume])
        evidence.snapshot = try snapshot([observation(fact: .resume(seconds: 200, runtime: 1_000, updatedAt: nil))])
        await sync.synchronize()
        XCTAssertEqual(sync.grant?.reviewCount, 1)
        let (manual, _) = try session(provider: provider, readSnapshot: { evidence.snapshot })
        manual.ongoingSync = sync
        await manual.compare()
        let row = try XCTUnwrap(manual.plan?.rows.first)
        await manual.apply(rowIDs: [row.id], overridingConflicts: [row.id], confirmsDestructiveChanges: false)
        XCTAssertNil(manual.error)
        XCTAssertEqual(manual.outcomes[row.id], .confirmed)
        XCTAssertEqual(sync.grant?.reviewCount, 0)
        manual.cancel()
        evidence.snapshot = try snapshot([observation(fact: .resume(seconds: 400, runtime: 1_000, updatedAt: nil))])
        let restored = syncController(provider: provider, evidence: evidence, store: store, connection: "stable-account")
        await restored.synchronize()
        XCTAssertNil(restored.error)
        XCTAssertEqual(restored.confirmedCount, 1)
        let actual = try await provider.item(id: "server-item")
        XCTAssertEqual(actual.resumePosition, 400)
    }

    @MainActor
    func testReviewedResumeContinuesPastLegacySkippedWatchHistory() async throws {
        let categorySets: [Set<TrackerHistorySyncCategory>] = [[.resume], [.resume, .watched]]
        for categories in categorySets {
            let oldWatch = try observation(id: "old-watch")
            let evidence = ImportEvidence(try snapshot([oldWatch]))
            let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
            let provider = ImportProvider(.mediaShare, item: item(position: 100))
            let sync = syncController(provider: provider, evidence: evidence, store: store)
            await enable(sync, evidence: evidence, categories: categories)
            try restoreLegacySkip(sync, store: store)
            await sync.synchronize()
            var writes = await provider.writes
            XCTAssertEqual(writes, 0, "Enrollment must not backfill the old watch")

            evidence.snapshot = try snapshot([
                oldWatch, observation(id: "resume", fact: .resume(seconds: 200, runtime: 1_000, updatedAt: nil))
            ])
            await sync.synchronize()
            XCTAssertEqual(sync.grant?.reviewCount, 1)
            let (manual, _) = try session(provider: provider, readSnapshot: { evidence.snapshot })
            manual.ongoingSync = sync
            await manual.compare()
            let row = try XCTUnwrap(manual.plan?.rows.first { $0.change == .resume(200) })
            XCTAssertEqual(row.comparison, .trackerConflict, "Manual review retains the full tracker history")
            await manual.apply(rowIDs: [row.id], overridingConflicts: [row.id], confirmsDestructiveChanges: false)
            XCTAssertNil(manual.error)
            XCTAssertEqual(manual.outcomes[row.id], .confirmed)
            XCTAssertEqual(sync.grant?.reviewCount, 0)
            manual.cancel()

            evidence.snapshot = try snapshot([
                oldWatch, observation(id: "resume", fact: .resume(seconds: 400, runtime: 1_000, updatedAt: nil))
            ])
            let restored = syncController(provider: provider, evidence: evidence, store: store)
            await restored.synchronize()
            XCTAssertNil(restored.error)
            XCTAssertEqual(restored.confirmedCount, 1)
            XCTAssertEqual(restored.grant?.reviewCount, 0)
            let actual = try await provider.item(id: "server-item")
            XCTAssertEqual(actual.resumePosition, 400)
            XCTAssertFalse(actual.isPlayed)
            await restored.synchronize()
            writes = await provider.writes
            XCTAssertEqual(writes, 2, "The reviewed import and later resume each write only once")
            evidence.snapshot = try snapshot([oldWatch, observation(id: "completion")])
            await restored.synchronize()
            let completed = try await provider.item(id: "server-item")
            XCTAssertEqual(completed.isPlayed, categories.contains(.watched))
            XCTAssertEqual(restored.confirmedCount, categories.contains(.watched) ? 1 : 0)
            await restored.synchronize()
            writes = await provider.writes
            XCTAssertEqual(writes, categories.contains(.watched) ? 3 : 2)
        }
    }

    @MainActor
    func testOngoingSyncKeepsCompetingNewRecordsBeyondItsBatch() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(.mediaShare, item: item())
        let sync = syncController(provider: provider, evidence: evidence, store: store)
        await enable(sync, evidence: evidence, categories: [.resume, .watched])
        var observations = try (1...24).map {
            try TrackerHistoryObservation(
                recordID: String(format: "record-%02d", $0), kind: .movie,
                identities: [.external(source: "tmdb", value: String($0 + 1_000))], fact: .watched(at: nil)
            )
        }
        observations.append(try observation(
            id: "record-00", fact: .resume(seconds: 200, runtime: 1_000, updatedAt: nil)
        ))
        observations.append(try observation(id: "record-99"))
        evidence.snapshot = try snapshot(observations)
        await sync.synchronize()
        XCTAssertNil(sync.error)
        XCTAssertFalse(sync.hasMoreChanges)
        XCTAssertEqual(sync.confirmedCount, 0)
        XCTAssertEqual(sync.grant?.reviewCount, 26)
        XCTAssertEqual(sync.grant?.lastCompletedResult?.libraries?.first?.counts, [.noMatch: 24, .trackerConflict: 2])
        let writes = await provider.writes
        XCTAssertEqual(writes, 0, "The batch boundary cannot hide competing new tracker evidence")
    }

    @MainActor
    func testProvenContinuationStillDefersChangedAndUnconsentedHistory() async throws {
        let oldWatch = try observation(id: "old-watch")
        let competingHistory = try [
            [observation(id: "old-watch", fact: .watched(at: Date(timeIntervalSince1970: 123)))],
            [oldWatch, observation(id: "new-watch")]
        ]
        for history in competingHistory {
            let evidence = ImportEvidence(try snapshot([oldWatch]))
            let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
            let provider = ImportProvider(.mediaShare, item: item(position: 200))
            let sync = syncController(provider: provider, evidence: evidence, store: store)
            await enable(sync, evidence: evidence, categories: [.resume])
            evidence.snapshot = try snapshot([
                oldWatch, observation(id: "resume", fact: .resume(seconds: 200, runtime: 1_000, updatedAt: nil))
            ])
            await sync.synchronize()
            XCTAssertNil(sync.error)
            XCTAssertEqual(sync.grant?.reviewCount, 0)
            evidence.snapshot = try snapshot(history + [
                observation(id: "resume", fact: .resume(seconds: 400, runtime: 1_000, updatedAt: nil))
            ])
            await sync.synchronize()
            XCTAssertNil(sync.error)
            XCTAssertEqual(sync.confirmedCount, 0)
            XCTAssertEqual(sync.grant?.reviewCount, 1)
            let actual = try await provider.item(id: "server-item")
            XCTAssertEqual(actual.resumePosition, 200)
            let writes = await provider.writes
            XCTAssertEqual(writes, 0)
        }
    }

    @MainActor
    func testOngoingContinuationRevalidatesKnownHistoryBeforeDispatch() async throws {
        let oldWatch = try observation(id: "old-watch")
        let evidence = ImportEvidence(try snapshot([oldWatch]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(.mediaShare, item: item(position: 200))
        let sync = syncController(provider: provider, evidence: evidence, store: store)
        await enable(sync, evidence: evidence, categories: [.resume])
        evidence.snapshot = try snapshot([
            oldWatch, observation(id: "resume", fact: .resume(seconds: 200, runtime: 1_000, updatedAt: nil))
        ])
        await sync.synchronize()
        XCTAssertNil(sync.error)
        XCTAssertEqual(sync.grant?.reviewCount, 0)
        let resume = try observation(id: "resume", fact: .resume(seconds: 400, runtime: 1_000, updatedAt: nil))
        evidence.snapshot = try snapshot([oldWatch, resume])
        let changed = try snapshot([
            observation(id: "old-watch", fact: .watched(at: Date(timeIntervalSince1970: 123))), resume
        ])
        evidence.nextRead = { evidence.nextRead = { evidence.snapshot = changed } }
        await sync.synchronize()
        XCTAssertEqual(sync.error as? TrackerHistoryError, .stalePreview)
        let writes = await provider.writes
        XCTAssertEqual(writes, 0, "Continuation must not discard full dispatch-time evidence")
    }

    @MainActor
    func testManualImportCannotTransferProofToReplacementConsent() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(.mediaShare, item: item(position: 100))
        let sync = syncController(provider: provider, evidence: evidence, store: store)
        await enable(sync, evidence: evidence, categories: [.resume])
        evidence.snapshot = try snapshot([observation(fact: .resume(seconds: 200, runtime: 1_000, updatedAt: nil))])
        let replaceConsent = ImportPermission()
        replaceConsent.allowed = false
        let currentScope = sync.contextScope
        let (manual, _) = try session(provider: provider, readSnapshot: {
            if replaceConsent.allowed {
                replaceConsent.allowed = false
                await sync.enable(
                    afterReview: .init(snapshot: evidence.snapshot, serverScope: currentScope, candidates: []),
                    accountIDs: ["account"], categories: [.resume]
                )
            }
            return evidence.snapshot
        })
        manual.ongoingSync = sync
        await manual.compare()
        let row = try XCTUnwrap(manual.plan?.rows.first)
        let oldID = sync.grant?.id
        replaceConsent.allowed = true
        await manual.apply(rowIDs: [row.id], overridingConflicts: [row.id], confirmsDestructiveChanges: false)
        XCTAssertNil(manual.error)
        XCTAssertNotEqual(sync.grant?.id, oldID)
        XCTAssertEqual(manual.outcomes[row.id], .confirmed)
        evidence.snapshot = try snapshot([observation(fact: .resume(seconds: 400, runtime: 1_000, updatedAt: nil))])
        await sync.synchronize()
        let actual = try await provider.item(id: "server-item")
        XCTAssertEqual(actual.resumePosition, 200)
        XCTAssertEqual(sync.grant?.reviewCount, 1)
    }

    @MainActor
    func testContinuationReceiptStorageFailuresKeepDestinationHeld() async throws {
        for successfulWrites in 0...2 {
            let evidence = ImportEvidence(try snapshot([]))
            let secure = HistorySyncSecureStore()
            let store = try DurableLocalStateStore(secureStore: secure)
            let provider = ImportProvider(.mediaShare, item: item())
            let sync = syncController(provider: provider, evidence: evidence, store: store)
            await enable(sync, evidence: evidence, categories: [.resume])
            evidence.snapshot = try snapshot([observation(fact: .resume(seconds: 200, runtime: 1_000, updatedAt: nil))])
            await provider.onNextRead {
                await provider.onNextRead {
                    await provider.onNextRead { secure.failWrites(afterSuccessfulWrites: successfulWrites) }
                }
            }
            await sync.synchronize()
            XCTAssertEqual(sync.error as? DurableLocalStateError, .storageUnavailable)
            let actual = try await provider.item(id: "server-item")
            XCTAssertEqual(actual.resumePosition, 200)
            secure.allowWrites()
            evidence.snapshot = try snapshot([observation(fact: .resume(seconds: 400, runtime: 1_000, updatedAt: nil))])
            let restored = syncController(provider: provider, evidence: evidence, store: store)
            await restored.synchronize()
            let writes = await provider.writes
            XCTAssertEqual(writes, 1)
            XCTAssertGreaterThan(try XCTUnwrap(restored.grant).reviewCount, 0)
        }
    }

    @MainActor
    func testOngoingSyncIncompleteReadsAndFailedRevocationNeverWrite() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let secure = HistorySyncSecureStore()
        let store = try DurableLocalStateStore(secureStore: secure)
        let provider = ImportProvider(.mediaShare, item: item())
        let sync = syncController(provider: provider, evidence: evidence, store: store)
        await enable(sync, evidence: evidence)
        evidence.snapshot = try snapshot([observation()])
        evidence.failRead = true
        await sync.synchronize()
        XCTAssertEqual(sync.error as? TrackerHistoryError, .incompleteSnapshot)
        secure.failWrites()
        sync.disable()
        XCTAssertEqual(sync.error as? TrackerHistorySyncError, .revocationFailed)
        XCTAssertFalse(sync.isEnabled)
        evidence.failRead = false
        await sync.synchronize()
        XCTAssertFalse(sync.isEnabled)
        let writes = await provider.writes
        XCTAssertEqual(writes, 0)
    }

    @MainActor
    func testOneCheckProcessesLargeHistoryAcrossBothLibrariesWithoutReplayingWrites() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let accounts = [account(.mediaShare), account(.mediaShare, id: "second")]
        let scope = WatchMutationServerScope(profile: .init(id: "profile", name: "Test"), accounts: accounts)
        let items = (0..<30).map { MediaItem(id: "item-\($0)", title: "Movie \($0)", kind: .movie,
                                            providerIDs: ["Tmdb": String(1_000 + $0)]) }
        let index = IdentityIndexSnapshot(byIdentity: Dictionary(uniqueKeysWithValues: items.enumerated().map { offset, item in
            (.external(source: "tmdb", value: String(1_000 + offset)), accounts.map {
                .init(accountID: $0.id, itemID: item.id, providerKind: .mediaShare, kind: .movie)
            })
        }))
        let first = ImportProvider(.mediaShare, item: items[0], relatedItems: Array(items.dropFirst()))
        let second = ImportProvider(.mediaShare, item: items[0], relatedItems: Array(items.dropFirst()))
        let sync = syncController(provider: first, evidence: evidence, store: store, serverScope: scope, indexSnapshot: index,
                                  otherProviders: ["second": second])
        await sync.enable(afterReview: .init(snapshot: evidence.snapshot, serverScope: scope, candidates: []),
                          accountIDs: Set(accounts.map(\.id)), categories: [.watched])
        evidence.snapshot = try snapshot((0..<3_245).map {
            try TrackerHistoryObservation(
                recordID: String(format: "record-%02d", $0), kind: .movie,
                identities: [.external(source: "tmdb", value: String($0 + 1_000))], fact: .watched(at: nil)
            )
        })
        await sync.synchronize()
        XCTAssertNil(sync.error)
        XCTAssertFalse(sync.hasMoreChanges)
        XCTAssertEqual(sync.confirmedCount, 60)
        let results = try XCTUnwrap(sync.grant?.lastCompletedResult?.libraries)
        XCTAssertEqual(Set(results.map(\.accountID)), Set(accounts.map(\.id)))
        for result in results { XCTAssertEqual(result.counts, [.updated: 30, .noMatch: 3_215]) }
        await sync.synchronize()
        XCTAssertNil(sync.error)
        XCTAssertEqual(sync.confirmedCount, 0)
        for provider in [first, second] {
            let writes = await provider.writes
            XCTAssertEqual(writes, 30)
            for item in items {
                let actual = try await provider.item(id: item.id)
                XCTAssertTrue(actual.isPlayed)
            }
        }
    }

    @MainActor
    func testOngoingSyncRechecksChangedTrackerEvidenceBeforeWriting() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(.mediaShare, item: item())
        let sync = syncController(provider: provider, evidence: evidence, store: store)
        await enable(sync, evidence: evidence)
        evidence.snapshot = try snapshot([observation()])
        let changed = try snapshot([observation(fact: .watched(at: Date(timeIntervalSince1970: 123)))])
        evidence.nextRead = { evidence.nextRead = { evidence.snapshot = changed } }
        await sync.synchronize()
        XCTAssertEqual(sync.error as? TrackerHistoryError, .stalePreview)
        let writes = await provider.writes
        XCTAssertEqual(writes, 0)
        XCTAssertGreaterThan(try XCTUnwrap(sync.grant).reviewCount, 0)
    }

    @MainActor
    func testOngoingSyncRejectsSnapshotsOverTheExactObservationLimit() async throws {
        let records = try (0..<100_001).map { try observation(id: String($0)) }
        let evidence = ImportEvidence(try snapshot(records))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(.mediaShare, item: item())
        let sync = syncController(provider: provider, evidence: evidence, store: store)
        await sync.enable(
            afterReview: .init(snapshot: evidence.snapshot, serverScope: sync.contextScope, candidates: []),
            accountIDs: ["account"], categories: [.watched]
        )
        XCTAssertEqual(sync.error as? TrackerHistorySyncError, .historyTooLarge)
        XCTAssertFalse(sync.isEnabled)
        XCTAssertNil(sync.grant)
        evidence.snapshot = try snapshot(Array(records.prefix(100_000)))
        await enable(sync, evidence: evidence)
        evidence.snapshot = try snapshot(records)
        await sync.synchronize()
        XCTAssertEqual(sync.error as? TrackerHistorySyncError, .historyTooLarge)
        XCTAssertEqual(sync.grant?.lastCheckStatus, .failed)
        XCTAssertNil(sync.grant?.lastCompletedResult)
        let writes = await provider.writes
        XCTAssertEqual(writes, 0)
    }

    @MainActor
    func testOngoingEvidenceIgnoresTitleAndIdentityOrderButPreservesFacts() throws {
        let first = try TrackerHistoryObservation(
            recordID: "watch", kind: .movie,
            identities: [.external(source: "tmdb", value: "550"), .external(source: "imdb", value: "tt0137523")],
            sourceTitle: "First name", fact: .watched(at: nil)
        )
        let renamed = try TrackerHistoryObservation(
            recordID: first.recordID, kind: first.kind, identities: first.identities.reversed(),
            sourceTitle: "Renamed title", fact: first.fact
        )
        XCTAssertEqual(
            try TrackerHistorySyncController.fingerprint(first),
            try TrackerHistorySyncController.fingerprint(renamed)
        )
    }

    @MainActor
    func testAddingVerifiedEpisodeEvidenceDoesNotBackfillButNewWatchStillDelivers() async throws {
        let parent = MediaIdentity.external(source: "series-tmdb:s1e2", value: "100")
        let original = try TrackerHistoryObservation(
            recordID: "episode", kind: .episode, identities: [parent],
            season: 1, episode: 2, episodeOrdering: .tmdb, fact: .watched(at: nil)
        )
        func enriched(_ fact: TrackerHistoryObservation.Fact) throws -> TrackerHistoryObservation {
            try .init(
                recordID: original.recordID, kind: original.kind, identities: original.identities,
                season: 1, episode: 2, episodeOrdering: .tmdb,
                verifiedEpisodeIdentities: [parent, .external(source: "tmdb:s1e2", value: "200")],
                fact: fact
            )
        }
        let episode = MediaItem(
            id: "server-item", title: "Episode", kind: .episode, seasonNumber: 1, episodeNumber: 2,
            providerIDs: ["Tmdb": "200", "SeriesTmdb": "100"], sourceAccountID: "account"
        )
        let provider = ImportProvider(.mediaShare, item: episode)
        let evidence = ImportEvidence(try snapshot([original]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let index = IdentityIndexSnapshot(byIdentity: [
            parent: [.init(accountID: "account", itemID: episode.id, providerKind: provider.kind, kind: .episode)]
        ])
        let sync = syncController(provider: provider, evidence: evidence, store: store, indexSnapshot: index)
        await enable(sync, evidence: evidence)
        try restoreLegacySkip(sync, store: store)
        evidence.snapshot = try snapshot([enriched(original.fact)])
        await sync.synchronize()
        XCTAssertNil(sync.error)
        let before = await provider.writes
        XCTAssertEqual(before, 0)
        evidence.snapshot = try snapshot([enriched(.watched(at: Date(timeIntervalSince1970: 123)))])
        await sync.synchronize()
        XCTAssertNil(sync.error)
        let after = await provider.writes
        XCTAssertEqual(after, 1)
        await sync.synchronize()
        let repeated = await provider.writes
        XCTAssertEqual(repeated, 1)
    }
}

@MainActor private final class ImportEvidence {
    var snapshot: TrackerHistorySnapshot
    var failRead = false
    var nextRead: (@MainActor () -> Void)?
    init(_ snapshot: TrackerHistorySnapshot) { self.snapshot = snapshot }
}

private final class ImportOwner: Sendable {}

@MainActor private final class ImportPermission { var allowed = true }

private actor ImportProvider: MediaProvider, WatchStateProviding, ResumeStateWriting {
    let kind: ProviderKind
    let session: UserSession
    private var current: MediaItem
    private var relatedItems: [String: MediaItem]
    private let losesWriteReply: Bool
    private let failsReadback: Bool
    private var nextRead: (@Sendable () async -> Void)?
    private(set) var writes = 0
    private(set) var itemReads: [String: Int] = [:]
    init(
        _ kind: ProviderKind = .jellyfin,
        item: MediaItem = MediaItem(id: "server-item", title: "Movie", kind: .movie),
        losesWriteReply: Bool = false, failsReadback: Bool = false, relatedItems: [MediaItem] = []
    ) {
        self.kind = kind
        session = UserSession(
            server: .init(id: "server", name: "Server", baseURL: URL(string: "https://example.test")!, provider: kind),
            userID: "viewer", userName: "Viewer", deviceID: "device", accessToken: ""
        )
        current = item
        self.relatedItems = Dictionary(uniqueKeysWithValues: relatedItems.map { ($0.id, $0) })
        self.losesWriteReply = losesWriteReply
        self.failsReadback = failsReadback
    }
    func replace(item: MediaItem) {
        if item.id == current.id { current = item }
        else { relatedItems[item.id] = item }
    }
    func onNextRead(_ action: @escaping @Sendable () async -> Void) { nextRead = action }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem {
        itemReads[id, default: 0] += 1
        guard id == current.id || relatedItems[id] != nil else { throw AppError.notFound }
        if failsReadback && writes > 0 { throw AppError.serverUnreachable }
        let action = nextRead
        nextRead = nil
        await action?()
        if id == current.id { return current }
        guard let item = relatedItems[id] else { throw AppError.notFound }
        return item
    }
    func children(of itemID: String) async throws -> [MediaItem] {
        guard relatedItems[itemID]?.kind == .series else { throw AppError.notFound }
        return ([current] + Array(relatedItems.values)).filter { $0.kind == .episode && $0.seriesID == itemID }
    }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        throw AppError.notFound
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
    func setPlayed(_ played: Bool, itemID: String) async throws {
        if itemID == current.id { current.isPlayed = played }
        else { relatedItems[itemID]?.isPlayed = played }
        writes += 1
        if losesWriteReply { throw AppError.serverUnreachable }
    }
    func setResumePosition(_ seconds: TimeInterval, itemID: String, capturedAt: Date) async throws {
        if itemID == current.id { current.resumePosition = seconds }
        else { relatedItems[itemID]?.resumePosition = seconds }
        writes += 1
        if losesWriteReply { throw AppError.serverUnreachable }
    }
}

private final class HistorySyncSecureStore: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var writesBeforeFailure: Int?
    func failWrites(afterSuccessfulWrites count: Int = 0) {
        lock.lock(); defer { lock.unlock() }; writesBeforeFailure = count
    }
    func allowWrites() { lock.lock(); defer { lock.unlock() }; writesBeforeFailure = nil }
    func setString(_ value: String, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let remaining = writesBeforeFailure {
            guard remaining > 0 else { throw DurableLocalStateError.storageUnavailable }
            writesBeforeFailure = remaining - 1
        }
        values[key] = value
    }
    func string(for key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func readString(for key: String) throws -> String? { string(for: key) }
    func removeValue(for key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = nil }
}

private struct ImportApplier: WatchMutationAuthorizationEnforcing {
    let provider: ImportProvider
    var otherProviders: [String: ImportProvider] = [:]
    func requireServerScope(_ scope: WatchMutationServerScope) async throws {}
    func setPlayed(_ played: Bool, on target: WatchMutationTarget) async throws {
        let provider = otherProviders[target.accountID] ?? self.provider
        try await WatchMutationDeliveryAuthorization.checkSourcePrecondition(provider: provider, target: target)
        try await provider.setPlayed(played, itemID: target.itemID)
        try await WatchMutationDeliveryAuthorization.check()
    }

    func setResumePosition(_ seconds: TimeInterval, on target: WatchMutationTarget, capturedAt: Date) async throws {
        let provider = otherProviders[target.accountID] ?? self.provider
        try await WatchMutationDeliveryAuthorization.checkSourcePrecondition(provider: provider, target: target)
        try await provider.setResumePosition(seconds, itemID: target.itemID, capturedAt: capturedAt)
        try await WatchMutationDeliveryAuthorization.check()
    }
    func scrobbleTrakt(_ intent: TraktScrobbleIntent) async throws { throw AppError.invalidResponse }
}
