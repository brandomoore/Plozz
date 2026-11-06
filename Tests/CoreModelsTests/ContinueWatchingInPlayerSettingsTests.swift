import XCTest
@testable import CoreModels

/// The player's Continue Watching tab (#388) is on unless turned off.
final class ContinueWatchingInPlayerSettingsTests: XCTestCase {
    func testDefaultAndLegacyPayloadShowTheTab() throws {
        XCTAssertTrue(PlaybackSettings.default.continueWatchingInPlayer)
        let legacy = Data(#"{"autoPlayNextEpisode":false}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(PlaybackSettings.self, from: legacy).continueWatchingInPlayer)
    }

    func testRoundTripPreservesBothChoices() throws {
        for enabled in [false, true] {
            let settings = PlaybackSettings(continueWatchingInPlayer: enabled)
            let data = try JSONEncoder().encode(settings)
            XCTAssertEqual(try JSONDecoder().decode(PlaybackSettings.self, from: data), settings)
        }
    }

    func testEveryOptionalTabDefaultsOnWithoutChangingTheLegacyChoice() throws {
        for enabled in [false, true] {
            let data = Data(#"{"continueWatchingInPlayer":\#(enabled),"autoPlayNextEpisode":false}"#.utf8)
            let settings = try JSONDecoder().decode(PlaybackSettings.self, from: data)
            for tab in PlayerOptionalTab.allCases {
                XCTAssertTrue(PlaybackSettings.default[keyPath: tab.visibilityKeyPath])
                XCTAssertEqual(
                    settings[keyPath: tab.visibilityKeyPath], tab == .continueWatching ? enabled : true
                )
            }
            XCTAssertFalse(settings.autoPlayNextEpisode)
        }
    }

    func testAllVisibilityCombinationsRoundTripWithoutChangingPlaybackBehavior() throws {
        for mask in 0..<(1 << PlayerOptionalTab.allCases.count) {
            var settings = PlaybackSettings.default
            for (index, tab) in PlayerOptionalTab.allCases.enumerated() {
                settings[keyPath: tab.visibilityKeyPath] = mask & (1 << index) != 0
            }
            let data = try JSONEncoder().encode(settings)
            XCTAssertEqual(try JSONDecoder().decode(PlaybackSettings.self, from: data), settings)
            XCTAssertTrue(settings.autoPlayNextEpisode)
            XCTAssertTrue(settings.autoPlayNextPlaylistItem)
            XCTAssertTrue(settings.showUpNextCard)
        }
    }

    @MainActor
    func testVisibilityPersistsIndependentlyForEachProfile() throws {
        let suite = "PlayerTabs-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let primary = PlaybackSettingsStore(defaults: defaults)
        let second = PlaybackSettingsStore(defaults: defaults, namespace: "second")
        let model = PlaybackSettingsModel(store: primary)
        for tab in PlayerOptionalTab.allCases {
            model.settings[keyPath: tab.visibilityKeyPath] = false
        }
        XCTAssertEqual(primary.load(), model.settings)
        XCTAssertEqual(second.load(), .default)
        let secondaryModel = PlaybackSettingsModel(store: second)
        secondaryModel.settings.castInPlayer = false
        XCTAssertEqual(second.load(), PlaybackSettings(castInPlayer: false))
        XCTAssertEqual(PlaybackSettingsModel(store: primary).settings, model.settings)
    }

    func testPlayerTabsAreSearchableOnEveryPlatform() {
        let expected = ["player-tab-chapters", "player-tab-cast", "player-tab-episodes",
                        "player-tab-playlist", "continue-watching-in-player"]
        for platform: SettingsSearchEntry.Platform in [.phone, .tablet, .television] {
            let index = SettingsSearchIndex(
                entries: SettingsSearchCatalog.entries(on: platform), locale: Locale(identifier: "en_US")
            )
            let results = index.results(for: "player tabs")
            for id in expected {
                XCTAssertTrue(results.contains { $0.id == id }, "\(platform): \(id)")
            }
        }
    }
}
