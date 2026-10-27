import XCTest
@testable import CoreModels

final class LosslessAudioSettingsTests: XCTestCase {
    func testNewAndUpgradingDevicesDefaultToLosslessWithoutPersistingAnImplicitChoice() throws {
        try withDefaults { defaults in
            for namespace: String? in [nil, "guest"] {
                let profile = PlaybackSettingsStore(defaults: defaults, namespace: namespace)
                var settings = PlaybackSettings.default
                settings.trueHDAtmosEnabled = false
                profile.save(settings)
                XCTAssertTrue(LosslessAudioSettingsStore(defaults: defaults).load())
                XCTAssertFalse(profile.load().trueHDAtmosEnabled)
                XCTAssertNil(defaults.object(forKey: LosslessAudioSettingsStore.storageKey))
            }
        }
    }

    func testExplicitOffAndOnPersistAcrossStoreRecreation() throws {
        try withDefaults { defaults in
            let store = LosslessAudioSettingsStore(defaults: defaults)
            for enabled in [false, true, false] {
                store.save(enabled)
                XCTAssertEqual(LosslessAudioSettingsStore(defaults: defaults).load(), enabled)
            }
        }
    }

    func testInvalidStoredValuesUseTheDefaultWithoutDestroyingTheStoredValue() throws {
        try withDefaults { defaults in
            for value: Any in ["futureValue", Data([1, 2])] {
                defaults.set(value, forKey: LosslessAudioSettingsStore.storageKey)
                XCTAssertTrue(LosslessAudioSettingsStore(defaults: defaults).load())
                XCTAssertNotNil(defaults.object(forKey: LosslessAudioSettingsStore.storageKey))
            }
        }
    }

    func testDeviceAudioChoiceDoesNotTransferOrChangeWithProfiles() throws {
        try withDefaults { source in
            try withDefaults { target in
                let sourceStore = LosslessAudioSettingsStore(defaults: source)
                let targetStore = LosslessAudioSettingsStore(defaults: target)
                sourceStore.save(false)
                targetStore.save(true)
                for namespace: String? in [nil, "adult", "kids"] {
                    let snapshot = ProfileSettingsTransfer.capture(namespace: namespace, defaults: source)
                    XCTAssertNil(snapshot[LosslessAudioSettingsStore.storageKey])
                    ProfileSettingsTransfer.apply(snapshot, namespace: namespace, defaults: target)
                    XCTAssertFalse(sourceStore.load())
                    XCTAssertTrue(targetStore.load())
                }
                XCTAssertFalse(ProfileSettingsTransfer.transferableBaseKeys.contains(
                    LosslessAudioSettingsStore.storageKey
                ))
            }
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "LosslessAudioSettingsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
