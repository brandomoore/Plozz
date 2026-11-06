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
}
