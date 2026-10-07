import XCTest
@testable import CoreModels

final class ArtworkSettingsTests: XCTestCase {
    func testRecommendedAndLibraryFirstKeepSourceSeparateFromPresentation() {
        let recommended = ArtworkSettings.default
        XCTAssertTrue(recommended.prefersTextlessArtwork(in: .continueWatching))
        XCTAssertTrue(recommended.prefersOnlineArtwork(in: .browse))
        XCTAssertFalse(recommended.prefersOnlineArtwork(in: .music))
        let library = ArtworkSettings(preference: .library)
        for area in ArtworkArea.allCases {
            XCTAssertFalse(library.prefersOnlineArtwork(in: area))
        }
        XCTAssertFalse(library.prefersTextlessArtwork(in: .continueWatching))
    }

    func testOverridesInheritChangesWithoutBecomingPermanentDefaults() {
        var settings = ArtworkSettings()
        settings.setOverride(.library, for: .continueWatching)
        settings.preference = .online
        XCTAssertFalse(settings.prefersOnlineArtwork(in: .continueWatching))
        XCTAssertTrue(settings.prefersOnlineArtwork(in: .browse))
        XCTAssertEqual(settings.override(for: .browse), .automatic)
        settings.setOverride(.automatic, for: .continueWatching)
        XCTAssertTrue(settings.prefersTextlessArtwork(in: .continueWatching))
        XCTAssertTrue(settings.overrides.isEmpty)
        settings.setOverride(.online, for: .music)
        settings.resetOverrides()
        settings.preference = .recommended
        XCTAssertFalse(settings.prefersOnlineArtwork(in: .music))
    }

    func testCodableRoundTripAndUnknownFutureValues() throws {
        let settings = ArtworkSettings(preference: .online, overrides: [.browse: .library])
        XCTAssertEqual(
            try JSONDecoder().decode(ArtworkSettings.self, from: JSONEncoder().encode(settings)),
            settings
        )
        let future = Data(#"{"preference":"future","overrides":{"future":"library","browse":"future","search":"online"}}"#.utf8)
        let decoded = try JSONDecoder().decode(ArtworkSettings.self, from: future)
        XCTAssertEqual(decoded.preference, .recommended)
        XCTAssertEqual(decoded.overrides, [.search: .online])
    }

    func testRemovingCustomizationsAppliesTheMainPreferenceToEveryView() {
        for preference in [ArtworkPreference.library, .online] {
            var settings = ArtworkSettings(
                preference: preference,
                overrides: [.browse: .library, .music: .online]
            )
            settings.resetOverrides()
            XCTAssertEqual(settings.preference, preference)
            for area in ArtworkArea.allCases {
                XCTAssertEqual(settings.override(for: area), .automatic)
                XCTAssertEqual(settings.prefersOnlineArtwork(in: area), preference == .online)
            }
        }
    }

    func testRecommendedWithBrowseCustomizedRetainsTheMusicDefault() {
        var settings = ArtworkSettings(overrides: [.browse: .library])
        XCTAssertFalse(settings.prefersOnlineArtwork(in: .browse))
        XCTAssertFalse(settings.prefersOnlineArtwork(in: .music))
        XCTAssertTrue(settings.prefersOnlineArtwork(in: .home))
        settings.preference = .online
        settings.preference = .recommended
        XCTAssertEqual(settings.overrides, [.browse: .library])
        XCTAssertFalse(settings.prefersOnlineArtwork(in: .music))
        settings.resetOverrides()
        XCTAssertEqual(settings.preference, .recommended)
        XCTAssertTrue(settings.prefersOnlineArtwork(in: .browse))
        XCTAssertFalse(settings.prefersOnlineArtwork(in: .music))
    }

    func testDisplayedInheritedSourceIgnoresOverridesAndTracksThePreset() {
        var settings = ArtworkSettings()
        settings.setOverride(.library, for: .browse)
        settings.setOverride(.online, for: .music)
        XCTAssertEqual(settings.inheritedPreference(in: .browse), .online)
        XCTAssertEqual(settings.inheritedPreference(in: .music), .library)
        settings.preference = .library
        XCTAssertEqual(settings.inheritedPreference(in: .browse), .library)
        XCTAssertEqual(settings.inheritedPreference(in: .music), .library)
        XCTAssertTrue(settings.prefersOnlineArtwork(in: .music))
        settings.preference = .online
        XCTAssertFalse(settings.prefersOnlineArtwork(in: .browse))
        settings.setOverride(.automatic, for: .browse)
        XCTAssertTrue(settings.prefersOnlineArtwork(in: .browse))
    }

    func testMigrationPreservesLibraryPreferenceWithoutChangingProviderSettings() throws {
        let name = "ArtworkSettingsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let legacy = MetadataProviderSettings(orderMode: .custom, preferOnlineArtwork: false, disabledOrder: ["tmdb"])
        let data = try JSONEncoder().encode(legacy)
        defaults.set(data, forKey: "com.plozz.metadataProviderSettings")
        let primary = ArtworkSettingsStore(defaults: defaults)
        let other = ArtworkSettingsStore(defaults: defaults, namespace: "other")
        XCTAssertEqual(primary.load().preference, .library)
        XCTAssertEqual(other.load().preference, .library)
        primary.save(.init(preference: .online))
        XCTAssertEqual(primary.load().preference, .online)
        XCTAssertEqual(other.load().preference, .library)
        XCTAssertEqual(defaults.data(forKey: "com.plozz.metadataProviderSettings"), data)
    }

    func testProfileTransferAndSyncedResetDoNotRepeatLegacyMigration() throws {
        let name = "ArtworkSettingsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let source = ArtworkSettingsStore(defaults: defaults, namespace: "source")
        let destination = ArtworkSettingsStore(defaults: defaults, namespace: "destination")
        source.save(.init(preference: .library, overrides: [.browse: .online]))
        ProfileSettingsTransfer.apply(
            ProfileSettingsTransfer.capture(namespace: "source", defaults: defaults),
            namespace: "destination", defaults: defaults
        )
        XCTAssertEqual(destination.load(), source.load())
        ProfileSettingsTransfer.removeOne(
            baseKey: ArtworkSettingsStore.storageKey, namespace: "destination", defaults: defaults
        )
        XCTAssertEqual(destination.load(), .default)
        XCTAssertEqual(source.load().preference, .library)
    }
}
