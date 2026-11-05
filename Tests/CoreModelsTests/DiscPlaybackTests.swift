import XCTest
@testable import CoreModels

final class DiscPlaybackTests: XCTestCase {
    func testExistingProfilesKeepDirectPlayback() throws {
        XCTAssertEqual(PlaybackSettings.default.discPlayback, .playVideo)
        for json in ["{}", #"{"discPlayback":"future-mode"}"#] {
            XCTAssertEqual(
                try JSONDecoder().decode(PlaybackSettings.self, from: Data(json.utf8)).discPlayback,
                .playVideo
            )
        }
    }

    @MainActor
    func testPreferenceRoundTripsWithoutCrossingProfiles() throws {
        let suite = "DiscPlaybackTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let guest = PlaybackSettingsStore(defaults: defaults, namespace: "guest")
        let model = PlaybackSettingsModel(store: guest)
        model.settings.discPlayback = .openMenu
        XCTAssertEqual(PlaybackSettingsModel(store: guest).settings.discPlayback, .openMenu)
        XCTAssertEqual(
            PlaybackSettingsModel(store: PlaybackSettingsStore(defaults: defaults)).settings.discPlayback,
            .playVideo
        )
        XCTAssertEqual(
            try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(model.settings)),
            model.settings
        )
    }

    func testUnknownIsAttemptableButKnownUnavailableHasNoMenuAction() {
        for behavior in DiscPlaybackBehavior.allCases {
            for availability in [DiscMenuAvailability.unknown, .available] {
                let choice = DiscPlaybackChoice(default: behavior, availability: availability)
                XCTAssertEqual(choice.primary, behavior)
                XCTAssertEqual(choice.alternative, behavior.alternative)
            }
            let choice = DiscPlaybackChoice(default: behavior, availability: .unavailable(.unsupportedRuntime))
            XCTAssertEqual(choice.primary, .playVideo)
            XCTAssertNil(choice.alternative)
            XCTAssertEqual(choice.unavailableReason, .unsupportedRuntime)
        }
    }

    func testOnePlayOverrideIsNotPersisted() throws {
        var item = MediaItem(id: "disc", title: "Fixture", kind: .movie)
        item.versions = [MediaVersion(id: "index", container: "bdmv")]
        let oneShot = item.requestingDiscPlayback(.openMenu)
        XCTAssertTrue(oneShot.explicitSourceSelection)
        XCTAssertEqual(oneShot.discPlaybackOverride, .openMenu)
        XCTAssertFalse(item.explicitSourceSelection)
        XCTAssertEqual(item.effectiveDiscPlayback(default: .openMenu), .openMenu)
        item.discPlaybackOverride = .playVideo
        XCTAssertEqual(item.selectingVersion("index").discPlaybackOverride, .playVideo)
        XCTAssertEqual(item.effectiveDiscPlayback(default: .openMenu), .playVideo)
        let data = try JSONEncoder().encode(item)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("discPlaybackOverride"))
        XCTAssertNil(try JSONDecoder().decode(MediaItem.self, from: data).discPlaybackOverride)
    }

    func testSelectedFileControlsDiscAvailability() {
        var item = MediaItem(id: "versions", title: "Fixture", kind: .movie)
        item.versions = [
            MediaVersion(id: "disc", container: "BDMV"), MediaVersion(id: "file", container: "mkv")
        ]
        XCTAssertEqual(item.selectingVersion("disc").discMenuAvailability, .unknown)
        XCTAssertNil(item.selectingVersion("file").discMenuAvailability)
        XCTAssertEqual(item.selectingVersion("file").effectiveDiscPlayback(default: .openMenu), .playVideo)
    }

    func testInspectionHidesOnlyConclusiveMenuLimitations() {
        var index = Data("INDX0200".utf8)
        index.append(contentsOf: [0, 0, 0, 40])
        index.append(Data(repeating: 0, count: 28))
        index.append(contentsOf: [0, 0, 0, 26])
        index.append(Data(repeating: 0, count: 26))
        index[56] = 0x40
        XCTAssertEqual(DiscMenuInspection.availability(index: index), .unknown)
        index[62] = 0xff
        index[63] = 0xff
        XCTAssertEqual(DiscMenuInspection.availability(index: index), .unavailable(.missingMenu))
        index[56] = 0x80
        XCTAssertEqual(DiscMenuInspection.availability(index: index), .unavailable(.unsupportedRuntime))
        for version in ["0240", "0300"] {
            index.replaceSubrange(4..<8, with: version.utf8)
            XCTAssertEqual(DiscMenuInspection.availability(index: index), .unavailable(.unsupportedRuntime))
        }
        for end in 0..<index.count {
            XCTAssertEqual(DiscMenuInspection.availability(index: index.prefix(end)), .unknown)
        }
        index[8] = 0xff
        XCTAssertEqual(DiscMenuInspection.availability(index: index), .unknown)
    }

    func testKnownUnavailableSelectedVersionKeepsDirectDefault() throws {
        var disc = MediaVersion(id: "disc", container: "bdmv")
        disc.discMenuAvailability = .unavailable(.unsupportedRuntime)
        var item = MediaItem(id: "disc", title: "Fixture", kind: .movie)
        item.versions = [disc]
        XCTAssertEqual(item.effectiveDiscPlayback(default: .openMenu), .playVideo)
        XCTAssertEqual(try JSONDecoder().decode(MediaVersion.self, from: JSONEncoder().encode(disc)), disc)
    }
}
