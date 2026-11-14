import XCTest
@testable import CoreModels

final class DolbyVisionFELSettingsTests: XCTestCase {
    @MainActor
    func testConversionDefaultsOnAndExplicitOffIsProfileScoped() throws {
        let suite = "fel-conversion-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let primary = PlaybackSettingsStore(defaults: defaults)
        let guest = PlaybackSettingsStore(defaults: defaults, namespace: "guest")
        XCTAssertTrue(primary.load().dolbyVisionFELConversion)
        let model = PlaybackSettingsModel(store: primary)
        model.settings.dolbyVisionFELConversion = false
        XCTAssertFalse(primary.load().dolbyVisionFELConversion)
        XCTAssertTrue(guest.load().dolbyVisionFELConversion)
    }

    func testRetiredFELPreferenceIsIgnoredAndNotWrittenBack() throws {
        for payload in [
            #"{}"#,
            #"{"dolbyVisionFELEnabled":true}"#,
            #"{"dolbyVisionFELEnabled":false}"#,
            #"{"dolbyVisionFELEnabled":null}"#,
            #"{"dolbyVisionFELEnabled":"unknown"}"#
        ] {
            let settings = try JSONDecoder().decode(PlaybackSettings.self, from: Data(payload.utf8))
            XCTAssertEqual(settings, .default)
            let encoded = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any]
            )
            XCTAssertNil(encoded["dolbyVisionFELEnabled"])
        }
    }

    func testLegacyFELChoicesDoNotChangeOtherPlaybackPreferences() throws {
        for enabled in [false, true] {
            let settings = try JSONDecoder().decode(
                PlaybackSettings.self, from: Data("""
                {"dolbyVisionFELEnabled":\(enabled),"rememberAudioTrackPerSeries":false}
                """.utf8)
            )
            XCTAssertEqual(settings, PlaybackSettings(rememberAudioTrackPerSeries: false))
            XCTAssertEqual(
                try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(settings)),
                settings
            )
        }
    }

    @MainActor
    func testLegacyProfileTransferCannotRestoreFELAndPreservesOtherChoices() throws {
        let suite = "DolbyVisionFELSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let primaryStore = PlaybackSettingsStore(defaults: defaults)
        let guestStore = PlaybackSettingsStore(defaults: defaults, namespace: "guest")
        let guestKey = SettingsKey.scoped("com.plozz.playbackSettings", namespace: "guest")
        defaults.set(Data("""
        {"dolbyVisionFELEnabled":true,"rememberAudioTrackPerSeries":false}
        """.utf8), forKey: guestKey)
        let guest = PlaybackSettingsModel(store: guestStore)
        let expected = PlaybackSettings(rememberAudioTrackPerSeries: false)
        XCTAssertEqual(PlaybackSettingsModel(store: primaryStore).settings, .default)
        XCTAssertEqual(guest.settings, expected)

        let snapshot = ProfileSettingsTransfer.capture(namespace: "guest", defaults: defaults)
        ProfileSettingsTransfer.apply(snapshot, namespace: "restored", defaults: defaults)
        let restoredStore = PlaybackSettingsStore(defaults: defaults, namespace: "restored")
        XCTAssertEqual(restoredStore.load(), expected)
        guest.settings.audioLanguagePreference = .language("ja")
        XCTAssertEqual(guestStore.load().audioLanguagePreference, .language("ja"))
        XCTAssertEqual(restoredStore.load(), expected)
        let saved = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: guestKey))) as? [String: Any]
        )
        XCTAssertNil(saved["dolbyVisionFELEnabled"])
    }
}
