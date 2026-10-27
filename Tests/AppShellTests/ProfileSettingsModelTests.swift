import Foundation
import XCTest
import CoreModels
@testable import AppShell

/// Unit tests for ``ProfileSettingsModel`` — the per-profile settings facet split
/// out of ``AppState``. Verifies the two behaviours that used to live in
/// `AppState.rebuildSettingsModels()`: namespace-scoped (re)builds swap the
/// sub-models on profile switch, and injected models (the test path) are treated
/// as immutable and never rebuilt.
@MainActor
final class ProfileSettingsModelTests: XCTestCase {
    func testNewProfileKeepsLibraryHeroDefaultsAfterLeavingCollectionsOnlyProfile() {
        let first = "HeroDefaults.first.\(UUID())"
        let second = "HeroDefaults.second.\(UUID())"
        defer {
            for namespace in [first, second] {
                UserDefaults.standard.removeObject(forKey: SettingsKey.scoped("com.plozz.heroSettings", namespace: namespace))
            }
        }
        let model = ProfileSettingsModel(namespace: first, isSeerrConfigured: { false })
        model.heroSettingsModel.settings.sources = [.collection]
        model.rebuild(namespace: second)
        XCTAssertEqual(model.heroSettingsModel.effectiveSettings.sources,
                       [.continueWatching, .recentlyAdded, .randomFromLibrary, .watchlist])
        model.heroSettingsModel.settings.style = .followsFocus
        model.rebuild(namespace: first)
        XCTAssertEqual(model.heroSettingsModel.effectiveSettings.sources, [.collection])
        model.rebuild(namespace: second)
        XCTAssertEqual(model.heroSettingsModel.effectiveSettings.sources,
                       [.continueWatching, .recentlyAdded, .randomFromLibrary, .watchlist])
    }

    func testContentRatingVisibilityChangesWithTheActiveProfile() {
        let first = "ContentRatings.first.\(UUID())"
        let second = "ContentRatings.second.\(UUID())"
        defer {
            for namespace in [first, second] {
                UserDefaults.standard.removeObject(forKey: SettingsKey.scoped(
                    ContentRatingSettingsStore.storageKey, namespace: namespace
                ))
            }
        }
        let model = ProfileSettingsModel(namespace: first)
        XCTAssertTrue(model.contentRatingModel.showsRatings)
        model.contentRatingModel.showsRatings = false
        model.rebuild(namespace: second)
        XCTAssertTrue(model.contentRatingModel.showsRatings)
        model.rebuild(namespace: first)
        XCTAssertFalse(model.contentRatingModel.showsRatings)
    }

    func testRebuildingKeepsAutomaticDiscoveryAndExplicitChoicesProfileScoped() {
        let first = "Discovery.first.\(UUID())"
        let second = "Discovery.second.\(UUID())"
        defer {
            for namespace in [first, second] {
                UserDefaults.standard.removeObject(forKey: SettingsKey.scoped("com.plozz.heroSettings", namespace: namespace))
            }
        }
        var configured = false
        let model = ProfileSettingsModel(namespace: first, isSeerrConfigured: { configured })
        XCTAssertFalse(model.heroSettingsModel.effectiveSettings.isEnabled(.featured))
        configured = true
        XCTAssertTrue(model.heroSettingsModel.effectiveSettings.isEnabled(.featured))
        model.heroSettingsModel.settings.setEnabled(.featured, enabled: false)
        model.rebuild(namespace: second)
        XCTAssertTrue(model.heroSettingsModel.effectiveSettings.isEnabled(.featured))
        configured = false
        XCTAssertFalse(model.heroSettingsModel.effectiveSettings.isEnabled(.featured))
        model.heroSettingsModel.settings.setEnabled(.featured, enabled: true)
        model.rebuild(namespace: first)
        configured = true
        XCTAssertFalse(model.heroSettingsModel.effectiveSettings.isEnabled(.featured))
        model.rebuild(namespace: second)
        configured = false
        XCTAssertTrue(model.heroSettingsModel.effectiveSettings.isEnabled(.featured))
    }

    func testRebuildingKeepsTheLiveDiscoveryPolicyIncludingPreviouslyRetainedModels() {
        var isKids = false
        let model = ProfileSettingsModel(namespace: "policy-a", allowsDiscovery: { !isKids })
        let oldHero = model.heroSettingsModel
        XCTAssertTrue(oldHero.effectiveSettings.allowsDiscovery)
        isKids = true
        XCTAssertFalse(oldHero.effectiveSettings.allowsDiscovery)
        model.rebuild(namespace: "policy-b")
        XCTAssertFalse(model.heroSettingsModel.effectiveSettings.allowsDiscovery)
        XCTAssertFalse(oldHero.effectiveSettings.allowsDiscovery)
        isKids = false
        XCTAssertTrue(model.heroSettingsModel.effectiveSettings.allowsDiscovery)
    }

    func testDefaultBuildIsNotTreatedAsInjected() {
        let model = ProfileSettingsModel(namespace: "ns-a")
        XCTAssertFalse(model.usesInjectedModels)
    }

    func testRebuildSwapsSubModelInstances() {
        let model = ProfileSettingsModel(namespace: "ns-a")
        let themeBefore = ObjectIdentifier(model.themeModel)
        let subtitleBefore = ObjectIdentifier(model.subtitleBehaviorModel)
        // A non-injectable model (always built) must also swap.
        let heroBefore = ObjectIdentifier(model.heroSettingsModel)
        let detailBefore = ObjectIdentifier(model.detailPageModel)

        model.rebuild(namespace: "ns-b")

        XCTAssertNotEqual(themeBefore, ObjectIdentifier(model.themeModel))
        XCTAssertNotEqual(subtitleBefore, ObjectIdentifier(model.subtitleBehaviorModel))
        XCTAssertNotEqual(heroBefore, ObjectIdentifier(model.heroSettingsModel))
        XCTAssertNotEqual(detailBefore, ObjectIdentifier(model.detailPageModel))
    }

    /// `rebuild(namespace:)` must swap *every* sub-model, not just a
    /// representative few — a missed model would silently freeze to the old profile.
    /// The language model is here because it WAS missed: it existed and supported
    /// namespacing, but nothing rebuilt it, so "per-profile language" was in truth
    /// device-wide.
    func testRebuildSwapsAllSubModelInstances() {
        let model = ProfileSettingsModel(namespace: "ns-a")

        let before: [ObjectIdentifier] = [
            ObjectIdentifier(model.contentRatingModel),
            ObjectIdentifier(model.appLanguageModel),
            ObjectIdentifier(model.subtitleBehaviorModel),
            ObjectIdentifier(model.subtitleStyleModel),
            ObjectIdentifier(model.spoilerModel),
            ObjectIdentifier(model.playbackModel),
            ObjectIdentifier(model.subtitlePolicyModel),
            ObjectIdentifier(model.audioPolicyModel),
            ObjectIdentifier(model.themeModel),
            ObjectIdentifier(model.themeMusicModel),
            ObjectIdentifier(model.diagnosticsModel),
            ObjectIdentifier(model.musicPlayerModel),
            ObjectIdentifier(model.homeLibraryVisibilityModel),
            ObjectIdentifier(model.uiDensityModel),
            ObjectIdentifier(model.cardStyleModel),
            ObjectIdentifier(model.watchStatusIndicatorModel),
            ObjectIdentifier(model.navigationStyleModel),
            ObjectIdentifier(model.transparencyModel),
            ObjectIdentifier(model.heroSettingsModel),
            ObjectIdentifier(model.nightShiftModel),
        ]
        XCTAssertEqual(before.count, 20, "Expected 20 per-profile sub-models")

        model.rebuild(namespace: "ns-b")

        let after: [ObjectIdentifier] = [
            ObjectIdentifier(model.contentRatingModel),
            ObjectIdentifier(model.appLanguageModel),
            ObjectIdentifier(model.subtitleBehaviorModel),
            ObjectIdentifier(model.subtitleStyleModel),
            ObjectIdentifier(model.spoilerModel),
            ObjectIdentifier(model.playbackModel),
            ObjectIdentifier(model.subtitlePolicyModel),
            ObjectIdentifier(model.audioPolicyModel),
            ObjectIdentifier(model.themeModel),
            ObjectIdentifier(model.themeMusicModel),
            ObjectIdentifier(model.diagnosticsModel),
            ObjectIdentifier(model.musicPlayerModel),
            ObjectIdentifier(model.homeLibraryVisibilityModel),
            ObjectIdentifier(model.uiDensityModel),
            ObjectIdentifier(model.cardStyleModel),
            ObjectIdentifier(model.watchStatusIndicatorModel),
            ObjectIdentifier(model.navigationStyleModel),
            ObjectIdentifier(model.transparencyModel),
            ObjectIdentifier(model.heroSettingsModel),
            ObjectIdentifier(model.nightShiftModel),
        ]

        for (index, (old, new)) in zip(before, after).enumerated() {
            XCTAssertNotEqual(old, new, "Sub-model at index \(index) was not swapped on rebuild")
        }
    }

    /// A namespace round-trip: rebuilding to a new namespace and back builds fresh
    /// instances each time (state is scoped to the namespace, never reused), and a
    /// same-namespace round-trip still swaps because rebuild always constructs anew.
    func testRebuildRoundTripScopesToNamespace() {
        let model = ProfileSettingsModel(namespace: "ns-a")
        // Retain the instances: a released object's address can be reused by a
        // later allocation and is not evidence that the model was reused.
        let themeA = model.themeModel

        model.rebuild(namespace: "ns-b")
        let themeB = model.themeModel
        XCTAssertFalse(themeA === themeB)

        // Returning to the original namespace rebuilds fresh state scoped to it
        // rather than restoring the prior instance.
        model.rebuild(namespace: "ns-a")
        let themeABack = model.themeModel
        XCTAssertFalse(themeB === themeABack)
        XCTAssertFalse(themeA === themeABack)
    }

    func testRebuildScopesAccidentalExitPreferenceToActiveProfile() {
        let primaryNamespace = "ProfileSettingsModelTests.primary.\(UUID().uuidString)"
        let childNamespace = "ProfileSettingsModelTests.child.\(UUID().uuidString)"
        let primaryKey = SettingsKey.scoped(
            "preventsAccidentalExit",
            namespace: primaryNamespace
        )
        let childKey = SettingsKey.scoped(
            "preventsAccidentalExit",
            namespace: childNamespace
        )
        defer {
            UserDefaults.standard.removeObject(forKey: primaryKey)
            UserDefaults.standard.removeObject(forKey: childKey)
        }

        let model = ProfileSettingsModel(namespace: primaryNamespace)
        XCTAssertFalse(model.navigationStyleModel.preventsAccidentalExit)
        model.navigationStyleModel.preventsAccidentalExit = true

        model.rebuild(namespace: childNamespace)
        XCTAssertFalse(model.navigationStyleModel.preventsAccidentalExit)

        model.rebuild(namespace: primaryNamespace)
        XCTAssertTrue(model.navigationStyleModel.preventsAccidentalExit)
    }

    func testHomeLayoutSelectionSurvivesProfileSwitchWithoutChangingNavigation() {
        let primary = "HomeLayout.primary.\(UUID().uuidString)"
        let other = "HomeLayout.other.\(UUID().uuidString)"
        defer {
            for namespace in [primary, other] {
                UserDefaults.standard.removeObject(forKey: SettingsKey.scoped("com.plozz.heroSettings", namespace: namespace))
                UserDefaults.standard.removeObject(forKey: SettingsKey.scoped(DetailPageSettingsStore.baseKey, namespace: namespace))
                UserDefaults.standard.removeObject(forKey: SettingsKey.scoped(CardCaptionSettingsStore.storageKey, namespace: namespace))
                UserDefaults.standard.removeObject(forKey: SettingsKey.scoped(CardCaptionSettingsStore.storageKey, namespace: namespace) + ".migrated")
            }
        }
        let model = ProfileSettingsModel(namespace: primary)
        let navigation = model.navigationStyleModel.style
        model.heroSettingsModel.settings.style = .followsFocus
        model.heroSettingsModel.settings.logoSize = HeroLogoSize(rawValue: 3)
        model.heroSettingsModel.settings.showcaseLogoSize = HeroLogoSize(rawValue: 8)
        model.detailPageModel.settings.logoSize = HeroLogoSize(rawValue: 6)
        model.cardStyleModel.captions.setOverride(.show, for: .home)

        model.rebuild(namespace: other)
        XCTAssertEqual(model.heroSettingsModel.settings.style, .carousel)
        XCTAssertEqual(model.heroSettingsModel.settings.logoSize, .default)
        XCTAssertEqual(model.heroSettingsModel.settings.showcaseLogoSize, .default)
        XCTAssertEqual(model.detailPageModel.settings.logoSize, .default)
        XCTAssertTrue(model.cardStyleModel.captions.showsLabels(in: .home))
        XCTAssertFalse(model.cardStyleModel.captions.showsLabels(in: .home, isShowcase: true))
        model.rebuild(namespace: primary)
        XCTAssertEqual(model.heroSettingsModel.settings.style, .followsFocus)
        XCTAssertEqual(model.heroSettingsModel.settings.logoSize.rawValue, 3)
        XCTAssertEqual(model.heroSettingsModel.settings.showcaseLogoSize.rawValue, 8)
        XCTAssertEqual(model.detailPageModel.settings.logoSize.rawValue, 6)
        XCTAssertTrue(model.cardStyleModel.captions.showsLabels(in: .home))
        XCTAssertEqual(model.navigationStyleModel.style, navigation)
    }

    /// The three models that previously had no injection parameter
    /// (`subtitlePolicyModel`, `audioPolicyModel`, `heroSettingsModel`) are now
    /// injectable and preserved as-is, mirroring the other injected models.
    func testNewlyInjectableModelsArePreservedAndNotRebuilt() {
        let injectedContentRatings = ContentRatingSettingsModel(store: ContentRatingSettingsStore(namespace: "seed"))
        let injectedSubtitlePolicy = SubtitlePolicyModel(store: SubtitlePolicyStore(namespace: "seed"))
        let injectedAudioPolicy = AudioPolicyModel(store: AudioPolicyStore(namespace: "seed"))
        let injectedHero = HeroSettingsModel(store: HeroSettingsStore(namespace: "seed"))

        let model = ProfileSettingsModel(
            namespace: "ns-a",
            subtitlePolicyModel: injectedSubtitlePolicy,
            audioPolicyModel: injectedAudioPolicy,
            contentRatingModel: injectedContentRatings,
            heroSettingsModel: injectedHero
        )

        XCTAssertTrue(model.usesInjectedModels)
        XCTAssertTrue(model.subtitlePolicyModel === injectedSubtitlePolicy)
        XCTAssertTrue(model.audioPolicyModel === injectedAudioPolicy)
        XCTAssertTrue(model.heroSettingsModel === injectedHero)
        XCTAssertTrue(model.contentRatingModel === injectedContentRatings)

        // Rebuild is a no-op under injection: identities are preserved.
        model.rebuild(namespace: "ns-b")
        XCTAssertTrue(model.subtitlePolicyModel === injectedSubtitlePolicy)
        XCTAssertTrue(model.audioPolicyModel === injectedAudioPolicy)
        XCTAssertTrue(model.heroSettingsModel === injectedHero)
        XCTAssertTrue(model.contentRatingModel === injectedContentRatings)
    }

    func testInjectedModelsAreNotRebuilt() {
        let injectedTheme = ThemeSettingsModel(store: ThemeSettingsStore(namespace: "seed"))
        let model = ProfileSettingsModel(namespace: "ns-a", themeModel: injectedTheme)
        XCTAssertTrue(model.usesInjectedModels)
        XCTAssertTrue(model.themeModel === injectedTheme)

        let subtitleBefore = ObjectIdentifier(model.subtitleBehaviorModel)
        model.rebuild(namespace: "ns-b")

        // Rebuild is a no-op when models were injected: identity is preserved.
        XCTAssertTrue(model.themeModel === injectedTheme)
        XCTAssertEqual(subtitleBefore, ObjectIdentifier(model.subtitleBehaviorModel))
    }
}
