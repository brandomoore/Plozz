import CoreModels
import FeatureLiveTVCore
import Foundation
import XCTest
@testable import AppRuntime

@MainActor
final class LiveTVSourceSyncBridgeTests: XCTestCase {
    func testAddressesGuideIdentitiesEditsAndDeletionRoundTripWithoutRepublishing() async throws {
        let sender = try Fixture()
        let receiver = try Fixture()
        let source = LiveTVPlaylistSource(
            name: "Fixture", playlistURL: URL(string: "https://example.test/list?token=fixture")!,
            guideURLs: [URL(string: "https://example.test/guide?token=guide-fixture")!],
            guideSourceIDs: ["stable-guide"]
        )
        try sender.store.save(.init(playlists: [source]))
        let initial = try await sender.bridge.capture(sender.snapshot([:]))
        await receiver.bridge.apply(receiver.snapshot(initial))
        XCTAssertEqual(try receiver.store.load().playlists, [source])
        let echo = try await receiver.bridge.capture(receiver.snapshot(initial))
        XCTAssertEqual(echo, initial)

        var edited = try sender.store.load()
        edited.playlists[0].name = "Updated"
        edited.playlists[0].guideLookaheadDays = 14
        try sender.store.save(edited)
        let update = try await sender.bridge.capture(sender.snapshot(initial))
        await receiver.bridge.apply(receiver.snapshot(update))
        XCTAssertEqual(try receiver.store.load().playlists, edited.playlists)

        var removed = try sender.store.load()
        removed.playlists = []
        try sender.store.save(removed)
        let deletion = try await sender.bridge.capture(sender.snapshot(update))
        await receiver.bridge.apply(receiver.snapshot(deletion))
        XCTAssertTrue(try receiver.store.load().playlists.isEmpty)
        let deletedEcho = try await receiver.bridge.capture(receiver.snapshot(deletion))
        XCTAssertEqual(deletedEcho, deletion)
    }

    func testImportedFilesRequireCompleteTransferAndRestoreInEitherDeliveryOrder() async throws {
        let sender = try Fixture()
        let receiver = try Fixture()
        let chunksFirst = try Fixture()
        let id = UUID()
        let data = Data("#EXTM3U\n#EXTINF:-1,Fixture\nlive.m3u8\n".utf8)
        let base = URL(string: "https://example.test/")!
        _ = try await sender.cache.storeImportedPlaylist(data: data, id: id, baseURL: base)
        let source = LiveTVPlaylistSource(
            id: id.uuidString, name: "Imported", playlistURL: URL(string: "plozz-playlist://" + id.uuidString.lowercased())!
        )
        try sender.store.save(.init(playlists: [source]))
        let records = try await sender.bridge.capture(sender.snapshot([:]))
        let manifests = records.filter { LiveTVPortableRecordKey.parse($0.key)?.kind == .source }
        let chunks = records.filter { LiveTVPortableRecordKey.parse($0.key)?.kind == .snapshot }
        XCTAssertFalse(chunks.isEmpty)
        await receiver.bridge.apply(receiver.snapshot(manifests))
        XCTAssertTrue(try receiver.store.load().playlists.isEmpty)
        XCTAssertEqual(receiver.bridge.statuses[receiver.profileID], .pendingFiles(1))
        let pendingEcho = try await receiver.bridge.capture(receiver.snapshot(manifests))
        XCTAssertEqual(pendingEcho, manifests)
        await chunksFirst.bridge.apply(chunksFirst.snapshot(chunks))
        XCTAssertTrue(try chunksFirst.store.load().playlists.isEmpty)
        for device in [receiver, chunksFirst] {
            await device.bridge.apply(device.snapshot(records))
            XCTAssertEqual(try device.store.load().playlists, [source])
            let imported = try await device.cache.importedPlaylist(id: id)
            XCTAssertEqual(imported.channels.first?.streamURL?.absoluteString, "https://example.test/live.m3u8")
            let echo = try await device.bridge.capture(device.snapshot(records))
            XCTAssertEqual(echo, records)
        }
    }

    func testLocalEditsSurviveIncomingSnapshotAndStaleSnapshotsCannotRollBack() async throws {
        let fixture = try Fixture()
        var source = LiveTVPlaylistSource(name: "First", playlistURL: URL(string: "https://example.test/live")!)
        let record = LiveTVPortableRecordKey(profileID: fixture.profileID, kind: .source, entityID: source.id).recordName
        let initial = [record: try LiveTVSourceSyncManifest(source: source).canonicalData()]
        let oldSnapshot = fixture.snapshot(initial)
        await fixture.bridge.apply(oldSnapshot)
        source.name = "Remote update"
        let updated = [record: try LiveTVSourceSyncManifest(source: source).canonicalData()]
        await fixture.bridge.apply(fixture.snapshot(updated))
        await fixture.bridge.apply(oldSnapshot)
        XCTAssertEqual(try fixture.store.load().playlists[0].name, "Remote update")
        var local = try fixture.store.load()
        local.playlists[0].name = "Unpublished local edit"
        try fixture.store.save(local)
        await fixture.bridge.apply(fixture.snapshot(updated))
        XCTAssertEqual(try fixture.store.load().playlists[0].name, "Unpublished local edit")
        let captured = try await fixture.bridge.capture(fixture.snapshot(updated))
        let manifest = try JSONDecoder().decode(LiveTVSourceSyncManifest.self, from: XCTUnwrap(captured[record]))
        XCTAssertEqual(manifest.source?.name, "Unpublished local edit")
    }

    func testMainSwitchAndAccountEpochFenceSourceTransfer() async throws {
        let sender = try Fixture()
        let receiver = try Fixture()
        let source = LiveTVPlaylistSource(name: "Fixture", playlistURL: URL(string: "https://example.test/live")!)
        try sender.store.save(.init(playlists: [source]))
        let records = try await sender.bridge.capture(sender.snapshot([:]))
        SyncSetupFeatureFlag(defaults: receiver.defaults).isEnabled = false
        await receiver.bridge.apply(receiver.snapshot(records))
        XCTAssertTrue(try receiver.store.load().playlists.isEmpty)
        SyncSetupFeatureFlag(defaults: receiver.defaults).isEnabled = true
        let oldAccount = receiver.snapshot(records)
        await receiver.bridge.apply(oldAccount)
        XCTAssertEqual(try receiver.store.load().playlists, [source])
        LiveTVPortableSyncPreferenceStore.accountDidChange(defaults: receiver.defaults)
        receiver.bridge.accountDidChange()
        await receiver.bridge.apply(oldAccount)
        XCTAssertTrue(try receiver.store.load().playlists.isEmpty)
        LiveTVPortableSyncPreferenceStore.accountDidChange(defaults: sender.defaults)
        sender.bridge.accountDidChange()
        XCTAssertEqual(try sender.store.load().playlists, [source], "Locally authored sources remain local.")
    }

    func testProductionParticipationFollowsMainSwitchWithoutProfileOptIn() throws {
        let fixture = try Fixture()
        let bridge = LiveTVPortableSyncBridge(
            profiles: fixture.profiles, directory: fixture.folder, defaults: fixture.defaults,
            followsMainSync: true, sourceStore: { _ in fixture.store }
        )
        let preference = LiveTVPortableSyncPreferenceStore(defaults: fixture.defaults, profileID: fixture.profileID)
        XCTAssertFalse(preference.isEnabled)
        bridge.refreshParticipation()
        XCTAssertTrue(preference.isEnabled)
        SyncSetupFeatureFlag(defaults: fixture.defaults).isEnabled = false
        bridge.refreshParticipation()
        XCTAssertFalse(preference.isEnabled)
    }

    func testCaptureWithoutDurableLedgerSaveCannotOverwriteLocalEditAfterRestart() async throws {
        let fixture = try Fixture()
        let source = LiveTVPlaylistSource(name: "Original", playlistURL: URL(string: "https://example.test/live")!)
        let name = LiveTVPortableRecordKey(profileID: fixture.profileID, kind: .source, entityID: source.id).recordName
        let original = [name: try LiveTVSourceSyncManifest(source: source).canonicalData()]
        await fixture.bridge.apply(fixture.snapshot(original))
        var edited = try fixture.store.load()
        edited.playlists[0].name = "Local edit before failed ledger save"
        try fixture.store.save(edited)
        let captured = try await fixture.bridge.capture(fixture.snapshot(original))
        XCTAssertNotEqual(captured, original)

        let restarted = fixture.restartedBridge()
        await restarted.apply(fixture.snapshot(original))
        XCTAssertEqual(try fixture.store.load().playlists, edited.playlists)
        let retry = try await restarted.capture(fixture.snapshot(original))
        XCTAssertEqual(retry, captured, "The uncommitted intent must be retried, not replaced by the old fallback.")
    }

    func testCapturedDeletionSurvivesFailedLedgerSaveAndRestart() async throws {
        let fixture = try Fixture()
        let source = LiveTVPlaylistSource(name: "Original", playlistURL: URL(string: "https://example.test/live")!)
        let name = LiveTVPortableRecordKey(profileID: fixture.profileID, kind: .source, entityID: source.id).recordName
        let original = [name: try LiveTVSourceSyncManifest(source: source).canonicalData()]
        await fixture.bridge.apply(fixture.snapshot(original))
        var removed = try fixture.store.load()
        removed.playlists = []
        try fixture.store.save(removed)
        let captured = try await fixture.bridge.capture(fixture.snapshot(original))
        let restarted = fixture.restartedBridge()
        await restarted.apply(fixture.snapshot(original))
        XCTAssertTrue(try fixture.store.load().playlists.isEmpty)
        let retry = try await restarted.capture(fixture.snapshot(original))
        XCTAssertEqual(retry, captured)
    }

    func testDurableReceiptPermitsServerConflictWinnerButNotOverANewerLocalEdit() async throws {
        for editAgain in [false, true] {
            let fixture = try Fixture()
            var source = LiveTVPlaylistSource(name: "Original", playlistURL: URL(string: "https://example.test/live")!)
            let name = LiveTVPortableRecordKey(profileID: fixture.profileID, kind: .source, entityID: source.id).recordName
            let original = [name: try LiveTVSourceSyncManifest(source: source).canonicalData()]
            await fixture.bridge.apply(fixture.snapshot(original))
            var edited = try fixture.store.load()
            edited.playlists[0].name = "First local edit"
            try fixture.store.save(edited)
            let captured = try await fixture.bridge.capture(fixture.snapshot(original))
            var ledger = SyncLedger()
            _ = ledger.reconcileLocal(desired: captured, now: 10)
            source.name = "Newer server winner"
            _ = ledger.applySendConflict(.init(
                recordName: name, value: try LiveTVSourceSyncManifest(source: source).canonicalData(),
                editedAt: 20, systemFields: Data()
            ), now: 20)
            ledger = try JSONDecoder().decode(SyncLedger.self, from: JSONEncoder().encode(ledger))
            if editAgain {
                edited = try fixture.store.load()
                edited.playlists[0].name = "Local edit after capture"
                try fixture.store.save(edited)
            }
            let restarted = fixture.restartedBridge()
            let snapshot = fixture.snapshot(
                ledger.entries.mapValues(\.localValue),
                receipts: ledger.entries.compactMapValues(\.localCaptureDigest)
            )
            await restarted.apply(snapshot)
            XCTAssertEqual(try fixture.store.load().playlists[0].name,
                           editAgain ? "Local edit after capture" : "Newer server winner")
            let next = try await restarted.capture(snapshot)
            if !editAgain { XCTAssertEqual(next, ledger.entries.mapValues(\.localValue)) }
        }
    }

    func testSourceStoreSaveFailureKeepsOldCheckpointAndRetries() async throws {
        let fixture = try Fixture()
        var source = LiveTVPlaylistSource(name: "Original", playlistURL: URL(string: "https://example.test/live")!)
        let name = LiveTVPortableRecordKey(profileID: fixture.profileID, kind: .source, entityID: source.id).recordName
        let original = [name: try LiveTVSourceSyncManifest(source: source).canonicalData()]
        await fixture.bridge.apply(fixture.snapshot(original))
        let before = try fixture.store.load()
        source.name = "Remote update"
        let updated = [name: try LiveTVSourceSyncManifest(source: source).canonicalData()]
        fixture.secrets.setWriteFailure(true)
        await fixture.bridge.apply(fixture.snapshot(updated))
        XCTAssertEqual(fixture.bridge.statuses[fixture.profileID], .unavailable)
        XCTAssertEqual(try fixture.store.load(), before)
        fixture.secrets.setWriteFailure(false)
        await fixture.bridge.apply(fixture.snapshot(updated))
        XCTAssertEqual(try fixture.store.load().playlists, [source])
        XCTAssertEqual(fixture.bridge.statuses[fixture.profileID], .ready)
    }

    func testRemovedAndUnknownProfilesDoNotReceiveSources() async throws {
        let fixture = try Fixture()
        let source = LiveTVPlaylistSource(name: "Original", playlistURL: URL(string: "https://example.test/live")!)
        let bytes = try LiveTVSourceSyncManifest(source: source).canonicalData()
        let unknown = LiveTVPortableRecordKey(profileID: "unknown-profile", kind: .source, entityID: source.id).recordName
        await fixture.bridge.apply(fixture.snapshot([unknown: bytes]))
        XCTAssertTrue(try fixture.store.load().playlists.isEmpty)
        let preserved = try await fixture.bridge.capture(fixture.snapshot([unknown: bytes]))
        XCTAssertEqual(preserved[unknown], bytes)
        try fixture.bridge.removeProfile(fixture.profileID)
        let removed = LiveTVPortableRecordKey(profileID: fixture.profileID, kind: .source, entityID: source.id).recordName
        await fixture.bridge.apply(fixture.snapshot([removed: bytes]))
        XCTAssertTrue(try fixture.store.load().playlists.isEmpty)
        let captured = try await fixture.bridge.capture(fixture.snapshot([removed: bytes]))
        let manifest = try JSONDecoder().decode(LiveTVSourceSyncManifest.self, from: XCTUnwrap(captured[removed]))
        XCTAssertNil(manifest.source)
    }

    func testTamperedImportedTransferDoesNotInstallOrPublishASource() async throws {
        let sender = try Fixture()
        let receiver = try Fixture()
        let id = UUID()
        _ = try await sender.cache.storeImportedPlaylist(
            data: Data("#EXTM3U\n#EXTINF:-1,Fixture\nhttps://example.test/live\n".utf8), id: id
        )
        let source = LiveTVPlaylistSource(
            id: id.uuidString, name: "Imported", playlistURL: URL(string: "plozz-playlist://" + id.uuidString.lowercased())!
        )
        try sender.store.save(.init(playlists: [source]))
        var records = try await sender.bridge.capture(sender.snapshot([:]))
        let chunk = try XCTUnwrap(records.keys.first { LiveTVPortableRecordKey.parse($0)?.kind == .snapshot })
        records[chunk] = Data("#EXTM3U\n#EXTINF:-1,Tampered\nhttps://example.test/changed\n".utf8)
        await receiver.bridge.apply(receiver.snapshot(records))
        XCTAssertTrue(try receiver.store.load().playlists.isEmpty)
        XCTAssertEqual(receiver.bridge.statuses[receiver.profileID], .unavailable)
        let installed = try await receiver.cache.hasImportedPlaylist(id: id)
        XCTAssertFalse(installed)
    }

    func testRemoteAddressChangeInvalidatesParentalGrantThroughProductionStore() async throws {
        let fixture = try Fixture()
        var source = LiveTVPlaylistSource(name: "Original", playlistURL: URL(string: "https://example.test/live")!)
        let name = LiveTVPortableRecordKey(profileID: fixture.profileID, kind: .source, entityID: source.id).recordName
        let approvals = LiveTVSourceApprovalStore(defaults: fixture.defaults, profileID: fixture.profileID)
        let wrapped = LiveTVApprovalAwareSourcesStore(underlying: fixture.store, approvals: approvals)
        let cache = fixture.cache
        let bridge = LiveTVSourceSyncBridge(
            profiles: fixture.profiles, defaults: fixture.defaults, store: { _ in wrapped }, cache: { _ in cache }
        )
        let original = [name: try LiveTVSourceSyncManifest(source: source).canonicalData()]
        await bridge.apply(fixture.snapshot(original))
        let context = LiveTVSourceApprovalContext(
            profile: Profile(id: fixture.profileID, name: "Child", isKidsProfile: true),
            parentalPIN: try XCTUnwrap(ParentalPIN.make(pin: "1234", iterations: 1)), activeAccountIDs: []
        )
        try approvals.approve(source: source, context: context, permit: XCTUnwrap(context.authorize(parentalPIN: "1234")))
        _ = try await bridge.capture(fixture.snapshot(original))
        XCTAssertEqual(try approvals.status(source: source, context: context), .approved)
        source.playlistURL = URL(string: "https://example.test/changed")!
        await bridge.apply(fixture.snapshot([name: try LiveTVSourceSyncManifest(source: source).canonicalData()]))
        XCTAssertEqual(try wrapped.load().playlists, [source])
        XCTAssertEqual(try approvals.status(source: source, context: context), .needsApproval)
    }

    @MainActor private final class Fixture {
        let suite = "LiveTVSourceSyncTests." + UUID().uuidString
        let defaults: UserDefaults
        let profiles: ProfilesModel
        let folder: URL
        let store: LiveTVSourcesStore
        let cache: LiveTVIndexedCache
        let bridge: LiveTVSourceSyncBridge
        let secrets = SourceSyncTestSecrets()
        var sequence: UInt64 = 0
        var profileID: String { profiles.activeProfileID }

        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            profiles = ProfilesModel(store: ProfileStore(defaults: defaults))
            folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            store = LiveTVSourcesStore(secureStore: secrets)
            cache = LiveTVIndexedCache(
                url: folder.appendingPathComponent("catalog.sqlite"), namespace: profiles.activeProfileID,
                authorizationScope: "fixture", secureStore: secrets, importedFilesURL: folder.appendingPathComponent("imports")
            )
            let store = self.store
            let cache = self.cache
            bridge = LiveTVSourceSyncBridge(profiles: profiles, defaults: defaults, store: { _ in store }, cache: { _ in cache })
        }

        func restartedBridge() -> LiveTVSourceSyncBridge {
            let store = self.store
            let cache = self.cache
            return LiveTVSourceSyncBridge(profiles: profiles, defaults: defaults, store: { _ in store }, cache: { _ in cache })
        }

        func snapshot(_ records: [String: Data], receipts: [String: Data] = [:]) -> SyncChannelSnapshot {
            sequence += 1
            return .init(sequence: sequence, authority: LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: defaults),
                         records: records, localCaptureDigests: receipts)
        }

        deinit {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
    }
}

private final class SourceSyncTestSecrets: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var failWrites = false
    func setWriteFailure(_ enabled: Bool) { lock.withLock { failWrites = enabled } }
    func setString(_ value: String, for key: String) throws {
        try lock.withLock {
            if failWrites { throw CocoaError(.fileWriteNoPermission) }
            values[key] = value
        }
    }
    func string(for key: String) -> String? { lock.withLock { values[key] } }
    func readString(for key: String) throws -> String? { string(for: key) }
    func removeValue(for key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}
