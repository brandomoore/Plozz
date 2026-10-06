import XCTest
@testable import AppShell
import AppRuntime
import CoreModels
import FeatureAuth

@MainActor
final class PlaybackStopFanOutTests: XCTestCase {
    func testPlaybackStopHonorsCrossServerSyncOffAtStopTime() async {
        let item = MediaItem(
            id: "origin-item",
            title: "Dune",
            kind: .movie,
            runtime: 100,
            providerIDs: ["Tmdb": "438631"],
            sourceAccountID: "origin"
        )
        let lookup = MutableIdentityLookup()
        let recorder = PlaybackStopRecorder()
        let stopped = expectation(description: "Stop handled")
        // Live reader returns OFF: the stop must scope to the origin server only,
        // even though the warm identity union knows peer servers.
        let bridge = WatchOutboxBridge(
            beginLiveSession: { _, _ in },
            finishPlayback: { accountID, itemID, _, mutation, item in
                recorder.record(accountID: accountID, itemID: itemID, mutation: mutation, item: item)
                stopped.fulfill()
            },
            checkpoint: { _ in },
            crossServerSync: { false }
        )

        let handler = makePlaybackStoppedHandler(
            convergingItem: item,
            primaryAccountID: "origin",
            liveAccountID: "origin",
            liveItemID: "origin-item",
            watchBridge: bridge,
            identitySources: lookup.sources(for:)
        )

        lookup.sources = [
            MediaSourceRef(accountID: "origin", itemID: "origin-item", providerKind: .jellyfin),
            MediaSourceRef(accountID: "plex", itemID: "plex-item", providerKind: .plex),
            MediaSourceRef(accountID: "jellyfin-two", itemID: "jf-two-item", providerKind: .jellyfin)
        ]

        handler(95, 95)
        await fulfillment(of: [stopped], timeout: 2)

        let call = recorder.onlyCall
        XCTAssertEqual(
            call?.mutation?.targets,
            [WatchMutationTarget(accountID: "origin", itemID: "origin-item", providerKind: .jellyfin)],
            "With sync OFF the stop must converge on the origin server only"
        )
        XCTAssertEqual(call?.mutation?.expansionPending, false, "Sync OFF must suppress drain-time re-expansion")
        XCTAssertEqual(call?.mutation?.identities, [], "Sync OFF must carry no identity seeds")
    }

    func testPlaybackStopFanOutUsesLiveIdentitySourcesAtStopTime() async {
        let item = MediaItem(
            id: "origin-item",
            title: "Dune",
            kind: .movie,
            runtime: 100,
            providerIDs: ["Tmdb": "438631"],
            sourceAccountID: "origin"
        )
        let lookup = MutableIdentityLookup()
        let recorder = PlaybackStopRecorder()
        let stopped = expectation(description: "Stop handled")
        let bridge = WatchOutboxBridge(
            beginLiveSession: { _, _ in },
            finishPlayback: { accountID, itemID, _, mutation, item in
                recorder.record(accountID: accountID, itemID: itemID, mutation: mutation, item: item)
                stopped.fulfill()
            },
            checkpoint: { _ in },
            crossServerSync: { true }
        )

        let handler = makePlaybackStoppedHandler(
            convergingItem: item,
            primaryAccountID: "origin",
            liveAccountID: "origin",
            liveItemID: "origin-item",
            watchBridge: bridge,
            identitySources: lookup.sources(for:)
        )

        lookup.sources = [
            MediaSourceRef(accountID: "origin", itemID: "origin-item", providerKind: .jellyfin),
            MediaSourceRef(accountID: "plex", itemID: "plex-item", providerKind: .plex),
            MediaSourceRef(accountID: "jellyfin-two", itemID: "jf-two-item", providerKind: .jellyfin)
        ]

        handler(95, 95)
        await fulfillment(of: [stopped], timeout: 2)

        let call = recorder.onlyCall
        XCTAssertEqual(call?.accountID, "origin")
        XCTAssertEqual(call?.itemID, "origin-item")
        XCTAssertEqual(
            call?.mutation?.targets,
            [
                WatchMutationTarget(accountID: "origin", itemID: "origin-item", providerKind: .jellyfin),
                WatchMutationTarget(accountID: "plex", itemID: "plex-item", providerKind: .plex),
                WatchMutationTarget(accountID: "jellyfin-two", itemID: "jf-two-item", providerKind: .jellyfin)
            ],
            "Targets must come from the live warmed identity snapshot at stop time, not the empty creation-time snapshot"
        )
        XCTAssertEqual(
            call?.item?.id,
            "origin-item",
            "The played card rides along, so a row that has never carried this title can show it without asking a server that may not have recorded the play yet"
        )
    }

    func testPlaybackCheckpointFansOutToUnionWithoutEndingSession() async {
        let item = MediaItem(
            id: "origin-item",
            title: "Dune",
            kind: .movie,
            runtime: 100,
            providerIDs: ["Tmdb": "438631"],
            sourceAccountID: "origin"
        )
        let lookup = MutableIdentityLookup()
        let checkpoints = CheckpointRecorder()
        let checkpointed = expectation(description: "Checkpoint handled")
        var finishCalls = 0
        let bridge = WatchOutboxBridge(
            beginLiveSession: { _, _ in },
            finishPlayback: { _, _, _, _, _ in finishCalls += 1 },
            checkpoint: { mutation in
                checkpoints.record(mutation)
                checkpointed.fulfill()
            },
            crossServerSync: { true }
        )

        let handler = makePlaybackCheckpointHandler(
            convergingItem: item,
            primaryAccountID: "origin",
            watchBridge: bridge,
            identitySources: lookup.sources(for:)
        )

        lookup.sources = [
            MediaSourceRef(accountID: "origin", itemID: "origin-item", providerKind: .jellyfin),
            MediaSourceRef(accountID: "plex", itemID: "plex-item", providerKind: .plex)
        ]

        // A partial mid-play position (~50%): converge resume to every server, but
        // never end the live session (that only happens at stop).
        handler(50, 50)
        await fulfillment(of: [checkpointed], timeout: 2)

        let mutation = checkpoints.onlyMutation
        XCTAssertEqual(
            mutation??.targets,
            [
                WatchMutationTarget(accountID: "origin", itemID: "origin-item", providerKind: .jellyfin),
                WatchMutationTarget(accountID: "plex", itemID: "plex-item", providerKind: .plex)
            ],
            "A checkpoint must fan the resume position out to the full warmed union"
        )
        XCTAssertEqual(mutation??.played, nil, "A partial checkpoint must not mark the item played")
        XCTAssertEqual(finishCalls, 0, "A checkpoint must not end the live session")
    }

    func testLateCheckpointAndStopStayWithLaunchingPlexHomeProfile() async throws {
        let fixture = try makeProfileFixture()
        let app = fixture.app
        let profiles = app.profilesModel
        let item = fixture.item
        let originalReconciler = app.watchReconciler
        app.identityIndex.identitySnapshotStore.update(snapshot(peer: "viewer-a-peer"))
        let bridge = app.makePlaybackWatchBridge()
        let checkpoint = makePlaybackCheckpointHandler(
            convergingItem: item, primaryAccountID: "shared-plex",
            watchBridge: bridge,
            identitySources: { _ in
                XCTFail("Playback must use the launch-scoped lookup")
                return []
            }
        )
        let stop = makePlaybackStoppedHandler(
            convergingItem: item, primaryAccountID: "shared-plex",
            liveAccountID: "shared-plex", liveItemID: item.id,
            watchBridge: bridge,
            identitySources: { _ in
                XCTFail("Playback must use the launch-scoped lookup")
                return []
            }
        )
        bridge.beginLiveSession("shared-plex", item.id)
        try await waitUntil {
            await originalReconciler.isLiveSession(accountID: "shared-plex", itemID: item.id)
        }

        profiles.select(fixture.otherProfile.id)
        app.accountsProviders.reloadAccounts()
        app.identityIndex.identitySnapshotStore.update(snapshot(peer: "viewer-b-only"))
        let otherReconciler = app.watchReconciler
        let otherBridge = app.makePlaybackWatchBridge()
        otherBridge.beginLiveSession("shared-plex", item.id)
        try await waitUntil {
            await otherReconciler.isLiveSession(accountID: "shared-plex", itemID: item.id)
        }

        checkpoint(50, 50)
        try await waitUntil { await originalReconciler.snapshot().pending.first?.resumePosition == 50 }
        let pendingCheckpoint = await originalReconciler.snapshot().pending
        XCTAssertEqual(Set(try XCTUnwrap(pendingCheckpoint.first).targets.map(\.accountID)),
                       ["shared-plex", "viewer-a-peer"])
        let stillPlaying = await originalReconciler.isLiveSession(accountID: "shared-plex", itemID: item.id)
        XCTAssertTrue(stillPlaying, "A checkpoint must preserve the origin-server deferral")

        let wrongProfileUpdate = expectation(description: "No optimistic updates in viewer B")
        wrongProfileUpdate.isInverted = true
        let observer = NotificationCenter.default.addObserver(
            forName: .mediaItemDidMutate, object: nil, queue: .main
        ) { notification in
            guard MediaItemMutation.from(notification)?.itemIDs.contains(item.id) == true else { return }
            wrongProfileUpdate.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        stop(95, 95)
        try await waitUntil {
            let state = await originalReconciler.snapshot()
            let live = await originalReconciler.isLiveSession(accountID: "shared-plex", itemID: item.id)
            return state.pending.first?.played == true && !live
        }
        await fulfillment(of: [wrongProfileUpdate], timeout: 0.1)

        let pendingStop = await originalReconciler.snapshot().pending
        XCTAssertEqual(pendingStop.count, 1, "The stop must supersede A's checkpoint in A's outbox")
        XCTAssertEqual(Set(try XCTUnwrap(pendingStop.first).targets.map(\.accountID)),
                       ["shared-plex", "viewer-a-peer"])
        let otherState = await otherReconciler.snapshot()
        XCTAssertTrue(otherState.pending.isEmpty, "A's stop must never enter B's outbox")
        let otherStillPlaying = await otherReconciler.isLiveSession(accountID: "shared-plex", itemID: item.id)
        XCTAssertTrue(otherStillPlaying, "A's late stop must not end B's session for the same Plex rating key")
        await otherReconciler.finishLiveSession(
            accountID: "shared-plex", itemID: item.id, mutation: nil,
            serverScope: app.accountsProviders.watchMutationServerScope
        )
    }

    func testSameProfileLateStopPreservesServerViewerAndDoesNotPublishIntoReplacementUI() async throws {
        let fixture = try makeProfileFixture()
        let app = fixture.app
        let originalScope = app.accountsProviders.watchMutationServerScope
        let bridge = app.makePlaybackWatchBridge()
        let stop = makePlaybackStoppedHandler(
            convergingItem: fixture.item, primaryAccountID: "shared-plex",
            liveAccountID: "shared-plex", liveItemID: fixture.item.id,
            watchBridge: bridge, identitySources: { _ in [] }
        )
        // Persisting the selected viewer can precede the asynchronous credential
        // switch. Both identities must be fenced, not just credential revision.
        app.profilesModel.update(app.profilesModel.activeProfile.settingHomeUserBinding(
            PlexHomeUserBinding(homeUserID: "replacement", name: "Replacement"),
            forPlexAccount: "shared-plex"
        ))
        let wrongUIUpdate = expectation(description: "No update for another Home user in the same profile")
        wrongUIUpdate.isInverted = true
        let itemID = fixture.item.id
        let observer = NotificationCenter.default.addObserver(
            forName: .mediaItemDidMutate, object: nil, queue: .main
        ) { notification in
            if MediaItemMutation.from(notification)?.itemIDs.contains(itemID) == true { wrongUIUpdate.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        stop(95, 95)
        try await waitUntil { await app.watchReconciler.pendingCount == 1 }
        await fulfillment(of: [wrongUIUpdate], timeout: 0.1)
        let pending = await app.watchReconciler.snapshot().pending
        XCTAssertEqual(pending.first?.serverScope, originalScope)
        let visiblePending = await app.pendingWatchMutations()
        XCTAssertTrue(visiblePending.isEmpty, "Home overlays must not replay another server viewer's pending progress")
    }

    func testCapturedBridgeUsesLiveSettingsAndIndexOnlyForLaunchingProfile() throws {
        let fixture = try makeProfileFixture()
        let app = fixture.app
        let namespace = app.profilesModel.activeNamespace
        let store = PlaybackSettingsStore(namespace: namespace)
        var settings = store.load()
        settings.syncWatchAcrossServers = false
        store.save(settings)
        let bridge = app.makePlaybackWatchBridge()
        XCTAssertFalse(bridge.crossServerSync())
        settings.syncWatchAcrossServers = true
        store.save(settings)
        XCTAssertTrue(bridge.crossServerSync(), "A's own mid-play setting changes must remain live")

        app.identityIndex.identitySnapshotStore.update(snapshot(peer: "warmed-during-play"))
        XCTAssertEqual(Set(bridge.identitySources?(fixture.item).map(\.accountID) ?? []),
                       ["shared-plex", "warmed-during-play"])

        app.profilesModel.select(fixture.otherProfile.id)
        app.accountsProviders.reloadAccounts()
        app.identityIndex.identitySnapshotStore.update(snapshot(peer: "viewer-b-only"))
        XCTAssertTrue(bridge.crossServerSync(), "B's disabled setting must not change A's late stop")
        XCTAssertEqual(bridge.identitySources?(fixture.item), [],
                       "After switching, use A's launch snapshot, never B's live identity index")
    }

    private func snapshot(peer: String) -> IdentityIndexSnapshot {
        IdentityIndexSnapshot(byIdentity: [
            .external(source: "tmdb", value: "438631"): [
                IndexedSource(accountID: "shared-plex", itemID: "origin-item", providerKind: .plex, kind: .movie),
                IndexedSource(accountID: peer, itemID: "peer-item", providerKind: .jellyfin, kind: .movie)
            ]
        ])
    }

    private func makeProfileFixture() throws -> (app: AppState, otherProfile: Profile, item: MediaItem) {
        let suite = "PlaybackStopFanOutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let profiles = ProfilesModel(store: ProfileStore(defaults: defaults))
        var first = profiles.add(name: "Viewer A")
        first.plexHomeUserAccountID = "shared-plex"
        first.plexHomeUserID = "home-a"
        profiles.update(first)
        var second = profiles.add(name: "Viewer B")
        second.plexHomeUserAccountID = "shared-plex"
        second.plexHomeUserID = "home-b"
        profiles.update(second)
        profiles.select(first.id)
        for (profile, sync) in [(first, true), (second, false)] {
            var settings = PlaybackSettings.default
            settings.syncWatchAcrossServers = sync
            PlaybackSettingsStore(namespace: profile.id).save(settings)
            let key = SettingsKey.scoped("com.plozz.playbackSettings", namespace: profile.id)
            addTeardownBlock { UserDefaults.standard.removeObject(forKey: key) }
        }
        let account = Account(
            id: "shared-plex",
            server: MediaServer(id: "plex-server", name: "Plex",
                                baseURL: URL(string: "https://plex.example.test")!, provider: .plex),
            userID: "household-owner", userName: "Owner", deviceID: "fixture"
        )
        XCTAssertNotEqual(first.plexPlaybackIdentityKey(for: [account]),
                          second.plexPlaybackIdentityKey(for: [account]))
        let accounts = AccountStore(secureStore: InMemorySecureStore())
        try accounts.add(account, token: "fixture-owner-token")
        let registry = ProviderRegistry()
        registry.register(.plex) { _ in
            XCTFail("An inactive viewer's late stop must not resolve the current viewer's provider")
            throw AppError.notFound
        }
        let app = AppState(
            accountStore: accounts, registry: registry, profilesModel: profiles,
            appAdmissionStore: AppAdmissionStore(defaults: defaults)
        )
        app.accountsProviders.onAccountsInvalidated = {}
        app.accountsProviders.onActiveAccountsChanged = { _, _ in }
        app.accountsProviders.reloadAccounts()
        let item = MediaItem(
            id: "origin-item", title: "Dune", kind: .movie, runtime: 100,
            providerIDs: ["Tmdb": "438631"], sourceAccountID: account.id
        )
        return (app, second, item)
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Playback lifecycle callback did not settle")
    }
}

private final class CheckpointRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var mutations: [WatchMutation?] = []

    var onlyMutation: WatchMutation?? {
        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(mutations.count, 1)
        return mutations.first
    }

    func record(_ mutation: WatchMutation?) {
        lock.lock()
        mutations.append(mutation)
        lock.unlock()
    }
}

private final class MutableIdentityLookup: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSources: [MediaSourceRef] = []

    var sources: [MediaSourceRef] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedSources
        }
        set {
            lock.lock()
            storedSources = newValue
            lock.unlock()
        }
    }

    func sources(for item: MediaItem) -> [MediaSourceRef] {
        sources
    }
}

private final class PlaybackStopRecorder: @unchecked Sendable {
    struct Call {
        let accountID: String?
        let itemID: String
        let mutation: WatchMutation?
        /// The played card. Carried so a surface can show a title it was not
        /// already showing — the first play of something is precisely the case
        /// Continue Watching has no existing card to update.
        let item: MediaItem?
    }

    private let lock = NSLock()
    private var calls: [Call] = []

    var onlyCall: Call? {
        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(calls.count, 1)
        return calls.first
    }

    func record(accountID: String?, itemID: String, mutation: WatchMutation?, item: MediaItem?) {
        lock.lock()
        calls.append(Call(accountID: accountID, itemID: itemID, mutation: mutation, item: item))
        lock.unlock()
    }
}
