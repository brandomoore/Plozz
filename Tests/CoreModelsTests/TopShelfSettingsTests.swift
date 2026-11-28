import CoreModels
import XCTest

@MainActor
final class TopShelfSettingsTests: XCTestCase {
    func testDefaultsAndAllowedRange() {
        XCTAssertTrue(TopShelfSettings.default.isEnabled)
        XCTAssertFalse(TopShelfSettings.default.usesFullScreen)
        XCTAssertEqual(TopShelfSettings.default.continueWatchingItems, 4)
        XCTAssertEqual(TopShelfSettings.default.recentlyAddedItems, 4)
        XCTAssertEqual(TopShelfSettings.itemCountRange, 1...20)
    }

    func testDisableSurvivesRelaunchAndReenablePreservesCounts() throws {
        try withDefaults { defaults in
            let model = TopShelfSettingsModel(defaults: defaults)
            model.settings = .init(continueWatchingItems: 7, recentlyAddedItems: 12)
            model.settings.isEnabled = false
            let relaunched = TopShelfSettingsModel(defaults: defaults)
            XCTAssertEqual(relaunched.settings,
                           .init(isEnabled: false, continueWatchingItems: 7, recentlyAddedItems: 12))
            relaunched.settings.isEnabled = true
            XCTAssertEqual(TopShelfSettingsModel(defaults: defaults).settings,
                           .init(continueWatchingItems: 7, recentlyAddedItems: 12))
        }

    }

    func testAppleTVUsersChooseIndependentlyOfPlozzProfile() throws {
        try withDefaults { firstUser in
            try withDefaults { secondUser in
                TopShelfSettingsModel(defaults: firstUser).settings.isEnabled = false
                XCTAssertTrue(TopShelfSettingsModel(defaults: secondUser).settings.isEnabled)
                XCTAssertFalse(TopShelfSettingsModel(defaults: firstUser).settings.isEnabled)
            }
        }
    }

    func testCountsRemainIndependentAndSurviveRelaunch() throws {
        try withDefaults { defaults in
            let model = TopShelfSettingsModel(defaults: defaults)
            model.settings.continueWatchingItems = 20
            XCTAssertEqual(model.settings.recentlyAddedItems, 4)
            model.settings.recentlyAddedItems = 1
            XCTAssertEqual(TopShelfSettingsModel(defaults: defaults).settings,
                           TopShelfSettings(continueWatchingItems: 20, recentlyAddedItems: 1))
        }
    }

    func testFullscreenSelectionPersistsWithoutChangingCountsOrEnablement() throws {
        try withDefaults { defaults in
            let model = TopShelfSettingsModel(defaults: defaults)
            model.settings = .init(isEnabled: false, continueWatchingItems: 3, recentlyAddedItems: 9)
            model.settings.usesFullScreen = true
            XCTAssertEqual(TopShelfSettingsModel(defaults: defaults).settings,
                           .init(isEnabled: false, usesFullScreen: true,
                                 continueWatchingItems: 3, recentlyAddedItems: 9))
            model.settings.usesFullScreen = false
            XCTAssertEqual(TopShelfSettingsModel(defaults: defaults).settings,
                           .init(isEnabled: false, continueWatchingItems: 3, recentlyAddedItems: 9))
        }
    }

    func testInitializationMutationAndDecodingBoundBothCounts() throws {
        var settings = TopShelfSettings(continueWatchingItems: -100, recentlyAddedItems: Int.max)
        XCTAssertEqual(settings, TopShelfSettings(continueWatchingItems: 1, recentlyAddedItems: 20))
        settings.continueWatchingItems = 21
        settings.recentlyAddedItems = 0
        XCTAssertEqual(settings, TopShelfSettings(continueWatchingItems: 20, recentlyAddedItems: 1))
        let decoded = try JSONDecoder().decode(
            TopShelfSettings.self,
            from: Data(#"{"continueWatchingItems":0,"recentlyAddedItems":500}"#.utf8)
        )
        XCTAssertEqual(decoded, TopShelfSettings(continueWatchingItems: 1, recentlyAddedItems: 20))
    }

    func testOlderPartialSettingsUseDefaultsForMissingCounts() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(TopShelfSettings.self, from: Data("{}".utf8)), .default)
        XCTAssertEqual(
            try decoder.decode(TopShelfSettings.self, from: Data(#"{"continueWatchingItems":9}"#.utf8)),
            TopShelfSettings(continueWatchingItems: 9, recentlyAddedItems: 4)
        )
        let countOnly = try decoder.decode(
            TopShelfSettings.self, from: Data(#"{"continueWatchingItems":8,"recentlyAddedItems":12}"#.utf8)
        )
        XCTAssertEqual(countOnly, .init(isEnabled: true, continueWatchingItems: 8, recentlyAddedItems: 12))
    }

    func testCorruptSettingsRecoverWithoutErasingStoredEvidence() throws {
        try withDefaults { defaults in
            let corrupt = Data("invalid".utf8)
            defaults.set(corrupt, forKey: TopShelfSettingsModel.storageKey)
            let model = TopShelfSettingsModel(defaults: defaults)
            XCTAssertEqual(model.settings, .default)
            XCTAssertEqual(defaults.data(forKey: TopShelfSettingsModel.storageKey), corrupt)
            model.settings.recentlyAddedItems = 7
            XCTAssertEqual(TopShelfSettingsModel(defaults: defaults).settings.recentlyAddedItems, 7)
        }
    }

    func testProfileTransferCannotOverwriteOrExportDeviceCounts() throws {
        try withDefaults { defaults in
            let model = TopShelfSettingsModel(defaults: defaults)
            model.settings = .init(isEnabled: false, continueWatchingItems: 8, recentlyAddedItems: 12)
            let attemptedTransfer = try PropertyListSerialization.data(
                fromPropertyList: [JSONEncoder().encode(TopShelfSettings.default)],
                format: .binary, options: 0
            )
            for namespace: String? in [nil, "guest"] {
                XCTAssertNil(ProfileSettingsTransfer.capture(namespace: namespace, defaults: defaults)[
                    TopShelfSettingsModel.storageKey
                ])
                ProfileSettingsTransfer.apply(
                    [TopShelfSettingsModel.storageKey: attemptedTransfer],
                    namespace: namespace, defaults: defaults
                )
                XCTAssertEqual(TopShelfSettingsModel(defaults: defaults).settings, model.settings)
            }
            XCTAssertNil(defaults.object(forKey: TopShelfSettingsModel.storageKey + ".guest"))
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "TopShelfSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
