import CoreModels
import Foundation
import XCTest
@testable import FeatureWatchlistCore

@MainActor
final class WatchlistCloudReplayTests: XCTestCase {
    private let profileID = "webdav-viewer"
    private let baselineTime: Int64 = 1_000_000
    private let removalTime: Int64 = 2_000_000
    private let readdTime: Int64 = 3_000_000
    private let restartTime: Int64 = 4_000_000

    func testOlderCloudRemovalCannotEraseReaddAfterRestartBeforePublish() throws {
        let fixture = try makeFixture()
        try readd(fixture.model, aliasID: fixture.aliasID)
        let restored = try restart(fixture)
        XCTAssertTrue(restored.model.activeSnapshot.contains(aliasID: fixture.aliasID))

        var ledger = restored.ledger
        try receive(fixture.olderRemoval, ledger: &ledger, model: restored.model)
        let secondRestart = WatchlistModel(storageDirectory: fixture.directory)
        try secondRestart.activate(profileID: profileID)
        XCTAssertTrue(
            restored.model.activeSnapshot.contains(aliasID: fixture.aliasID),
            "An older cloud removal must not overwrite the newer local re-add saved before restart."
        )
        XCTAssertTrue(secondRestart.activeSnapshot.contains(aliasID: fixture.aliasID))
        XCTAssertEqual(ledger.pendingUploads().count, 1)
    }

    func testOlderCloudRemovalCannotEraseReaddWhenSyncLedgerIsMissing() throws {
        let fixture = try makeFixture()
        try readd(fixture.model, aliasID: fixture.aliasID)
        let restored = try restart(fixture)
        XCTAssertTrue(restored.model.activeSnapshot.contains(aliasID: fixture.aliasID))

        var ledger = SyncLedger()
        try receive(fixture.olderRemoval, ledger: &ledger, model: restored.model)
        XCTAssertTrue(
            restored.model.activeSnapshot.contains(aliasID: fixture.aliasID),
            "Recovering sync metadata must not discard a newer durable Watchlist action."
        )
        XCTAssertEqual(ledger.pendingUploads().count, 1)
    }

    func testCapturedUnsentReaddSurvivesOlderCloudRemovalAndRestart() throws {
        let fixture = try makeFixture()
        try readd(fixture.model, aliasID: fixture.aliasID)
        var ledger = fixture.ledger
        let plan = ledger.reconcileLocal(
            desired: try fixture.model.captureSyncRecords(profileID: profileID), now: readdTime
        )
        XCTAssertEqual(plan.uploads.count, 1)
        try save(ledger, to: fixture.ledgerURL)
        let restored = try restart(fixture)
        ledger = restored.ledger

        try receive(fixture.olderRemoval, ledger: &ledger, model: restored.model)
        XCTAssertTrue(restored.model.activeSnapshot.contains(aliasID: fixture.aliasID))
        XCTAssertEqual(ledger.pendingUploads().count, 1)
        let secondRestart = WatchlistModel(storageDirectory: fixture.directory)
        try secondRestart.activate(profileID: profileID)
        XCTAssertTrue(secondRestart.activeSnapshot.contains(aliasID: fixture.aliasID))
    }

    func testActuallyNewerCloudRemovalWinsOverCapturedReadd() throws {
        let fixture = try makeFixture()
        try readd(fixture.model, aliasID: fixture.aliasID)
        var ledger = fixture.ledger
        _ = ledger.reconcileLocal(
            desired: try fixture.model.captureSyncRecords(profileID: profileID), now: readdTime
        )
        let peer = WatchlistModel()
        try peer.activate(profileID: profileID)
        try peer.remove(
            profileID: profileID, aliasID: fixture.aliasID, kind: .series,
            at: date(restartTime + 1_000)
        )
        let newer = try remoteRecord(from: peer, aliasID: fixture.aliasID, editedAt: restartTime + 1_000)

        try receive(newer, ledger: &ledger, model: fixture.model)
        XCTAssertFalse(fixture.model.activeSnapshot.contains(aliasID: fixture.aliasID))
        XCTAssertTrue(ledger.pendingUploads().isEmpty)
        let restored = WatchlistModel(storageDirectory: fixture.directory)
        try restored.activate(profileID: profileID)
        XCTAssertFalse(restored.activeSnapshot.contains(aliasID: fixture.aliasID))
    }

    func testEmptyCloudFetchDoesNotRemoveUnpublishedLocalSave() throws {
        let fixture = try makeFixture()
        try readd(fixture.model, aliasID: fixture.aliasID)
        let restored = try restart(fixture)
        var ledger = restored.ledger
        let changes = ledger.applyFetched(saved: [], deleted: [], now: restartTime)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertTrue(restored.model.activeSnapshot.contains(aliasID: fixture.aliasID))
        let plan = ledger.reconcileLocal(
            desired: try restored.model.captureSyncRecords(profileID: profileID), now: restartTime
        )
        XCTAssertEqual(plan.uploads.count, 1)
    }

    func testNewerCloudRemovalWinsEvenBeforeLocalCapture() throws {
        let fixture = try makeFixture()
        try readd(fixture.model, aliasID: fixture.aliasID)
        let restored = try restart(fixture)
        let peer = WatchlistModel()
        try peer.activate(profileID: profileID)
        try peer.remove(
            profileID: profileID, aliasID: fixture.aliasID, kind: .series,
            at: date(restartTime + 1_000)
        )
        var ledger = restored.ledger
        try receive(
            remoteRecord(from: peer, aliasID: fixture.aliasID, editedAt: restartTime + 1_000),
            ledger: &ledger, model: restored.model
        )
        XCTAssertFalse(restored.model.activeSnapshot.contains(aliasID: fixture.aliasID))
        XCTAssertTrue(ledger.pendingUploads().isEmpty)
    }

    func testOlderCloudAddCannotResurrectUncapturedLocalRemoval() throws {
        let fixture = try makeFixture()
        try fixture.model.remove(
            profileID: profileID, aliasID: fixture.aliasID, kind: .series, at: date(readdTime)
        )
        let restored = try restart(fixture)
        let peer = WatchlistModel()
        try peer.activate(profileID: profileID)
        try peer.add(profileID: profileID, aliasID: fixture.aliasID, kind: .series, at: date(removalTime))
        var ledger = restored.ledger
        try receive(
            remoteRecord(from: peer, aliasID: fixture.aliasID, editedAt: removalTime),
            ledger: &ledger, model: restored.model
        )
        XCTAssertFalse(restored.model.activeSnapshot.contains(aliasID: fixture.aliasID))
        let upload = try XCTUnwrap(ledger.pendingUploads().first)
        XCTAssertEqual(
            CanonicalJSON.decode(WatchlistIntentSyncDTO.self, from: upload.value)?.desiredState, .absent
        )
    }

    func testCapturedActionStillUsesLogicalClockWhenDeviceDatesDisagree() throws {
        let fixture = try makeFixture()
        try readd(fixture.model, aliasID: fixture.aliasID)
        var ledger = fixture.ledger
        _ = ledger.reconcileLocal(
            desired: try fixture.model.captureSyncRecords(profileID: profileID), now: readdTime
        )
        let remote = SyncRemoteRecord(
            recordName: fixture.olderRemoval.recordName, value: fixture.olderRemoval.value,
            editedAt: restartTime + 1_000, systemFields: Data([3])
        )
        try receive(remote, ledger: &ledger, model: fixture.model)
        XCTAssertFalse(fixture.model.activeSnapshot.contains(aliasID: fixture.aliasID))
        XCTAssertTrue(ledger.pendingUploads().isEmpty)
    }

    func testPreservedReaddUploadsAndConvergesWithPeer() throws {
        let fixture = try makeFixture()
        try readd(fixture.model, aliasID: fixture.aliasID)
        let restored = try restart(fixture)
        var ledger = restored.ledger
        try receive(fixture.olderRemoval, ledger: &ledger, model: restored.model)
        let upload = try XCTUnwrap(ledger.pendingUploads().first)

        let peer = WatchlistModel()
        try peer.activate(profileID: profileID)
        var peerLedger = SyncLedger()
        try receive(fixture.olderRemoval, ledger: &peerLedger, model: peer)
        XCTAssertFalse(peer.activeSnapshot.contains(aliasID: fixture.aliasID))
        let repair = SyncRemoteRecord(
            recordName: upload.recordName, value: upload.value,
            editedAt: upload.editedAt, systemFields: Data([3])
        )
        try receive(repair, ledger: &peerLedger, model: peer)
        ledger.applySendSuccess(
            recordName: upload.recordName, savedValue: upload.value,
            savedEditedAt: upload.editedAt, systemFields: repair.systemFields
        )
        try receive(repair, ledger: &ledger, model: restored.model)
        XCTAssertTrue(peer.activeSnapshot.contains(aliasID: fixture.aliasID))
        XCTAssertEqual(
            try peer.captureSyncRecords(profileID: profileID),
            try restored.model.captureSyncRecords(profileID: profileID)
        )
        XCTAssertTrue(peerLedger.pendingUploads().isEmpty)
        XCTAssertTrue(ledger.pendingUploads().isEmpty)
        try save(ledger, to: fixture.ledgerURL)
        let finalRestart = try restart(fixture)
        XCTAssertTrue(finalRestart.model.activeSnapshot.contains(aliasID: fixture.aliasID))
        XCTAssertTrue(finalRestart.ledger.pendingUploads().isEmpty)
    }

    func testNativeImportTimestampDoesNotBlockExplicitCloudRemoval() throws {
        let fixture = try makeFixture()
        try fixture.model.add(
            profileID: profileID, aliasID: fixture.aliasID, kind: .series,
            origin: .nativeImport, at: date(readdTime)
        )
        var ledger = fixture.ledger
        try receive(fixture.olderRemoval, ledger: &ledger, model: fixture.model)
        XCTAssertFalse(fixture.model.activeSnapshot.contains(aliasID: fixture.aliasID))
    }

    func testCloudRemovalForAnotherProfileDoesNotRemoveCurrentProfileSave() throws {
        let fixture = try makeFixture()
        let otherProfile = "other-viewer"
        let peer = WatchlistModel()
        try peer.activate(profileID: otherProfile)
        try peer.remove(profileID: otherProfile, aliasID: fixture.aliasID, kind: .series, at: date(removalTime))
        let key = WatchlistMediaStateRecordKey(profileID: otherProfile, aliasID: fixture.aliasID)
        let bytes = try XCTUnwrap(peer.captureSyncRecords(profileID: otherProfile)[key.recordName])
        var ledger = fixture.ledger
        let changes = ledger.applyFetched(saved: [
            SyncRemoteRecord(recordName: key.recordName, value: bytes, editedAt: removalTime, systemFields: Data([2]))
        ], deleted: [], now: restartTime)
        try apply(changes, to: fixture.model, ledger: ledger)
        XCTAssertTrue(fixture.model.activeSnapshot.contains(aliasID: fixture.aliasID))
        let restored = WatchlistModel(storageDirectory: fixture.directory)
        try restored.activate(profileID: profileID)
        XCTAssertTrue(restored.activeSnapshot.contains(aliasID: fixture.aliasID))
    }

    func testConsecutiveRemoteEditsKeepLogicalClockOrderWithoutCaptureEvenAcrossRestart() throws {
        for restartBetweenDeliveries in [false, true] {
            let fixture = try makeFixture()
            var ledger = fixture.ledger
            var model = fixture.model
            let first = ledger.applyFetched(saved: [fixture.olderRemoval], deleted: [], now: removalTime)
            try apply(first, to: model, ledger: ledger)
            XCTAssertFalse(model.activeSnapshot.contains(aliasID: fixture.aliasID))
            if restartBetweenDeliveries {
                try save(ledger, to: fixture.ledgerURL)
                let restored = try restart(fixture)
                ledger = restored.ledger
                model = restored.model
            }
            let peer = WatchlistModel()
            try peer.activate(profileID: profileID)
            try peer.add(
                profileID: profileID, aliasID: fixture.aliasID, kind: .series,
                at: date(baselineTime + 1_000)
            )
            let next = try remoteRecord(from: peer, aliasID: fixture.aliasID, editedAt: readdTime)
            let second = ledger.applyFetched(saved: [next], deleted: [], now: restartTime)
            try apply(second, to: model, ledger: ledger)
            XCTAssertTrue(model.activeSnapshot.contains(aliasID: fixture.aliasID))
            let plan = ledger.reconcileLocal(
                desired: try model.captureSyncRecords(profileID: profileID), now: restartTime
            )
            XCTAssertTrue(plan.isEmpty)
        }
    }

    func testLegacyStoreDoesNotInventLocalAuthorshipFromSyncedOrigin() throws {
        let fixture = try makeFixture()
        let store = try AtomicWatchlistIntentStore(directoryURL: fixture.directory, profileID: profileID)
        let original = try Data(contentsOf: store.fileURL)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        object.removeValue(forKey: "locallyAuthoredAliasIDs")
        try JSONSerialization.data(withJSONObject: object).write(to: store.fileURL, options: .atomic)
        let legacy = try store.load()
        XCTAssertTrue(legacy.locallyAuthoredAliasIDs.isEmpty)
        XCTAssertEqual(legacy.intents.first?.origin, .local)
    }

    func testAliasRedirectKeepsUncapturedLocalAuthorshipAcrossRestart() throws {
        let fixture = try makeFixture()
        try readd(fixture.model, aliasID: fixture.aliasID)
        let winner = MediaAliasID()
        let aliases = MediaAliasSnapshot(records: [
            try XCTUnwrap(MediaAliasRecord(id: fixture.aliasID, kind: .series, redirectTarget: winner)),
            try XCTUnwrap(MediaAliasRecord(id: winner, kind: .series))
        ])
        try fixture.model.reconcileAliases(profileID: profileID, aliasSnapshot: aliases)
        let restored = try restart(fixture)
        let peer = WatchlistModel()
        try peer.activate(profileID: profileID)
        try peer.remove(profileID: profileID, aliasID: winner, kind: .series, at: date(removalTime))
        var ledger = SyncLedger()
        try receive(
            remoteRecord(from: peer, aliasID: winner, editedAt: removalTime),
            ledger: &ledger, model: restored.model
        )
        XCTAssertTrue(restored.model.activeSnapshot.contains(aliasID: winner))
    }

    func testAliasMergeDoesNotGiveRemoteWinnerLosingLocalAuthorship() throws {
        let fixture = try makeFixture()
        let winner = MediaAliasID()
        let peer = WatchlistModel()
        try peer.activate(profileID: profileID)
        try peer.remove(profileID: profileID, aliasID: winner, kind: .series, at: date(readdTime))
        var ledger = fixture.ledger
        let remoteRemoval = try remoteRecord(from: peer, aliasID: winner, editedAt: readdTime)
        try apply(
            ledger.applyFetched(saved: [remoteRemoval], deleted: [], now: readdTime),
            to: fixture.model, ledger: ledger
        )
        let aliases = MediaAliasSnapshot(records: [
            try XCTUnwrap(MediaAliasRecord(id: fixture.aliasID, kind: .series, redirectTarget: winner)),
            try XCTUnwrap(MediaAliasRecord(id: winner, kind: .series))
        ])
        try fixture.model.reconcileAliases(profileID: profileID, aliasSnapshot: aliases)
        try save(ledger, to: fixture.ledgerURL)
        let restored = try restart(fixture)
        ledger = restored.ledger
        try peer.add(profileID: profileID, aliasID: winner, kind: .series, at: date(removalTime))
        try receive(
            remoteRecord(from: peer, aliasID: winner, editedAt: restartTime),
            ledger: &ledger, model: restored.model
        )
        XCTAssertTrue(restored.model.activeSnapshot.contains(aliasID: winner))
    }

    func testNativeReaddSupersessionSurvivesOlderCloudRemovalBeforeCaptureAcrossRestart() throws {
        let fixture = try makeFixture()
        var ledger = fixture.ledger
        try receive(fixture.olderRemoval, ledger: &ledger, model: fixture.model)
        XCTAssertTrue(try fixture.model.markRemovalSuperseded(
            profileID: profileID, aliasID: fixture.aliasID, at: date(readdTime)
        ))
        try save(ledger, to: fixture.ledgerURL)
        let restored = try restart(fixture)
        ledger = restored.ledger
        let peer = WatchlistModel()
        try peer.activate(profileID: profileID)
        try peer.remove(
            profileID: profileID, aliasID: fixture.aliasID, kind: .series,
            at: date(removalTime + 1_000)
        )
        try receive(
            remoteRecord(from: peer, aliasID: fixture.aliasID, editedAt: removalTime + 1_000),
            ledger: &ledger, model: restored.model
        )
        let intent = try XCTUnwrap(restored.model.activeSnapshot.intent(for: fixture.aliasID))
        XCTAssertEqual(intent.metadata.removalSupersededAt, date(readdTime))
        XCTAssertFalse(intent.metadata.suppressesNativePresence)
        XCTAssertEqual(ledger.pendingUploads().count, 1)
    }

    private struct Fixture {
        let directory: URL
        let ledgerURL: URL
        let model: WatchlistModel
        let ledger: SyncLedger
        let aliasID: MediaAliasID
        let olderRemoval: SyncRemoteRecord
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchlistCloudReplay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Watchlist", isDirectory: true)
        let ledgerURL = root.appendingPathComponent("sync-ledger.json")
        let model = WatchlistModel(storageDirectory: directory)
        try model.activate(profileID: profileID)
        let item = MediaItem(
            id: "series/Caminandes", title: "Caminandes", kind: .series,
            sourceAccountID: "share:webdav.example:443/media#viewer"
        )
        let aliasID = MediaAliasID()
        try model.add(
            profileID: profileID, aliasID: aliasID, kind: .series,
            presentation: try XCTUnwrap(MediaAliasEvidence(item: item)).presentation,
            at: date(baselineTime)
        )
        var ledger = SyncLedger()
        let plan = ledger.reconcileLocal(
            desired: try model.captureSyncRecords(profileID: profileID), now: baselineTime
        )
        for upload in plan.uploads {
            ledger.applySendSuccess(
                recordName: upload.recordName, savedValue: upload.value,
                savedEditedAt: upload.editedAt, systemFields: Data([1])
            )
        }
        try save(ledger, to: ledgerURL)
        let peer = WatchlistModel()
        try peer.activate(profileID: profileID)
        try peer.remove(profileID: profileID, aliasID: aliasID, kind: .series, at: date(removalTime))
        return Fixture(
            directory: directory, ledgerURL: ledgerURL, model: model, ledger: ledger,
            aliasID: aliasID, olderRemoval: try remoteRecord(from: peer, aliasID: aliasID, editedAt: removalTime)
        )
    }

    private func readd(_ model: WatchlistModel, aliasID: MediaAliasID) throws {
        try model.remove(profileID: profileID, aliasID: aliasID, kind: .series, at: date(readdTime - 100))
        try model.add(profileID: profileID, aliasID: aliasID, kind: .series, at: date(readdTime))
    }

    private func restart(_ fixture: Fixture) throws -> (model: WatchlistModel, ledger: SyncLedger) {
        let model = WatchlistModel(storageDirectory: fixture.directory)
        try model.activate(profileID: profileID)
        let ledger = try JSONDecoder().decode(SyncLedger.self, from: Data(contentsOf: fixture.ledgerURL))
        return (model, ledger)
    }

    private func remoteRecord(
        from model: WatchlistModel, aliasID: MediaAliasID, editedAt: Int64
    ) throws -> SyncRemoteRecord {
        let key = WatchlistMediaStateRecordKey(profileID: profileID, aliasID: aliasID)
        return SyncRemoteRecord(
            recordName: key.recordName,
            value: try XCTUnwrap(model.captureSyncRecords(profileID: profileID)[key.recordName]),
            editedAt: editedAt, systemFields: Data([2])
        )
    }

    private func receive(_ remote: SyncRemoteRecord, ledger: inout SyncLedger, model: WatchlistModel) throws {
        // Production fetch ordering: resolve against the persisted sync ledger,
        // then apply the winners before the post-fetch local capture runs.
        let changes = ledger.applyFetched(saved: [remote], deleted: [], now: restartTime)
        try apply(changes, to: model, ledger: ledger)
        _ = ledger.reconcileLocal(
            desired: try model.captureSyncRecords(profileID: profileID), now: restartTime
        )
    }

    private func apply(_ changes: SyncLocalChanges, to model: WatchlistModel, ledger: SyncLedger) throws {
        var profiles: [String: [WatchlistMediaStateRecordKey: Data]] = [:]
        for (name, value) in changes {
            let key = try XCTUnwrap(WatchlistMediaStateRecordKey.parse(name))
            if let value { profiles[key.profileID, default: [:]][key] = value }
        }
        for (profile, records) in profiles {
            let report = try model.applyRemoteSyncRecords(
                profileID: profile, changes: records,
                localCaptureDigests: ledger.entries.compactMapValues(\.localCaptureDigest)
            )
            XCTAssertEqual(report.rejectedCount, 0)
        }
    }

    private func save(_ ledger: SyncLedger, to url: URL) throws {
        try JSONEncoder().encode(ledger).write(to: url, options: .atomic)
    }

    private func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}
