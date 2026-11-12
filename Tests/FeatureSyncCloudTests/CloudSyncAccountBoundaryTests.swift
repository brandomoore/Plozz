import Foundation
import XCTest
import CloudKit
import CoreModels
@testable import FeatureSyncCloud

final class CloudSyncAccountBoundaryTests: XCTestCase {
    private struct Persisted: Encodable { let ledger: SyncLedger }

    func testOlderAdmissionCannotOverwriteANewerAccountDuringReset() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("config.json")
        try JSONEncoder().encode("A").write(to: file.appendingPathExtension("account"))
        let gate = AdmissionGate()
        let service = CloudConfigSyncService(.init(
            containerIdentifier: "iCloud.test", stateFileURL: file, isEnabled: { true },
            captureRecords: { $0 }, applyRecords: { _ in },
            onAccountSwitch: { await gate.pauseFirstReset() }))
        let older = Task { await service.confirmAccountIdentity("B") }
        await gate.waitUntilStarted()
        let latest = await service.confirmAccountIdentity("C")
        XCTAssertTrue(latest)
        await gate.release()
        let superseded = await older.value
        XCTAssertFalse(superseded)
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(contentsOf: file.appendingPathExtension("account"))), "C")
        let same = await service.confirmAccountIdentity("C")
        XCTAssertTrue(same)
    }

    func testAccountResetCanChangeChannelAuthorityWithoutRestartLoop() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("config.json")
        try JSONEncoder().encode("A").write(to: file.appendingPathExtension("account"))
        let authority = TestAuthority()
        let service = CloudConfigSyncService(.init(
            containerIdentifier: "iCloud.test", stateFileURL: file, isEnabled: { true },
            captureRecords: { $0 }, applyRecords: { _ in }),
            channels: [.init(
                schema: .mediaStateV1, stateFileURL: folder.appendingPathComponent("watch.json"),
                captureRecords: { $0 }, applyRecords: { _ in },
                onAccountSwitch: { authority.renew() },
                captureSnapshot: { $0.records }, applySnapshot: { _ in },
                snapshotAuthority: { authority.value })])
        let admitted = await service.confirmAccountIdentity("B")
        XCTAssertTrue(admitted)
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(contentsOf: file.appendingPathExtension("account"))), "B")
        let again = await service.confirmAccountIdentity("B")
        XCTAssertTrue(again)
        XCTAssertEqual(authority.value, "1")
    }

    func testStagedOfflineDeletionRemainsInTheDurableSendQueue() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("config.json")
        var ledger = SyncLedger()
        _ = ledger.applyFetched(saved: ["keep", "remove"].map {
            .init(recordName: $0, value: Data($0.utf8), editedAt: 1, systemFields: Data())
        }, deleted: [], now: 1)
        try JSONEncoder().encode(Persisted(ledger: ledger)).write(to: file)
        let service = CloudConfigSyncService(.init(
            containerIdentifier: "iCloud.test", stateFileURL: file, isEnabled: { true },
            captureRecords: { _ in ["keep": Data("keep".utf8)] }, applyRecords: { _ in }))
        let admitted = await service.confirmAccountIdentity("A")
        XCTAssertTrue(admitted)
        let staged = await service.stageLocalChangesBeforeFetch()
        XCTAssertTrue(staged)
        let changes = await service.pendingLedgerChanges()
        XCTAssertTrue(changes.contains {
            if case .deleteRecord(let id) = $0 { return id.recordName == "remove" }
            return false
        })
    }

    func testColdStartAccountChangeResetsOldBaselineBeforeCapture() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("config.json")
        try JSONEncoder().encode("account-A").write(to: file.appendingPathExtension("account"))
        var ledger = SyncLedger()
        _ = ledger.applyFetched(saved: [.init(recordName: "descriptor:old", value: Data("old".utf8),
                                              editedAt: 1, systemFields: Data())], deleted: [], now: 1)
        try JSONEncoder().encode(Persisted(ledger: ledger)).write(to: file)
        let reset = ResetCounter()
        let service = CloudConfigSyncService(.init(
            containerIdentifier: "iCloud.test", stateFileURL: file, isEnabled: { true },
            captureRecords: { $0 }, applyRecords: { _ in },
            onAccountSwitch: { await reset.increment() }))
        let admitted = await service.confirmAccountIdentity("account-B")
        XCTAssertTrue(admitted)
        let restored = try await service.restoredLedgers()
        XCTAssertTrue(try XCTUnwrap(restored.first).entries.isEmpty)
        let count = await reset.count
        XCTAssertEqual(count, 1)
        let again = await service.confirmAccountIdentity("account-B")
        XCTAssertTrue(again)
        let sameCount = await reset.count
        XCTAssertEqual(sameCount, 1)
    }

    func testSameAccountStagesDisabledLocalEditBeforeRemoteApply() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("config.json")
        let key = "profile:one"
        var ledger = SyncLedger()
        _ = ledger.applyFetched(saved: [.init(recordName: key, value: Data("original".utf8),
                                              editedAt: 1, systemFields: Data())], deleted: [], now: 1)
        try JSONEncoder().encode(Persisted(ledger: ledger)).write(to: file)
        let latest = Data("latest-local".utf8)
        let service = CloudConfigSyncService(.init(
            containerIdentifier: "iCloud.test", stateFileURL: file, isEnabled: { true },
            captureRecords: { _ in [key: latest] }, applyRecords: { _ in }))
        let admitted = await service.confirmAccountIdentity("account-A")
        XCTAssertTrue(admitted)
        let staged = await service.stageLocalChangesBeforeFetch()
        XCTAssertTrue(staged)
        let ledgers = try await service.restoredLedgers()
        var restored = try XCTUnwrap(ledgers.first)
        _ = restored.applyFetched(saved: [.init(recordName: key, value: Data("earlier-remote".utf8),
                                                editedAt: 2, systemFields: Data())], deleted: [], now: 3)
        XCTAssertEqual(restored.entries[key]?.localValue, latest)
        XCTAssertTrue(restored.entries[key]?.dirty == true)
    }
}

private actor ResetCounter {
    var count = 0
    func increment() { count += 1 }
}

private final class TestAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var revision = 0
    var value: String { lock.withLock { String(revision) } }
    func renew() { lock.withLock { revision += 1 } }
}

private actor AdmissionGate {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func pauseFirstReset() async {
        guard !started else { return }
        started = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}
