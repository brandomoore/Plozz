import XCTest
@testable import CoreModels

@MainActor
final class SubtitleStylePreferencesTests: XCTestCase {
    func testFileEmphasisSettingPreservesOtherCapturedSourcePolicies() {
        var style = SubtitleStyle.default
        style.usesSourceColors = false
        XCTAssertTrue(style.usesSourceEmphasis)
        style.usesSourceEmphasis = false
        XCTAssertFalse(style.usesSourceEmphasis)
        XCTAssertEqual(style.captionSourceOverrides?.foregroundColor, false)
        XCTAssertEqual(style.captionSourceOverrides?.foregroundOpacity, false)
        style.captionSourceOverrides?.windowCornerRadius = false
        let previous = style.captionSourceOverrides
        style.usesSourceEmphasis = true
        XCTAssertEqual(style.captionSourceOverrides?.foregroundColor, previous?.foregroundColor)
        XCTAssertEqual(style.captionSourceOverrides?.foregroundOpacity, previous?.foregroundOpacity)
        XCTAssertEqual(style.captionSourceOverrides?.windowCornerRadius, false)
    }

    func testNewProfilesDefaultToMatchingButOldMissingFieldsRemainCustom() throws {
        let name = "SubtitleStyleDefaultsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for namespace: String? in [nil, "new-viewer"] {
            let store = SubtitleStyleStore(defaults: defaults, namespace: namespace)
            XCTAssertTrue(store.load().base.followsSystemStyle)
            XCTAssertTrue(store.load().resolvedLiveTV.followsSystemStyle)
            XCTAssertNil(store.load().liveTV)
        }
        for json in ["{}", #"{"base":{}}"#, #"{"base":{"fontScale":0.37},"liveTV":{"fontScale":1.17}}"#] {
            let saved = try JSONDecoder().decode(SubtitleStylePreferences.self, from: Data(json.utf8))
            XCTAssertFalse(saved.base.followsSystemStyle)
            XCTAssertFalse(saved.resolvedLiveTV.followsSystemStyle)
        }
        XCTAssertFalse(try JSONDecoder().decode(SubtitleStyle.self, from: Data("{}".utf8)).followsSystemStyle)
        XCTAssertFalse(SubtitleStyle.default.followsSystemStyle, "The old custom baseline is not a new-profile default.")
        XCTAssertTrue(SubtitleStyle.profileDefault.followsSystemStyle, "Explicit Reset and a new profile share this default.")
    }

    func testEverySavedChoiceAndIndependentLiveChoiceSurvivesUpgradeAndReset() throws {
        let name = "SubtitleStyleSavedChoiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for namespace: String? in [nil, "viewer"] {
            let store = SubtitleStyleStore(defaults: defaults, namespace: namespace)
            for baseFollows in [false, true] {
                for liveFollows in [false, true] {
                    var base = SubtitleStyle.default
                    base.followsSystemStyle = baseFollows
                    base.fontScale = 0.37
                    var live = SubtitleStyle.default
                    live.followsSystemStyle = liveFollows
                    live.fontScale = 1.17
                    let expected = SubtitleStylePreferences(base: base, overrides: [.anime: base], liveTV: live)
                    store.save(expected)
                    let model = SubtitleStyleModel(store: SubtitleStyleStore(defaults: defaults, namespace: namespace))
                    XCTAssertEqual(store.load(), expected)
                    XCTAssertEqual(model.style.followsSystemStyle, baseFollows)
                    XCTAssertEqual(model.resolvedLiveTVStyle.followsSystemStyle, liveFollows)
                    model.style = .profileDefault
                    XCTAssertTrue(store.load().base.followsSystemStyle)
                    XCTAssertEqual(store.load().liveTV, live, "Library reset cannot replace the independent Live TV look.")
                    XCTAssertEqual(store.load().overrides[.anime], base)
                    model.resolvedLiveTVStyle = .profileDefault
                    XCTAssertTrue(store.load().liveTV?.followsSystemStyle == true)
                }
            }
        }
    }

    func testDefaultAndNamedLegacyNamespacesStillMigrateTheCustomLook() throws {
        let name = "SubtitleStyleLegacyDefaultTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for namespace: String? in [nil, "legacy-viewer"] {
            for oldFlag in [false, true] {
                let legacy = LegacyCaptionSettings(
                    fontScale: 0.61, textColor: .cyan, backgroundColor: .yellow,
                    edgeStyle: .uniform, followsSystemStyle: oldFlag
                )
                defaults.removeObject(forKey: SettingsKey.scoped(SubtitleStyleStore.storageKey, namespace: namespace))
                defaults.set(try JSONEncoder().encode(legacy),
                             forKey: SettingsKey.scoped(LegacyCaptionSettings.storageKey, namespace: namespace))
                let store = SubtitleStyleStore(defaults: defaults, namespace: namespace)
                XCTAssertEqual(store.load().base, SubtitleStyle(from: legacy))
                XCTAssertFalse(store.load().base.followsSystemStyle)
                XCTAssertNil(store.load().liveTV)
                store.save(.init(base: .profileDefault))
                XCTAssertTrue(SubtitleStyleStore(defaults: defaults, namespace: namespace).load().base.followsSystemStyle,
                              "Legacy data may seed once, never overwrite a modern saved choice.")
            }
        }
        XCTAssertTrue(SubtitleStyleStore(defaults: defaults, namespace: "untouched-new-profile").load().base.followsSystemStyle)
    }

    func testFrozenAppearanceRoundTripsAllPublicFieldsWithoutNormalizingUniformEdge() throws {
        var style = SubtitleStyle.default
        style.fontDescriptor = .init(
            archive: Data([1, 3, 5, 7]), postScriptName: "ExampleFace",
            displayName: "Example Face · Small Capitals", weight: 0.23
        )
        var policy = SubtitleCaptionSourceOverrides()
        policy.font = false
        policy.relativeSize = false
        policy.foregroundColor = false
        policy.foregroundOpacity = true
        policy.backgroundColor = true
        policy.backgroundOpacity = false
        policy.windowColor = false
        policy.windowOpacity = true
        policy.windowCornerRadius = false
        policy.edge = true
        style.captionSourceOverrides = policy
        style.captionEdgeStyleRawValue = 17
        style.fontScale = 1.137
        style.textColor = .init(red: 0.12, green: 0.34, blue: 0.56, alpha: 0.37)
        style.glyphBackground = .init(red: 0.4, green: 0.2, blue: 0.1, alpha: 0.21)
        style.background = .init(color: .init(red: 0.3, green: 0.5, blue: 0.7, alpha: 0.48), cornerRadius: 3.75)
        style.edge = .init(style: .uniform)
        style.border.isEnabled = false
        let data = try JSONEncoder().encode(SubtitleStylePreferences(base: style, liveTV: style))
        let restored = try JSONDecoder().decode(SubtitleStylePreferences.self, from: data)
        XCTAssertEqual(restored.base, style)
        XCTAssertEqual(restored.liveTV, style)
        XCTAssertEqual(restored.base.edge.style, .uniform)
        XCTAssertFalse(restored.base.border.isEnabled)
    }

    func testForegroundColorAndOpacitySourcePermissionsAreIndependent() throws {
        let source = SubtitleColor(red: 0.6, green: 0.4, blue: 0.2, alpha: 0.25)
        for allowColor in [false, true] {
            for allowOpacity in [false, true] {
                var style = SubtitleStyle.default
                style.textColor = .init(red: 0.1, green: 0.3, blue: 0.5, alpha: 0.75)
                style.captionSourceOverrides = .init()
                style.captionSourceOverrides?.foregroundColor = allowColor
                style.captionSourceOverrides?.foregroundOpacity = allowOpacity
                style.usesSourceColors = allowColor
                let result = style.sourceTextColor(source) ?? style.textColor
                XCTAssertEqual(result.red, allowColor ? source.red : style.textColor.red)
                XCTAssertEqual(result.green, allowColor ? source.green : style.textColor.green)
                XCTAssertEqual(result.blue, allowColor ? source.blue : style.textColor.blue)
                XCTAssertEqual(result.alpha, allowOpacity ? source.alpha : style.textColor.alpha)
            }
        }
        var historical = SubtitleStyle.default
        historical.usesSourceColors = false
        XCTAssertNil(historical.sourceTextColor(source), "Old custom styles still disable source alpha with source colors.")
    }

    func testFineSizeStepsAndBothRangeEndpointsPersistExactly() throws {
        for scale in [0.2, 1.01, 1.37, 4.0] {
            var style = SubtitleStyle.default
            style.fontScale = scale
            let saved = try JSONEncoder().encode(SubtitleStylePreferences(base: style, liveTV: style))
            let restored = try JSONDecoder().decode(SubtitleStylePreferences.self, from: saved)
            XCTAssertEqual(restored.base.fontScale, scale)
            XCTAssertEqual(restored.liveTV?.fontScale, scale)
        }
    }

    func testExistingPreferencesInheritTheBaseForLiveTV() throws {
        let data = Data(#"{"base":{"fontScale":0.4}}"#.utf8)
        let preferences = try JSONDecoder().decode(SubtitleStylePreferences.self, from: data)
        XCTAssertNil(preferences.liveTV)
        XCTAssertEqual(preferences.resolvedLiveTV.fontScale, 0.4)
    }

    func testLiveOverrideRoundTripsWithoutChangingLibraryStyles() throws {
        var library = SubtitleStyle.default
        library.textColor = .yellow
        var live = SubtitleStyle.default
        live.followsSystemStyle = true
        live.fontScale = 0.4
        live.systemFont = .caption(.smallCapitals)
        library.systemFont = .named("Courier")
        let preferences = SubtitleStylePreferences(base: library, overrides: [.anime: .default], liveTV: live)
        let decoded = try JSONDecoder().decode(
            SubtitleStylePreferences.self, from: JSONEncoder().encode(preferences)
        )
        XCTAssertEqual(decoded, preferences)
        XCTAssertEqual(decoded.resolved(for: .movie), library)
        XCTAssertEqual(decoded.resolved(for: .anime), .default)
        XCTAssertEqual(decoded.resolvedLiveTV, live)
    }

    func testSeparateStyleStartsFromCurrentLookAndEditsStayProfileScoped() throws {
        let name = "SubtitleStylePreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SubtitleStyleStore(defaults: defaults, namespace: "viewer")
        let model = SubtitleStyleModel(store: store)
        model.style.textColor = .yellow
        model.usesSeparateLiveTVStyle = true
        XCTAssertEqual(model.liveTVStyle, model.style)
        model.resolvedLiveTVStyle.followsSystemStyle = true
        model.resolvedLiveTVStyle.fontScale = 0.4
        model.style.textColor = .cyan

        let restored = SubtitleStyleModel(store: store)
        XCTAssertEqual(restored.style.textColor, .cyan)
        XCTAssertEqual(restored.liveTVStyle?.textColor, .yellow)
        XCTAssertEqual(restored.liveTVStyle?.fontScale, 0.4)
        XCTAssertEqual(restored.liveTVStyle?.followsSystemStyle, true)
        XCTAssertEqual(SubtitleStyleStore(defaults: defaults).load(), .default)
        XCTAssertEqual(SubtitleStyleStore(defaults: defaults, namespace: "other").load(), .default)

        restored.usesSeparateLiveTVStyle = false
        XCTAssertNil(store.load().liveTV)
        XCTAssertEqual(restored.resolvedLiveTVStyle, restored.style)
    }
}
