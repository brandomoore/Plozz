import CoreModels
import Foundation
import XCTest
@testable import AppRuntime

final class SyncSetupLaunchPreparationTests: XCTestCase {
    func testUnreadableInstallationBlocksLaunchWithoutChoosingForTheUser() throws {
        for existing in [false, true] {
            let suite = "SyncLaunchPreparation.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let flag = SyncSetupFeatureFlag(defaults: defaults)
            let unreadable = ProfileStore(defaults: defaults, secureStore: UnreadableStore())
            XCTAssertFalse(SyncSetupLaunchPreparation.prepare(flag: flag, profiles: unreadable))
            XCTAssertTrue(flag.needsLaunchPreparation)
            XCTAssertNil(defaults.object(forKey: SyncSetupFeatureFlag.storageKey))

            let recovered = ProfileStore(defaults: defaults)
            if existing { recovered.saveProfiles([Profile(name: "Existing")]) }
            XCTAssertTrue(SyncSetupLaunchPreparation.prepare(flag: flag, profiles: recovered))
            XCTAssertEqual(flag.needsOnboardingChoice, !existing)
            XCTAssertEqual(flag.isEnabled, existing)
        }
    }

    func testExplicitChoiceDoesNotRequireReclassifyingTheInstallation() throws {
        for enabled in [false, true] {
            let suite = "SyncLaunchExplicit.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let flag = SyncSetupFeatureFlag(defaults: defaults)
            flag.isEnabled = enabled
            XCTAssertTrue(SyncSetupLaunchPreparation.prepare(
                flag: flag, profiles: ProfileStore(defaults: defaults, secureStore: UnreadableStore())
            ))
            XCTAssertEqual(flag.isEnabled, enabled)
            XCTAssertFalse(flag.needsOnboardingChoice)
        }
    }

    func testPendingChoiceSurvivesRelaunchEvenIfProfileStorageBecomesUnavailable() throws {
        let suite = "SyncLaunchPending.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let flag = SyncSetupFeatureFlag(defaults: defaults)
        XCTAssertTrue(SyncSetupLaunchPreparation.prepare(flag: flag, profiles: ProfileStore(defaults: defaults)))
        XCTAssertTrue(SyncSetupLaunchPreparation.prepare(
            flag: flag, profiles: ProfileStore(defaults: defaults, secureStore: UnreadableStore())
        ))
        XCTAssertTrue(flag.needsOnboardingChoice)
        XCTAssertFalse(flag.isEnabled)
    }
}

private struct UnreadableStore: SecureStoring {
    enum Failure: Error { case unavailable }
    func setString(_ value: String, for key: String) throws { throw Failure.unavailable }
    func string(for key: String) -> String? { nil }
    func readString(for key: String) throws -> String? { throw Failure.unavailable }
    func removeValue(for key: String) throws { throw Failure.unavailable }
}
