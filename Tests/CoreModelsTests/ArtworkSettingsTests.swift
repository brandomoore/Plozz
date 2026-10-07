import XCTest
@testable import CoreModels

final class ArtworkSettingsTests: XCTestCase {
    func testRecommendedAndLibraryFirstKeepSourceSeparateFromPresentation() {
        let recommended = ArtworkSettings.default
        XCTAssertTrue(recommended.prefersTextlessArtwork(in: .continueWatching))
        for area in ArtworkArea.allCases {
            XCTAssertEqual(recommended.prefersOnlineArtwork(in: area), area == .continueWatching)
            XCTAssertEqual(recommended.inheritedPreference(in: area), area == .continueWatching ? .online : .library)
        }
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
        XCTAssertFalse(settings.prefersOnlineArtwork(in: .home))
        settings.preference = .online
        settings.preference = .recommended
        XCTAssertEqual(settings.overrides, [.browse: .library])
        XCTAssertFalse(settings.prefersOnlineArtwork(in: .music))
        settings.resetOverrides()
        XCTAssertEqual(settings.preference, .recommended)
        XCTAssertFalse(settings.prefersOnlineArtwork(in: .browse))
        XCTAssertFalse(settings.prefersOnlineArtwork(in: .music))
    }

    func testDisplayedInheritedSourceIgnoresOverridesAndTracksThePreset() {
        var settings = ArtworkSettings()
        settings.setOverride(.library, for: .browse)
        settings.setOverride(.online, for: .music)
        XCTAssertEqual(settings.inheritedPreference(in: .browse), .library)
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

    func testRecommendedVariesAvailableDetailsButLibraryKeepsTheSelectedBackdrop() throws {
        let selected = try XCTUnwrap(URL(string: "https://library.example.test/selected.jpg"))
        let alternate = try XCTUnwrap(URL(string: "https://metadata.example.test/alternate.jpg"))
        let item = MediaItem(
            id: "movie", title: "Movie", kind: .movie, heroBackdropURL: selected,
            artworkSelections: [
                .init(placement: .homeHero, references: [.remote(alternate), .remote(selected)]),
                .init(placement: .detailBackdrop, references: [.remote(selected), .remote(alternate)])
            ]
        )
        let recommended = ArtworkSettings.default
        XCTAssertEqual(recommended.artworkReferences(for: item, placement: .homeHero, in: .home),
                       [.remote(selected), .remote(alternate)])
        XCTAssertEqual(recommended.artworkReferences(for: item, placement: .detailBackdrop, in: .details),
                       [.remote(alternate), .remote(selected)])
        var library = ArtworkSettings(preference: .library)
        for area in [ArtworkArea.home, .details, .playback] {
            XCTAssertEqual(library.artworkReferences(for: item, placement: .detailBackdrop, in: area).first,
                           .remote(selected))
        }
        library.setOverride(.online, for: .details)
        XCTAssertTrue(library.prefersOnlineArtwork(in: .details))
        XCTAssertFalse(library.prefersOnlineArtwork(in: .browse))
        let single = MediaItem(id: "single", title: "Single", kind: .movie, heroBackdropURL: selected)
        XCTAssertEqual(recommended.artworkReferences(for: single, placement: .detailBackdrop, in: .details),
                       [.remote(selected)], "A single available image stays usable on both screens.")
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
