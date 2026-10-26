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

    @MainActor
    private func syncController(
        provider: ImportProvider, evidence: ImportEvidence, store: DurableLocalStateStore,
        permission: ImportPermission? = nil, connection: String = "connection",
        serverScope: WatchMutationServerScope? = nil, reconciler existingReconciler: WatchStateReconciler? = nil,
        supportedCategories: Set<TrackerHistorySyncCategory> = [.watched, .resume],
        allowsForegroundChecks: Bool = true
    ) -> TrackerHistorySyncController {
        let scope = serverScope ?? self.scope()
        let permission = permission ?? ImportPermission()
        let index = IdentityIndexSnapshot(byIdentity: [
            .external(source: "tmdb", value: "550"): [
                .init(accountID: "account", itemID: "server-item", providerKind: .jellyfin, kind: .movie)
            ]
        ])
        let reconciler = existingReconciler ?? WatchStateReconciler(
            store: InMemoryWatchMutationStore(), applier: ImportApplier(provider: provider)
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
                    index: { index }, resolveProvider: { _ in provider },
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
        let plan = TrackerHistoryImportPlan(snapshot: evidence.snapshot, serverScope: scope(), candidates: [])
        await sync.enable(afterReview: plan, accountIDs: ["account"], categories: categories)
        XCTAssertNil(sync.error)
        XCTAssertTrue(sync.isEnabled)
    }

    @MainActor
    func testOngoingSyncRejectsUnsupportedCategoriesAndOldBroaderGrants() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(item: item())
        let sync = syncController(
            provider: provider, evidence: evidence, store: store, supportedCategories: [.watched]
        )
        let reviewed = TrackerHistoryImportPlan(snapshot: evidence.snapshot, serverScope: scope(), candidates: [])
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
            provider: ImportProvider(item: item()), evidence: evidence, store: store, allowsForegroundChecks: false
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
        let provider = ImportProvider(item: item())
        let sync = syncController(provider: provider, evidence: evidence, store: store)
        await enable(sync, evidence: evidence)
        try TrackerHistorySyncController.revokePermission(
            store: store, profileID: scope().profileID, trackerID: "test-tracker"
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
            let provider = ImportProvider(item: item())
            let sync = syncController(provider: provider, evidence: evidence, store: store)
            await enable(sync, evidence: evidence)
            evidence.snapshot = try snapshot([movie(.completed, edited: true)])
            await sync.synchronize()
            XCTAssertNil(sync.error)
            let writes = await provider.writes
            XCTAssertEqual(writes, initiallyCompleted ? 0 : 1)
        }
    }

    @MainActor
    func testOngoingSyncDoesNotBackfillReviewedHistoryOrReplayAfterRestart() async throws {
        let evidence = ImportEvidence(try snapshot([observation()]))
        let secure = HistorySyncSecureStore()
        let store = try DurableLocalStateStore(secureStore: secure)
        let provider = ImportProvider(item: item())
        let sync = syncController(provider: provider, evidence: evidence, store: store)
        await enable(sync, evidence: evidence)
        await sync.synchronize()
        var writes = await provider.writes
        XCTAssertEqual(writes, 0)
        evidence.snapshot = try snapshot([observation(), observation(id: "new-play")])
        await sync.synchronize()
        XCTAssertNil(sync.error)
        XCTAssertEqual(sync.confirmedCount, 1)
        writes = await provider.writes
        XCTAssertEqual(writes, 1)
        await provider.replace(item: item())
        let restored = syncController(
            provider: provider, evidence: evidence, store: try DurableLocalStateStore(secureStore: secure)
        )
        await restored.synchronize()
        writes = await provider.writes
        XCTAssertEqual(writes, 1, "A server-side reset must not resurrect previously imported history")
        XCTAssertTrue(restored.isEnabled)
    }

    @MainActor
    func testOngoingSyncKeepsUncertainTargetsBlockedAcrossRestartAndNewRecords() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(item: item(), losesWriteReply: true, failsReadback: true)
        let sync = syncController(provider: provider, evidence: evidence, store: store)
        await enable(sync, evidence: evidence)
        evidence.snapshot = try snapshot([observation()])
        await sync.synchronize()
        XCTAssertNotNil(sync.error)
        let initialWrites = await provider.writes
        XCTAssertEqual(initialWrites, 1)
        let recoveredProvider = ImportProvider(item: item())
        let restored = syncController(provider: recoveredProvider, evidence: evidence, store: store)
        await restored.synchronize()
        evidence.snapshot = try snapshot([observation(), observation(id: "another-record")])
        await restored.synchronize()
        let retryWrites = await recoveredProvider.writes
        XCTAssertEqual(retryWrites, 0)
        XCTAssertGreaterThan(try XCTUnwrap(restored.grant).reviewCount, 0)
    }

    @MainActor
    func testOngoingSyncConnectionServerUserAndProfileChangesRequireNewConsent() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(item: item())
        let sync = syncController(provider: provider, evidence: evidence, store: store)
        await enable(sync, evidence: evidence)
        let otherProfile = WatchMutationServerScope(
            profile: .init(id: "another-profile", name: "Another"), accounts: [account()]
        )
        for (connection, scope) in [
            ("reconnected", scope()), ("connection", scope(userID: "another-viewer")), ("connection", otherProfile)
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
        let provider = ImportProvider(item: item())
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
        let provider = ImportProvider(item: item())
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
        let provider = ImportProvider(item: item())
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
        let provider = ImportProvider(item: item(position: 100))
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
    func testOngoingSyncEnrollmentRejectsChangedReviewAndEmptySelections() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(item: item())
        let sync = syncController(provider: provider, evidence: evidence, store: store)
        let plan = TrackerHistoryImportPlan(snapshot: evidence.snapshot, serverScope: scope(), candidates: [])
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
    func testOngoingSyncDefersLivePlaybackWithFullViewerScopeAndSelectedServerGrant() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(item: item())
        let fullScope = WatchMutationServerScope(
            profile: .init(id: "profile", name: "Test"), accounts: [account(), account(.plex, id: "plex")]
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
    func testOngoingSyncImportsOnlyCompatibleResumeAndKeepsLaterServerConflict() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(item: item())
        let sync = syncController(provider: provider, evidence: evidence, store: store)
        await enable(sync, evidence: evidence, categories: [.resume])
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
        await sync.synchronize()
        server = try await provider.item(id: "server-item")
        XCTAssertEqual(server.resumePosition, 200)
        XCTAssertGreaterThan(try XCTUnwrap(sync.grant).reviewCount, 0)
    }

    @MainActor
    func testOngoingSyncIncompleteReadsAndFailedRevocationNeverWrite() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let secure = HistorySyncSecureStore()
        let store = try DurableLocalStateStore(secureStore: secure)
        let provider = ImportProvider(item: item())
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
    func testOngoingSyncBoundsNewRecordsWithoutDroppingTheRemainder() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(item: item())
        let sync = syncController(provider: provider, evidence: evidence, store: store)
        await enable(sync, evidence: evidence)
        evidence.snapshot = try snapshot((0..<26).map {
            try TrackerHistoryObservation(
                recordID: String(format: "record-%02d", $0), kind: .movie,
                identities: [.external(source: "tmdb", value: String($0 + 1_000))], fact: .watched(at: nil)
            )
        })
        await sync.synchronize()
        XCTAssertNil(sync.error)
        XCTAssertTrue(sync.hasMoreChanges)
        XCTAssertEqual(sync.grant?.reviewCount, 25)
        await sync.synchronize()
        XCTAssertFalse(sync.hasMoreChanges)
        XCTAssertEqual(sync.grant?.reviewCount, 26)
        let writes = await provider.writes
        XCTAssertEqual(writes, 0)
    }

    @MainActor
    func testOngoingSyncRechecksChangedTrackerEvidenceBeforeWriting() async throws {
        let evidence = ImportEvidence(try snapshot([]))
        let store = try DurableLocalStateStore(secureStore: HistorySyncSecureStore())
        let provider = ImportProvider(item: item())
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
        let provider = ImportProvider(item: item())
        let sync = syncController(provider: provider, evidence: evidence, store: store)
        await sync.enable(
            afterReview: .init(snapshot: evidence.snapshot, serverScope: scope(), candidates: []),
            accountIDs: ["account"], categories: [.watched]
        )
        XCTAssertEqual(sync.error as? TrackerHistorySyncError, .historyTooLarge)
        XCTAssertFalse(sync.isEnabled)
        XCTAssertNil(sync.grant)
        evidence.snapshot = try snapshot(Array(records.prefix(100_000)))
        await enable(sync, evidence: evidence)
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
    func setResumePosition(_ seconds: TimeInterval, itemID: String, capturedAt: Date) async throws {
        current.resumePosition = seconds
        writes += 1
        if losesWriteReply { throw AppError.serverUnreachable }
    }
}

private final class HistorySyncSecureStore: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var shouldFailWrites = false
    func failWrites() { lock.lock(); defer { lock.unlock() }; shouldFailWrites = true }
    func setString(_ value: String, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        if shouldFailWrites { throw DurableLocalStateError.storageUnavailable }
        values[key] = value
    }
    func string(for key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func readString(for key: String) throws -> String? { string(for: key) }
    func removeValue(for key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = nil }
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
        try await WatchMutationDeliveryAuthorization.checkSourcePrecondition(provider: provider, target: target)
        try await provider.setResumePosition(seconds, itemID: target.itemID, capturedAt: capturedAt)
        try await WatchMutationDeliveryAuthorization.check()
    }
    func scrobbleTrakt(_ intent: TraktScrobbleIntent) async throws { throw AppError.invalidResponse }
}
