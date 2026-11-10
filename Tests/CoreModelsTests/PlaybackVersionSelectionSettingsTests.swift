import XCTest
@testable import CoreModels

final class PlaybackVersionSelectionSettingsTests: XCTestCase {
    func testOldUnknownAndNullModesRemainUnanswered() throws {
        for json in ["{}", #"{"versionSelectionMode":null}"#, #"{"versionSelectionMode":"future"}"#] {
            XCTAssertNil(try JSONDecoder().decode(PlaybackSettings.self, from: Data(json.utf8)).versionSelectionMode)
        }
    }

    func testModesRoundTripWithoutChangingOtherPlaybackPreferences() throws {
        for mode in PlaybackVersionSelectionMode.allCases {
            for remembers in [false, true] {
                let settings = PlaybackSettings(
                    backgroundAudio: true, versionSelectionMode: mode, rememberVersionPerSeries: remembers
                )
                XCTAssertEqual(try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(settings)), settings)
            }
        }
    }

    func testLegacyRememberModeMigratesWithoutAnotherIntroduction() throws {
        let migrated = try JSONDecoder().decode(PlaybackSettings.self, from: Data(
            #"{"versionSelectionMode":"rememberChoice"}"#.utf8
        ))
        XCTAssertEqual(migrated.versionSelectionMode, .automatic)
        XCTAssertTrue(migrated.rememberVersionPerSeries)
        XCTAssertTrue(PlaybackSettings.default.rememberVersionPerSeries)
        let disabled = try JSONDecoder().decode(PlaybackSettings.self, from: Data(
            #"{"versionSelectionMode":"rememberChoice","rememberVersionPerSeries":false}"#.utf8
        ))
        XCTAssertEqual(disabled.versionSelectionMode, .automatic)
        XCTAssertFalse(disabled.rememberVersionPerSeries)
    }

    @MainActor
    func testChoiceIsProfileScopedAndIncludedInProfileTransfer() throws {
        let suite = "version-mode-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let primary = PlaybackSettingsStore(defaults: defaults)
        let guest = PlaybackSettingsStore(defaults: defaults, namespace: "guest")
        let model = PlaybackSettingsModel(store: primary)
        model.settings.versionSelectionMode = .askEveryTime
        XCTAssertEqual(primary.load().versionSelectionMode, .askEveryTime)
        XCTAssertNil(guest.load().versionSelectionMode)
        let guestModel = PlaybackSettingsModel(store: guest)
        guestModel.settings.versionSelectionMode = .serverOrder
        XCTAssertEqual(VersionPreferenceStore(defaults: defaults, namespace: "guest").selectionMode, .serverOrder)
        XCTAssertEqual(VersionPreferenceStore(defaults: defaults).selectionMode, .askEveryTime)
        guestModel.settings.rememberVersionPerSeries = false
        XCTAssertFalse(VersionPreferenceStore(defaults: defaults, namespace: "guest").remembersSeriesVersions)
        XCTAssertTrue(VersionPreferenceStore(defaults: defaults).remembersSeriesVersions)
        let snapshot = ProfileSettingsTransfer.capture(namespace: "guest", defaults: defaults)
        ProfileSettingsTransfer.apply(snapshot, namespace: "restored", defaults: defaults)
        XCTAssertEqual(PlaybackSettingsStore(defaults: defaults, namespace: "restored").load().versionSelectionMode, .serverOrder)
        XCTAssertFalse(VersionPreferenceStore(defaults: defaults, namespace: "restored").remembersSeriesVersions)
        XCTAssertEqual(primary.load().versionSelectionMode, .askEveryTime)
    }

    func testDisabledSeriesMemoryDoesNotDisableMoviePreferences() throws {
        let suite = "version-memory-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = PlaybackSettingsStore(defaults: defaults)
        settings.save(PlaybackSettings(rememberVersionPerSeries: false))
        let preferences = VersionPreferenceStore(defaults: defaults)
        XCTAssertTrue(preferences.shouldRememberVersion(for: .init(id: "movie", title: "Movie", kind: .movie)))
        XCTAssertFalse(preferences.shouldRememberVersion(for: .init(id: "series", title: "Series", kind: .series)))
        XCTAssertFalse(preferences.shouldRememberVersion(for: .init(
            id: "episode", title: "Episode", kind: .episode, seriesID: "series"
        )))
    }

    func testAutomaticMatchingDoesNotSubstituteDifferentOrUnknownFacts() {
        let original = MediaVersion(
            id: "one", edition: "Extended", height: 2160,
            videoCodec: "hevc", videoRange: "HDR10", audioProfile: "Atmos"
        )
        let descriptor = MediaVersionDescriptor(version: original)
        var next = original
        next.id = "another-episode"
        XCTAssertTrue(descriptor.matchesForAutomaticSelection(next))
        next.height = 1080
        XCTAssertFalse(descriptor.matchesForAutomaticSelection(next))
        next = original
        next.videoRange = "SDR"
        XCTAssertFalse(descriptor.matchesForAutomaticSelection(next))
        next = original
        next.edition = "Theatrical"
        XCTAssertFalse(descriptor.matchesForAutomaticSelection(next))
        next = original
        next.audioProfile = nil
        XCTAssertFalse(descriptor.matchesForAutomaticSelection(next))
        XCTAssertFalse(MediaVersionDescriptor().matchesForAutomaticSelection(original))
    }
}
