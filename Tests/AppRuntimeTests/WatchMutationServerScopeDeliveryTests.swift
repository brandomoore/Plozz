import CoreModels
import FeatureAuthCore
import Foundation
import XCTest
@testable import AppRuntime

@MainActor
final class WatchMutationServerScopeDeliveryTests: XCTestCase {
    private func fixture() throws -> ServerViewerFixture {
        let suite = "WatchMutationServerScopeDeliveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return try ServerViewerFixture(defaults: defaults)
    }

    private func stop(scope: WatchMutationServerScope, crossServer: Bool = false) throws -> WatchMutation {
        try XCTUnwrap(WatchMutationFactory.playbackStop(
            item: MediaItem(
                id: "item", title: "Fixture", kind: .movie, runtime: 100,
                providerIDs: ["Tmdb": "1"], sourceAccountID: "plex"
            ),
            position: 95, watchedPercent: 95, primaryAccountID: "plex", crossServerSync: crossServer
        )).bindingServerScope(scope)
    }

    func testLateStopAndRelaunchNeverWriteToReplacementPlexHomeViewer() async throws {
        let first = try fixture()
        try await first.activate("a")
        let scope = first.accounts.watchMutationServerScope
        let revision = first.plex.effectiveCredentialRevision(for: first.account)
        let store = InMemoryWatchMutationStore()
        let reconciler = WatchStateReconciler(store: store, applier: first.applier())
        await reconciler.beginLiveSession(accountID: "plex", itemID: "item", serverScope: scope)

        // Engine teardown completes only after Watching as has changed within
        // the same Plozz profile and the replacement credential is installed.
        try await first.activate("b")
        let delayedStop = try stop(scope: scope)
        await reconciler.finishLiveSession(
            accountID: "plex", itemID: "item", mutation: delayedStop, serverScope: scope
        )
        let writesBeforeRestart = await first.receipts.writes
        XCTAssertTrue(writesBeforeRestart.isEmpty)
        let pending = await reconciler.snapshot()
        XCTAssertEqual(pending.pending.count, 1)
        XCTAssertEqual(pending.pending.first?.attempts, 0)

        // A real Codable round-trip drops all runtime objects/credential
        // revisions, unlike handing the same in-memory mutation to another actor.
        let persisted = try JSONEncoder().encode(pending)
        let restored = try JSONDecoder().decode(WatchOutboxState.self, from: persisted)
        let relaunched = try fixture()
        try await relaunched.activate("b")
        let replay = WatchStateReconciler(
            store: InMemoryWatchMutationStore(restored), applier: relaunched.applier()
        )
        await replay.drain()
        let replacementWrites = await relaunched.receipts.writes
        XCTAssertTrue(replacementWrites.isEmpty, "The actual replacement provider must receive no request")
        let stillPending = await replay.pendingCount
        XCTAssertEqual(stillPending, 1)

        try await relaunched.activate("a")
        XCTAssertNotEqual(revision, relaunched.plex.effectiveCredentialRevision(for: relaunched.account))
        XCTAssertEqual(scope, relaunched.accounts.watchMutationServerScope)
        await replay.drain()
        await replay.drain()
        let resumedWrites = await relaunched.receipts.writes
        XCTAssertEqual(resumedWrites, ["server-user-a:played", "server-user-a:resume"])
        let remaining = await replay.pendingCount
        XCTAssertEqual(remaining, 0)
    }

    func testProviderResolutionSuspensionCannotRetargetTheCapturedViewer() async throws {
        let fixture = try fixture()
        try await fixture.activate("a")
        let gate = ServerViewerResolutionGate()
        let reconciler = WatchStateReconciler(
            store: InMemoryWatchMutationStore(), applier: fixture.applier(gate: gate)
        )
        _ = await reconciler.enqueue(try stop(scope: fixture.accounts.watchMutationServerScope))
        let draining = Task { await reconciler.drain() }
        await gate.waitUntilPaused()
        try await fixture.activate("b")
        await gate.open()
        await draining.value
        let replacementWrites = await fixture.receipts.writes
        XCTAssertTrue(replacementWrites.isEmpty)
        let pending = await reconciler.pendingCount
        XCTAssertEqual(pending, 1)

        try await fixture.activate("a")
        await reconciler.drain()
        let originalWrites = await fixture.receipts.writes
        XCTAssertEqual(originalWrites, ["server-user-a:played", "server-user-a:resume"])
    }

    func testSelectedBindingCannotAuthorizeAnInstalledDifferentViewerOrOwnerFallback() async throws {
        let fixture = try fixture()
        XCTAssertTrue(fixture.plex.hasResolvedWatchMutationIdentity(forAccountID: "plex"))
        fixture.selectMetadata("a")
        XCTAssertFalse(fixture.plex.hasResolvedWatchMutationIdentity(forAccountID: "plex"),
                       "A selected Home user without an override must not borrow the owner's credential")
        let scopeA = fixture.accounts.watchMutationServerScope
        let reconciler = WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: fixture.applier())
        _ = await reconciler.enqueue(try stop(scope: scopeA))
        await reconciler.drain()
        try await fixture.activate("b")
        fixture.selectMetadata("a")
        XCTAssertFalse(fixture.plex.hasResolvedWatchMutationIdentity(forAccountID: "plex"),
                       "Persisted profile identity alone is not proof of the installed viewer")
        await reconciler.drain()
        let wrongWrites = await fixture.receipts.writes
        XCTAssertTrue(wrongWrites.isEmpty)

        try await fixture.activate("a")
        await reconciler.drain()
        let correctWrites = await fixture.receipts.writes
        XCTAssertEqual(correctWrites, ["server-user-a:played", "server-user-a:resume"])
        fixture.selectMetadata(nil)
        XCTAssertFalse(fixture.plex.hasResolvedWatchMutationIdentity(forAccountID: "plex"),
                       "Selecting owner must also wait for an old Home override to be removed")
    }

    func testWrongViewerDoesNotConsumeTheExpansionRetryBudget() async throws {
        let fixture = try fixture()
        try await fixture.activate("a")
        let intent = try stop(scope: fixture.accounts.watchMutationServerScope, crossServer: true)
        let reconciler = WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: fixture.applier())
        try await fixture.activate("b")
        _ = await reconciler.enqueue(intent)
        for _ in 0..<15 { await reconciler.drain() }
        let pending = await reconciler.snapshot().pending
        XCTAssertEqual(pending, [intent], "Deferral must not age, expand, or retire the original viewer's work")
        let writes = await fixture.receipts.writes
        XCTAssertTrue(writes.isEmpty)
    }
}

@MainActor
private final class ServerViewerFixture {
    let account: Account
    let accounts: AccountsProvidersModel
    let profiles: ProfilesModel
    let plex: PlexHomeUsersModel
    let receipts = ServerViewerReceipts()

    init(defaults: UserDefaults) throws {
        account = Account(
            id: "plex",
            server: MediaServer(id: "server", name: "Plex", baseURL: URL(string: "https://plex.invalid")!, provider: .plex),
            userID: "owner", userName: "Owner", deviceID: "device"
        )
        let store = AccountStore(secureStore: InMemorySecureStore())
        try store.add(account, token: "owner")
        profiles = ProfilesModel(store: ProfileStore(defaults: defaults))
        let registry = ProviderRegistry()
        let receipts = receipts
        registry.register(.plex) { context in
            ServerViewerProvider(session: context.session, receipts: receipts)
        }
        accounts = AccountsProvidersModel(accountStore: store, registry: registry, profilesModel: profiles)
        plex = PlexHomeUsersModel(
            accountsProviders: accounts, profilesModel: profiles,
            plexHomeUserTokenCache: PlexHomeUserTokenCache(store: InMemorySecureStore()),
            automaticSignInStore: AutomaticSignInStore(defaults: defaults, secureStore: InMemorySecureStore()),
            switchProfile: { _ in XCTFail("This fixture never changes Plozz profiles") }
        )
        plex.plexHomeUserSwitch = { user, _, _, _ in "user-\(user)" }
        plex.plexServerTokenResolve = { _, token, _ in "server-\(token)" }
        accounts.tokenResolver = { [plex] in plex.resolvedToken(for: $0) }
        accounts.credentialRevision = { [plex] in plex.effectiveCredentialRevision(for: $0) }
        accounts.reloadAccounts()
    }

    func selectMetadata(_ user: String?) {
        profiles.update(profiles.activeProfile.settingHomeUserBinding(
            user.map { PlexHomeUserBinding(homeUserID: $0, name: $0, requiresPIN: false) },
            forPlexAccount: "plex"
        ))
    }

    func activate(_ user: String) async throws {
        plex.setPlexHomeUserForActiveProfile(
            accountID: "plex", user: PlexHomeUser(id: user, name: user, requiresPIN: false)
        )
        for _ in 0..<200 {
            if plex.hasResolvedWatchMutationIdentity(forAccountID: "plex"),
               plex.resolvedToken(for: "plex") == "server-user-\(user)" { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Fixture Home-user switch did not complete")
        throw AppError.serverUnreachable
    }

    func applier(gate: ServerViewerResolutionGate? = nil) -> AppShellWatchMutationApplier {
        AppShellWatchMutationApplier(
            validateServerScope: { [accounts, plex] scope in
                try await MainActor.run {
                    try accounts.requireWatchMutationServerScope(
                        scope, isPlexIdentityResolved: plex.hasResolvedWatchMutationIdentity
                    )
                }
            },
            resolveProvider: { [accounts, plex] accountID in
                await gate?.pauseOnce()
                return await MainActor.run {
                    accounts.provider(
                        forWatchMutationAccountID: accountID,
                        isPlexIdentityResolved: plex.hasResolvedWatchMutationIdentity
                    )
                }
            },
            applyTrakt: { _ in }, applySimkl: { _ in }, applyAniList: { _ in }, applyMAL: { _ in }
        )
    }
}

private actor ServerViewerResolutionGate {
    private var paused = false
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    func pauseOnce() async {
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

private actor ServerViewerReceipts {
    private(set) var writes: [String] = []
    func record(_ value: String) { writes.append(value) }
}

private struct ServerViewerProvider: MediaProvider, WatchStateProviding, ResumeStateWriting {
    let kind = ProviderKind.plex
    let session: UserSession
    let receipts: ServerViewerReceipts
    func setPlayed(_ played: Bool, itemID: String) async throws {
        await receipts.record("\(session.accessToken):played")
    }
    func setResumePosition(_ seconds: TimeInterval, itemID: String, capturedAt: Date) async throws {
        await receipts.record("\(session.accessToken):resume")
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage { throw AppError.notFound }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
