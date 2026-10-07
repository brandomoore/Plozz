import CoreModels
import XCTest

final class AppInstallationTests: XCTestCase {
    func testOrdinaryAndBrandedBuildsRetainTheirExistingRouting() throws {
        for identifier in [nil, "com.thatcube.Plozz", "com.thatcube.Plozz.my-branch", "test.host"] {
            let value = try AppInstallation(bundleIdentifier: identifier)
            XCTAssertEqual(value, .standard)
            XCTAssertEqual(value.cloudContainerIdentifier, "iCloud.com.thatcube.Plozz")
            XCTAssertEqual(value.cloudZoneName("PlozzSyncV3Zone"), "PlozzSyncV3Zone")
            XCTAssertEqual(value.pairingServiceType, "_plozz-pair._tcp")
            XCTAssertEqual(value.pairingURLPrefix, "https://plozz.app/pair#")
        }
    }

    func testCasesHaveDistinctStorageAndPairingRoutes() throws {
        let firstID = UUID()
        let secondID = UUID()
        let first = try AppInstallation(
            bundleIdentifier: AppInstallation.firstRunBundlePrefix + firstID.uuidString.lowercased()
        )
        let second = AppInstallation.firstRun(secondID)
        XCTAssertEqual(first.firstRunCaseID, firstID)
        XCTAssertEqual(first.cloudContainerIdentifier, "iCloud.com.thatcube.Plozz.FirstRun")
        XCTAssertNotEqual(first.cloudZoneName("zone"), second.cloudZoneName("zone"))
        XCTAssertNotEqual(first.pairingServiceType, second.pairingServiceType)
        XCTAssertNotEqual(first.pairingURLPrefix, second.pairingURLPrefix)
        XCTAssertNotEqual(first.pairingServiceType, AppInstallation.standard.pairingServiceType)
        XCTAssertLessThanOrEqual(first.pairingServiceType.split(separator: ".")[0].dropFirst().count, 15)
    }

    func testMalformedFirstRunIdentifiersNeverFallBackToNormalStorage() {
        for suffix in ["", ".", ".not-a-uuid", ".AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", ".main.extra"] {
            XCTAssertThrowsError(try AppInstallation(bundleIdentifier: "com.thatcube.Plozz.first-run" + suffix))
        }
    }
}
