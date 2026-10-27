import XCTest
@testable import CoreModels

final class ThemeMusicSettingsTests: XCTestCase {
    func testThemeMusicCarriesCredentialFreeSource() throws {
        let source = try SecretFreeURLSource(
            url: URL(string: "https://themes.example/title.mp3")!
        )
        let theme = ThemeMusic(
            itemID: "title",
            playbackSource: .publicURL(source),
            title: "Main Theme"
        )

        XCTAssertEqual(
            theme.playbackSource.publicURL,
            URL(string: "https://themes.example/title.mp3")
        )
        XCTAssertEqual(theme.title, "Main Theme")
    }

    func testDefaultIsOptInOff() {
        let settings = ThemeMusicSettings.default
        XCTAssertFalse(settings.isEnabled)
        XCTAssertFalse(settings.shouldPlay)
        XCTAssertEqual(settings.volume.level, 0.25)
    }

    func testShouldPlayRequiresEnabledAndAudibleVolume() {
        XCTAssertFalse(ThemeMusicSettings(isEnabled: false, volume: .high).shouldPlay)
        XCTAssertFalse(ThemeMusicSettings(isEnabled: true, volume: .off).shouldPlay)
        XCTAssertTrue(ThemeMusicSettings(isEnabled: true, volume: .low).shouldPlay)
        XCTAssertTrue(ThemeMusicSettings(isEnabled: true, volume: .medium).shouldPlay)
        XCTAssertTrue(ThemeMusicSettings(isEnabled: true, volume: .high).shouldPlay)
    }

    func testVolumeGainCoversSilenceToFullDeviceVolume() {
        XCTAssertEqual(ThemeMusicVolume.off.gain, 0)
        XCTAssertLessThan(ThemeMusicVolume.low.gain, ThemeMusicVolume.medium.gain)
        XCTAssertLessThan(ThemeMusicVolume.medium.gain, ThemeMusicVolume.high.gain)
        XCTAssertEqual(ThemeMusicVolume(1).gain, 1)
        XCTAssertEqual(ThemeMusicVolume(0.01).gain, 0.01)
        XCTAssertEqual(ThemeMusicVolume(0.73).gain, 0.73)
        XCTAssertEqual(ThemeMusicVolume(-1).gain, 0)
        XCTAssertEqual(ThemeMusicVolume(2).gain, 1)
        XCTAssertEqual(ThemeMusicVolume(.nan), .default)
        XCTAssertEqual(ThemeMusicVolume(.infinity), .default)
    }

    func testLegacyLevelsKeepExactGain() throws {
        for (token, gain): (String, Float) in [("off", 0), ("low", 0.15), ("medium", 0.35), ("high", 0.6)] {
            let settings = try JSONDecoder().decode(
                ThemeMusicSettings.self, from: Data(#"{"isEnabled":true,"volume":"\#(token)"}"#.utf8)
            )
            XCTAssertEqual(settings.volume.gain, gain)
        }
    }

    func testCodableRoundTrip() throws {
        let settings = ThemeMusicSettings(
            isEnabled: true,
            volume: ThemeMusicVolume(0.73)
        )
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(
            try JSONDecoder().decode(ThemeMusicSettings.self, from: data),
            settings
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["volume"] as? Double, 0.73)
    }

    func testLenientDecodeUsesDefaultsForMissingAndUnknownFields() throws {
        let missing = try JSONDecoder().decode(
            ThemeMusicSettings.self,
            from: Data(#"{"isEnabled":true,"loops":true}"#.utf8)
        )
        XCTAssertTrue(missing.isEnabled)
        XCTAssertEqual(missing.volume, .default)

        let unknown = try JSONDecoder().decode(
            ThemeMusicSettings.self,
            from: Data(#"{"isEnabled":true,"volume":"deafening"}"#.utf8)
        )
        XCTAssertEqual(unknown.volume, .default)
    }

    func testStoreRoundTripAndProfileIsolation() {
        let suite = "ThemeMusicSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let primary = ThemeMusicSettingsStore(defaults: defaults)
        let second = ThemeMusicSettingsStore(defaults: defaults, namespace: "profile-2")
        let saved = ThemeMusicSettings(
            isEnabled: true,
            volume: .high
        )

        primary.save(saved)
        XCTAssertEqual(primary.load(), saved)
        XCTAssertEqual(second.load(), .default)
        primary.save(ThemeMusicSettings(volume: .low))
        XCTAssertEqual(primary.load().volume.level, 0.15, "An existing saved low volume must not be raised to the new default.")
    }

    @MainActor
    func testModelPersistsChanges() {
        let suite = "ThemeMusicSettingsModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ThemeMusicSettingsStore(defaults: defaults)
        let model = ThemeMusicSettingsModel(store: store)
        model.settings.isEnabled = true
        model.settings.volume = .medium

        XCTAssertTrue(store.load().isEnabled)
        XCTAssertEqual(store.load().volume, .medium)
    }
}
