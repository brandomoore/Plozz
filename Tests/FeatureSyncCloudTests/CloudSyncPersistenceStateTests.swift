import Foundation
import XCTest
import CoreModels
@testable import FeatureSyncCloud

final class CloudSyncPersistenceStateTests: XCTestCase {
    private func ledger(value: UInt8 = 1) -> SyncLedger {
        var ledger = SyncLedger()
        _ = ledger.reconcileLocal(desired: ["record": Data([value])], now: 1)
        return ledger
    }

    func testUnchangedLedgerDoesNotEncodeOrWriteAgain() {
        let state = CloudSyncPersistenceState()
        let ledger = ledger()
        var writes = 0
        XCTAssertTrue(state.writeIfChanged(ledger: ledger, engineRevision: nil) { writes += 1 })
        for _ in 0..<10 {
            XCTAssertFalse(state.writeIfChanged(ledger: ledger, engineRevision: nil) { writes += 1 })
        }
        XCTAssertEqual(writes, 1)
    }

    func testChangedLedgerAndResetArePersistedImmediately() {
        let state = CloudSyncPersistenceState()
        var writes = 0
        XCTAssertTrue(state.writeIfChanged(ledger: ledger(), engineRevision: nil) { writes += 1 })
        XCTAssertTrue(state.writeIfChanged(ledger: ledger(value: 2), engineRevision: nil) { writes += 1 })
        XCTAssertTrue(state.writeIfChanged(ledger: SyncLedger(), engineRevision: nil) { writes += 1 })
        XCTAssertEqual(writes, 3)
    }

    func testEngineStateChangesOnlyInvalidateTheirOwnChannel() {
        let primary = CloudSyncPersistenceState()
        let secondary = CloudSyncPersistenceState()
        let ledger = ledger()
        XCTAssertTrue(primary.writeIfChanged(ledger: ledger, engineRevision: 0) {})
        XCTAssertTrue(secondary.writeIfChanged(ledger: ledger, engineRevision: nil) {})
        XCTAssertTrue(primary.writeIfChanged(ledger: ledger, engineRevision: 1) {})
        XCTAssertFalse(secondary.writeIfChanged(ledger: ledger, engineRevision: nil) {
            XCTFail("An engine-state update must not serialize an unchanged secondary ledger.")
        })
    }

    func testFailedWriteRemainsEligibleForRetry() {
        enum Expected: Error { case write }
        let state = CloudSyncPersistenceState()
        let initial = ledger()
        let updated = ledger(value: 2)
        XCTAssertTrue(state.writeIfChanged(ledger: initial, engineRevision: 0) {})
        XCTAssertThrowsError(try state.writeIfChanged(ledger: updated, engineRevision: 1) {
            throw Expected.write
        })
        XCTAssertTrue(state.writeIfChanged(ledger: updated, engineRevision: 1) {})
        XCTAssertFalse(state.writeIfChanged(ledger: updated, engineRevision: 1) {})
    }

    func testClockIsDurableEvenWhenEntriesAreUnchanged() throws {
        let first = try JSONDecoder().decode(SyncLedger.self, from: Data(#"{"entries":{},"clock":1}"#.utf8))
        let second = try JSONDecoder().decode(SyncLedger.self, from: Data(#"{"entries":{},"clock":2}"#.utf8))
        XCTAssertFalse(first.hasSamePersistedState(as: second))
        let state = CloudSyncPersistenceState()
        XCTAssertTrue(state.writeIfChanged(ledger: first, engineRevision: nil) {})
        XCTAssertTrue(state.writeIfChanged(ledger: second, engineRevision: nil) {})
    }

    func testTransientOnlyChangesDoNotInvalidatePersistence() {
        let original = SyncLedger()
        var resyncing = original
        resyncing.beginFullResync()
        XCTAssertNotEqual(original, resyncing)
        XCTAssertTrue(original.hasSamePersistedState(as: resyncing))
        let state = CloudSyncPersistenceState()
        XCTAssertTrue(state.writeIfChanged(ledger: original, engineRevision: nil) {})
        XCTAssertFalse(state.writeIfChanged(ledger: resyncing, engineRevision: nil) {})
    }

    func testServerAcknowledgementAndPendingDeleteAreDurable() {
        var ledger = ledger()
        _ = ledger.reconcileLocal(desired: ["record": Data([1]), "keep": Data([2])], now: 2)
        let state = CloudSyncPersistenceState()
        XCTAssertTrue(state.writeIfChanged(ledger: ledger, engineRevision: nil) {})
        ledger.applySendSuccess(
            recordName: "record", savedValue: Data([1]), savedEditedAt: 1,
            systemFields: Data([5])
        )
        XCTAssertTrue(state.writeIfChanged(ledger: ledger, engineRevision: nil) {})
        _ = ledger.reconcileLocal(desired: ["keep": Data([2])], now: 3, synthesizeDeletions: true)
        XCTAssertEqual(ledger.entries["record"]?.pendingDelete, true)
        XCTAssertTrue(state.writeIfChanged(ledger: ledger, engineRevision: nil) {})
        ledger.applyDeleteSuccess("record")
        XCTAssertTrue(state.writeIfChanged(ledger: ledger, engineRevision: nil) {})
    }
}
