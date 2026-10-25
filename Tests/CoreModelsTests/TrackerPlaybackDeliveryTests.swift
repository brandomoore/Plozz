import Foundation
import XCTest
@testable import CoreModels

final class TrackerPlaybackDeliveryTests: XCTestCase {
    private func delivery(
        session: UUID = UUID(), position: Double = 900, captured: Double = 900, final: Bool = false
    ) throws -> TrackerPlaybackDelivery {
        .init(
            sample: try .init(
                sessionID: session, startedAt: .init(timeIntervalSince1970: 0),
                capturedAt: .init(timeIntervalSince1970: captured),
                item: .init(id: "movie", title: "Test", kind: .movie),
                position: position, duration: 1_000, isFinal: final
            ),
            trackerID: "publicmetadb", connectionID: "consent",
            serverScope: .init(profile: .init(id: "profile", name: "Test"), accounts: [])
        )
    }

    func testCompletionBoundaryAndInvalidClockEvidence() throws {
        XCTAssertFalse(try delivery(position: 899.999).sample.isComplete)
        XCTAssertTrue(try delivery(position: 900).sample.isComplete)
        XCTAssertThrowsError(try delivery(position: .infinity))
        XCTAssertThrowsError(try delivery(position: -.infinity))
        XCTAssertThrowsError(try delivery(position: .nan))
        XCTAssertThrowsError(try delivery(captured: -1))
    }

    func testCheckpointsCoalesceWithinOneViewingButNotAcrossRewatches() async throws {
        let store = InMemoryWatchMutationStore()
        let sut = WatchStateReconciler(store: store, applier: PlaybackApplier())
        let first = try delivery()
        _ = await sut.enqueueTrackerPlayback(first)
        _ = await sut.enqueueTrackerPlayback(try delivery(session: first.id, position: 950, captured: 950, final: true))
        _ = await sut.enqueueTrackerPlayback(try delivery(captured: 1_800))
        let rows = await sut.snapshot().trackerPlayback
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].sample.position, 950)
        XCTAssertEqual(rows[0].completedAt, first.completedAt)
        let restored = try JSONDecoder().decode(WatchOutboxState.self, from: JSONEncoder().encode(store.load()))
        XCTAssertEqual(restored.trackerPlayback, rows)
    }

    func testTrackerOnlyDeliveryCannotWriteServersOrOtherTrackers() async throws {
        let applier = PlaybackApplier()
        let sut = WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: applier)
        let original = try delivery(final: true)
        _ = await sut.enqueueTrackerPlayback(original)
        await sut.drain()
        let sent = await applier.deliveries
        let otherWrites = await applier.otherWrites
        let state = await sut.snapshot()
        XCTAssertEqual(sent, [original])
        XCTAssertEqual(otherWrites, 0)
        XCTAssertTrue(state.trackerPlayback.isEmpty)
        XCTAssertTrue(state.pending.isEmpty)
    }

    func testUnconfirmedDeliveryRemainsParkedAcrossCheckpointsAndRelaunch() async throws {
        let applier = PlaybackApplier(failure: .unconfirmed)
        let store = InMemoryWatchMutationStore()
        let sut = WatchStateReconciler(store: store, applier: applier)
        let original = try delivery()
        _ = await sut.enqueueTrackerPlayback(original)
        await sut.drain()
        _ = await sut.enqueueTrackerPlayback(try delivery(session: original.id, captured: 1_000, final: true))
        await sut.drain()
        let restored = WatchStateReconciler(store: store, applier: applier)
        await restored.drain()
        let sent = await applier.deliveries
        XCTAssertEqual(sent.count, 1)
        let rows = await restored.snapshot().trackerPlayback
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].blocked)
    }

    func testPersistenceFailureNeverDispatches() async throws {
        let applier = PlaybackApplier()
        let sut = WatchStateReconciler(store: FailingStore(), applier: applier)
        let queued = await sut.enqueueTrackerPlayback(try delivery(final: true))
        await sut.drain()
        XCTAssertFalse(queued)
        let sent = await applier.deliveries
        XCTAssertTrue(sent.isEmpty)
    }

    func testNewCheckpointCannotEraseInFlightUncertainty() async throws {
        let applier = PlaybackApplier(failure: .unconfirmed)
        let sut = WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: applier)
        let first = try delivery()
        let last = try delivery(session: first.id, captured: 1_000, final: true)
        await applier.onReport { _ = await sut.enqueueTrackerPlayback(last) }
        _ = await sut.enqueueTrackerPlayback(first)
        await sut.drain()
        let rows = await sut.snapshot().trackerPlayback
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].sample, last.sample)
        XCTAssertTrue(rows[0].blocked)
        await sut.drain()
        let sent = await applier.deliveries
        XCTAssertEqual(sent.count, 1)
    }

    func testServerScopeRejectionCannotReachTracker() async throws {
        let applier = PlaybackApplier(rejectScope: true)
        let sut = WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: applier)
        _ = await sut.enqueueTrackerPlayback(try delivery(final: true))
        await sut.drain()
        let sent = await applier.deliveries
        let rows = await sut.snapshot().trackerPlayback
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(rows[0].blocked)
        XCTAssertNotNil(rows[0].nextAttemptAt)
    }
}

private actor PlaybackApplier: WatchMutationAuthorizationEnforcing {
    private(set) var deliveries: [TrackerPlaybackDelivery] = []
    private(set) var otherWrites = 0
    let failure: TrackerPlaybackDeliveryError?
    let rejectScope: Bool
    private var callback: (@Sendable () async -> Void)?
    func onReport(_ callback: @escaping @Sendable () async -> Void) { self.callback = callback }
    init(failure: TrackerPlaybackDeliveryError? = nil, rejectScope: Bool = false) {
        self.failure = failure
        self.rejectScope = rejectScope
    }
    func requireServerScope(_ scope: WatchMutationServerScope) async throws {
        if rejectScope { throw WatchMutationServerScopeError.unavailable }
    }
    func reportTrackerPlayback(_ delivery: TrackerPlaybackDelivery) async throws {
        try await WatchMutationDeliveryAuthorization.check()
        XCTAssertEqual(WatchMutationDeliveryAuthorization.current?.serverScope, delivery.serverScope)
        deliveries.append(delivery)
        await callback?()
        if let failure { throw failure }
    }
    func setPlayed(_ played: Bool, on target: WatchMutationTarget) async throws { otherWrites += 1 }
    func setResumePosition(_ seconds: TimeInterval, on target: WatchMutationTarget, capturedAt: Date) async throws {
        otherWrites += 1
    }
    func scrobbleTrakt(_ intent: TraktScrobbleIntent) async throws { otherWrites += 1 }
}

private struct FailingStore: WatchMutationStoring {
    func load() -> WatchOutboxState { .empty }
    func save(_ state: WatchOutboxState) throws { throw DurableLocalStateError.malformedPayload }
}
