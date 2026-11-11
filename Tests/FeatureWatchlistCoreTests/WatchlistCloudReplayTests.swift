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
        XCTExpectFailure("Known sync capture gap investigated under #445; not yet fixed.") {
            XCTAssertTrue(
                restored.model.activeSnapshot.contains(aliasID: fixture.aliasID),
                "An older cloud removal must not overwrite the newer local re-add saved before restart."
            )
            XCTAssertTrue(secondRestart.activeSnapshot.contains(aliasID: fixture.aliasID))
        }
    }

    func testOlderCloudRemovalCannotEraseReaddWhenSyncLedgerIsMissing() throws {
        let fixture = try makeFixture()
        try readd(fixture.model, aliasID: fixture.aliasID)
        let restored = try restart(fixture)
        XCTAssertTrue(restored.model.activeSnapshot.contains(aliasID: fixture.aliasID))

        var ledger = SyncLedger()
        try receive(fixture.olderRemoval, ledger: &ledger, model: restored.model)
        XCTExpectFailure("Known sync-ledger recovery gap investigated under #445; not yet fixed.") {
            XCTAssertTrue(
                restored.model.activeSnapshot.contains(aliasID: fixture.aliasID),
                "Recovering sync metadata must not discard a newer durable Watchlist action."
            )
        }
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
        try apply(changes, to: fixture.model)
        XCTAssertTrue(fixture.model.activeSnapshot.contains(aliasID: fixture.aliasID))
        let restored = WatchlistModel(storageDirectory: fixture.directory)
        try restored.activate(profileID: profileID)
        XCTAssertTrue(restored.activeSnapshot.contains(aliasID: fixture.aliasID))
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
        try apply(changes, to: model)
        _ = ledger.reconcileLocal(
            desired: try model.captureSyncRecords(profileID: profileID), now: restartTime
        )
    }

    private func apply(_ changes: SyncLocalChanges, to model: WatchlistModel) throws {
        var profiles: [String: [WatchlistMediaStateRecordKey: Data]] = [:]
        for (name, value) in changes {
            let key = try XCTUnwrap(WatchlistMediaStateRecordKey.parse(name))
            if let value { profiles[key.profileID, default: [:]][key] = value }
        }
        for (profile, records) in profiles {
            let report = try model.applyRemoteSyncRecords(profileID: profile, changes: records)
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
