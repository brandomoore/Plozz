import CloudKit
import CoreModels
import FeatureSyncCloud
import XCTest

final class LiveTVCloudSyncSchemaTests: XCTestCase {
    func testLiveTVUsesDeployedRecordFieldsButIsolatedZoneFromOlderClients() {
        let live = CloudSyncSchemaDescriptor.liveTVStateV1
        let media = CloudSyncSchemaDescriptor.mediaStateV1
        XCTAssertEqual(live.recordType, media.recordType)
        XCTAssertEqual(live.fieldValue, media.fieldValue)
        XCTAssertEqual(live.fieldEditedAt, media.fieldEditedAt)
        XCTAssertNotEqual(live.zoneID, media.zoneID)
        XCTAssertFalse(live.encryptsValue)
    }

    func testRecordMappingRoundTripsOnlyThroughLiveTVChannel() throws {
        let schema = CloudSyncSchemaDescriptor.liveTVStateV1
        let key = LiveTVPortableRecordKey(profileID: "profile", kind: .channel, entityID: "channel")
        let bytes = try LiveTVPortableRecord(channel: .init(isFavorite: true)).encoded()
        let upload = SyncUpload(recordName: key.recordName, value: bytes, editedAt: 42, systemFields: nil)
        let record = CKRecord(recordType: schema.recordType, recordID: schema.recordID(forRecordName: key.recordName))
        upload.populate(record, schema: schema)
        XCTAssertEqual(SyncRemoteRecord(ckRecord: record, schema: schema)?.value, bytes)
        XCTAssertNil(SyncRemoteRecord(ckRecord: record, schema: .mediaStateV1))
        XCTAssertNil(SyncRemoteRecord(ckRecord: record, schema: .configV3))
    }

    func testSourceManifestsAndFileChunksOnlyUseEncryptedFieldsAndASeparateZone() throws {
        let schema = CloudSyncSchemaDescriptor.liveTVSourcesV1
        XCTAssertTrue(schema.encryptsValue)
        XCTAssertEqual(schema.recordType, CloudSyncSchemaDescriptor.trackerTokensV1.recordType)
        XCTAssertNotEqual(schema.zoneID, CloudSyncSchemaDescriptor.trackerTokensV1.zoneID)
        for kind in [LiveTVPortableRecordKey.Kind.source, .snapshot] {
            let key = LiveTVPortableRecordKey(profileID: "profile", kind: kind, entityID: "source")
            let bytes = Data("private-fixture-data".utf8)
            let upload = SyncUpload(recordName: key.recordName, value: bytes, editedAt: 42, systemFields: nil)
            let record = CKRecord(recordType: schema.recordType, recordID: schema.recordID(forRecordName: key.recordName))
            upload.populate(record, schema: schema)
            XCTAssertNil(record[schema.fieldValue])
            XCTAssertEqual(record.encryptedValues[schema.fieldValue] as? Data, bytes)
            let acknowledged = try XCTUnwrap(SyncRemoteRecord(ckRecord: record, schema: schema))
            var ledger = SyncLedger()
            _ = ledger.reconcileLocal(desired: [key.recordName: bytes], now: 42)
            ledger.applySendSuccess(recordName: acknowledged.recordName, savedValue: acknowledged.value,
                                    savedEditedAt: acknowledged.editedAt, systemFields: acknowledged.systemFields)
            XCTAssertTrue(ledger.pendingUploads().isEmpty)
            XCTAssertEqual(ledger.entries[key.recordName]?.syncedValue, bytes)
            XCTAssertNil(SyncRemoteRecord(ckRecord: record, schema: .liveTVStateV1))
            XCTAssertNil(SyncRemoteRecord(ckRecord: record, schema: .trackerTokensV1))
        }
    }
}
