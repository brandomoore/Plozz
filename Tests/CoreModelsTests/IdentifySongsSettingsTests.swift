import XCTest
@testable import CoreModels

/// Refs #351: song identification is on unless the profile turns it off.
final class IdentifySongsSettingsTests: XCTestCase {
    func testDefaultAndLegacyPayloadIdentifySongs() throws {
        XCTAssertTrue(PlaybackSettings.default.identifySongs)
        let legacy = Data(#"{"autoPlayNextEpisode":false}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(PlaybackSettings.self, from: legacy).identifySongs)
    }

    func testRoundTripPreservesBothChoices() throws {
        for enabled in [false, true] {
            let settings = PlaybackSettings(identifySongs: enabled)
            let data = try JSONEncoder().encode(settings)
            XCTAssertEqual(try JSONDecoder().decode(PlaybackSettings.self, from: data), settings)
        }
    }
}
