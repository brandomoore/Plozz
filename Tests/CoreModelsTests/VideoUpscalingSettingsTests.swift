import XCTest
@testable import CoreModels

final class VideoUpscalingSettingsTests: XCTestCase {
    func testOlderAndInvalidPreferencesUseAutomaticWithoutResettingOtherSettings() throws {
        for field in ["", #","videoUpscaling":null"#, #","videoUpscaling":"future-mode""#,
                      #","videoUpscaling":42"#] {
            let data = Data("""
            {"rememberAudioTrackPerSeries":false\(field)}
            """.utf8)
            let settings = try JSONDecoder().decode(PlaybackSettings.self, from: data)
            XCTAssertEqual(settings.videoUpscaling, .automatic)
            XCTAssertFalse(settings.rememberAudioTrackPerSeries)
        }
    }

    @MainActor
    func testExplicitChoicesPersistIndependentlyAndTransferWithTheProfile() throws {
        let suite = "VideoUpscalingSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let primary = PlaybackSettingsStore(defaults: defaults)
        let guest = PlaybackSettingsStore(defaults: defaults, namespace: "guest")
        let model = PlaybackSettingsModel(store: primary)
        XCTAssertEqual(model.settings.videoUpscaling, .automatic)
        model.settings.videoUpscaling = .off
        let guestModel = PlaybackSettingsModel(store: guest)
        guestModel.settings.videoUpscaling = .animation
        XCTAssertEqual(primary.load().videoUpscaling, .off)
        XCTAssertEqual(guest.load().videoUpscaling, .animation)
        let snapshot = ProfileSettingsTransfer.capture(namespace: "guest", defaults: defaults)
        ProfileSettingsTransfer.apply(snapshot, namespace: "restored", defaults: defaults)
        let restored = PlaybackSettingsStore(defaults: defaults, namespace: "restored")
        XCTAssertEqual(restored.load().videoUpscaling, .animation)
        guestModel.settings.videoUpscaling = .standard
        XCTAssertEqual(guest.load().videoUpscaling, .standard)
        guestModel.settings.videoUpscaling = .automatic
        XCTAssertEqual(guest.load().videoUpscaling, .automatic)
        XCTAssertEqual(restored.load().videoUpscaling, .animation)
        XCTAssertEqual(primary.load().videoUpscaling, .off)
    }
}
