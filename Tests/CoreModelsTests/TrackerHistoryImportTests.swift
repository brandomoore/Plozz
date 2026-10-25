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
                .init(accountID: "account", itemID: "server-item", providerKind: .jellyfin, kind: .movie)
            ]
        ])
        let reconciler = WatchStateReconciler(
            store: InMemoryWatchMutationStore(), applier: ImportApplier(provider: provider)
        )
        return (
            TrackerHistoryImportSession(
                scope: scope(), destinations: [], reconciler: reconciler,
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
}

@MainActor private final class ImportEvidence {
    var snapshot: TrackerHistorySnapshot
    var failRead = false
    init(_ snapshot: TrackerHistorySnapshot) { self.snapshot = snapshot }
}

private final class ImportOwner: Sendable {}

@MainActor private final class ImportPermission { var allowed = true }

private actor ImportProvider: MediaProvider, WatchStateProviding {
    let kind: ProviderKind = .jellyfin
    let session = UserSession(
        server: MediaServer(
            id: "server", name: "Server", baseURL: URL(string: "https://example.test")!, provider: .jellyfin
        ),
        userID: "viewer", userName: "Viewer", deviceID: "device", accessToken: ""
    )
    private var current: MediaItem
    private let losesWriteReply: Bool
    private let failsReadback: Bool
    private var nextRead: (@Sendable () async -> Void)?
    private(set) var writes = 0
    init(
        item: MediaItem = MediaItem(id: "server-item", title: "Movie", kind: .movie),
        losesWriteReply: Bool = false, failsReadback: Bool = false
    ) {
        current = item
        self.losesWriteReply = losesWriteReply
        self.failsReadback = failsReadback
    }
    func replace(item: MediaItem) { current = item }
    func onNextRead(_ action: @escaping @Sendable () async -> Void) { nextRead = action }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem {
        guard id == current.id else { throw AppError.notFound }
        if failsReadback && writes > 0 { throw AppError.serverUnreachable }
        let action = nextRead
        nextRead = nil
        await action?()
        return current
    }
    func children(of itemID: String) async throws -> [MediaItem] { throw AppError.notFound }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        throw AppError.notFound
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
    func setPlayed(_ played: Bool, itemID: String) async throws {
        current.isPlayed = played
        writes += 1
        if losesWriteReply { throw AppError.serverUnreachable }
    }
}

private struct ImportApplier: WatchMutationAuthorizationEnforcing {
    let provider: ImportProvider
    func requireServerScope(_ scope: WatchMutationServerScope) async throws {}
    func setPlayed(_ played: Bool, on target: WatchMutationTarget) async throws {
        try await WatchMutationDeliveryAuthorization.checkSourcePrecondition(provider: provider, target: target)
        try await provider.setPlayed(played, itemID: target.itemID)
        try await WatchMutationDeliveryAuthorization.check()
    }
    func setResumePosition(_ seconds: TimeInterval, on target: WatchMutationTarget, capturedAt: Date) async throws {
        throw AppError.invalidResponse
    }
    func scrobbleTrakt(_ intent: TraktScrobbleIntent) async throws { throw AppError.invalidResponse }
}
