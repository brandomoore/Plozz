import CloudKit
import CoreModels
@testable import FeatureSyncCloud
import XCTest

final class FirstRunCloudIsolationTests: XCTestCase {
    private let schemas: [CloudSyncSchemaDescriptor] = [
        .configV3, .trackerTokensV1, .mediaStateV1, .liveTVStateV1, .liveTVSourcesV1
    ]

    func testEveryChannelIsIsolatedWithoutChangingItsRecordContract() {
        let installation = AppInstallation.firstRun(UUID())
        let other = AppInstallation.firstRun(UUID())
        for schema in schemas {
            let scoped = schema.scoped(to: installation)
            XCTAssertEqual(schema.scoped(to: .standard), schema)
            XCTAssertNotEqual(scoped.zoneID, schema.zoneID)
            XCTAssertNotEqual(scoped.zoneID, schema.scoped(to: other).zoneID)
            XCTAssertEqual(scoped.recordType, schema.recordType)
            XCTAssertEqual(scoped.encryptsValue, schema.encryptsValue)
            XCTAssertEqual(scoped.fieldKind, schema.fieldKind)
            XCTAssertEqual(scoped.fieldValue, schema.fieldValue)
            XCTAssertEqual(scoped.fieldEditedAt, schema.fieldEditedAt)
            XCTAssertEqual(scoped.kindDerivation, schema.kindDerivation)
            XCTAssertEqual(scoped.maximumPayloadBytes, schema.maximumPayloadBytes)
            XCTAssertTrue(scoped.legacyZoneIDs.isEmpty)
            XCTAssertFalse(scoped.contains(schema.recordID(forRecordName: "record")))
        }
    }

    func testServiceScopesPrimaryAndAllAdditionalChannels() throws {
        let installation = AppInstallation.firstRun(UUID())
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let service = CloudConfigSyncService(.init(
            containerIdentifier: installation.cloudContainerIdentifier,
            stateFileURL: directory.appendingPathComponent("config.json"),
            isEnabled: { false }, captureRecords: { $0 }, applyRecords: { _ in },
            installation: installation
        ), channels: schemas.dropFirst().enumerated().map { index, schema in
            .init(schema: schema, stateFileURL: directory.appendingPathComponent("\(index).json"),
                  captureRecords: { $0 }, applyRecords: { _ in })
        })
        XCTAssertEqual(service.channelSchemas, schemas.map { $0.scoped(to: installation) })
    }

    func testFirstRunRequiresTheExactContainerAndReadableProvisioning() throws {
        let testContainer = AppInstallation.firstRun(UUID()).cloudContainerIdentifier
        func profile(_ containers: [String]) throws -> Data {
            try PropertyListSerialization.data(
                fromPropertyList: ["Entitlements": ["com.apple.developer.icloud-container-identifiers": containers]],
                format: .xml, options: 0
            )
        }
        for data in [nil, Data(), try profile([]), try profile(["iCloud.com.thatcube.Plozz"])] {
            XCTAssertFalse(CloudSyncEntitlementPolicy.permits(
                container: testContainer, profileData: data, requiresProof: true
            ))
        }
        XCTAssertTrue(CloudSyncEntitlementPolicy.permits(
            container: testContainer, profileData: try profile([testContainer]), requiresProof: true
        ))
        XCTAssertTrue(CloudSyncEntitlementPolicy.permits(
            container: "iCloud.com.thatcube.Plozz", profileData: nil, requiresProof: false
        ))
    }
}
