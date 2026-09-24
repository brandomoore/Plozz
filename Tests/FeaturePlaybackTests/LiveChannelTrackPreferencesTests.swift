#if canImport(AVFoundation)
import CoreModels
import XCTest

@testable import FeaturePlayback

/// Live TV follows the profile's "Use native subtitles" setting for subtitles
/// the engine's AVPlayer draws (the remote-HLS route).
@MainActor
final class LiveChannelTrackPreferencesTests: XCTestCase {
    func testEngineStyleKeepsPlozzLookWhenNativeSubtitlesAreOff() {
        let preferences = LiveChannelTrackPreferences(usesNativeSubtitles: false)
        XCTAssertFalse(preferences.engineSubtitleStyle.followsSystemStyle)
        XCTAssertNotNil(preferences.engineSubtitleStyle.textStyleRules())
    }

    func testEngineStyleDefersToSystemWhenNativeSubtitlesAreOn() {
        let preferences = LiveChannelTrackPreferences(usesNativeSubtitles: true)
        XCTAssertTrue(preferences.engineSubtitleStyle.followsSystemStyle)
        XCTAssertNil(preferences.engineSubtitleStyle.textStyleRules(), "no overrides: system caption style")
        XCTAssertFalse(preferences.subtitleStyle.followsSystemStyle, "the overlay's own style is untouched")
    }

    func testProfileSettingSeedsPreference() {
        let namespace = "test-\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        defer {
            defaults.removeObject(forKey: SettingsKey.scoped(SubtitleBehaviorStore.storageKey, namespace: namespace))
        }
        SubtitleBehaviorStore(defaults: defaults, namespace: namespace)
            .save(SubtitleBehavior(usesNativeSubtitles: true))
        XCTAssertTrue(LiveChannelTrackPreferences(namespace: namespace).usesNativeSubtitles)
    }
}
#endif
