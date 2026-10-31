import XCTest
@testable import CoreModels

final class SkipMarkerSettingsTests: XCTestCase {
    func testDefaultsKeepManualSkippingForAllContentWithFiveSecondAutomaticDelay() {
        let settings = PlaybackSettings.default
        XCTAssertTrue(settings.skipMarkersEnabled)
        XCTAssertEqual(settings.skipAutomaticDelaySeconds, 5)
        XCTAssertEqual(settings.skipContentCategories, Set(ContentCategory.allCases))
        for category in ContentCategory.allCases {
            XCTAssertEqual(settings.skipMarkerModes(for: category).mode(for: .intro), .on)
        }
    }

    func testLegacyModesPreserveBehaviorAndTiming() throws {
        for mode in SkipIntrosMode.allCases {
            let settings = try JSONDecoder().decode(
                PlaybackSettings.self,
                from: JSONSerialization.data(withJSONObject: ["skipIntros": mode.rawValue])
            )
            XCTAssertEqual(settings.skipIntros, mode)
            XCTAssertEqual(settings.skipMarkersEnabled, mode != .off)
            XCTAssertEqual(settings.skipMarkerModes.mode(for: .intro), mode)
            XCTAssertEqual(settings.configuredSkipDelay(), mode == .autoInstant ? 0 : 5)
        }
    }

    func testLegacyMixedInstantAndDelayedOverridesKeepIndependentTiming() throws {
        let settings = try JSONDecoder().decode(PlaybackSettings.self, from: Data(
            #"{"skipIntros":"autoInstant","skipModeOverrides":{"intro":"autoDelay","credits":"on","recap":"off"}}"#.utf8
        ))
        XCTAssertEqual(settings.skipMarkerModes.mode(for: .intro), .autoDelay)
        XCTAssertEqual(settings.skipMarkerModes.delay(for: .intro), 5)
        XCTAssertEqual(settings.skipMarkerModes.mode(for: .preview), .autoInstant)
        XCTAssertEqual(settings.skipMarkerModes.mode(for: .credits), .on)
        XCTAssertEqual(settings.skipMarkerModes.mode(for: .recap), .off)
    }

    func testMasterSwitchRestoresConfigurationIncludingAnOffBaseWithActiveOverrides() throws {
        for base in [SkipIntrosMode.autoDelay, .off] {
            var settings = PlaybackSettings(
                skipIntros: base, skipModeOverrides: [.intro: .autoInstant, .credits: .autoDelay],
                skipContentCategories: [.tvShow, .anime], skipAutomaticDelaySeconds: 12,
                skipAutomaticDelayOverrides: [.intro: 0, .credits: 23], useCommunityMarkers: false
            )
            let original = settings
            settings.setSkipMarkersEnabled(false)
            XCTAssertEqual(settings.skipMarkerModes, .allOff)
            settings = try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(settings))
            settings.setSkipMarkersEnabled(true)
            XCTAssertEqual(settings, original)
        }
    }

    func testEnablingALegacyOffProfileStartsWithTheManualButton() throws {
        var settings = try JSONDecoder().decode(PlaybackSettings.self, from: Data(#"{"skipIntros":false}"#.utf8))
        settings.setSkipMarkersEnabled(true)
        XCTAssertEqual(settings.skipMarkerModes.mode(for: .intro), .on)
        XCTAssertEqual(settings.skipAutomaticDelaySeconds, 5)
    }

    func testContentSwitchesAreIndependentAndDoNotChangeStoredModes() {
        var settings = PlaybackSettings(skipIntros: .autoDelay)
        for category in [ContentCategory.movie, .tvShow, .anime] {
            settings.skipContentCategories.remove(category)
            XCTAssertEqual(settings.skipMarkerModes(for: category), .allOff)
            for other in ContentCategory.allCases where other != category {
                XCTAssertEqual(settings.skipMarkerModes(for: other).mode(for: .intro), .autoDelay)
            }
            settings.skipContentCategories.insert(category)
        }
        XCTAssertEqual(settings.skipIntros, .autoDelay)
    }

    func testImmediateAndEverySecondThroughThirtyResolveToTheChosenTiming() {
        XCTAssertEqual(PlaybackSettings.skipAutomaticDelayOptions, Array(0...30))
        var settings = PlaybackSettings(skipIntros: .autoDelay)
        for seconds in 0...30 {
            settings.setSkipAutomaticDelay(seconds)
            XCTAssertEqual(settings.configuredSkipDelay(), seconds)
            XCTAssertEqual(settings.skipMarkerModes.mode(for: .intro), seconds == 0 ? .autoInstant : .autoDelay)
            XCTAssertEqual(settings.skipMarkerModes.delay(for: .intro), TimeInterval(seconds))
        }
    }

    func testSeparateMarkersInheritCurrentTimingThenRemainIndependent() {
        var settings = PlaybackSettings(skipIntros: .autoDelay, skipAutomaticDelaySeconds: 12)
        settings.setSkipMarkersSeparately(true)
        for kind in MediaSegment.Kind.skippable {
            XCTAssertEqual(settings.configuredSkipDelay(for: kind), 12)
        }
        settings.setSkipAutomaticDelay(0, for: .intro)
        settings.setSkipAutomaticDelay(30, for: .credits)
        settings.setConfiguredSkipMode(.off, for: .commercial)
        XCTAssertEqual(settings.skipMarkerModes.mode(for: .intro), .autoInstant)
        XCTAssertEqual(settings.skipMarkerModes.delay(for: .credits), 30)
        XCTAssertEqual(settings.skipMarkerModes.delay(for: .recap), 12)
        XCTAssertEqual(settings.skipMarkerModes.mode(for: .commercial), .off)
        settings.setSkipMarkersSeparately(false)
        XCTAssertEqual(settings.skipMarkerModes.delay(for: .intro), 12)
    }

    func testMarkerEditsDoNotRequireSeparateModeOrResetInheritedChoices() throws {
        var settings = PlaybackSettings(skipIntros: .autoDelay, skipAutomaticDelaySeconds: 12)
        settings.setSkipAutomaticDelay(0, for: .intro)
        settings.setConfiguredSkipMode(.off, for: .credits)
        settings.setSkipAutomaticDelay(30, for: .recap)
        XCTAssertEqual(settings.skipMarkerModes.mode(for: .intro), .autoInstant)
        XCTAssertEqual(settings.skipMarkerModes.mode(for: .credits), .off)
        XCTAssertEqual(settings.skipMarkerModes.delay(for: .recap), 30)
        for kind in [MediaSegment.Kind.preview, .commercial] {
            XCTAssertEqual(settings.configuredSkipMode(for: kind), .autoDelay)
            XCTAssertEqual(settings.configuredSkipDelay(for: kind), 12)
        }
        let configured = settings
        settings.setSkipMarkersEnabled(false)
        settings = try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(settings))
        settings.setSkipMarkersEnabled(true)
        XCTAssertEqual(settings, configured)
    }

    func testEveryMarkerCanHaveIndependentContentModesAndTiming() throws {
        var settings = PlaybackSettings(skipIntros: .autoDelay, skipAutomaticDelaySeconds: 12)
        for kind in MediaSegment.Kind.skippable {
            settings.setConfiguredSkipMode(.autoDelay, for: kind, category: .movie)
            settings.setSkipAutomaticDelay(3, for: kind, category: .movie)
            settings.setConfiguredSkipMode(.on, for: kind, category: .tvShow)
            settings.setConfiguredSkipMode(.off, for: kind, category: .anime)
        }
        settings = try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(settings))
        for kind in MediaSegment.Kind.skippable {
            XCTAssertEqual(settings.skipMarkerModes(for: .movie).mode(for: kind), .autoDelay)
            XCTAssertEqual(settings.skipMarkerModes(for: .movie).delay(for: kind), 3)
            XCTAssertEqual(settings.skipMarkerModes(for: .tvShow).mode(for: kind), .on)
            XCTAssertEqual(settings.skipMarkerModes(for: .anime).mode(for: kind), .off)
            XCTAssertEqual(settings.skipMarkerModes(for: .other).mode(for: kind), .autoDelay)
            XCTAssertEqual(settings.skipMarkerModes(for: .other).delay(for: kind), 12)
        }
        for seconds in 0...30 {
            settings.setSkipAutomaticDelay(seconds, for: .intro, category: .movie)
            XCTAssertEqual(settings.configuredSkipDelay(for: .intro, category: .movie), seconds)
            XCTAssertEqual(settings.skipMarkerModes(for: .movie).delay(for: .intro), TimeInterval(seconds))
            XCTAssertEqual(settings.skipMarkerModes(for: .movie).mode(for: .intro), seconds == 0 ? .autoInstant : .autoDelay)
            XCTAssertEqual(settings.skipMarkerModes(for: .movie).delay(for: .credits), 3)
            XCTAssertEqual(settings.configuredSkipDelay(for: .intro, category: .tvShow), 12)
            XCTAssertEqual(settings.configuredSkipMode(for: .intro, category: .anime), .off)
        }
    }

    func testContentRulesInheritLegacyPerMarkerChoicesUntilEdited() throws {
        var settings = try JSONDecoder().decode(PlaybackSettings.self, from: Data(
            #"{"skipIntros":"autoInstant","skipModeOverrides":{"intro":"autoDelay","credits":"off"},"skipAutomaticDelayOverrides":{"intro":21}}"#.utf8
        ))
        for category in [ContentCategory.movie, .tvShow, .anime] {
            XCTAssertEqual(settings.configuredSkipMode(for: .intro, category: category), .autoDelay)
            XCTAssertEqual(settings.configuredSkipDelay(for: .intro, category: category), 21)
            XCTAssertEqual(settings.configuredSkipMode(for: .credits, category: category), .off)
            XCTAssertEqual(settings.configuredSkipDelay(for: .recap, category: category), 0)
        }
        settings.setConfiguredSkipMode(.on, for: .intro, category: .anime)
        settings.setSkipAutomaticDelay(9, for: .intro, category: .anime)
        settings.setConfiguredSkipMode(.autoDelay, for: .intro, category: .anime)
        XCTAssertEqual(settings.skipMarkerModes(for: .anime).delay(for: .intro), 9)
        XCTAssertEqual(settings.skipMarkerModes(for: .movie).delay(for: .intro), 21)
        XCTAssertEqual(settings.skipMarkerModes(for: .tvShow).delay(for: .intro), 21)
        XCTAssertEqual(settings.skipMarkerRules.count, 1)
        XCTAssertEqual(settings.skipMarkerRules[.anime]?.count, 1)
    }

    func testContentRulesRespectMasterAndCategoryGatesWithoutLosingChoices() throws {
        var settings = PlaybackSettings(
            skipIntros: .off, skipMarkerRules: [.movie: [.intro: .init(mode: .autoDelay, automaticDelaySeconds: 7)]]
        )
        XCTAssertTrue(settings.skipMarkersEnabled)
        let original = settings
        settings.setSkipMarkersEnabled(false)
        XCTAssertEqual(settings.skipMarkerModes(for: .movie), .allOff)
        settings = try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(settings))
        settings.setSkipMarkersEnabled(true)
        XCTAssertEqual(settings, original)
        settings.skipContentCategories.remove(.movie)
        XCTAssertEqual(settings.skipMarkerModes(for: .movie), .allOff)
        XCTAssertEqual(settings.configuredSkipDelay(for: .intro, category: .movie), 7)
        settings.skipContentCategories.insert(.movie)
        XCTAssertEqual(settings, original)
    }

    func testSharedDefaultReachesEveryMarkerExceptExplicitContentChoices() throws {
        var settings = PlaybackSettings()
        settings.setConfiguredSkipMode(.autoInstant)
        settings.setConfiguredSkipMode(.on, for: .intro, category: .anime)
        for category in ContentCategory.allCases {
            for kind in MediaSegment.Kind.skippable {
                let exception = category == .anime && kind == .intro
                XCTAssertEqual(settings.usesDefaultSkipRule(for: kind, category: category), !exception)
                XCTAssertEqual(settings.skipMarkerModes(for: category).mode(for: kind), exception ? .on : .autoInstant)
                XCTAssertEqual(settings.skipMarkerModes(for: category).delay(for: kind), 0)
            }
        }
        settings.setSkipAutomaticDelay(13)
        settings = try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(settings))
        for category in ContentCategory.allCases {
            for kind in MediaSegment.Kind.skippable {
                let exception = category == .anime && kind == .intro
                XCTAssertEqual(settings.skipMarkerModes(for: category).mode(for: kind), exception ? .on : .autoDelay)
                XCTAssertEqual(settings.skipMarkerModes(for: category).delay(for: kind), exception ? 0 : 13)
            }
        }
        settings.useDefaultSkipRule(for: .intro, category: .anime)
        XCTAssertTrue(settings.skipMarkerRules.isEmpty)
        XCTAssertTrue(settings.usesDefaultSkipRule(for: .intro, category: .anime))
        XCTAssertEqual(settings.skipMarkerModes(for: .anime).delay(for: .intro), 13)
        settings.setConfiguredSkipMode(.autoInstant)
        XCTAssertEqual(settings.skipMarkerModes(for: .anime).mode(for: .intro), .autoInstant)
    }

    func testChoosingTheSameValueStillPinsAnExceptionUntilUseDefault() throws {
        var settings = PlaybackSettings()
        settings.setConfiguredSkipMode(.on, for: .intro, category: .anime)
        settings.setConfiguredSkipMode(.autoInstant)
        XCTAssertEqual(settings.skipMarkerModes(for: .anime).mode(for: .intro), .on)
        XCTAssertFalse(settings.usesDefaultSkipRule(for: .intro, category: .anime))
        settings.useDefaultSkipRule(for: .intro, category: .anime)
        settings = try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(settings.usesDefaultSkipRule(for: .intro, category: .anime))
        XCTAssertEqual(settings.skipMarkerModes(for: .anime).mode(for: .intro), .autoInstant)
    }

    func testUseDefaultRemovesOnlyTheSelectedLegacyExceptionAndPreservesAllSiblings() throws {
        for mode in SkipIntrosMode.allCases {
            for category in ContentCategory.allCases {
                var settings = PlaybackSettings(
                    skipIntros: .autoDelay, skipModeOverrides: [.intro: mode, .credits: .off],
                    skipContentCategories: [.movie], skipAutomaticDelaySeconds: 12,
                    skipAutomaticDelayOverrides: [.intro: 21],
                    skipMarkerRules: [.tvShow: [.intro: .init(mode: .autoDelay, automaticDelaySeconds: 9)]],
                    useCommunityMarkers: false
                )
                let original = settings
                settings.useDefaultSkipRule(for: .intro, category: category)
                settings = try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(settings))
                XCTAssertTrue(settings.usesDefaultSkipRule(for: .intro, category: category))
                XCTAssertEqual(settings.configuredSkipMode(for: .intro, category: category), .autoDelay)
                XCTAssertEqual(settings.configuredSkipDelay(for: .intro, category: category), 12)
                XCTAssertEqual(settings.skipContentCategories, original.skipContentCategories)
                XCTAssertFalse(settings.useCommunityMarkers)
                for other in ContentCategory.allCases where other != category {
                    XCTAssertEqual(
                        settings.skipMarkerModes(for: other).mode(for: .intro),
                        original.skipMarkerModes(for: other).mode(for: .intro)
                    )
                    XCTAssertEqual(
                        settings.configuredSkipMode(for: .intro, category: other),
                        original.configuredSkipMode(for: .intro, category: other)
                    )
                    XCTAssertEqual(
                        settings.configuredSkipDelay(for: .intro, category: other),
                        original.configuredSkipDelay(for: .intro, category: other)
                    )
                }
                for other in ContentCategory.allCases {
                    XCTAssertEqual(settings.configuredSkipMode(for: .credits, category: other), .off)
                }
                let restored = settings
                settings.useDefaultSkipRule(for: .intro, category: category)
                XCTAssertEqual(settings, restored, "Use default is idempotent")
            }
        }
    }

    func testUseDefaultClearsLegacyTimingOnlyExceptionsWithoutChangingDisabledMaster() throws {
        var settings = PlaybackSettings(
            skipIntros: .autoDelay, skipMarkersEnabled: false, skipAutomaticDelaySeconds: 7,
            skipAutomaticDelayOverrides: [.intro: 23]
        )
        XCTAssertFalse(settings.usesDefaultSkipRule(for: .intro, category: .movie))
        settings.useDefaultSkipRule(for: .intro, category: .movie)
        settings = try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(settings.skipMarkersEnabled)
        settings.setSkipMarkersEnabled(true)
        XCTAssertTrue(settings.usesDefaultSkipRule(for: .intro, category: .movie))
        XCTAssertEqual(settings.skipMarkerModes(for: .movie).delay(for: .intro), 7)
        for category in [ContentCategory.tvShow, .anime, .other] {
            XCTAssertEqual(settings.skipMarkerModes(for: category).delay(for: .intro), 23)
        }
    }

    func testContentRuleDecodingBoundsTimingAndIgnoresUnknownCategoriesAndMarkers() throws {
        let settings = try JSONDecoder().decode(PlaybackSettings.self, from: Data(
            #"{"skipMarkerRules":{"movie":{"intro":{"mode":"autoDelay","automaticDelaySeconds":99},"credits":{"mode":"autoDelay","automaticDelaySeconds":-1},"unknown":{"mode":"off","automaticDelaySeconds":5}},"future":{"intro":{"mode":"off","automaticDelaySeconds":5}}}}"#.utf8
        ))
        XCTAssertEqual(settings.skipMarkerRules.count, 1)
        XCTAssertEqual(settings.skipMarkerRules[.movie]?.count, 2)
        XCTAssertEqual(settings.skipMarkerModes(for: .movie).delay(for: .intro), 30)
        XCTAssertEqual(settings.skipMarkerModes(for: .movie).mode(for: .credits), .autoInstant)
    }

    func testDelayBoundsAndZeroAreConsistentForImportedPreferences() throws {
        var settings = try JSONDecoder().decode(PlaybackSettings.self, from: Data(
            #"{"skipIntros":"autoDelay","skipAutomaticDelaySeconds":-10,"skipModeOverrides":{"credits":"autoDelay"},"skipAutomaticDelayOverrides":{"credits":99}}"#.utf8
        ))
        XCTAssertEqual(settings.skipAutomaticDelaySeconds, 0)
        XCTAssertEqual(settings.skipMarkerModes.mode(for: .intro), .autoInstant)
        XCTAssertEqual(settings.skipMarkerModes.delay(for: .credits), 30)
        settings.skipAutomaticDelaySeconds = 500
        settings.skipAutomaticDelayOverrides = [.credits: -20]
        XCTAssertEqual(settings.skipAutomaticDelaySeconds, 30)
        XCTAssertEqual(settings.skipMarkerModes.mode(for: .credits), .autoInstant)
    }

    func testProfileStoresRetainAllPreferencesWithoutLeakingToAnotherProfile() throws {
        let suite = "SkipMarkerSettingsTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = PlaybackSettingsStore(defaults: defaults, namespace: "first")
        let second = PlaybackSettingsStore(defaults: defaults, namespace: "second")
        var settings = PlaybackSettings(
            skipIntros: .autoDelay, skipModeOverrides: [.credits: .autoDelay],
            skipMarkersEnabled: false, skipContentCategories: [.anime],
            skipAutomaticDelaySeconds: 8, skipAutomaticDelayOverrides: [.credits: 21],
            skipMarkerRules: [.anime: [.intro: .init(mode: .on, automaticDelaySeconds: 13)]]
        )
        first.save(settings)
        XCTAssertEqual(first.load(), settings)
        XCTAssertEqual(second.load(), .default)
        let snapshot = ProfileSettingsTransfer.capture(namespace: "first", defaults: defaults)
        ProfileSettingsTransfer.apply(snapshot, namespace: "second", defaults: defaults)
        XCTAssertEqual(second.load(), settings)
        XCTAssertEqual(PlaybackSettingsStore(defaults: defaults).load(), .default)
        settings.useDefaultSkipRule(for: .intro, category: .anime)
        settings.setConfiguredSkipMode(.autoInstant)
        first.save(settings)
        XCTAssertEqual(first.load(), settings)
        XCTAssertTrue(first.load().usesDefaultSkipRule(for: .intro, category: .anime))
        let inherited = ProfileSettingsTransfer.capture(namespace: "first", defaults: defaults)
        ProfileSettingsTransfer.apply(inherited, namespace: "second", defaults: defaults)
        XCTAssertEqual(second.load(), settings)
        XCTAssertTrue(second.load().usesDefaultSkipRule(for: .intro, category: .anime))
        XCTAssertEqual(PlaybackSettingsStore(defaults: defaults).load(), .default)
    }
}
