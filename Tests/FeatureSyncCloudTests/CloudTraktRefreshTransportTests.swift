import CloudKit
import CoreModels
import Foundation
import XCTest
@testable import FeatureSyncCloud

final class CloudTraktRefreshTransportTests: XCTestCase {
    func testSharedGrantUsesExistingEncryptedSchemaAndStableProfileScope() {
        let schema = CloudSyncSchemaDescriptor.trackerTokensV1
        let scope = "com.plozz.app.tokens\0trakt.oauth.profile-a"
        let name = CloudTraktRefreshTransport.recordName(scope: scope)
        XCTAssertEqual(CloudTraktRefreshTransport.scope(recordName: name), scope)
        XCTAssertNotEqual(
            name, CloudTraktRefreshTransport.recordName(scope: "com.plozz.app.tokens\0trakt.oauth.profile-b")
        )
        XCTAssertEqual(schema.recordType, "PlozzTrackerTokensV1Record")
        XCTAssertEqual(schema.zoneName, "PlozzTrackerTokensV1Zone")
        XCTAssertTrue(schema.encryptsValue)
        // Legacy capture understands this grammar and retains the opaque value.
        XCTAssertTrue(name.hasPrefix("trackerToken:"))
        XCTAssertEqual(schema.kind(forRecordName: name), "trackerToken")
    }

    func testBothCASAndLegacyTraktRecordsAreExcludedFromLastWriterWins() {
        XCTAssertTrue(CloudTraktRefreshTransport.manages(
            recordName: CloudTraktRefreshTransport.recordName(scope: "service\0trakt.oauth")
        ))
        XCTAssertTrue(CloudTraktRefreshTransport.manages(recordName: "trackerToken:service|trakt.oauth"))
        XCTAssertTrue(CloudTraktRefreshTransport.manages(recordName: "trackerToken:service|trakt.oauth.profile"))
        XCTAssertFalse(CloudTraktRefreshTransport.manages(recordName: "trackerToken:service|simkl.oauth"))
        XCTAssertFalse(CloudTraktRefreshTransport.manages(recordName: "trackerToken:service|trakt.oauthOther"))
        XCTAssertNil(CloudTraktRefreshTransport.scope(recordName: "trackerToken:service|trakt.oauth"))
    }

    func testExistingMappingNeverPlacesCredentialPayloadInPlaintextFields() {
        let schema = CloudSyncSchemaDescriptor.trackerTokensV1
        let name = CloudTraktRefreshTransport.recordName(scope: "service\0trakt.oauth")
        let payload = Data("fake encrypted credential envelope".utf8)
        let record = CKRecord(recordType: schema.recordType, recordID: schema.recordID(forRecordName: name))
        SyncUpload(recordName: name, value: payload, editedAt: 1, systemFields: nil)
            .populate(record, schema: schema)
        XCTAssertNil(record[schema.fieldValue])
        XCTAssertEqual(record.encryptedValues[schema.fieldValue] as? Data, payload)
        XCTAssertEqual(SyncRemoteRecord(ckRecord: record, schema: schema)?.value, payload)
    }

    func testUnitTestHostDoesNotConstructCloudKitContainer() {
        XCTAssertFalse(CloudTraktRefreshTransport.isAvailable(containerIdentifier: "iCloud.com.thatcube.Plozz"))
        XCTAssertFalse(CloudTraktRefreshTransport.requiresCoordination(containerIdentifier: "iCloud.com.thatcube.Plozz"))
        // Construction stays lazy even when an unentitled caller bypasses bootstrap.
        _ = CloudTraktRefreshTransport(containerIdentifier: "iCloud.not.entitled")
    }
}
