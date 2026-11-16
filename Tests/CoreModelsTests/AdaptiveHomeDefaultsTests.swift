import CoreModels
import XCTest

@MainActor
final class AdaptiveHomeDefaultsTests: XCTestCase {
    private func source(
        _ accountID: String, serverID: String = "server", userID: String = "viewer",
        provider: ProviderKind = .jellyfin
    ) -> (ResolvedAccount, AdaptiveHomeProvider) {
        let server = MediaServer(
            id: serverID, name: serverID, baseURL: URL(string: "https://media.example")!,
            provider: provider
        )
        let backend = AdaptiveHomeProvider(session: UserSession(
            server: server, userID: userID, userName: "Viewer", deviceID: "device", accessToken: ""
        ))
        return (
            ResolvedAccount(
                account: Account(id: accountID, server: server, userID: userID,
                                 userName: "Viewer", deviceID: "device"),
                provider: backend
            ), backend
        )
    }

    private func model() -> (HomeLibraryVisibilityModel, String) {
        let name = "AdaptiveHome-\(UUID())"
        let store = HomeLibraryVisibilityStore(defaults: UserDefaults(suiteName: name)!, namespace: "profile")
        return (HomeLibraryVisibilityModel(store: store), name)
    }

    func testSingleServerMatchesOrderedSectionsWithoutEnumeratingLibraries() async {
        let (model, suite) = model()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (account, provider) = source("a")
        let sections: [ServerHomeSection] = [
            .init(id: "nextup", kind: .nextUp),
            .init(id: "libraries", kind: .libraries),
            .init(id: "resume", kind: .continueWatching)
        ]
        await provider.setLayout(.init(sections: sections, source: .webPreferences))
        await model.prepareServerDefaults(accounts: [account])
        let visibility = model.visibility
        XCTAssertEqual(visibility.rowCustomization?.defaults, .matchServer)
        XCTAssertEqual(visibility.rowCustomization?.effectiveOrder, [
            .server(accountID: "a", section: "nextup"), .libraries, .global(.continueWatching)
        ])
        XCTAssertFalse(visibility.isGlobalRowEnabled(.watchlist))
        XCTAssertTrue(visibility.isGlobalRowEnabled(.continueWatching))
        let calls = await provider.calls
        XCTAssertEqual(calls.layouts, 1)
        XCTAssertEqual(calls.libraries, 0)
    }

    func testMultipleServersCombineCommonRowsAndKeepOtherServerDefaults() async {
        let (model, suite) = model()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (a, first) = source("a", serverID: "one")
        let (b, second) = source("b", serverID: "two")
        await first.setLayout(.init(sections: [
            .init(id: "resume", kind: .continueWatching),
            .init(id: "picks", kind: .recommendations, title: "Server picks", libraryID: "movies")
        ], source: .promotedHubs))
        await second.setLayout(.init(sections: [
            .init(id: "resume", kind: .continueWatching),
            .init(id: "latest", kind: .recentlyAdded, libraryID: "shows")
        ], source: .webPreferences))
        await model.prepareServerDefaults(accounts: [a, b])
        XCTAssertEqual(model.visibility.rowCustomization?.defaults, .matchServer)
        XCTAssertEqual(model.visibility.rowCustomization?.resolvedDefaults?.mode, .combined)
        XCTAssertTrue(model.visibility.isGlobalRowEnabled(.recentlyAdded))
        let firstCalls = await first.calls
        let secondCalls = await second.calls
        XCTAssertEqual(firstCalls.layouts + secondCalls.layouts, 2)
        let native = model.visibility.rowCustomization?.availableServerRows ?? []
        let choices = HomeRowChoice.shared + native.filter {
            if case .server = $0.id { return true }
            return false
        }.map(HomeRowChoice.init(serverRow:))
        XCTAssertEqual(model.visibility.rowSections(choices: choices).enabled, [
            .global(.continueWatching), .global(.comingSoon), .global(.watchlist), .global(.recentlyAdded),
            .server(accountID: "a", section: "picks"), .server(accountID: "b", section: "latest"),
            .liveTV, .libraries
        ])
        model.useRowDefaults(.combined)
        XCTAssertEqual(model.visibility.rowSections(choices: choices).enabled, [
            .global(.continueWatching), .global(.comingSoon), .global(.watchlist),
            .global(.recentlyAdded), .liveTV, .libraries
        ])
    }

    func testMultipleServersRetainOfflineRowsAndFallbackOnlyForUnsupportedSources() async {
        let (model, suite) = model()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (a, first) = source("a", serverID: "one")
        let (b, _) = source("b", serverID: "two")
        let now = Date(timeIntervalSince1970: 1_000)
        await first.setLayout(.init(sections: [
            .init(id: "picks", kind: .recommendations)
        ], source: .server))
        await model.prepareServerDefaults(accounts: [a, b], now: now)
        let initial = model.visibility.rowCustomization?.resolvedDefaults
        XCTAssertEqual(initial?.fallbackAccountIDs, ["b"])
        XCTAssertFalse(model.visibility.rowCustomization!.isVisible(
            .library("a:movies", kind: .recentlyAdded), providerDefault: true
        ))
        XCTAssertTrue(model.visibility.rowCustomization!.isVisible(
            .library("b:movies", kind: .recentlyAdded), providerDefault: true
        ))
        await first.setError(.serverUnreachable)
        await model.prepareServerDefaults(accounts: [a, b], now: now.addingTimeInterval(121))
        XCTAssertEqual(model.visibility.rowCustomization?.resolvedDefaults, initial)
        XCTAssertEqual(model.serverMatchFailures, ["a": .serverUnreachable])
        await first.setLayout(.init(sections: [], source: .server))
        await model.prepareServerDefaults(accounts: [a, b], now: now.addingTimeInterval(242))
        let emptyNative = model.visibility.rowCustomization?.resolvedDefaults
        XCTAssertEqual(emptyNative?.fallbackAccountIDs, ["b"])
        await first.setError(.serverUnreachable)
        await model.prepareServerDefaults(accounts: [a, b], now: now.addingTimeInterval(363))
        XCTAssertEqual(model.visibility.rowCustomization?.resolvedDefaults, emptyNative,
                       "An offline server's deliberately empty layout is not a missing layout.")
        await model.prepareServerDefaults(accounts: [b], now: now.addingTimeInterval(364))
        XCTAssertEqual(model.visibility.rowCustomization?.resolvedDefaults?.mode, .providerFallback)
        XCTAssertTrue(model.visibility.rowCustomization?.availableServerRows.isEmpty == true)
        XCTAssertTrue(model.serverMatchFailures.isEmpty)
    }

    func testFailuresIdentifyEachServerAndClearIndependentlyAfterRecovery() async {
        let (model, suite) = model()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (a, first) = source("a", serverID: "one")
        let (b, second) = source("b", serverID: "two")
        let (c, _) = source("c", serverID: "unsupported")
        await first.setError(.serverUnreachable)
        await second.setError(.unauthorized)
        await model.prepareServerDefaults(accounts: [a, b, c])
        XCTAssertEqual(model.serverMatchFailures, ["a": .serverUnreachable, "b": .unauthorized])

        await first.setLayout(.init(sections: [], source: .server))
        await model.prepareServerDefaults(accounts: [a, b, c])
        XCTAssertEqual(model.serverMatchFailures, ["b": .unauthorized])

        await second.setLayout(.init(sections: [], source: .server))
        await model.prepareServerDefaults(accounts: [a, b, c])
        XCTAssertTrue(model.serverMatchFailures.isEmpty)

        await first.setError(.serverUnreachable)
        await model.prepareServerDefaults(accounts: [a])
        XCTAssertEqual(model.serverMatchFailures, ["a": .serverUnreachable])
        model.useRowDefaults(.combined)
        XCTAssertTrue(model.serverMatchFailures.isEmpty)
    }

    func testChangingViewerClearsPreviousFailureWhileNewRequestIsPending() async {
        let (model, suite) = model()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (a, first) = source("a", provider: .plex)
        let (_, second) = source("a", provider: .plex)
        await first.setError(.unauthorized)
        await model.prepareServerDefaults(accounts: [
            ResolvedAccount(account: a.account, provider: first, plexHomeUserID: "first")
        ])
        XCTAssertEqual(model.serverMatchFailures, ["a": .unauthorized])

        await second.suspend()
        let pending = Task { await model.prepareServerDefaults(accounts: [
            ResolvedAccount(account: a.account, provider: second, plexHomeUserID: "second")
        ]) }
        await second.waitUntilRequested()
        XCTAssertTrue(model.serverMatchFailures.isEmpty)
        await second.resume()
        await pending.value
        XCTAssertTrue(model.serverMatchFailures.isEmpty)
    }

    func testReturningToFreshCacheClearsAnotherViewersFailureWithoutRefetching() async {
        let (model, suite) = model()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (a, first) = source("a", provider: .plex)
        let (_, second) = source("a", provider: .plex)
        let firstViewer = ResolvedAccount(account: a.account, provider: first, plexHomeUserID: "first")
        let secondViewer = ResolvedAccount(account: a.account, provider: second, plexHomeUserID: "second")
        let now = Date(timeIntervalSince1970: 1_000)
        await model.prepareServerDefaults(accounts: [firstViewer], now: now)
        await second.setError(.unauthorized)
        await model.prepareServerDefaults(accounts: [secondViewer], now: now.addingTimeInterval(1))
        XCTAssertEqual(model.serverMatchFailures, ["a": .unauthorized])
        await model.prepareServerDefaults(accounts: [firstViewer], now: now.addingTimeInterval(2))
        XCTAssertTrue(model.serverMatchFailures.isEmpty)
        let calls = await first.calls
        XCTAssertEqual(calls.layouts, 1)
    }

    func testPlexHomeViewerChangeInvalidatesFreshLayoutWithUnchangedAccountUser() async {
        let (model, suite) = model()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (a, backend) = source("a", provider: .plex)
        func viewer(_ id: String) -> ResolvedAccount {
            ResolvedAccount(account: a.account, provider: backend, plexHomeUserID: id)
        }
        let now = Date(timeIntervalSince1970: 1_000)
        await backend.setLayout(.init(sections: [.init(id: "adult", kind: .recommendations)], source: .server))
        await model.prepareServerDefaults(accounts: [viewer("adult")], now: now)
        await backend.setLayout(.init(sections: [.init(id: "child", kind: .recommendations)], source: .server))
        await model.prepareServerDefaults(accounts: [viewer("child")], now: now.addingTimeInterval(1))
        XCTAssertEqual(model.visibility.rowCustomization?.availableServerRows.map(\.section.id), ["child"])
        let calls = await backend.calls
        XCTAssertEqual(calls.layouts, 2)
        let cached = HomeLibraryVisibilityStore(
            defaults: UserDefaults(suiteName: suite)!, namespace: "profile"
        ).loadServerDefaults()
        XCTAssertTrue(cached?.scope.contains("home:child") == true)
        XCTAssertFalse(cached?.scope.contains(a.credentialRevision.rawValue.uuidString) == true)
    }

    func testEffectiveCredentialChangeCannotJoinOrPublishSupersededDiscovery() async {
        let (model, suite) = model()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (a, old) = source("a", provider: .plex)
        let (_, current) = source("a", provider: .plex)
        await old.setLayout(.init(sections: [.init(id: "old", kind: .recommendations)], source: .server))
        await old.suspend()
        let oldRequest = Task { await model.prepareServerDefaults(accounts: [
            ResolvedAccount(account: a.account, provider: old, plexHomeUserID: "child")
        ]) }
        await old.waitUntilRequested()
        await current.setLayout(.init(sections: [.init(id: "current", kind: .recommendations)], source: .server))
        await model.prepareServerDefaults(accounts: [
            ResolvedAccount(
                account: a.account, provider: current, plexHomeUserID: "child",
                credentialRevision: CredentialRevision()
            )
        ])
        await old.setError(.serverUnreachable)
        await old.resume()
        await oldRequest.value
        XCTAssertEqual(model.visibility.rowCustomization?.availableServerRows.map(\.section.id), ["current"])
        XCTAssertTrue(model.serverMatchFailures.isEmpty)
        let calls = await current.calls
        XCTAssertEqual(calls.layouts, 1)
    }

    func testEffectiveCredentialRotationInvalidatesFreshLayout() async {
        let (model, suite) = model()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (a, backend) = source("a", provider: .plex)
        await backend.setLayout(.init(sections: [.init(id: "old", kind: .recommendations)], source: .server))
        await model.prepareServerDefaults(accounts: [a])
        await backend.setLayout(.init(sections: [.init(id: "current", kind: .recommendations)], source: .server))
        await model.prepareServerDefaults(accounts: [
            ResolvedAccount(account: a.account, provider: backend, credentialRevision: CredentialRevision())
        ])
        XCTAssertEqual(model.visibility.rowCustomization?.availableServerRows.map(\.section.id), ["current"])
        let calls = await backend.calls
        XCTAssertEqual(calls.layouts, 2)
    }

    func testSameViewerCacheSurvivesRelaunchAndEphemeralCredentialRevision() async {
        let (model, suite) = model()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (a, backend) = source("a", provider: .plex)
        await backend.setLayout(.init(sections: [.init(id: "known", kind: .recommendations)], source: .server))
        await model.prepareServerDefaults(accounts: [
            ResolvedAccount(account: a.account, provider: backend, plexHomeUserID: "child")
        ])
        let relaunched = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(
            defaults: UserDefaults(suiteName: suite)!, namespace: "profile"
        ))
        await backend.setError(.serverUnreachable)
        await relaunched.prepareServerDefaults(accounts: [
            ResolvedAccount(
                account: a.account, provider: backend, plexHomeUserID: "child",
                credentialRevision: CredentialRevision()
            )
        ])
        XCTAssertEqual(relaunched.visibility.rowCustomization?.availableServerRows.map(\.section.id), ["known"])
        XCTAssertEqual(relaunched.serverMatchFailures, ["a": .serverUnreachable])
    }

    func testReturningToFreshViewerCacheFencesAnotherViewersPendingRequest() async {
        let (model, suite) = model()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (a, first) = source("a", provider: .plex)
        let (_, second) = source("a", provider: .plex)
        let firstViewer = ResolvedAccount(account: a.account, provider: first, plexHomeUserID: "first")
        let secondViewer = ResolvedAccount(account: a.account, provider: second, plexHomeUserID: "second")
        await first.setLayout(.init(sections: [.init(id: "first", kind: .recommendations)], source: .server))
        await model.prepareServerDefaults(accounts: [firstViewer])
        await second.setLayout(.init(sections: [.init(id: "second", kind: .recommendations)], source: .server))
        await second.suspend()
        let pending = Task { await model.prepareServerDefaults(accounts: [secondViewer]) }
        await second.waitUntilRequested()
        await model.prepareServerDefaults(accounts: [firstViewer])
        await second.resume()
        await pending.value
        XCTAssertEqual(model.visibility.rowCustomization?.availableServerRows.map(\.section.id), ["first"])
        let calls = await first.calls
        XCTAssertEqual(calls.layouts, 1)
    }

    func testTwoAccountsForSameServerUserStillMatchOneServer() async {
        let (model, suite) = model()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (a, first) = source("a")
        let (b, _) = source("b")
        await first.setLayout(.init(sections: [.init(id: "resume", kind: .continueWatching)], source: .server))
        await model.prepareServerDefaults(accounts: [a, b])
        XCTAssertEqual(model.visibility.rowCustomization?.resolvedDefaults?.mode, .server)
    }

    func testProviderIsPartOfPhysicalServerIdentity() async {
        let (model, suite) = model()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (a, _) = source("a", provider: .jellyfin)
        let (b, _) = source("b", provider: .plex)
        await model.prepareServerDefaults(accounts: [a, b])
        XCTAssertEqual(model.visibility.rowCustomization?.resolvedDefaults?.mode, .combined)
    }

    func testAutomaticModeAdaptsButCustomAllHiddenDoesNot() async {
        let (model, suite) = model()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (a, first) = source("a", serverID: "one")
        let (b, _) = source("b", serverID: "two")
        await first.setLayout(.init(sections: [.init(id: "resume", kind: .continueWatching)], source: .server))
        await model.prepareServerDefaults(accounts: [a])
        await model.prepareServerDefaults(accounts: [a, b])
        XCTAssertEqual(model.visibility.rowCustomization?.resolvedDefaults?.mode, .combined)
        let choices = HomeRowChoice.shared
        model.applyRows(.init(enabled: [], disabled: choices.map(\.id)), choices: choices)
        let custom = model.visibility
        XCTAssertEqual(custom.rowCustomization?.defaults, .custom)
        await model.prepareServerDefaults(accounts: [a])
        XCTAssertEqual(model.visibility, custom)
        XCTAssertTrue(model.visibility.rowSections(choices: choices).enabled.isEmpty)
        model.useRowDefaults(.matchServer)
        await model.prepareServerDefaults(accounts: [a])
        XCTAssertEqual(model.visibility.rowCustomization?.resolvedDefaults?.mode, .server)
        XCTAssertTrue(model.visibility.isGlobalRowEnabled(.continueWatching))
    }

    func testManualRowEditFreezesNativeRequestsAndDoesNotSyncResolvedCache() async throws {
        let (model, suite) = model()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (account, provider) = source("a")
        await provider.setLayout(.init(sections: [
            .init(id: "native", kind: .recommendations, title: "Server picks"),
            .init(id: "resume", kind: .continueWatching)
        ], source: .server))
        await model.prepareServerDefaults(accounts: [account])
        let encodedAutomatic = try JSONEncoder().encode(model.visibility)
        let decodedAutomatic = try JSONDecoder().decode(HomeLibraryVisibility.self, from: encodedAutomatic)
        XCTAssertNil(decodedAutomatic.rowCustomization?.resolvedDefaults)
        let definitions = try XCTUnwrap(model.visibility.rowCustomization?.availableServerRows)
        let choices = definitions.map(HomeRowChoice.init(serverRow:))
        model.applyRows(
            .init(enabled: [.global(.continueWatching), .server(accountID: "a", section: "native")],
                  disabled: []),
            choices: choices
        )
        let restored = try JSONDecoder().decode(
            HomeLibraryVisibility.self, from: JSONEncoder().encode(model.visibility)
        )
        XCTAssertEqual(restored.rowCustomization?.defaults, .custom)
        XCTAssertEqual(restored.rowCustomization?.availableServerRows.count, 2)
        XCTAssertEqual(restored.rowCustomization?.effectiveOrder.first, .global(.continueWatching))
    }

    func testReorderingAndHidingInOneEditPreservesTheEditedOrder() {
        let watching = HomeRowID.global(.continueWatching)
        let latest = HomeRowID.global(.recentlyAdded)
        let watchlist = HomeRowID.global(.watchlist)
        var rows = HomeRowCustomization(defaults: .matchServer)
        rows.resolvedDefaults = .init(
            mode: .server, order: [watching, latest, watchlist]
        )
        rows.apply(
            .init(enabled: [watchlist, watching], disabled: [latest, .libraries, .liveTV]),
            choices: HomeRowChoice.shared
        )
        XCTAssertEqual(rows.defaults, .custom)
        XCTAssertEqual(rows.sections(choices: HomeRowChoice.shared).enabled, [watchlist, watching])
        XCTAssertFalse(rows.isVisible(latest, providerDefault: true))
        XCTAssertNil(rows.resolvedDefaults)
    }

    func testFailedRefreshRetainsMatchingCacheButDifferentUserCannotReuseIt() async {
        let (model, suite) = model()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (a, first) = source("a")
        await first.setLayout(.init(sections: [.init(id: "resume", kind: .continueWatching)], source: .server))
        let now = Date(timeIntervalSince1970: 1_000)
        await model.prepareServerDefaults(accounts: [a], now: now)
        let original = model.visibility.rowCustomization?.resolvedDefaults
        await first.setError(.serverUnreachable)
        await model.prepareServerDefaults(accounts: [a], now: now.addingTimeInterval(121))
        XCTAssertEqual(model.serverMatchFailures, ["a": .serverUnreachable])
        XCTAssertEqual(model.visibility.rowCustomization?.resolvedDefaults, original)
        let (b, second) = source("a", userID: "another-user")
        await second.setError(.unauthorized)
        await model.prepareServerDefaults(accounts: [b], now: now.addingTimeInterval(122))
        XCTAssertNil(model.visibility.rowCustomization?.resolvedDefaults)
        XCTAssertEqual(model.serverMatchFailures, ["a": .unauthorized])
    }

    func testDerivedServerLayoutCacheCannotChangeProfileTransfer() async {
        let (model, suite) = model()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        model.useRowDefaults(.matchServer)
        let before = ProfileSettingsTransfer.capture(namespace: "profile", defaults: defaults)
        let (account, provider) = source("a")
        await provider.setLayout(.init(sections: [
            .init(id: "native", kind: .recommendations)
        ], source: .server))
        await model.prepareServerDefaults(accounts: [account])
        XCTAssertNotNil(HomeLibraryVisibilityStore(defaults: defaults, namespace: "profile").loadServerDefaults())
        XCTAssertEqual(ProfileSettingsTransfer.capture(namespace: "profile", defaults: defaults), before)
    }

    func testReturningWithinFreshnessWindowDoesNotRepeatLayoutRequest() async {
        let (model, suite) = model()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (account, provider) = source("a")
        let now = Date(timeIntervalSince1970: 1_000)
        await model.prepareServerDefaults(accounts: [account], now: now)
        await model.prepareServerDefaults(accounts: [account], now: now.addingTimeInterval(1))
        let calls = await provider.calls
        XCTAssertEqual(calls.layouts, 1)
    }
}

private actor AdaptiveHomeProvider: MediaProvider {
    nonisolated let session: UserSession
    nonisolated var kind: ProviderKind { session.server.provider }
    var calls = (layouts: 0, libraries: 0)
    private var layout: ServerHomeLayout?
    private var error: AppError?
    private var suspended = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var requested: CheckedContinuation<Void, Never>?

    init(session: UserSession) { self.session = session }
    func setLayout(_ layout: ServerHomeLayout) { self.layout = layout; error = nil }
    func setError(_ error: AppError) { self.error = error }
    func suspend() { suspended = true }
    func waitUntilRequested() async {
        if continuation != nil { return }
        await withCheckedContinuation { requested = $0 }
    }
    func resume() { continuation?.resume(); continuation = nil; suspended = false }
    func serverHomeLayout() async throws -> ServerHomeLayout? {
        calls.layouts += 1
        if suspended {
            await withCheckedContinuation {
                continuation = $0
                requested?.resume()
                requested = nil
            }
        }
        if let error { throw error }
        return layout
    }
    func libraries() async throws -> [MediaLibrary] { calls.libraries += 1; return [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: 0, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
