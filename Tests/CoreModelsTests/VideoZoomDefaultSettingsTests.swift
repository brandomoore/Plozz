import XCTest
@testable import CoreModels

final class VideoZoomDefaultSettingsTests: XCTestCase {
    func testOlderSettingsAndPartialPlatformPayloadKeepAutomaticDefaults() throws {
        let old = try JSONDecoder().decode(PlaybackSettings.self, from: Data(#"{"backgroundAudio":true}"#.utf8))
        XCTAssertTrue(old.backgroundAudio)
        for platform in VideoZoomDefaults.Platform.allCases {
            XCTAssertEqual(old.videoZoom[platform].mode, .picture)
        }
        let partial = try JSONDecoder().decode(
            PlaybackSettings.self,
            from: Data(#"{"videoZoom":{"phone":{"mode":0}},"backgroundAudio":true}"#.utf8)
        )
        XCTAssertEqual(partial.videoZoom.phone.mode, .fit)
        XCTAssertEqual(partial.videoZoom.tablet.mode, .picture)
        XCTAssertEqual(partial.videoZoom.television.mode, .picture)
        XCTAssertTrue(partial.backgroundAudio)
    }

    @MainActor
    func testPlatformChoicesPersistAndTransferWithoutChangingOtherProfiles() throws {
        let suite = "VideoZoomDefaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let primary = PlaybackSettingsModel(store: PlaybackSettingsStore(defaults: defaults))
        let guestStore = PlaybackSettingsStore(defaults: defaults, namespace: "guest")
        let guest = PlaybackSettingsModel(store: guestStore)
        guest.settings.videoZoom[.phone] = .init(mode: .fit, pictureFitsInsideSafeArea: true)
        guest.settings.videoZoom[.tablet] = .init(mode: .custom, customPercent: 117)
        guest.settings.videoZoom[.television] = .init(mode: .fill)
        primary.settings.videoZoom[.phone] = .init(mode: .stretch)
        XCTAssertEqual(PlaybackSettingsModel(store: guestStore).settings.videoZoom, guest.settings.videoZoom)
        let snapshot = ProfileSettingsTransfer.capture(namespace: "guest", defaults: defaults)
        ProfileSettingsTransfer.apply(snapshot, namespace: "restored", defaults: defaults)
        let restored = PlaybackSettingsStore(defaults: defaults, namespace: "restored").load()
        XCTAssertEqual(restored.videoZoom, guest.settings.videoZoom)
        XCTAssertEqual(PlaybackSettingsStore(defaults: defaults).load().videoZoom.phone.mode, .stretch)
        XCTAssertEqual(restored.videoZoom.phone.mode, .fit)
        XCTAssertTrue(restored.videoZoom.phone.pictureFitsInsideSafeArea)
        XCTAssertFalse(restored.videoZoom.tablet.pictureFitsInsideSafeArea)
        XCTAssertEqual(restored.videoZoom.tablet.customPercent, 117)
        XCTAssertEqual(restored.videoZoom.television.mode, .fill)
    }
}
