import XCTest
@testable import CoreModels

final class PlaybackOrientationSettingsTests: XCTestCase {
    func testMenuOrderAndLegacyRawValues() throws {
        XCTAssertEqual(PlaybackOrientation.allCases, [.auto, .portrait, .landscape, .landscapeLeft, .landscapeRight])
        for (raw, expected) in [("auto", PlaybackOrientation.auto), ("portrait", .portrait), ("landscape", .landscape)] {
            let settings = try JSONDecoder().decode(
                PlaybackSettings.self, from: Data("{\"orientation\":\"\(raw)\"}".utf8)
            )
            XCTAssertEqual(settings.orientation, expected)
        }
    }

    func testDefaultAndOlderPayloadsPreferLandscape() throws {
        XCTAssertEqual(PlaybackSettings.default.orientation, .landscape)
        XCTAssertEqual(PlaybackSettings().orientation, .landscape)
        for payload in [
            #"{}"#,
            #"{"orientation":null,"backgroundAudio":true}"#,
            #"{"orientation":"future-mode","backgroundAudio":true}"#
        ] {
            let settings = try JSONDecoder().decode(PlaybackSettings.self, from: Data(payload.utf8))
            XCTAssertEqual(settings.orientation, .landscape)
            XCTAssertEqual(settings.backgroundAudio, payload != "{}")
        }
    }

    func testExplicitSavedAutomaticRotationIsPreserved() throws {
        let settings = try JSONDecoder().decode(
            PlaybackSettings.self, from: Data(#"{"orientation":"auto"}"#.utf8)
        )
        XCTAssertEqual(settings.orientation, .auto)
    }

    func testEveryOrientationRoundTrips() throws {
        for orientation in PlaybackOrientation.allCases {
            let settings = PlaybackSettings(backgroundAudio: true, orientation: orientation)
            XCTAssertEqual(
                try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(settings)),
                settings
            )
        }
    }

    @MainActor
    func testProfilesRestoreAndTransferOnlyTheirOwnPreference() throws {
        let suite = "orientation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let primaryStore = PlaybackSettingsStore(defaults: defaults)
        let guestStore = PlaybackSettingsStore(defaults: defaults, namespace: "guest")
        let primary = PlaybackSettingsModel(store: primaryStore)
        let guest = PlaybackSettingsModel(store: guestStore)
        primary.settings.orientation = .landscapeLeft
        guest.settings.orientation = .landscapeRight

        XCTAssertEqual(PlaybackSettingsModel(store: primaryStore).settings.orientation, .landscapeLeft)
        XCTAssertEqual(PlaybackSettingsModel(store: guestStore).settings.orientation, .landscapeRight)
        XCTAssertNotNil(defaults.data(forKey: "com.plozz.playbackSettings"))
        let snapshot = ProfileSettingsTransfer.capture(namespace: "guest", defaults: defaults)
        ProfileSettingsTransfer.apply(snapshot, namespace: "restored", defaults: defaults)
        XCTAssertEqual(PlaybackSettingsStore(defaults: defaults, namespace: "restored").load().orientation, .landscapeRight)
        XCTAssertEqual(primaryStore.load().orientation, .landscapeLeft)
    }
}
