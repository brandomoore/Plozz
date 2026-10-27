import XCTest
@testable import CoreModels

final class HeroBackgroundSettingsTests: XCTestCase {
    func testDefaultsAreMutedTrailerOnBothSurfaces() {
        let d = HeroBackgroundSettings.default
        XCTAssertTrue(d.homeTrailerEnabled)
        XCTAssertTrue(d.homeTrailerMuted)
        XCTAssertEqual(d.detailMode, .trailer)
        XCTAssertTrue(d.detailTrailerMuted)
        XCTAssertTrue(d.detailTrailerEnabled)
        XCTAssertFalse(d.themeMusicEnabled)
    }

    func testDetailModesAreMutuallyExclusive() {
        for mode in HeroBackgroundMode.allCases {
            let s = HeroBackgroundSettings(detailMode: mode)
            XCTAssertFalse(
                s.detailTrailerEnabled && s.themeMusicEnabled,
                "Trailer and theme music may never be enabled together on the detail page"
            )
        }
    }

    func testNewFormatRoundTrips() throws {
        let s = HeroBackgroundSettings(
            homeTrailerEnabled: false, homeTrailerMuted: false,
            detailMode: .themeMusic, detailTrailerMuted: false
        )
        let back = try JSONDecoder().decode(
            HeroBackgroundSettings.self, from: JSONEncoder().encode(s)
        )
        XCTAssertEqual(back, s)
    }

    // MARK: Migration from the legacy single-mode shape

    func testLegacyThemeMusicMigratesToDetailOnlyHomeTrailerOff() throws {
        // Old blob: theme music was always a detail-page thing, and the single mode
        // wasn't `.trailer`, so the home trailer should end up OFF.
        let data = Data(#"{"mode":"themeMusic","trailerMuted":false}"#.utf8)
        let s = try JSONDecoder().decode(HeroBackgroundSettings.self, from: data)
        XCTAssertEqual(s.detailMode, .themeMusic)
        XCTAssertFalse(s.homeTrailerEnabled)
        XCTAssertFalse(s.homeTrailerMuted)
        XCTAssertFalse(s.detailTrailerMuted)
    }

    func testLegacyTrailerMigratesToBothSurfaces() throws {
        let data = Data(#"{"mode":"trailer","trailerMuted":true}"#.utf8)
        let s = try JSONDecoder().decode(HeroBackgroundSettings.self, from: data)
        XCTAssertEqual(s.detailMode, .trailer)
        XCTAssertTrue(s.homeTrailerEnabled)     // old mode was .trailer
        XCTAssertTrue(s.homeTrailerMuted)
        XCTAssertTrue(s.detailTrailerMuted)
    }

    func testLenientDecodeFallsBackForUnknownMode() throws {
        let data = Data(#"{"mode":"future-mode"}"#.utf8)
        let s = try JSONDecoder().decode(HeroBackgroundSettings.self, from: data)
        XCTAssertEqual(s, .default)
    }

    func testStoreMigratesExistingThemeMusicOptIn() {
        let suite = "HeroBackgroundSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = ThemeMusicSettings(isEnabled: true, volume: .low)
        defaults.set(
            try! JSONEncoder().encode(legacy),
            forKey: "com.plozz.themeMusicSettings"
        )
        XCTAssertEqual(
            HeroBackgroundSettingsStore(defaults: defaults).load().detailMode,
            .themeMusic
        )
    }

    func testSilentThemeMusicMigrationPreservesModesInEitherLoadOrder() throws {
        for mode in HeroBackgroundMode.allCases {
            for themeLoadsFirst in [false, true] {
                let suite = "HeroBackgroundSettingsTests.\(UUID().uuidString)"
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let backgroundStore = HeroBackgroundSettingsStore(defaults: defaults)
                let musicStore = ThemeMusicSettingsStore(defaults: defaults)
                var expected = HeroBackgroundSettings(
                    homeTrailerEnabled: false, homeTrailerMuted: false,
                    detailMode: mode, detailTrailerMuted: false
                )
                backgroundStore.save(expected)
                defaults.set(Data(#"{"isEnabled":true,"volume":"off"}"#.utf8), forKey: "com.plozz.themeMusicSettings")

                if themeLoadsFirst {
                    XCTAssertEqual(musicStore.load(), .default)
                } else {
                    _ = backgroundStore.load()
                }
                if mode == .themeMusic { expected.detailMode = .off }
                XCTAssertEqual(backgroundStore.load(), expected)
                XCTAssertEqual(musicStore.load(), .default)
                XCTAssertEqual(
                    try JSONDecoder().decode(
                        HeroBackgroundSettings.self,
                        from: XCTUnwrap(defaults.data(forKey: "com.plozz.heroBackgroundSettings"))
                    ),
                    expected
                )

                expected.detailMode = .themeMusic
                backgroundStore.save(expected)
                XCTAssertEqual(backgroundStore.load(), expected, "A later explicit opt-in must persist.")
                XCTAssertEqual(musicStore.load().volume, .default)
            }
        }
    }

    func testLegacySilentOptInMigratesOnlyItsOwnProfile() throws {
        let suite = "HeroBackgroundSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let music = ThemeMusicSettingsStore(defaults: defaults)
        let otherMusic = ThemeMusicSettingsStore(defaults: defaults, namespace: "other")
        let background = HeroBackgroundSettingsStore(defaults: defaults)
        let otherBackground = HeroBackgroundSettingsStore(defaults: defaults, namespace: "other")
        defaults.set(Data(#"{"isEnabled":true,"volume":"off"}"#.utf8), forKey: "com.plozz.themeMusicSettings")
        otherMusic.save(ThemeMusicSettings(isEnabled: true, volume: .high))

        XCTAssertEqual(music.load(), .default)
        XCTAssertEqual(background.load().detailMode, .off)
        XCTAssertEqual(otherMusic.load(), ThemeMusicSettings(isEnabled: true, volume: .high))
        XCTAssertEqual(otherBackground.load().detailMode, .themeMusic)

        defaults.set(Data(#"{"isEnabled":true,"volume":"off"}"#.utf8), forKey: "com.plozz.themeMusicSettings.other")
        XCTAssertEqual(otherBackground.load().detailMode, .off)
        XCTAssertEqual(otherMusic.load(), .default)
        XCTAssertEqual(background.load().detailMode, .off)
        XCTAssertEqual(music.load(), .default)
    }

    func testSliderSilenceDoesNotMigrateOrResetBackgroundMode() throws {
        let suite = "ThemeMusicSliderSilence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let music = ThemeMusicSettingsStore(defaults: defaults)
        let background = HeroBackgroundSettingsStore(defaults: defaults)
        background.save(HeroBackgroundSettings(detailMode: .themeMusic))
        music.save(ThemeMusicSettings(isEnabled: true, volume: ThemeMusicVolume(0)))
        XCTAssertEqual(background.load().detailMode, .themeMusic)
        XCTAssertEqual(music.load().volume.level, 0)
        XCTAssertTrue(music.load().isEnabled)
    }
}
