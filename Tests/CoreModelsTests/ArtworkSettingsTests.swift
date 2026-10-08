import XCTest
@testable import CoreModels

final class ArtworkSettingsTests: XCTestCase {
    func testExistingSharedOverridesMigrateOnceIntoIndependentScopes() throws {
        let legacy = Data(#"{"preference":"recommended","overrides":{"home":"online","browse":"library"}}"#.utf8)
        var settings = try JSONDecoder().decode(ArtworkSettings.self, from: legacy)
        for area in [ArtworkArea.home, .homeRows, .recommended, .recommendedHero] {
            XCTAssertEqual(settings.preference(in: area), .online)
        }
        for area in [ArtworkArea.browse, .collections, .playlists] {
            XCTAssertEqual(settings.preference(in: area), .library)
        }
        settings.setOverride(.library, for: .home)
        settings.setOverride(.online, for: .browse)
        XCTAssertEqual(settings.preference(in: .homeRows), .online)
        XCTAssertEqual(settings.preference(in: .recommendedHero), .online)
        XCTAssertEqual(settings.preference(in: .collections), .library)
        XCTAssertEqual(settings.preference(in: .playlists), .library)
        settings.setOverride(.automatic, for: .homeRows)
        let restored = try JSONDecoder().decode(ArtworkSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored, settings)
        XCTAssertEqual(restored.preference(in: .homeRows), .recommended,
                       "Decoding a new configuration must not repeat the shared-scope migration.")
    }

    func testScopeNamesDistinguishPagesRowsAndPlayerArtwork() {
        for (area, name) in [
            (ArtworkArea.home, "Showcase / hero"),
            (.homeRows, "Other Home rows"),
            (.recommendedHero, "Recommended hero"),
            (.recommended, "Recommended rows"),
            (.continueWatching, "Continue Watching rows"),
            (.watchlist, "Watchlist page"),
            (.details, "Title detail pages"),
            (.episodes, "Episode browser"),
            (.playback, "Video player artwork")
        ] {
            XCTAssertEqual(String(localized: area.displayName), name)
            XCTAssertNotNil(area.detail)
        }
    }

    func testCustomStateAndPresetReplacementSurviveProfileStorageAndTransfer() throws {
        let name = "ArtworkPresetTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let source = ArtworkSettingsStore(defaults: defaults)
        var settings = ArtworkSettings.default
        settings.toggleCustomization(in: .browse)
        settings.toggleCustomization(in: .browse)
        source.save(settings)
        XCTAssertNil(source.load().selectedPreset)
        let entries = ProfileSettingsTransfer.capture(namespace: nil, defaults: defaults)
        ProfileSettingsTransfer.apply(entries, namespace: "other", defaults: defaults)
        let other = ArtworkSettingsStore(defaults: defaults, namespace: "other")
        XCTAssertEqual(other.load(), settings)
        settings.applyPreset(.recommended)
        other.save(settings)
        XCTAssertEqual(other.load(), .default)
        XCTAssertEqual(other.load().selectedPreset, .recommended)
        XCTAssertNil(source.load().selectedPreset)
    }

    func testRecommendedAndLibraryFirstKeepSourceSeparateFromPresentation() {
        let recommended = ArtworkSettings.default
        XCTAssertTrue(recommended.prefersTextlessArtwork(in: .continueWatching))
        for area in ArtworkArea.allCases {
            let online = [.home, .recommendedHero, .continueWatching].contains(area)
            XCTAssertEqual(recommended.prefersOnlineArtwork(in: area), online)
            XCTAssertEqual(recommended.inheritedPreference(in: area), online ? .online : .library)
        }
        let library = ArtworkSettings(preference: .library)
        for area in ArtworkArea.allCases {
            XCTAssertFalse(library.prefersOnlineArtwork(in: area))
        }
        XCTAssertFalse(library.prefersTextlessArtwork(in: .continueWatching))
    }

    func testRecommendedDetailHeroesDoNotChangePostersOrEpisodeRows() {
        for placement in [ArtworkPlacement.homeHero, .detailBackdrop, .logo] {
            XCTAssertTrue(ArtworkSettings.default.prefersOnlineArtwork(in: .details, placement: placement))
        }
        for placement in [ArtworkPlacement.poster, .seriesPoster, .episodeThumbnail] {
            XCTAssertFalse(ArtworkSettings.default.prefersOnlineArtwork(in: .details, placement: placement))
            XCTAssertFalse(ArtworkSettings.default.prefersOnlineArtwork(in: .episodes, placement: placement))
        }
        for preference in [ArtworkPreference.library, .online] {
            let settings = ArtworkSettings(overrides: [.home: preference, .recommendedHero: preference, .details: preference])
            for area in [ArtworkArea.home, .recommendedHero, .details] {
                for placement in [ArtworkPlacement.detailBackdrop, .logo, .poster] {
                    XCTAssertEqual(settings.prefersOnlineArtwork(in: area, placement: placement), preference == .online)
                }
            }
        }
    }

    func testExplicitMixedDetailsPersistIndependentlyOfThePresetAndOtherScopes() throws {
        let name = "ArtworkMixedTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ArtworkSettingsStore(defaults: defaults)
        for preset in ArtworkPreference.allCases {
            var settings = ArtworkSettings(preference: preset)
            settings.setOverride(.mixed, for: .details)
            store.save(settings)
            let entries = ProfileSettingsTransfer.capture(namespace: nil, defaults: defaults)
            ProfileSettingsTransfer.apply(entries, namespace: "mixed", defaults: defaults)
            let restored = ArtworkSettingsStore(defaults: defaults, namespace: "mixed").load()
            XCTAssertEqual(restored, settings)
            XCTAssertEqual(restored.customization(in: .details), .mixed)
            XCTAssertEqual(restored.override(for: .details), .mixed)
            XCTAssertNil(restored.selectedPreset)
            for placement in [ArtworkPlacement.homeHero, .detailBackdrop, .logo] {
                XCTAssertTrue(restored.prefersOnlineArtwork(in: .details, placement: placement))
            }
            XCTAssertFalse(restored.prefersOnlineArtwork(in: .details, placement: .poster))
            for area in ArtworkArea.allCases where area != .details {
                XCTAssertEqual(restored.preference(in: area), preset)
                XCTAssertFalse(area.customizationChoices.contains(.mixed))
            }
            settings.applyPreset(preset)
            XCTAssertEqual(settings, ArtworkSettings(preference: preset))
        }
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

    func testSyncedResetBeforeFirstProfileLoadConsumesLegacyMigration() throws {
        let name = "ArtworkSettingsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let legacy = try JSONEncoder().encode(MetadataProviderSettings(preferOnlineArtwork: false))
        defaults.set(legacy, forKey: "com.plozz.metadataProviderSettings")
        let source = ArtworkSettingsStore(defaults: defaults, namespace: "source")
        source.save(.init(preference: .online, overrides: [.browse: .library]))
        ProfileSettingsTransfer.apply(
            ProfileSettingsTransfer.capture(namespace: "source", defaults: defaults),
            namespace: "inactive", defaults: defaults
        )
        for namespace in ["inactive", "never-received"] {
            ProfileSettingsTransfer.removeOne(
                baseKey: ArtworkSettingsStore.storageKey, namespace: namespace, defaults: defaults
            )
            let store = ArtworkSettingsStore(defaults: defaults, namespace: namespace)
            XCTAssertEqual(store.load(), .default)
            XCTAssertEqual(store.load(), .default)
            XCTAssertFalse(ProfileSettingsTransfer.capture(namespace: namespace, defaults: defaults).keys
                .contains { $0.hasSuffix(".migrated") })
        }
        XCTAssertEqual(ArtworkSettingsStore(defaults: defaults, namespace: "fresh").load().preference, .library)
        XCTAssertEqual(source.load().overrides, [.browse: .library])
        XCTAssertEqual(defaults.data(forKey: "com.plozz.metadataProviderSettings"), legacy)
    }
}
