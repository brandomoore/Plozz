import AppRuntime
import CoreModels
import Foundation
import XCTest

@MainActor
final class WatchMutationDeliveryAuthorizationTests: XCTestCase {
    func testCorrectedWatchIntentSupersedesOnlyItsTargetDuringProviderResolution() async {
        let provider = DeliveryProvider()
        let gate = DeliveryResolutionGate()
        let applier = AppShellWatchMutationApplier(
            resolveProvider: { account in
                if account == "b" { await gate.pause() }
                return provider
            },
            applyTrakt: { _ in }, applySimkl: { _ in },
            applyAniList: { _ in }, applyMAL: { _ in }, allAccountIDs: { ["a", "b"] }
        )
        let reconciler = WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: applier)
        var older = WatchMutation(
            capturedAt: Date(timeIntervalSince1970: 1_000), canonicalMediaID: "imdb:tt111", played: true,
            targets: [.init(accountID: "a", itemID: "a"), .init(accountID: "b", itemID: "b")]
        )
        older.kind = .movie
        older.identities = [.external(source: "imdb", value: "tt111"), .external(source: "tmdb", value: "123")]
        var newer = WatchMutation(
            capturedAt: Date(timeIntervalSince1970: 2_000), canonicalMediaID: "imdb:tt111", played: false,
            targets: [.init(accountID: "b", itemID: "b")]
        )
        newer.kind = .movie
        newer.identities = [.external(source: "imdb", value: "tt111"), .external(source: "tmdb", value: "999")]
        await reconciler.enqueue(older)
        let drain = Task { await reconciler.drain() }
        await gate.waitUntilPaused()
        await reconciler.enqueue(newer)
        await gate.open()
        await drain.value
        await reconciler.drain()
        let writes = await provider.playedWrites
        XCTAssertEqual(writes, ["a:true", "b:false"])
    }

    private func mutation(expansion: Bool = false) -> WatchMutation {
        WatchMutation(
            capturedAt: Date(), canonicalMediaID: "imdb:tt1", seasonNumber: expansion ? 1 : nil,
            episodeNumber: expansion ? 1 : nil, played: true,
            targets: [WatchMutationTarget(accountID: "origin", itemID: "item")],
            episodeOrigin: expansion ? EpisodeOrigin(accountID: "origin", itemID: "item") : nil,
            expansionPending: expansion
        )
    }

    private func guarded(_ mutation: WatchMutation, scope: DeliveryScope) -> WatchMutation {
        mutation.requiringAuthorization { @MainActor in
            return scope.consent && scope.profile == "profile" && scope.identity == "identity"
        }
    }

    private func applier(
        provider: DeliveryProvider, gate: DeliveryResolutionGate? = nil
    ) -> AppShellWatchMutationApplier {
        AppShellWatchMutationApplier(
            resolveProvider: { _ in
                await gate?.pause()
                return provider
            },
            applyTrakt: { _ in }, applySimkl: { _ in },
            applyAniList: { _ in }, applyMAL: { _ in },
            allAccountIDs: { ["origin", "other"] }
        )
    }

    func testProviderResolutionRechecksConsentProfileAndIdentityBeforeWriting() async {
        for change in DeliveryScopeChange.allCases {
            let provider = DeliveryProvider()
            let gate = DeliveryResolutionGate()
            let scope = DeliveryScope()
            let reconciler = WatchStateReconciler(
                store: InMemoryWatchMutationStore(), applier: applier(provider: provider, gate: gate)
            )
            guard await reconciler.enqueue(guarded(mutation(), scope: scope)) else {
                XCTFail("Valid mutation must enqueue"); return
            }
            let drain = Task { await reconciler.drain() }
            await gate.waitUntilPaused()
            change.apply(to: scope)
            await gate.open()
            await drain.value
            let writes = await provider.writes
            XCTAssertTrue(writes.isEmpty, "\(change)")
            let pending = await reconciler.pendingCount
            XCTAssertEqual(pending, 0)
        }
    }

    func testEpisodeExpansionRechecksAfterProviderResolutionBeforeFurtherReads() async {
        let provider = DeliveryProvider()
        let gate = DeliveryResolutionGate()
        let scope = DeliveryScope()
        let reconciler = WatchStateReconciler(
            store: InMemoryWatchMutationStore(), applier: applier(provider: provider, gate: gate)
        )
        guard await reconciler.enqueue(guarded(mutation(expansion: true), scope: scope)) else {
            XCTFail("Valid mutation must enqueue"); return
        }
        let drain = Task { await reconciler.drain() }
        await gate.waitUntilPaused()
        scope.consent = false
        await gate.open()
        await drain.value
        let reads = await provider.reads
        let writes = await provider.writes
        XCTAssertTrue(reads.isEmpty)
        XCTAssertTrue(writes.isEmpty)
    }

    func testRevokedDismissalCannotFallBackToAnotherMutationButOrdinaryBehaviorIsUnchanged() async {
        for requiresAuthorization in [true, false] {
            let provider = DeliveryProvider()
            let scope = DeliveryScope()
            await provider.setAfterDismissal { await MainActor.run { scope.consent = false } }
            let reconciler = WatchStateReconciler(
                store: InMemoryWatchMutationStore(), applier: applier(provider: provider)
            )
            var intent = mutation()
            intent.played = nil
            intent.clearResume = true
            if requiresAuthorization { intent = guarded(intent, scope: scope) }
            _ = await reconciler.enqueue(intent)
            await reconciler.drain()
            let writes = await provider.writes
            XCTAssertEqual(writes, requiresAuthorization ? ["dismiss"] : ["dismiss", "resume"])
        }
    }

    func testUnguardedManualWriteDoesNotConsultLibraryConsent() async {
        let scope = DeliveryScope()
        scope.consent = false
        let provider = DeliveryProvider()
        let reconciler = WatchStateReconciler(
            store: InMemoryWatchMutationStore(), applier: applier(provider: provider)
        )
        _ = await reconciler.enqueue(mutation())
        await reconciler.drain()
        let writes = await provider.writes
        XCTAssertEqual(writes, ["played"])
    }

    func testValidGuardedProviderDeliveryUsesExistingPipelineOnce() async {
        let scope = DeliveryScope()
        let provider = DeliveryProvider()
        let reconciler = WatchStateReconciler(
            store: InMemoryWatchMutationStore(), applier: applier(provider: provider)
        )
        _ = await reconciler.enqueue(guarded(mutation(), scope: scope))
        await reconciler.drain()
        await reconciler.drain()
        let writes = await provider.writes
        XCTAssertEqual(writes, ["played"])
    }

    func testDispatchPreconditionRunsOnceBeforeWriteNotDuringPostWriteChecks() async {
        let scope = DeliveryScope()
        let provider = DeliveryProvider()
        let reconciler = WatchStateReconciler(
            store: InMemoryWatchMutationStore(), applier: applier(provider: provider)
        )
        let intent = mutation().requiringAuthorization(
            owner: scope,
            sourcePrecondition: { owner, _, target in
                await MainActor.run { owner.preconditions += 1 }
                let writes = await provider.writes
                guard writes.isEmpty, target.itemID == "item" else { throw TrackerHistoryError.stalePreview }
            },
            validator: { owner in await MainActor.run { owner.consent } }
        ).requiringAuthorization { true }
        _ = await reconciler.enqueue(intent)
        await reconciler.drain()
        XCTAssertEqual(scope.preconditions, 1)
        let writes = await provider.writes
        let pending = await reconciler.pendingCount
        XCTAssertEqual(writes, ["played"])
        XCTAssertEqual(pending, 0)
    }

    func testRejectedBaselineStopsBothPlayedAndResumeWriters() async {
        for resumeOnly in [false, true] {
            let scope = DeliveryScope()
            let provider = DeliveryProvider()
            let reconciler = WatchStateReconciler(
                store: InMemoryWatchMutationStore(), applier: applier(provider: provider)
            )
            var intent = mutation()
            if resumeOnly { intent.played = nil; intent.resumePosition = 120 }
            intent = intent.requiringAuthorization(
                owner: scope, sourcePrecondition: { _, _, _ in throw TrackerHistoryError.stalePreview },
                validator: { _ in true }
            )
            _ = await reconciler.enqueue(intent)
            await reconciler.drain()
            let writes = await provider.writes
            XCTAssertTrue(writes.isEmpty)
        }
    }

    func testVerificationBarrierWaitsForAnAlreadyRunningDrain() async {
        let provider = DeliveryProvider()
        let gate = DeliveryResolutionGate()
        let reconciler = WatchStateReconciler(
            store: InMemoryWatchMutationStore(), applier: applier(provider: provider, gate: gate)
        )
        _ = await reconciler.enqueue(mutation())
        let drain = Task { await reconciler.drain() }
        await gate.waitUntilPaused()
        let started = expectation(description: "Verification waiter started")
        let prematureReadback = expectation(description: "Readback cannot start before the writer resumes")
        prematureReadback.isInverted = true
        let permission = DeliveryScope()
        let waiter = Task {
            started.fulfill()
            await reconciler.drainAndWait()
            if permission.consent { prematureReadback.fulfill() }
            return await provider.writes
        }
        await fulfillment(of: [started], timeout: 2)
        await fulfillment(of: [prematureReadback], timeout: 0.1)
        permission.consent = false
        await gate.open()
        await drain.value
        let writesAtReadback = await waiter.value
        XCTAssertEqual(writesAtReadback, ["played"])
    }
}

@MainActor
private final class DeliveryScope {
    var preconditions = 0
    var consent = true
    var profile = "profile"
    var identity = "identity"
}

private enum DeliveryScopeChange: CaseIterable {
    case consent, profile, identity
    @MainActor func apply(to scope: DeliveryScope) {
        switch self {
        case .consent: scope.consent = false
        case .profile: scope.profile = "other"
        case .identity: scope.identity = "new"
        }
    }
}

private actor DeliveryResolutionGate {
    private var paused = false
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    func pause() async {
        guard !opened else { return }
        paused = true
        arrival?.resume()
        arrival = nil
        await withCheckedContinuation { waiter = $0 }
    }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func open() { opened = true; waiter?.resume(); waiter = nil }
}

private actor DeliveryProvider: MediaProvider, WatchStateProviding, ResumeStateWriting, ContinueWatchingRemovable {
    let kind = ProviderKind.jellyfin
    nonisolated let session = UserSession(
        server: MediaServer(
            id: "server", name: "Fixture", baseURL: URL(string: "https://server.invalid")!, provider: .jellyfin
        ),
        userID: "user", userName: "Fixture", deviceID: "device", accessToken: "fixture"
    )
    private(set) var writes: [String] = []
    private(set) var playedWrites: [String] = []
    private(set) var reads: [String] = []
    private var afterDismissal: (@Sendable () async -> Void)?
    func setAfterDismissal(_ action: @escaping @Sendable () async -> Void) { afterDismissal = action }
    func setPlayed(_ played: Bool, itemID: String) async throws {
        writes.append("played")
        playedWrites.append("\(itemID):\(played)")
    }
    func setResumePosition(_ seconds: TimeInterval, itemID: String, capturedAt: Date) async throws {
        writes.append("resume")
    }
    func removeFromContinueWatching(itemID: String) async throws {
        writes.append("dismiss")
        await afterDismissal?()
        throw AppError.serverUnreachable
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem {
        reads.append(id)
        return MediaItem(id: id, title: "Fixture", kind: .episode, seriesID: "series")
    }
    func children(of itemID: String) async throws -> [MediaItem] { reads.append(itemID); return [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        throw AppError.notFound
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
