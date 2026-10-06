import Foundation
import XCTest
@testable import CoreModels

@MainActor
final class WatchMutationServerScopeTests: XCTestCase {
    private let time = Date(timeIntervalSince1970: 1_700_000_000)

    private func scope(_ homeUser: String) -> WatchMutationServerScope {
        let profile = Profile(
            id: "profile", name: "Viewer", plexHomeUserID: homeUser, plexHomeUserAccountID: "plex"
        )
        return WatchMutationServerScope(profile: profile, accounts: [account()])
    }

    private func account() -> Account {
        Account(
            id: "plex",
            server: MediaServer(id: "server", name: "Plex", baseURL: URL(string: "https://plex.invalid")!, provider: .plex),
            userID: "owner", userName: "Owner", deviceID: "device"
        )
    }

    private func mutation(_ homeUser: String, offset: Double = 0, canonical: String = "imdb:tt1") -> WatchMutation {
        WatchMutation(
            capturedAt: time.addingTimeInterval(offset), canonicalMediaID: canonical,
            resumePosition: 50, targets: [WatchMutationTarget(accountID: "plex", itemID: "item")],
            identities: [.external(source: "tmdb", value: "1")], kind: .movie
        ).bindingServerScope(scope(homeUser))
    }

    func testServerScopeRoundTripSurvivesCredentialRotation() throws {
        let original = mutation("a")
        let restored = try JSONDecoder().decode(WatchMutation.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored, original)
        XCTAssertNil(restored.authorization, "A replayable server-user identity is not an ephemeral consent grant")

        var rotated = account()
        rotated.credentialRevision = CredentialRevision()
        let profile = Profile(
            id: "profile", name: "Renamed", plexHomeUserID: "a", plexHomeUserAccountID: "plex"
        )
        XCTAssertEqual(restored.serverScope, WatchMutationServerScope(profile: profile, accounts: [rotated]))
        XCTAssertEqual(restored.coalesceKey, original.coalesceKey)
        XCTAssertEqual(restored.bindingServerScope(scope("b")), restored, "Enqueue cannot retag the original viewer")
    }

    func testScopedEnvelopeCannotBeReadWithoutItsRequirement() throws {
        let data = try JSONEncoder().encode(mutation("a"))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for alteration in ["missing", "null", "changed"] {
            var object = original
            switch alteration {
            case "missing": object.removeValue(forKey: "serverScope")
            case "null": object["serverScope"] = NSNull()
            default:
                object["serverScope"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(scope("b")))
            }
            XCTAssertThrowsError(try JSONDecoder().decode(
                WatchMutation.self, from: JSONSerialization.data(withJSONObject: object)
            ))
        }
        struct LegacyIdentity: Decodable { let id: UUID }
        XCTAssertThrowsError(try JSONDecoder().decode(LegacyIdentity.self, from: data))

        let legacy = WatchMutation(capturedAt: time, canonicalMediaID: "legacy", played: true, targets: [])
        let legacyData = try JSONEncoder().encode(legacy)
        XCTAssertNoThrow(try JSONDecoder().decode(LegacyIdentity.self, from: legacyData))
        XCTAssertNil(try JSONDecoder().decode(WatchMutation.self, from: legacyData).serverScope)

        let guarded = mutation("a").requiringAuthorization { true }
        let roundTrip = try JSONDecoder().decode(WatchMutation.self, from: JSONEncoder().encode(guarded))
        XCTAssertEqual(roundTrip, guarded, "The v2 envelope preserves the separate ephemeral authorization requirement")
    }

    func testNonPlexScopeTracksServerUserWithoutInventingHomeUsers() {
        let profile = Profile(id: "profile", name: "Viewer")
        let withPlexBinding = profile.settingHomeUserBinding(
            PlexHomeUserBinding(homeUserID: "a", name: "A"), forPlexAccount: "server-account"
        )
        for kind in [ProviderKind.jellyfin, .emby, .mediaShare] {
            var account = Account(
                id: "server-account",
                server: MediaServer(id: "server", name: "Server", baseURL: URL(string: "https://server.invalid")!, provider: kind),
                userID: "a", userName: "A", deviceID: "device"
            )
            let original = WatchMutationServerScope(profile: profile, accounts: [account])
            XCTAssertEqual(original, WatchMutationServerScope(profile: withPlexBinding, accounts: [account]))
            account.userID = "b"
            XCTAssertNotEqual(original, WatchMutationServerScope(profile: profile, accounts: [account]))
        }
    }

    func testDifferentServerViewersCannotCoalesceOrSupersedeEachOthersClock() async {
        let reconciler = WatchStateReconciler(
            store: InMemoryWatchMutationStore(), applier: ScopedRecordingApplier(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        _ = await reconciler.enqueue(mutation("b", offset: 20))
        _ = await reconciler.enqueue(mutation("a", offset: 0, canonical: "tmdb:1"))
        _ = await reconciler.enqueue(mutation("a", offset: 10))
        let state = await reconciler.snapshot()
        XCTAssertEqual(state.pending.count, 2, "Shared title evidence must not combine different Plex Home users")
        XCTAssertEqual(state.pending.first { $0.serverScope == scope("a") }?.capturedAt, time.addingTimeInterval(10))
        XCTAssertEqual(state.pending.first { $0.serverScope == scope("b") }?.capturedAt, time.addingTimeInterval(20))
    }

    func testSameViewerManualActionStillSupersedesGuardedIntentButOtherViewerDoesNot() async {
        let reconciler = WatchStateReconciler(
            store: InMemoryWatchMutationStore(), applier: ScopedRecordingApplier(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let guarded = mutation("a").requiringAuthorization { true }
        _ = await reconciler.enqueue(guarded)
        _ = await reconciler.enqueue(mutation("b", offset: 10))
        var state = await reconciler.snapshot()
        XCTAssertEqual(state.pending.count, 2)
        _ = await reconciler.enqueue(mutation("a", offset: 20))
        state = await reconciler.snapshot()
        XCTAssertEqual(state.pending.count, 2)
        XCTAssertTrue(state.pending.allSatisfy { $0.authorization == nil })
    }

    func testLateStopOnlyEndsItsOwnServerViewerLiveSession() async {
        let applier = ScopedRecordingApplier()
        let reconciler = WatchStateReconciler(
            store: InMemoryWatchMutationStore(), applier: applier,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        await reconciler.beginLiveSession(accountID: "plex", itemID: "item", serverScope: scope("a"))
        await reconciler.beginLiveSession(accountID: "plex", itemID: "item", serverScope: scope("b"))
        _ = await reconciler.enqueue(mutation("b"))
        await reconciler.finishLiveSession(
            accountID: "plex", itemID: "item", mutation: mutation("a"), serverScope: scope("a")
        )
        let writes = await applier.writes
        XCTAssertEqual(writes, ["a"])
        let pending = await reconciler.snapshot().pending
        XCTAssertEqual(pending.map(\.serverScope), [scope("b")])
        let liveB = await reconciler.isLiveSession(accountID: "plex", itemID: "item", serverScope: scope("b"))
        XCTAssertTrue(liveB)
        await reconciler.finishLiveSession(accountID: "plex", itemID: "item", mutation: nil, serverScope: scope("b"))
        let allWrites = await applier.writes
        XCTAssertEqual(allWrites, ["a", "b"])
    }

    func testLiveGuardSurvivesUnrelatedAccountMembershipChange() async {
        let applier = ScopedRecordingApplier()
        let reconciler = WatchStateReconciler(
            store: InMemoryWatchMutationStore(), applier: applier,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let profile = Profile(
            id: "profile", name: "Viewer", plexHomeUserID: "a", plexHomeUserAccountID: "plex"
        )
        var other = account()
        other.id = "other"
        let expandedScope = WatchMutationServerScope(profile: profile, accounts: [account(), other])
        var intent = WatchMutation(
            capturedAt: time, canonicalMediaID: "item", resumePosition: 50,
            targets: [WatchMutationTarget(accountID: "plex", itemID: "item")]
        )
        intent = intent.bindingServerScope(expandedScope)
        await reconciler.beginLiveSession(accountID: "plex", itemID: "item", serverScope: scope("a"))
        _ = await reconciler.enqueue(intent)
        await reconciler.drain()
        let writes = await applier.writes
        XCTAssertTrue(writes.isEmpty, "Deferral belongs to this server viewer, not the household's entire account set")
    }

    func testUnawareApplierCannotSilentlyDropTheServerScope() async {
        let applier = LegacyServerScopeApplier()
        let intent = mutation("a")
        let reconciler = WatchStateReconciler(
            store: InMemoryWatchMutationStore(), applier: applier,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        _ = await reconciler.enqueue(intent)
        await reconciler.drain()
        let pending = await reconciler.snapshot().pending
        let writes = await applier.writes
        XCTAssertEqual(pending, [intent])
        XCTAssertEqual(writes, 0)
    }
}

private actor ScopedRecordingApplier: WatchMutationAuthorizationEnforcing {
    private(set) var writes: [String] = []
    func requireServerScope(_ scope: WatchMutationServerScope) async throws {}
    func setPlayed(_ played: Bool, on target: WatchMutationTarget) async throws {}
    func setResumePosition(_ seconds: TimeInterval, on target: WatchMutationTarget, capturedAt: Date) async throws {
        writes.append(WatchMutationDeliveryAuthorization.current?.serverScope?.accounts.first?.plexHomeUserID ?? "owner")
    }
    func scrobbleTrakt(_ intent: TraktScrobbleIntent) async throws {}
}

private actor LegacyServerScopeApplier: WatchMutationApplying {
    private(set) var writes = 0
    func setPlayed(_ played: Bool, on target: WatchMutationTarget) async throws { writes += 1 }
    func setResumePosition(_ seconds: TimeInterval, on target: WatchMutationTarget, capturedAt: Date) async throws {
        writes += 1
    }
    func scrobbleTrakt(_ intent: TraktScrobbleIntent) async throws { writes += 1 }
}
