import XCTest
@testable import CoreModels

@MainActor
final class SubtitleStylePreferencesTests: XCTestCase {
    func testFineSizeStepsAndBothRangeEndpointsPersistExactly() throws {
        for scale in [0.2, 1.01, 1.37, 4.0] {
            var style = SubtitleStyle.default
            style.fontScale = scale
            let saved = try JSONEncoder().encode(SubtitleStylePreferences(base: style, liveTV: style))
            let restored = try JSONDecoder().decode(SubtitleStylePreferences.self, from: saved)
            XCTAssertEqual(restored.base.fontScale, scale)
            XCTAssertEqual(restored.liveTV?.fontScale, scale)
        }
    }

    func testExistingPreferencesInheritTheBaseForLiveTV() throws {
        let data = Data(#"{"base":{"fontScale":0.4}}"#.utf8)
        let preferences = try JSONDecoder().decode(SubtitleStylePreferences.self, from: data)
        XCTAssertNil(preferences.liveTV)
        XCTAssertEqual(preferences.resolvedLiveTV.fontScale, 0.4)
    }

    func testLiveOverrideRoundTripsWithoutChangingLibraryStyles() throws {
        var library = SubtitleStyle.default
        library.textColor = .yellow
        var live = SubtitleStyle.default
        live.followsSystemStyle = true
        live.fontScale = 0.4
        live.systemFont = .caption(.smallCapitals)
        library.systemFont = .named("Courier")
        let preferences = SubtitleStylePreferences(base: library, overrides: [.anime: .default], liveTV: live)
        let decoded = try JSONDecoder().decode(
            SubtitleStylePreferences.self, from: JSONEncoder().encode(preferences)
        )
        XCTAssertEqual(decoded, preferences)
        XCTAssertEqual(decoded.resolved(for: .movie), library)
        XCTAssertEqual(decoded.resolved(for: .anime), .default)
        XCTAssertEqual(decoded.resolvedLiveTV, live)
    }

    func testSeparateStyleStartsFromCurrentLookAndEditsStayProfileScoped() throws {
        let name = "SubtitleStylePreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SubtitleStyleStore(defaults: defaults, namespace: "viewer")
        let model = SubtitleStyleModel(store: store)
        model.style.textColor = .yellow
        model.usesSeparateLiveTVStyle = true
        XCTAssertEqual(model.liveTVStyle, model.style)
        model.resolvedLiveTVStyle.followsSystemStyle = true
        model.resolvedLiveTVStyle.fontScale = 0.4
        model.style.textColor = .cyan

        let restored = SubtitleStyleModel(store: store)
        XCTAssertEqual(restored.style.textColor, .cyan)
        XCTAssertEqual(restored.liveTVStyle?.textColor, .yellow)
        XCTAssertEqual(restored.liveTVStyle?.fontScale, 0.4)
        XCTAssertEqual(restored.liveTVStyle?.followsSystemStyle, true)
        XCTAssertEqual(SubtitleStyleStore(defaults: defaults).load(), .default)
        XCTAssertEqual(SubtitleStyleStore(defaults: defaults, namespace: "other").load(), .default)

        restored.usesSeparateLiveTVStyle = false
        XCTAssertNil(store.load().liveTV)
        XCTAssertEqual(restored.resolvedLiveTVStyle, restored.style)
    }
}
