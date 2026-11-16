import XCTest
@testable import CoreModels

final class DeveloperInfoTests: XCTestCase {
    func testCopyTextJoinsLabelValuePairs() {
        let items = [
            DeveloperInfoItem(id: "a", label: "App", value: "Plozz"),
            DeveloperInfoItem(id: "b", label: "Build #", value: "2348"),
        ]
        XCTAssertEqual(DeveloperInfo.copyText(items), "App: Plozz\nBuild #: 2348")
    }

    func testCopyTextAppendsExtraItems() {
        let items = [DeveloperInfoItem(id: "a", label: "App", value: "Plozz")]
        let extra = [DeveloperInfoItem(id: "os", label: "OS", value: "tvOS 27")]
        XCTAssertEqual(DeveloperInfo.copyText(items, extra: extra), "App: Plozz\nOS: tvOS 27")
    }

    func testSnapshotSurfacesChannelAndAlwaysHasCoreRows() {
        let items = DeveloperInfo.snapshot(channel: .testflight)
        let ids = Set(items.map(\.id))
        for expected in ["app", "build-kind", "bundle-id", "version", "build-number", "channel", "app-group", "local-network", "crash-endpoint"] {
            XCTAssertTrue(ids.contains(expected), "missing \(expected)")
        }
        XCTAssertEqual(items.first(where: { $0.id == "channel" })?.value, "TestFlight")
    }

    func testSnapshotReportsTheLocalNetworkStateItIsGiven() {
        // The grant is per signed identity, so a re-signed install starts
        // undecided/denied. The Developer panel must show that fact rather than
        // guess, and an unqueried caller keeps the explicit "Not checked".
        XCTAssertEqual(
            DeveloperInfo.snapshot(localNetwork: "Denied — Settings")
                .first(where: { $0.id == "local-network" })?.value,
            "Denied — Settings"
        )
        XCTAssertEqual(
            DeveloperInfo.snapshot().first(where: { $0.id == "local-network" })?.value,
            "Not checked"
        )
    }
}
