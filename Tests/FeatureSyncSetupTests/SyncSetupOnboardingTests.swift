import CoreModels
import XCTest
@testable import FeatureSyncSetup

@MainActor
final class SyncSetupOnboardingTests: XCTestCase {
    func testPendingAndDeclinedChoicesDoNotPublishOrClearAnotherDevicesPresence() throws {
        for enabled in [false, true] {
            let suite = "SyncSetupOnboarding.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let flag = SyncSetupFeatureFlag(defaults: defaults)
            flag.prepareForLaunch(hasExistingInstallation: false)
            let original = SyncPresenceBeacon(
                setupExists: true, deviceName: "Other device", serverCount: 1, profileCount: 2
            )
            let beacons = InMemoryPresenceBeaconStore(original)
            var captures = 0
            let service = SyncSetupService(
                flag: flag, beaconStore: beacons, rendezvousStore: InMemoryPairingRendezvousStore(),
                deviceID: { "new-device" }, deviceName: { "New device" }, isConfigured: { true },
                configProvider: {
                    captures += 1
                    return .init(accounts: [], profiles: [Profile(id: "profile", name: "Me")])
                }
            )
            XCTAssertTrue(service.needsOnboardingChoice)
            XCTAssertFalse(service.isEnabled)
            service.publishPresence()
            XCTAssertNil(service.continueOffer())
            XCTAssertEqual(captures, 0)
            XCTAssertEqual(beacons.read(), original)
            service.setEnabled(enabled)
            XCTAssertFalse(service.needsOnboardingChoice)
            XCTAssertEqual(flag.isEnabled, enabled)
            XCTAssertEqual(captures, enabled ? 1 : 0)
            XCTAssertEqual(beacons.read()?.deviceName, enabled ? "New device" : "Other device")
        }
    }
}
