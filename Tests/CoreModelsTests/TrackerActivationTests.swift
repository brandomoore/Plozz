import Foundation
import XCTest
@testable import CoreModels

final class TrackerActivationTests: XCTestCase {
    @MainActor
    func testPauseIsPerGrantAndProfileAndDoesNotReviveOldAdmission() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let activation = TrackerActivationStore("trakt", defaults: defaults)
        let original = try XCTUnwrap(activation.observedAdmission(for: "grant"))
        let bound = activation.snapshot()
        try activation.setEnabled(false, for: "grant")
        let duringPause = Date.distantPast

        let restored = TrackerActivationStore("trakt", defaults: defaults)
        XCTAssertNil(restored.observedAdmission(for: "grant"))
        XCTAssertNil(bound.admission(for: "grant"))
        XCTAssertNotNil(restored.admission(for: "replacement-grant"))
        XCTAssertNotNil(TrackerActivationStore("simkl", defaults: defaults).admission(for: "grant"))
        activation.setNamespace("other") {}
        XCTAssertNotNil(activation.admission(for: "grant"))
        XCTAssertNil(bound.admission(for: "grant"))

        try restored.setEnabled(true, for: "grant")
        XCTAssertNotEqual(try XCTUnwrap(bound.admission(for: "grant")), original)
        TrackerActivationStore.$capturedAdmissions.withValue(["trakt": original]) {
            XCTAssertNil(bound.admission(for: "grant"))
        }
        TrackerActivationStore.$eventDate.withValue(duringPause) {
            XCTAssertNil(bound.admission(for: "grant"))
        }
        try restored.setEnabled(false, for: "grant")
        restored.didConnect("grant")
        XCTAssertNotNil(restored.observedAdmission(for: "grant"))
        TrackerActivationStore.$eventDate.withValue(duringPause) {
            XCTAssertNil(bound.admission(for: "grant"), "Delayed external reports predate the new connection")
        }
    }

    func testOutboxCoalescesAndRestoresOnlyAdmittedTrackerWorkWithoutSuppressingServerWrites() async throws {
        let origin = WatchMutationTarget(accountID: "server", itemID: "movie")
        let intent = TraktScrobbleIntent(kind: .movie, title: "Recorded", year: 2020, seasonNumber: nil,
                                         episodeNumber: nil, providerIDs: ["tmdb": "1"], progress: 100)
        let store = InMemoryWatchMutationStore()
        let date = Date()
        let enabled = MirrorRecorder(["trakt": "old", "simkl": "unchanged", "wetrakr": "old"])
        let first = WatchStateReconciler(store: store, applier: enabled)
        await first.enqueue(.init(capturedAt: date, canonicalMediaID: "movie", played: true,
                                  targets: [origin], trakt: intent))

        // The newer real watch was made with Trakt, WeTrakr and the anime
        // trackers off. Coalescing cannot lend it the previous admissions.
        let off = WatchStateReconciler(store: store, applier: MirrorRecorder(["simkl": "unchanged"]))
        await off.enqueue(.init(capturedAt: date.addingTimeInterval(1), canonicalMediaID: "movie",
                                played: true, targets: [origin], trakt: intent, traktProgress: intent))
        let state = try JSONDecoder().decode(WatchOutboxState.self, from: JSONEncoder().encode(store.load()))
        let queued = try XCTUnwrap(state.pending.first)
        XCTAssertEqual(state.pending.count, 1)
        XCTAssertFalse(queued.traktPending)
        XCTAssertNil(queued.traktProgress)
        XCTAssertFalse(queued.wetrakrPending)
        XCTAssertFalse(queued.anilistPending)
        XCTAssertFalse(queued.malPending)
        XCTAssertTrue(queued.simklPending)

        let playback = MirrorRecorder(["trakt": "new", "simkl": "unchanged", "wetrakr": "new",
                                       "anilist": "new", "myanimelist": "new"])
        let restored = WatchStateReconciler(store: InMemoryWatchMutationStore(state), applier: playback)
        await restored.drain()
        let sent = await playback.sent
        XCTAssertEqual(sent, ["server", "simkl"])
    }

    func testPendingWorkForReplacedAdmissionIsNotDeliveredOnRetry() async {
        let store = InMemoryWatchMutationStore()
        let recorder = MirrorRecorder(["trakt": "before"])
        let reconciler = WatchStateReconciler(store: store, applier: recorder)
        let intent = TraktScrobbleIntent(kind: .movie, title: "Film", year: nil, seasonNumber: nil,
                                         episodeNumber: nil, providerIDs: ["tmdb": "1"], progress: 100)
        await reconciler.enqueue(.init(capturedAt: Date(), canonicalMediaID: "movie", targets: [], trakt: intent))
        let after = MirrorRecorder(["trakt": "after"])
        let retry = WatchStateReconciler(store: store, applier: after)
        await retry.drain()
        let sent = await after.sent
        let pending = await retry.pendingCount
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(pending, 0)
    }

    func testLegacyUnboundQueueStillDeliversServerWriteButNoTrackerWork() async throws {
        let intent = TraktScrobbleIntent(kind: .movie, title: "Film", year: nil, seasonNumber: nil,
                                         episodeNumber: nil, providerIDs: ["tmdb": "1"], progress: 100)
        var legacy = WatchOutboxState.empty
        legacy.pending = [.init(capturedAt: Date(), canonicalMediaID: "movie", played: true,
                                targets: [.init(accountID: "server", itemID: "movie")], trakt: intent, traktProgress: intent)]
        let decoded = try JSONDecoder().decode(WatchOutboxState.self, from: JSONEncoder().encode(legacy))
        let applier = MirrorRecorder(["trakt": "new", "simkl": "new", "wetrakr": "new",
                                     "anilist": "new", "myanimelist": "new"])
        let retry = WatchStateReconciler(store: InMemoryWatchMutationStore(decoded), applier: applier)
        await retry.drain()
        let sent = await applier.sent
        XCTAssertEqual(sent, ["server"])
    }
}

private actor MirrorRecorder: WatchMutationApplying {
    nonisolated let trackerPlaybackAdmissions: [String: String]?
    nonisolated var wetrakrAccountIdentity: String? { "same-account" }
    var sent: [String] = []
    init(_ admissions: [String: String]) { trackerPlaybackAdmissions = admissions }
    func setPlayed(_ played: Bool, on target: WatchMutationTarget) { sent.append("server") }
    func setResumePosition(_ seconds: TimeInterval, on target: WatchMutationTarget, capturedAt: Date) {}
    func scrobbleTrakt(_ intent: TraktScrobbleIntent) { sent.append("trakt") }
    func scrobbleSimkl(_ intent: TraktScrobbleIntent) async throws { sent.append("simkl") }
    func scrobbleWetrakr(_ intent: TraktScrobbleIntent, capturedAt: Date, idempotencyKey: String,
                         expectedAccountIdentity: String) async throws { sent.append("wetrakr") }
    func scrobbleAniList(_ intent: TraktScrobbleIntent) async throws { sent.append("anilist") }
    func scrobbleMAL(_ intent: TraktScrobbleIntent) async throws { sent.append("myanimelist") }
}
