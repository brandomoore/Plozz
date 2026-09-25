#if canImport(AVFoundation)
import CoreModels
import XCTest

@testable import FeaturePlayback

@MainActor
final class LiveChannelTrackPreferencesTests: XCTestCase {
    func testNativeAndOverlayPathsUseTheSameStyleChoice() {
        var style = SubtitleStyle.default
        style.fontScale = 1.37
        let preferences = LiveChannelTrackPreferences(subtitleStyle: style)
        XCTAssertEqual(preferences.engineSubtitleStyle, style)
        XCTAssertNotNil(preferences.engineSubtitleStyle.textStyleRules())
        style.followsSystemStyle = true
        preferences.setSubtitleStyle(style)
        XCTAssertEqual(preferences.subtitleStyle, style)
        XCTAssertNil(preferences.engineSubtitleStyle.textStyleRules())
    }

    func testLivePlayerEditsRefreshSettingsAndOtherPanesWithoutChangingTheLibraryStyle() throws {
        let name = "LiveChannelTrackPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SubtitleStyleModel(store: SubtitleStyleStore(defaults: defaults, namespace: "viewer"))
        let first = LiveChannelTrackPreferences(namespace: "viewer", defaults: defaults)
        let second = LiveChannelTrackPreferences(namespace: "viewer", defaults: defaults)
        let otherProfile = LiveChannelTrackPreferences(namespace: "other", defaults: defaults)
        let original = settings.style
        var live = SubtitleStyle.default
        live.fontScale = 1.37
        live.textColor = .yellow
        first.setSubtitleStyle(live)
        XCTAssertEqual(settings.liveTVStyle, live)
        XCTAssertTrue(settings.usesSeparateLiveTVStyle)
        XCTAssertEqual(settings.style, original)
        XCTAssertEqual(second.subtitleStyle, live)
        XCTAssertEqual(otherProfile.subtitleStyle, .profileDefault)
        settings.usesSeparateLiveTVStyle = false
        XCTAssertEqual(first.subtitleStyle, original)
        XCTAssertEqual(second.subtitleStyle, original)
    }
}
#endif
