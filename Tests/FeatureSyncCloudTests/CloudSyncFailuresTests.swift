import CloudKit
import XCTest
@testable import FeatureSyncCloud

final class CloudSyncFailuresTests: XCTestCase {
    private let zone = CKRecordZone.ID(zoneName: "config")
    private let otherZone = CKRecordZone.ID(zoneName: "tokens")

    func testFailedRecordSaveSurvivesSendCompletionAndUnrelatedSuccessfulFetch() {
        var failures = CloudSyncFailures()
        let record = CKRecord.ID(recordName: "profile", zoneID: zone)
        failures.record(CKError(.invalidArguments), for: .saveRecord(record))

        // A completion callback, even with no engine-pending changes, is not an acknowledgement.
        XCTAssertEqual(failures.phase(hasPendingChanges: false), .error)
        failures.record(nil, for: .fetchZone(zone))
        failures.record(nil, for: .fetchDatabase)
        XCTAssertNil(failures.fetchError)
        XCTAssertEqual((failures.sendError as? CKError)?.code, .invalidArguments)
        XCTAssertEqual(failures.phase(hasPendingChanges: false), .error)

        failures.resolveRecord(record)
        XCTAssertEqual(failures.phase(hasPendingChanges: false), .idle)
    }

    func testZoneFetchFailureRequiresThatZoneToRecoverBeforeSnapshotIsComplete() {
        var failures = CloudSyncFailures()
        failures.record(CKError(.networkFailure), for: .fetchZone(zone))
        failures.record(nil, for: .fetchZone(otherZone))
        failures.record(nil, for: .sendChanges)
        XCTAssertNotNil(failures.fetchError)
        XCTAssertEqual(failures.phase(hasPendingChanges: false), .error)

        failures.record(nil, for: .fetchZone(zone))
        XCTAssertNil(failures.fetchError)
        XCTAssertEqual(failures.phase(hasPendingChanges: true), .syncing)
        XCTAssertEqual(failures.phase(hasPendingChanges: false), .idle)
    }

    func testZoneSaveAndDeleteFailuresClearIndependently() {
        var failures = CloudSyncFailures()
        failures.record(CKError(.permissionFailure), for: .saveZone(zone))
        failures.record(CKError(.networkUnavailable), for: .deleteZone(otherZone))
        failures.record(nil, for: .saveZone(zone))
        XCTAssertEqual((failures.sendError as? CKError)?.code, .networkUnavailable)
        failures.removeZone(otherZone)
        XCTAssertNil(failures.error)
    }

    func testAcknowledgedDeleteClearsSupersededRecordFailureOnly() {
        var failures = CloudSyncFailures()
        let record = CKRecord.ID(recordName: "profile", zoneID: zone)
        let other = CKRecord.ID(recordName: "profile", zoneID: otherZone)
        failures.record(CKError(.invalidArguments), for: .saveRecord(record))
        failures.record(CKError(.serviceUnavailable), for: .deleteRecord(record))
        failures.record(CKError(.serverRecordChanged), for: .saveRecord(other))
        failures.resolveRecord(record)
        XCTAssertEqual((failures.sendError as? CKError)?.code, .serverRecordChanged)
        failures.resolveRecord(other)
        XCTAssertNil(failures.error)
    }

    func testSaveAcknowledgementCannotClearAnUnresolvedDeletionOfTheSameRecord() {
        var failures = CloudSyncFailures()
        let record = CKRecord.ID(recordName: "profile", zoneID: zone)
        failures.record(CKError(.serverRecordChanged), for: .saveRecord(record))
        failures.record(CKError(.permissionFailure), for: .deleteRecord(record))
        failures.record(nil, for: .saveRecord(record))
        XCTAssertEqual((failures.sendError as? CKError)?.code, .permissionFailure)
        failures.resolveRecord(record)
        XCTAssertNil(failures.error)
    }

    func testRemovedZoneClearsOnlyItsFailures() {
        var failures = CloudSyncFailures()
        failures.record(CKError(.zoneNotFound), for: .fetchZone(zone))
        failures.record(CKError(.zoneNotFound), for: .saveRecord(.init(recordName: "profile", zoneID: zone)))
        failures.record(CKError(.networkFailure), for: .fetchDatabase)
        failures.removeZone(zone)
        XCTAssertNil(failures.sendError)
        XCTAssertEqual((failures.fetchError as? CKError)?.code, .networkFailure)
        failures.record(nil, for: .fetchDatabase)
        XCTAssertNil(failures.error)
    }

    func testThrownSendErrorCannotBeClearedByFetchCompletion() {
        var failures = CloudSyncFailures()
        failures.record(CKError(.networkFailure), for: .sendChanges)
        failures.record(nil, for: .fetchDatabase)
        XCTAssertEqual(failures.phase(hasPendingChanges: false), .error)
        failures.record(nil, for: .sendChanges)
        XCTAssertEqual(failures.phase(hasPendingChanges: false), .idle)
    }

    func testPeerReconciliationOrLocalRevertCanResolveAnUnneededSaveButNotADelete() {
        var failures = CloudSyncFailures()
        let reverted = CKRecord.ID(recordName: "reverted", zoneID: zone)
        let dirty = CKRecord.ID(recordName: "dirty", zoneID: zone)
        let deleting = CKRecord.ID(recordName: "deleting", zoneID: zone)
        failures.record(CKError(.invalidArguments), for: .saveRecord(reverted))
        failures.record(CKError(.permissionFailure), for: .saveRecord(dirty))
        failures.record(CKError(.networkFailure), for: .deleteRecord(deleting))
        failures.resolveUnneededSaves { $0 == dirty }
        failures.resolveRecord(dirty)
        XCTAssertEqual((failures.sendError as? CKError)?.code, .networkFailure)
        failures.resolveRecord(deleting)
        XCTAssertNil(failures.error)
    }
}
