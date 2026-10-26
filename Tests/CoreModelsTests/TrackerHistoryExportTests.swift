import Foundation
import XCTest
@testable import CoreModels

@MainActor
final class TrackerHistoryExportTests: XCTestCase {
    private let library = MediaLibrary(id: "library", title: "Movies", kind: .movie)

    private func movie(id: String = "movie", externalID: String = "550") -> MediaItem {
        .init(id: id, title: "Movie", kind: .movie, isPlayed: true, providerIDs: ["Tmdb": externalID])
    }

    private func preview(_ session: TrackerHistoryExportSession<String>) async {
        await session.compare(accountID: "account", library: library)
    }

    private func apply(_ session: TrackerHistoryExportSession<String>, confirmed: Bool = true) async {
        await session.apply(rowIDs: Set(session.rows.map(\.id)), confirmed: confirmed)
    }

    func testPreviewAndUnconfirmedSelectionNeverWrite() async throws {
        for kind in [ProviderKind.plex, .jellyfin] {
            let fixture = try ExportFixture(items: [movie()], kind: kind)
            let session = fixture.session()
            await preview(session)
            XCTAssertNil(session.error)
            XCTAssertEqual(session.rows.map(\.status), [.ready])
            XCTAssertEqual(fixture.writes, 0)
            await apply(session, confirmed: false)
            XCTAssertEqual(session.error as? TrackerHistoryError, .invalidSelection)
            XCTAssertEqual(fixture.writes, 0)
            await apply(session)
            XCTAssertNil(session.error)
            XCTAssertEqual(fixture.writes, 1)
            let writes = await fixture.provider.playbackWrites
            XCTAssertEqual(writes, 0)
        }
    }

    func testKnownUnknownAndUnfinishedRewatchDatesStayFaithful() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for (sourceDate, resume) in [(date, Optional<Double>.none), (date, 250), (nil, nil)] {
            var item = movie()
            item.lastPlayedAt = sourceDate
            item.resumePosition = resume
            let fixture = try ExportFixture(items: [item])
            let session = fixture.session()
            await preview(session)
            let expected = resume == nil ? sourceDate : nil
            XCTAssertEqual(session.rows.first?.watchDate, expected)
            await apply(session)
            XCTAssertNil(session.error)
            XCTAssertEqual(fixture.dates, [expected])
            if case .confirmed? = session.outcomes.values.first {} else { XCTFail("Watch was not confirmed") }
        }
    }

    func testStatusOnlyAdapterDoesNotPromiseOrSendOriginalDates() async throws {
        var item = movie()
        item.lastPlayedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let fixture = try ExportFixture(items: [item])
        let session = fixture.session(preservesDates: false)
        await preview(session)
        XCTAssertNil(session.rows.first?.watchDate)
        await apply(session)
        XCTAssertEqual(fixture.dates, [nil])
    }

    func testExistingWatchAndConflictingProgressAreNeverExported() async throws {
        for fact in [
            TrackerHistoryObservation.Fact.watched(at: nil),
            .resume(seconds: 200, runtime: 1_000, updatedAt: nil)
        ] {
            let fixture = try ExportFixture(items: [movie()])
            fixture.observations = [try fixture.observation(fact: fact)]
            let session = fixture.session()
            await preview(session)
            XCTAssertNotEqual(session.rows.first?.status, .ready)
            await apply(session)
            XCTAssertEqual(fixture.writes, 0)
        }
    }

    func testExistingListStatesAreConflictsNotMissingOrCompletedWatches() async throws {
        for state in TrackerHistoryListState.allCases {
            let fixture = try ExportFixture(items: [movie()])
            fixture.observations = [try fixture.observation(fact: .listState(state))]
            let session = fixture.session()
            await preview(session)
            XCTAssertNil(session.error)
            XCTAssertEqual(session.rows.first?.status, .conflict)
            await apply(session)
            XCTAssertEqual(session.error as? TrackerHistoryError, .invalidSelection)
            XCTAssertEqual(fixture.writes, 0)
        }
    }

    func testParentListStatesProtectEpisodesWithExactParentIDs() async throws {
        let item = MediaItem(
            id: "episode", title: "Episode", kind: .episode,
            seasonNumber: 1, episodeNumber: 2, isPlayed: true,
            providerIDs: ["Tvdb": "200", "SeriesTvdb": "100", "SeriesImdb": "tt123"]
        )
        for state in TrackerHistoryListState.allCases {
            let protected = [.planning, .paused, .dropped].contains(state)
            let fixture = try ExportFixture(items: [item], libraryKind: .series)
            let parent = try TrackerHistoryObservation(
                recordID: "parent/state", kind: .series,
                identities: [.external(source: "tvdb", value: "100"), .external(source: "imdb", value: "tt123")],
                fact: .listState(state)
            )
            XCTAssertFalse(parent.matches(item), "Parent state must never become an episode import")
            XCTAssertEqual(parent.matchesHistoryExport(item), protected)
            fixture.observations = [parent]
            let session = fixture.session()
            await session.compare(accountID: "account", library: .init(id: "library", title: "Shows", kind: .series))
            XCTAssertNil(session.error, "Multiple parent IDs must not duplicate one observation")
            XCTAssertEqual(session.rows.first?.status, protected ? .conflict : .ready)
            if protected { await apply(session) }
            XCTAssertEqual(fixture.writes, 0)
        }
    }

    func testParentProtectionDoesNotGuessFromEpisodeIDsTitlesOrContradictoryParents() throws {
        let parent = try TrackerHistoryObservation(
            recordID: "parent/state", kind: .series,
            identities: [.external(source: "tvdb", value: "100"), .external(source: "imdb", value: "tt123")],
            sourceTitle: "Shared title", fact: .listState(.paused)
        )
        for ids in [
            ["Tvdb": "100"],
            ["SeriesTvdb": "999"],
            ["SeriesTvdb": "100", "SeriesImdb": "tt456"],
            [:]
        ] {
            let item = MediaItem(
                id: "episode", title: "Shared title", kind: .episode,
                seasonNumber: 1, episodeNumber: 2, providerIDs: ids
            )
            XCTAssertFalse(parent.matchesHistoryExport(item))
        }
    }

    func testOtherSeriesEvidenceNeverBecomesParentListProtection() async throws {
        let item = MediaItem(
            id: "episode", title: "Episode", kind: .episode,
            seasonNumber: 1, episodeNumber: 2, isPlayed: true, providerIDs: ["Tvdb": "200", "SeriesTvdb": "100"]
        )
        for fact in [
            TrackerHistoryObservation.Fact.watched(at: nil),
            .episodeCount(watched: 12, repeats: nil),
            .resumePercentage(percent: 50, updatedAt: nil)
        ] {
            let fixture = try ExportFixture(items: [item], libraryKind: .series)
            fixture.observations = [try .init(
                recordID: "parent", kind: .series, identities: [.external(source: "tvdb", value: "100")], fact: fact
            )]
            let session = fixture.session()
            await session.compare(accountID: "account", library: .init(id: "library", title: "Shows", kind: .series))
            XCTAssertNil(session.error)
            XCTAssertEqual(session.rows.first?.status, .ready)
            XCTAssertEqual(fixture.writes, 0)
        }
    }

    func testUnsupportedIdentityAndFutureDatesStayUnselectable() async throws {
        for supported in [false, true] {
            var item = movie()
            if supported { item.lastPlayedAt = Date().addingTimeInterval(600) }
            let fixture = try ExportFixture(items: [item])
            fixture.supported = supported
            let session = fixture.session()
            await preview(session)
            XCTAssertEqual(session.rows.first?.status, .unsupported)
            await apply(session)
            XCTAssertEqual(fixture.writes, 0)
        }
    }

    func testDuplicateSourceIdentitiesAndResolvedTargetsBlockWholeBatch() async throws {
        for duplicateSource in [false, true] {
            let fixture = try ExportFixture(items: [
                movie(), movie(id: "second", externalID: duplicateSource ? "550" : "551")
            ])
            fixture.resolvedTarget = "550"
            let session = fixture.session()
            await preview(session)
            if duplicateSource { XCTAssertEqual(session.rows.map(\.status), [.ambiguous, .ambiguous]) }
            await apply(session)
            XCTAssertEqual(fixture.writes, 0)
            XCTAssertEqual(session.error as? TrackerHistoryError, .invalidSelection)
        }
    }

    func testForeignSnapshotConnectionIsRejected() async throws {
        let fixture = try ExportFixture(items: [movie()])
        fixture.snapshotConnectionID = "another-connection"
        let session = fixture.session()
        await preview(session)
        XCTAssertEqual(session.error as? TrackerHistoryError, .scopeChanged)
        XCTAssertFalse(session.hasCompared)
        XCTAssertEqual(fixture.writes, 0)
    }

    func testChangedServerTrackerAndConnectionFenceDelivery() async throws {
        for change in 0..<3 {
            let fixture = try ExportFixture(items: [movie()])
            let session = fixture.session()
            await preview(session)
            switch change {
            case 0:
                var changed = movie()
                changed.isPlayed = false
                await fixture.provider.replace([changed])
            case 1: fixture.observations = [try fixture.observation()]
            default: fixture.connected = false
            }
            await apply(session)
            XCTAssertNotNil(session.error)
            XCTAssertEqual(fixture.writes, 0)
        }
    }

    func testCurrentPlaybackOnEitherSideBlocksExport() async throws {
        for remote in [false, true] {
            let fixture = try ExportFixture(items: [movie()])
            let session = fixture.session()
            await preview(session)
            if remote { fixture.trackerPlaying = true }
            else { fixture.serverPlaying = true }
            await apply(session)
            XCTAssertEqual(session.error as? AppError, .conflict)
            XCTAssertEqual(fixture.writes, 0)
        }
    }

    func testWriteTimeAuthorizationAndCancellationAreChecked() async throws {
        for cancellation in [false, true] {
            let fixture = try ExportFixture(items: [movie()])
            let session = fixture.session()
            await preview(session)
            fixture.beforeWrite = {
                if cancellation { session.cancel() }
                else { fixture.authorized = false }
            }
            await apply(session)
            XCTAssertEqual(fixture.writes, 0)
            fixture.beforeWrite = nil
            fixture.authorized = true
            let reopened = fixture.session()
            await preview(reopened)
            await apply(reopened)
            XCTAssertNil(reopened.error)
            XCTAssertEqual(fixture.writes, 1)
        }
    }

    func testReceiptPersistenceAtTheFinalAuthorizationBoundaryPreventsDispatch() async throws {
        let fixture = try ExportFixture(items: [movie()])
        let session = fixture.session()
        await preview(session)
        fixture.beforeTargetRead = {
            if fixture.targetReads == 3 { fixture.secureStore.setFailsWrites(true) }
        }
        await apply(session)
        XCTAssertEqual(session.error as? DurableLocalStateError, .storageUnavailable)
        XCTAssertEqual(fixture.writes, 0)
    }

    func testCompetingSessionReceiptDuringAuthorizationIsNotOverwrittenOrRemoved() async throws {
        let store = HistoryExportSecureStore()
        let first = try ExportFixture(items: [movie()], secureStore: store)
        let second = try ExportFixture(items: [movie()], secureStore: store)
        second.failure = .uncertain
        let firstSession = first.session()
        let secondSession = second.session()
        await preview(firstSession)
        await preview(secondSession)
        first.beforeTargetRead = {
            if first.targetReads == 3 { await self.apply(secondSession) }
        }
        await apply(firstSession)
        XCTAssertEqual(firstSession.error as? TrackerHistoryExportError, .previousAttempt)
        XCTAssertEqual(first.writes, 0)
        XCTAssertEqual(second.writes, 1)
        first.beforeTargetRead = nil
        let reopened = first.session()
        await preview(reopened)
        await apply(reopened)
        XCTAssertEqual(reopened.error as? TrackerHistoryExportError, .previousAttempt)
        XCTAssertEqual(first.writes, 0)
    }

    func testReceiptPersistenceFailurePreventsDispatch() async throws {
        let fixture = try ExportFixture(items: [movie()])
        let session = fixture.session()
        await preview(session)
        fixture.secureStore.setFailsWrites(true)
        await apply(session)
        XCTAssertEqual(session.error as? DurableLocalStateError, .storageUnavailable)
        XCTAssertEqual(fixture.writes, 0)
    }

    func testUnknownDeliveryNeverReplaysAfterRecreatingSession() async throws {
        for failure in [ExportFixture.Failure.uncertain, .unexpected] {
            let fixture = try ExportFixture(items: [movie()])
            fixture.failure = failure
            var session = fixture.session()
            await preview(session)
            await apply(session)
            XCTAssertNotNil(session.error)
            XCTAssertEqual(fixture.writes, 1)
            fixture.failure = .none
            session = fixture.session()
            await preview(session)
            await apply(session)
            XCTAssertEqual(session.error as? TrackerHistoryExportError, .previousAttempt)
            XCTAssertEqual(fixture.writes, 1)
        }
    }

    func testLostAcknowledgmentCanConfirmPresenceWithoutClaimingOurWrite() async throws {
        let fixture = try ExportFixture(items: [movie()])
        fixture.failure = .appliedWithoutReply
        let session = fixture.session()
        await preview(session)
        await apply(session)
        XCTAssertNil(session.error)
        if case .alreadyPresent? = session.outcomes.values.first {} else { XCTFail("Unknown author was claimed") }
        XCTAssertEqual(fixture.writes, 1)
    }

    func testDefiniteRefusalPermitsOnlyANewExplicitAttempt() async throws {
        let fixture = try ExportFixture(items: [movie()])
        fixture.failure = .refused
        let session = fixture.session()
        await preview(session)
        await apply(session)
        XCTAssertEqual(session.error as? AppError, .unauthorized)
        fixture.failure = .none
        await apply(session)
        XCTAssertEqual(fixture.writes, 1)
        await preview(session)
        await apply(session)
        XCTAssertNil(session.error)
        XCTAssertEqual(fixture.writes, 2)
        XCTAssertEqual(Set(fixture.idempotencyKeys).count, 2)
    }

    func testDifferentReadbackDateDoesNotClaimFaithfulDateDelivery() async throws {
        var item = movie()
        item.lastPlayedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let fixture = try ExportFixture(items: [item])
        fixture.returnedDate = item.lastPlayedAt?.addingTimeInterval(60)
        let session = fixture.session()
        await preview(session)
        await apply(session)
        XCTAssertNil(session.error)
        if case .alreadyPresent? = session.outcomes.values.first {} else { XCTFail("Different date was claimed") }
    }

    func testFiftyTitlesAreAllowedButFiftyOneNeverPartiallyWrites() async throws {
        for count in [50, 51] {
            let fixture = try ExportFixture(items: (1...count).map {
                movie(id: "movie-\($0)", externalID: String($0))
            })
            let session = fixture.session()
            await preview(session)
            XCTAssertEqual(session.rows.count, count)
            await apply(session)
            XCTAssertEqual(fixture.writes, count == 50 ? 50 : 0)
            if count == 50 { XCTAssertNil(session.error) }
            else { XCTAssertEqual(session.error as? TrackerHistoryError, .invalidSelection) }
        }
    }

    func testPartialBatchStopsAndNeverReplaysEarlierDeliveries() async throws {
        let fixture = try ExportFixture(items: (1...3).map {
            movie(id: "movie-\($0)", externalID: String($0))
        })
        fixture.beforeWrite = { if fixture.writes == 1 { fixture.failure = .uncertain } }
        let session = fixture.session()
        await preview(session)
        let ids = session.rows.map(\.id)
        await apply(session)
        XCTAssertEqual(fixture.writes, 2)
        if case .confirmed? = session.outcomes[ids[0]] {} else { XCTFail("First delivery lost") }
        if case .unconfirmed? = session.outcomes[ids[1]] {} else { XCTFail("Uncertainty lost") }
        XCTAssertNil(session.outcomes[ids[2]])
        await apply(session)
        XCTAssertEqual(fixture.writes, 2)
        fixture.beforeWrite = nil
        fixture.failure = .none
        let reopened = fixture.session()
        await preview(reopened)
        XCTAssertEqual(reopened.rows.first?.status, .alreadyMatches)
        await reopened.apply(rowIDs: [reopened.rows[1].id], confirmed: true)
        XCTAssertEqual(reopened.error as? TrackerHistoryExportError, .previousAttempt)
        XCTAssertEqual(fixture.writes, 2)
        await preview(reopened)
        await reopened.apply(rowIDs: [reopened.rows[2].id], confirmed: true)
        XCTAssertNil(reopened.error)
        XCTAssertEqual(fixture.writes, 3)
    }

    func testFailedReadbackRetainsReceiptAcrossRestart() async throws {
        let fixture = try ExportFixture(items: [movie()])
        fixture.failReadback = true
        let session = fixture.session()
        await preview(session)
        await apply(session)
        XCTAssertEqual(session.error as? AppError, .serverUnreachable)
        XCTAssertEqual(fixture.writes, 1)
        fixture.failReadback = false
        fixture.observations = []
        let reopened = fixture.session()
        await preview(reopened)
        await apply(reopened)
        XCTAssertEqual(reopened.error as? TrackerHistoryExportError, .previousAttempt)
        XCTAssertEqual(fixture.writes, 1)
    }

    func testRemovedConfirmedWatchIsNotRecreated() async throws {
        let fixture = try ExportFixture(items: [movie()])
        let session = fixture.session()
        await preview(session)
        await apply(session)
        XCTAssertNil(session.error)
        fixture.observations = []
        let reopened = fixture.session()
        await preview(reopened)
        await apply(reopened)
        XCTAssertEqual(reopened.error as? TrackerHistoryExportError, .previousAttempt)
        XCTAssertEqual(fixture.writes, 1)
    }

    func testReceiptScopesSeparateProfilesTrackersAndConnections() async throws {
        for dimension in 0..<3 {
            let secureStore = HistoryExportSecureStore()
            let first = try ExportFixture(items: [movie()], secureStore: secureStore)
            first.failure = .uncertain
            let firstSession = first.session()
            await preview(firstSession)
            await apply(firstSession)
            let second = try ExportFixture(
                items: [movie()], profileID: dimension == 0 ? "other-profile" : "profile",
                secureStore: secureStore
            )
            let session = second.session(
                trackerID: dimension == 1 ? "other-tracker" : "fixture",
                connectionID: dimension == 2 ? "other-connection" : "durable"
            )
            await preview(session)
            await apply(session)
            XCTAssertNil(session.error)
            XCTAssertEqual(second.writes, 1)
        }
    }

    func testTrackerChangeDuringWriteAuthorizationPreventsDispatch() async throws {
        let fixture = try ExportFixture(items: [movie()])
        let session = fixture.session()
        await preview(session)
        let changed = try fixture.observation()
        fixture.beforeWrite = { fixture.observations = [changed] }
        await apply(session)
        XCTAssertEqual(session.error as? TrackerHistoryError, .stalePreview)
        XCTAssertEqual(fixture.writes, 0)
        fixture.beforeWrite = nil
        fixture.observations = []
        let reopened = fixture.session()
        await preview(reopened)
        await apply(reopened)
        XCTAssertNil(reopened.error)
        XCTAssertEqual(fixture.writes, 1)
    }

    func testChangedSourceMediaKindRejectsAnOtherwiseIdenticalBaseline() async throws {
        let fixture = try ExportFixture(items: [movie()])
        let session = fixture.session()
        await preview(session)
        var changed = movie()
        changed.kind = .series
        await fixture.provider.replace([changed])
        await apply(session)
        XCTAssertEqual(session.error as? TrackerHistoryError, .stalePreview)
        XCTAssertEqual(fixture.writes, 0)
    }

    func testServerChangesDuringTheFinalTrackerReadPreventDispatch() async throws {
        for playing in [false, true] {
            let fixture = try ExportFixture(items: [movie()])
            let session = fixture.session()
            await preview(session)
            var changed = movie()
            changed.isPlayed = false
            fixture.beforeTargetRead = {
                guard fixture.targetReads == 3 else { return }
                if playing { fixture.serverPlaying = true }
                else { await fixture.provider.replace([changed]) }
            }
            await apply(session)
            if playing { XCTAssertEqual(session.error as? AppError, .conflict) }
            else { XCTAssertEqual(session.error as? TrackerHistoryError, .stalePreview) }
            XCTAssertEqual(fixture.writes, 0)
        }
    }

    func testOneHundredThousandObservationsAreAllowedButAnExtraRecordRejectsTheSnapshot() async throws {
        for count in [100_000, 100_001] {
            let fixture = try ExportFixture(items: [movie()])
            fixture.observations = try (1...count).map { try fixture.observation(id: String($0)) }
            let session = fixture.session()
            await preview(session)
            if count == 100_000 {
                XCTAssertNil(session.error)
                XCTAssertTrue(session.hasCompared)
                XCTAssertEqual(session.rows.map(\.status), [.alreadyMatches])
            } else {
                XCTAssertEqual(session.error as? TrackerHistoryError, .incompleteSnapshot)
                XCTAssertFalse(session.hasCompared)
                XCTAssertTrue(session.rows.isEmpty)
            }
            XCTAssertEqual(fixture.writes, 0)
        }
    }

    func testIdentityIndexStillRejectsContradictoryIDsAndDeduplicatesMatches() async throws {
        var item = movie()
        item.providerIDs["Imdb"] = "tt123"
        for conflicting in [true, false] {
            let fixture = try ExportFixture(items: [item])
            fixture.observations = [try .init(
                recordID: "watch", kind: .movie, identities: [
                    .external(source: "tmdb", value: "550"),
                    .external(source: "imdb", value: conflicting ? "tt456" : "tt123")
                ], fact: .watched(at: nil)
            )]
            let session = fixture.session()
            await preview(session)
            XCTAssertNil(session.error)
            XCTAssertEqual(session.rows.first?.status, conflicting ? .ready : .alreadyMatches)
            await apply(session)
            XCTAssertEqual(fixture.writes, 0)
        }
    }
}

@MainActor
private final class ExportFixture {
    enum Failure { case none, refused, uncertain, unexpected, appliedWithoutReply }
    let provider: HistoryExportProvider
    let secureStore: HistoryExportSecureStore
    let store: DurableLocalStateStore
    let scope: WatchMutationServerScope
    var observations: [TrackerHistoryObservation] = []
    var snapshotConnectionID = "snapshot"
    var authorized = true
    var connected = true
    var supported = true
    var serverPlaying = false
    var trackerPlaying = false
    var resolvedTarget: String?
    var returnedDate: Date?
    var beforeWrite: (@MainActor () -> Void)?
    var beforeTargetRead: (@MainActor () async -> Void)?
    var targetReads = 0
    var failure: Failure = .none
    var writes = 0
    var failReadback = false
    var dates: [Date?] = []
    var idempotencyKeys: [String] = []

    init(
        items: [MediaItem], kind: ProviderKind = .jellyfin, profileID: String = "profile",
        secureStore: HistoryExportSecureStore = HistoryExportSecureStore(), libraryKind: MediaItemKind = .movie
    ) throws {
        provider = HistoryExportProvider(items: items, kind: kind, libraryKind: libraryKind)
        self.secureStore = secureStore
        store = try DurableLocalStateStore(secureStore: secureStore)
        scope = .init(profile: .init(id: profileID, name: "Test"), accounts: [
            .init(id: "account", server: provider.session.server,
                  userID: "viewer", userName: "Viewer", deviceID: "device")
        ])
    }

    func observation(
        id: String = "550", fact: TrackerHistoryObservation.Fact = .watched(at: nil)
    ) throws -> TrackerHistoryObservation {
        try .init(recordID: "watch/" + id, kind: .movie, identities: [.external(source: "tmdb", value: id)], fact: fact)
    }

    func session(
        preservesDates: Bool = true, trackerID: String = "fixture", connectionID: String = "durable"
    ) -> TrackerHistoryExportSession<String> {
        let source = TrackerServerHistorySource(
            scope: scope, accounts: [.init(id: "account", serverName: "Server", userName: "Viewer")],
            resolveProvider: { _ in self.provider }, isAuthorized: { self.authorized },
            isPlaying: { _, _ in self.serverPlaying }
        )
        return .init(
            trackerID: trackerID, trackerName: "Fixture", connectionID: connectionID, snapshotConnectionID: "snapshot",
            source: source, store: store, preservesWatchDates: preservesDates,
            isConnected: { self.connected }, supports: { _ in self.supported },
            readAll: {
                try .init(trackerID: trackerID, connectionID: self.snapshotConnectionID,
                          observations: self.observations, expectedCount: self.observations.count)
            },
            resolve: { item in
                guard let target = self.resolvedTarget ?? item.providerIDs["Tmdb"] else {
                    throw TrackerHistoryExportError.unsupported
                }
                return target
            },
            readTarget: { target in
                self.targetReads += 1
                await self.beforeTargetRead?()
                if self.failReadback, self.writes > 0 { throw AppError.serverUnreachable }
                return try .init(observations: self.observations.filter {
                    $0.identities.contains(.external(source: "tmdb", value: target))
                }, isPlaying: self.trackerPlaying)
            },
            write: { target, date, key, validate in
                self.beforeWrite?()
                try await validate()
                self.writes += 1
                self.dates.append(date)
                self.idempotencyKeys.append(key)
                switch self.failure {
                case .refused: throw TrackerHistoryExportError.notWritten(.unauthorized)
                case .uncertain: throw TrackerHistoryExportError.uncertainWrite
                case .unexpected: throw AppError.serverUnreachable
                case .none, .appliedWithoutReply:
                    self.observations.append(try self.observation(id: target, fact: .watched(at: self.returnedDate ?? date)))
                    if self.failure == .appliedWithoutReply { throw TrackerHistoryExportError.uncertainWrite }
                }
            }
        )
    }
}

private final class HistoryExportSecureStore: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var failsWrites = false
    func setFailsWrites(_ value: Bool) { lock.lock(); defer { lock.unlock() }; failsWrites = value }
    func setString(_ value: String, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failsWrites { throw DurableLocalStateError.storageUnavailable }
        values[key] = value
    }
    func string(for key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func readString(for key: String) throws -> String? { string(for: key) }
    func removeValue(for key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = nil }
}

private actor HistoryExportProvider: MediaProvider {
    nonisolated let kind: ProviderKind
    nonisolated let session: UserSession
    private var values: [MediaItem]
    private let libraryKind: MediaItemKind
    private(set) var playbackWrites = 0
    init(items: [MediaItem], kind: ProviderKind, libraryKind: MediaItemKind) {
        self.kind = kind
        values = items
        self.libraryKind = libraryKind
        session = .init(
            server: .init(id: "server", name: "Server", baseURL: URL(string: "https://example.test")!, provider: kind),
            userID: "viewer", userName: "Viewer", deviceID: "device", accessToken: ""
        )
    }
    func replace(_ items: [MediaItem]) { values = items }
    func libraries() async throws -> [MediaLibrary] { [.init(id: "library", title: "Library", kind: libraryKind)] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem {
        guard let item = values.first(where: { $0.id == id }) else { throw AppError.notFound }
        return item
    }
    func children(of itemID: String) async throws -> [MediaItem] { throw AppError.notFound }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        .init(items: Array(values.dropFirst(page.startIndex).prefix(page.limit)),
              startIndex: page.startIndex, totalCount: values.count)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws { playbackWrites += 1 }
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
