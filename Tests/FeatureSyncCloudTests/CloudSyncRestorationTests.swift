import Foundation
import XCTest
import CoreModels
@testable import FeatureSyncCloud

final class CloudSyncRestorationTests: XCTestCase {
    private struct PrimaryState: Encodable {
        let ledger: SyncLedger
    }

    private func ledger(_ id: String) -> SyncLedger {
        var result = SyncLedger()
        _ = result.reconcileLocal(desired: [id: Data(id.utf8)], now: 1)
        return result
    }

    private func configuration(_ file: URL) -> CloudConfigSyncService.Configuration {
        .init(containerIdentifier: "iCloud.test", stateFileURL: file,
              isEnabled: { false }, captureRecords: { $0 }, applyRecords: { _ in })
    }

    func testConstructionDoesNotReadFilesAndRestoreHappensOnce() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("primary.json")
        try JSONEncoder().encode(PrimaryState(ledger: ledger("before"))).write(to: file)
        let service = CloudConfigSyncService(configuration(file))
        let initiallyRestored = await service.hasRestoredLocalState
        XCTAssertFalse(initiallyRestored)

        let expected = ledger("after-construction")
        try JSONEncoder().encode(PrimaryState(ledger: expected)).write(to: file)
        let first = await service.restoredLedgers()
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(try XCTUnwrap(first.first).hasSamePersistedState(as: expected))

        try JSONEncoder().encode(PrimaryState(ledger: ledger("later"))).write(to: file)
        let second = await service.restoredLedgers()
        XCTAssertTrue(try XCTUnwrap(second.first).hasSamePersistedState(as: expected))
    }

    func testRestoresEveryChannelIncludingLegacyWrappedLedger() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let primaryFile = folder.appendingPathComponent("primary.json")
        let secondaryFile = folder.appendingPathComponent("secondary.json")
        let expectedPrimary = ledger("primary")
        let expectedSecondary = ledger("secondary")
        try JSONEncoder().encode(PrimaryState(ledger: expectedPrimary)).write(to: primaryFile)
        try JSONEncoder().encode(PrimaryState(ledger: expectedSecondary)).write(to: secondaryFile)
        let service = CloudConfigSyncService(configuration(primaryFile), channels: [
            .init(schema: .mediaStateV1, stateFileURL: secondaryFile,
                  captureRecords: { $0 }, applyRecords: { _ in })
        ])
        let restored = await service.restoredLedgers()
        XCTAssertEqual(restored.count, 2)
        guard restored.count == 2 else { return }
        XCTAssertTrue(restored[0].hasSamePersistedState(as: expectedPrimary))
        XCTAssertTrue(restored[1].hasSamePersistedState(as: expectedSecondary))
    }

    func testDisabledServiceDoesNotRestoreOrCreateFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = folder.appendingPathComponent("primary.json")
        let service = CloudConfigSyncService(configuration(file))
        await service.activate()
        let restored = await service.hasRestoredLocalState
        XCTAssertFalse(restored)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
}
