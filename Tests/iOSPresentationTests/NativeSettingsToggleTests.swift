#if os(iOS)
import CoreModels
import CoreUI
import FeatureProfiles
@testable import FeaturePlayback
@testable import FeatureSettings
import Observation
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class NativeSettingsToggleTests: XCTestCase {
    @Observable
    final class Model {
        var isOn = false
        var isDisabled = false
        var writes = 0

        var binding: Binding<Bool> {
            Binding(
                get: { self.isOn },
                set: { self.isOn = $0; self.writes += 1 }
            )
        }
    }

    @Observable
    final class SkipMarkerNavigation {
        var showsSettings = false
    }

    func testGroupedSettingsUseNativeSwitchesAndPreserveBindings() async throws {
        try await verifyNativeSwitch(grouped: true)
    }

    func testSharedSettingsStyleUsesNativeSwitchesOnMobile() async throws {
        try await verifyNativeSwitch(grouped: false)
    }

    func testAdaptiveCardSettingsKeepLabelsAndIndicatorsInFirstViewport() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let suite = "CompactCardSettings.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let cards = CardStyleSettingsModel(store: CardStyleSettingsStore(defaults: defaults))
        let indicators = WatchStatusIndicatorSettingsModel(store: WatchStatusIndicatorSettingsStore(defaults: defaults))
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        window.rootViewController = UIHostingController(rootView:
            NavigationStack {
                CardAppearanceControls(cards: cards, watchIndicator: indicators)
            }
            .environment(\.themePalette, .dark)
            .environment(\.colorScheme, .dark)
            .environment(\.locale, Locale(identifier: "en_US"))
        )
        window.makeKeyAndVisible()
        for width: CGFloat in [390, 600, 834, 600] {
            window.frame = CGRect(x: 0, y: 0, width: width, height: 900)
            for mode in WatchStatusIndicator.allCases {
                indicators.indicator = mode
                try await settle(window)
                let text = try captureText(window, name: "adaptive-cards-\(Int(width))-\(mode)")
                for label in ["Labels", "Customize labels", "Watch indicators", "Show unwatched episode count"] {
                    XCTAssertTrue(text.localizedCaseInsensitiveContains(label), text)
                }
                let showsLabelCards = text.contains("Show labels everywhere")
                XCTAssertEqual(showsLabelCards, text.contains("Hide labels everywhere"), text)
                if width < 632 { XCTAssertFalse(showsLabelCards, text) }
                XCTAssertTrue(text.contains("App default"), text)
                XCTAssertEqual(text.contains("Hidden"), width == 834 || mode == .hidden, text)
                XCTAssertEqual(text.contains("Color"), mode != .hidden)
                XCTAssertTrue(indicators.showsUnwatchedEpisodeCount)
            }
        }
    }

    func testCardPickerUsesAvailableWidthAndAccessibilityFallback() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 900, height: 900)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for size in [DynamicTypeSize.large, .accessibility1] {
            for width: CGFloat in [631, 632, 900, 400] {
                window.rootViewController = UIHostingController(rootView:
                    AdaptiveCardSettingsPicker {
                        Text("Side by side")
                    } compact: {
                        Text("Compact menu")
                    }
                    .frame(width: width)
                    .environment(\.dynamicTypeSize, size)
                    .environment(\.locale, Locale(identifier: "en_US"))
                )
                window.makeKeyAndVisible()
                try await settle(window)
                let text = try captureText(window, name: "card-picker-fit-\(Int(width))-\(size)")
                let showsChoices = width >= 632 && !size.isAccessibilitySize
                XCTAssertEqual(text.contains("Side by side"), showsChoices, text)
                XCTAssertEqual(text.contains("Compact menu"), !showsChoices, text)
            }
        }
    }

    func testSkipToggleRevealsOnlySettingsLinkAndRetainsProfileChoices() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let suite = "SkipSettingsHosted-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = PlaybackSettingsStore(defaults: defaults, namespace: "viewer")
        window.overrideUserInterfaceStyle = .dark
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        for width: CGFloat in [390, 834] {
            store.save(.init(
                skipIntros: .autoDelay, skipMarkersEnabled: false,
                skipContentCategories: [.tvShow, .anime], skipAutomaticDelaySeconds: 12
            ))
            let model = PlaybackSettingsModel(store: store)
            let navigation = SkipMarkerNavigation()
            window.frame = CGRect(x: 0, y: 0, width: width, height: 1000)
            window.rootViewController = UIHostingController(rootView:
                NavigationStack {
                    List {
                        SkipMarkerSettingsControl(model: model, onOpenSettings: { navigation.showsSettings = true })
                    }
                    .navigationDestination(isPresented: Binding(
                        get: { navigation.showsSettings },
                        set: { navigation.showsSettings = $0 }
                    )) {
                        SkipMarkerSettingsView(model: model)
                    }
                }
                    .environment(\.themePalette, .dark)
                    .environment(\.colorScheme, .dark)
                    .environment(\.locale, Locale(identifier: "en_US"))
            )
            window.makeKeyAndVisible()
            try await settle(window)
            for enabled in [false, true, false, true] {
                XCTAssertEqual(listedSwitches(in: window).count, 1)
                let master = try XCTUnwrap(listedSwitches(in: window).first)
                master.setOn(enabled, animated: false)
                master.sendActions(for: .valueChanged)
                try await settle(window)
                XCTAssertEqual(model.settings.skipMarkersEnabled, enabled)
                XCTAssertEqual(listedSwitches(in: window).count, 1)
                let text = try captureText(window, name: "skip-marker-link-\(Int(width))-\(enabled)")
                XCTAssertTrue(text.contains("Skip intros, credits & more"), text)
                XCTAssertEqual(text.contains("Customize"), enabled, text)
                XCTAssertFalse(text.contains("Skip markers"), text)
                for label in ["Behavior", "Show skip button", "Skip after", "Set each marker separately",
                              "Intros", "Credits", "Use community markers"] {
                    XCTAssertFalse(text.contains(label), text)
                }
                XCTAssertEqual(store.load().skipContentCategories, [.tvShow, .anime])
                XCTAssertEqual(store.load().skipAutomaticDelaySeconds, 12)
                XCTAssertEqual(store.load().skipIntros, .autoDelay)
                XCTAssertEqual(PlaybackSettingsStore(defaults: defaults).load(), .default)
            }
            navigation.showsSettings = true
            try await Task.sleep(for: .milliseconds(500))
            try await settle(window)
            let child = try await skipMarkerPageText(in: window, name: "skip-marker-navigation-\(Int(width))")
            for label in ["Default behavior", "Skip after", "12 seconds", "Intros", "Credits",
                          "Recaps", "Previews", "Commercials"] {
                XCTAssertTrue(child.contains(label), child)
            }
            navigation.showsSettings = false
            try await Task.sleep(for: .milliseconds(500))
            try await settle(window)
            XCTAssertEqual(listedSwitches(in: window).count, 1)
            XCTAssertTrue(model.settings.skipMarkersEnabled)
        }
    }

    func testSkipMarkerPageEditsNativePerMarkerTimingWithoutSeparateMode() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let suite = "SkipMarkerPageHosted-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = PlaybackSettingsStore(defaults: defaults, namespace: "viewer")
        window.overrideUserInterfaceStyle = .dark
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        for width: CGFloat in [390, 834] {
            store.save(.init(
                skipIntros: .on, skipAutomaticDelaySeconds: 12,
                skipMarkerRules: [.movie: [.intro: .init(mode: .autoDelay, automaticDelaySeconds: 12)]]
            ))
            let model = PlaybackSettingsModel(store: store)
            window.frame = CGRect(x: 0, y: 0, width: width, height: 1000)
            window.rootViewController = UIHostingController(rootView:
                NavigationStack {
                    SkipMarkerContentSettingsView(model: model, kind: .intro)
                }
                .environment(\.themePalette, .dark)
                .environment(\.colorScheme, .dark)
                .environment(\.locale, Locale(identifier: "en_US"))
            )
            window.makeKeyAndVisible()
            try await settle(window)
            let automatic = try captureText(window, name: "skip-settings-automatic-\(Int(width))")
            for label in ["Intros", "Skip after", "12 seconds", "Show skip button (default)",
                          "Movies", "TV Shows", "Anime"] {
                XCTAssertTrue(automatic.contains(label), "Missing \(label): \(automatic)")
            }
            XCTAssertFalse(automatic.contains("Set each marker separately"), automatic)
            XCTAssertFalse(automatic.contains("When your server has no intro or credits marker"), automatic)
            let stepper = try XCTUnwrap(firstStepper(in: window))
            stepper.value += stepper.stepValue
            stepper.sendActions(for: .valueChanged)
            try await settle(window)
            XCTAssertEqual(model.settings.configuredSkipDelay(for: .intro, category: .movie), 13)
            XCTAssertEqual(store.load().configuredSkipDelay(for: .intro, category: .movie), 13)
            XCTAssertEqual(store.load().configuredSkipDelay(for: .intro, category: .anime), 12)
            XCTAssertEqual(store.load().configuredSkipDelay(for: .credits), 12)
            model.settings.setSkipAutomaticDelay(29, for: .intro, category: .movie)
            try await settle(window)
            for _ in 0..<2 {
                stepper.value += stepper.stepValue
                stepper.sendActions(for: .valueChanged)
                try await settle(window)
                XCTAssertEqual(model.settings.configuredSkipDelay(for: .intro, category: .movie), 30)
            }
            model.settings.setSkipAutomaticDelay(1, for: .intro, category: .movie)
            try await settle(window)
            for _ in 0..<2 {
                stepper.value -= stepper.stepValue
                stepper.sendActions(for: .valueChanged)
                try await settle(window)
                XCTAssertEqual(model.settings.configuredSkipDelay(for: .intro, category: .movie), 1)
                XCTAssertEqual(model.settings.skipMarkerModes(for: .movie).mode(for: .intro), .autoDelay)
            }
            let movie = SkipMarkerRuleControls(model: model, scope: .content(.intro, .movie))
            movie.behavior.wrappedValue = .instant
            try await settle(window)
            XCTAssertNil(firstStepper(in: window))
            XCTAssertTrue(try captureText(window, name: "skip-settings-immediate-\(Int(width))").contains("Skip instantly"))
            movie.behavior.wrappedValue = .manual
            try await settle(window)
            let manual = try captureText(window, name: "skip-settings-manual-\(Int(width))")
            XCTAssertTrue(manual.contains("Show skip button"), manual)
            XCTAssertFalse(manual.contains("Skip after"), manual)
            model.settings.skipContentCategories.remove(.anime)
            try await settle(window)
            XCTAssertTrue(try captureText(window, name: "skip-anime-disabled-\(Int(width))")
                .contains("Disabled on the previous page."))
            window.rootViewController = UIHostingController(rootView:
                NavigationStack { SkipMarkerSettingsView(model: model) }
                    .environment(\.themePalette, .dark)
                    .environment(\.colorScheme, .dark)
                    .environment(\.locale, Locale(identifier: "en_US"))
            )
            try await settle(window)
            let page = try await skipMarkerPageText(in: window, name: "skip-marker-page-\(Int(width))")
            for label in ["Intros", "Credits", "Recaps", "Previews", "Commercials",
                          "Use community markers", "From IntroDB", "your server has none", "Shares"] {
                XCTAssertTrue(page.contains(label), page)
            }
            XCTAssertFalse(page.contains("Set each marker separately"), page)
            XCTAssertEqual(store.load().skipContentCategories, Set(ContentCategory.allCases).subtracting([.anime]))
            XCTAssertEqual(store.load().configuredSkipDelay(for: .intro, category: .movie), 0)
            XCTAssertEqual(store.load().configuredSkipDelay(for: .credits), 12)
            XCTAssertEqual(PlaybackSettingsStore(defaults: defaults).load(), .default)
        }
    }

    func testSharedSkipDefaultAndSingleAnimeExceptionAtPhoneAndTabletWidths() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let suite = "SkipDefaultHosted-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = PlaybackSettingsStore(defaults: defaults, namespace: "viewer")
        window.overrideUserInterfaceStyle = .dark
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        for width: CGFloat in [390, 834] {
            store.save(.default)
            let model = PlaybackSettingsModel(store: store)
            let shared = SkipMarkerRuleControls(model: model, scope: .defaultBehavior)
            let anime = SkipMarkerRuleControls(model: model, scope: .content(.intro, .anime))
            XCTAssertEqual(shared.behaviors, [.manual, .instant, .delayed])
            XCTAssertEqual(anime.behaviors, [.useDefault, .manual, .instant, .delayed, .off])
            shared.behavior.wrappedValue = .off
            XCTAssertEqual(shared.behaviors, [.manual, .instant, .delayed, .off])
            window.frame = CGRect(x: 0, y: 0, width: width, height: 1000)
            window.rootViewController = UIHostingController(rootView:
                NavigationStack { SkipMarkerSettingsView(model: model) }
                    .environment(\.themePalette, .dark)
                    .environment(\.colorScheme, .dark)
                    .environment(\.locale, Locale(identifier: "en_US"))
            )
            window.makeKeyAndVisible()
            try await settle(window)
            shared.behavior.wrappedValue = .instant
            try await settle(window)
            let instant = try captureText(window, name: "skip-default-instant-\(Int(width))")
            XCTAssertTrue(instant.contains("Default behavior"), instant)
            XCTAssertTrue(instant.contains("Skip instantly"), instant)
            XCTAssertNil(firstStepper(in: window))
            for category in [ContentCategory.movie, .tvShow, .anime] {
                for kind in MediaSegment.Kind.skippable {
                    XCTAssertTrue(store.load().usesDefaultSkipRule(for: kind, category: category))
                    XCTAssertEqual(store.load().skipMarkerModes(for: category).mode(for: kind), .autoInstant)
                }
            }
            shared.behavior.wrappedValue = .delayed
            try await settle(window)
            let defaultStepper = try XCTUnwrap(firstStepper(in: window))
            defaultStepper.value += defaultStepper.stepValue
            defaultStepper.sendActions(for: .valueChanged)
            try await settle(window)
            XCTAssertEqual(store.load().configuredSkipDelay(), 6)
            XCTAssertEqual(store.load().skipMarkerModes(for: .anime).delay(for: .intro), 6)
            shared.behavior.wrappedValue = .instant
            anime.behavior.wrappedValue = .manual
            XCTAssertEqual(store.load().skipMarkerRules.count, 1)
            XCTAssertEqual(store.load().skipMarkerRules[.anime]?.count, 1)
            window.rootViewController = UIHostingController(rootView:
                NavigationStack { SkipMarkerContentSettingsView(model: model, kind: .intro) }
                    .environment(\.themePalette, .dark)
                    .environment(\.colorScheme, .dark)
                    .environment(\.locale, Locale(identifier: "en_US"))
            )
            try await settle(window)
            let exception = try captureText(window, name: "skip-default-anime-exception-\(Int(width))")
            for label in ["Movies", "TV Shows", "Anime", "Skip instantly (default)", "Show skip button"] {
                XCTAssertTrue(exception.contains(label), exception)
            }
            XCTAssertFalse(exception.contains("Default:"), exception)
            XCTAssertFalse(exception.contains("Use default"), exception)
            XCTAssertNil(firstStepper(in: window))
            shared.behavior.wrappedValue = .delayed
            try await settle(window)
            XCTAssertEqual(model.settings.configuredSkipDelay(), 5)
            XCTAssertEqual(anime.behavior.wrappedValue, .manual)
            XCTAssertEqual(store.load().skipMarkerModes(for: .movie).delay(for: .intro), 5)
            XCTAssertNil(firstStepper(in: window), "Inherited timing is edited only on the default page")
            anime.behavior.wrappedValue = .useDefault
            try await settle(window)
            let inherited = try captureText(window, name: "skip-default-inherited-\(Int(width))")
            XCTAssertTrue(inherited.contains("Skip after 5 seconds (default)"), inherited)
            XCTAssertFalse(inherited.contains("Show skip button"), inherited)
            XCTAssertTrue(store.load().skipMarkerRules.isEmpty)
            XCTAssertEqual(store.load().skipMarkerModes(for: .anime).delay(for: .intro), 5)
            anime.behavior.wrappedValue = .instant
            XCTAssertEqual(store.load().skipMarkerModes(for: .anime).mode(for: .intro), .autoInstant)
            anime.behavior.wrappedValue = .delayed
            try await settle(window)
            let stepper = try XCTUnwrap(firstStepper(in: window))
            stepper.value += stepper.stepValue
            stepper.sendActions(for: .valueChanged)
            try await settle(window)
            XCTAssertEqual(store.load().skipMarkerModes(for: .anime).delay(for: .intro), 6)
            XCTAssertEqual(store.load().skipMarkerModes(for: .movie).delay(for: .intro), 5)
            anime.behavior.wrappedValue = .useDefault
            shared.behavior.wrappedValue = .instant
            try await settle(window)
            XCTAssertNil(firstStepper(in: window))
            XCTAssertEqual(anime.behavior.wrappedValue, .useDefault)
            XCTAssertEqual(store.load().skipMarkerModes(for: .anime).mode(for: .intro), .autoInstant)
            XCTAssertEqual(PlaybackSettingsStore(defaults: defaults).load(), .default)
        }
    }

    private func firstStepper(in view: UIView) -> UIStepper? {
        if let stepper = view as? UIStepper { return stepper }
        return view.subviews.lazy.compactMap { self.firstStepper(in: $0) }.first
    }

    private func skipMarkerPageText(in window: UIWindow, name: String) async throws -> String {
        func list(in view: UIView) -> UICollectionView? {
            if let list = view as? UICollectionView { return list }
            return view.subviews.lazy.compactMap { list(in: $0) }.first
        }
        let scroll = try XCTUnwrap(list(in: window))
        let top = -scroll.adjustedContentInset.top
        var text = ""
        var offset = top
        for index in 0..<10 {
            let bottom = max(top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            scroll.setContentOffset(CGPoint(x: 0, y: min(offset, bottom)), animated: false)
            try await settle(window)
            text += " " + (try captureText(window, name: "\(name)-\(index)"))
            if offset >= bottom { break }
            offset += scroll.bounds.height / 2
        }
        return text
    }

    func testBufferControlsShowIndependentDeviceSelectionsAtPhoneAndTabletWidths() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let suite = "BufferSettingsHosted-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        for width: CGFloat in [390, 834] {
            PlaybackReadAheadStore(defaults: defaults).save(.automatic)
            LivePlaybackBufferStore(defaults: defaults).save(.automatic)
            window.frame = CGRect(x: 0, y: 0, width: width, height: 900)
            window.rootViewController = UIHostingController(rootView:
                List {
                    PlaybackReadAheadControl(defaults: defaults)
                    LivePlaybackBufferControl(defaults: defaults)
                }
                .environment(\.themePalette, .dark)
                .environment(\.locale, Locale(identifier: "en_US"))
            )
            window.makeKeyAndVisible()
            try await settle(window)
            let initial = try captureText(window, name: "automatic-buffers-\(Int(width))")
            XCTAssertTrue(initial.contains("Video buffer"), initial)
            XCTAssertTrue(initial.contains("Live TV buffer"), initial)
            XCTAssertTrue(initial.contains("Automatic"), initial)
            PlaybackReadAheadStore(defaults: defaults).save(.oneMinute)
            LivePlaybackBufferStore(defaults: defaults).save(.thirtySeconds)
            try await settle(window)
            let selected = try captureText(window, name: "selected-buffers-\(Int(width))")
            XCTAssertTrue(selected.contains("1 minute"), selected)
            XCTAssertTrue(selected.contains("30 seconds"), selected)
        }
    }

    func testAdvancedPlaybackFELUsesNativeSwitchAndPersistsOnlyTheActiveProfile() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let suite = "FELSettingsHosted-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        let playback = PlaybackSettingsModel(store: PlaybackSettingsStore(defaults: defaults, namespace: "guest"))
        let external = ExternalPlayerSettingsModel(defaults: defaults)
        for width: CGFloat in [390, 834] {
            for scheme: ColorScheme in [.light, .dark] {
                playback.settings.dolbyVisionFELEnabled = false
                window.frame = CGRect(x: 0, y: 0, width: width, height: 900)
                window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
                window.rootViewController = UIHostingController(rootView: NavigationStack {
                    PlaybackAdvancedSettingsView(playback: playback, model: external)
                }
                .environment(\.colorScheme, scheme)
                .environment(\.themePalette, scheme == .dark ? .dark : .light)
                .environment(\.locale, Locale(identifier: "en_US")))
                window.makeKeyAndVisible()
                try await settle(window)
                let switches = listedSwitches(in: window)
                XCTAssertEqual(switches.count, 1)
                let control = try XCTUnwrap(switches.first)
                XCTAssertFalse(control.isOn)
                let text = try captureText(
                    window, name: "fel-settings-\(Int(width))-\(scheme)"
                )
                for label in ["FEL", "experimental", "May impact performance."] {
                    XCTAssertTrue(text.contains(label), "The setting and tradeoff must be visible: \(text)")
                }
                XCTAssertFalse(text.contains("Dolby Atmos"), text)
                if #available(iOS 26.0, *) {
                    XCTAssertFalse(text.contains("Disables spatial audio."), text)
                    XCTAssertTrue(text.contains("Rendering layout"), text)
                    XCTAssertTrue(text.contains("DTS:X"), text)
                } else {
                    XCTAssertTrue(text.contains("Disables spatial audio."), text)
                    XCTAssertFalse(text.contains("Rendering layout"), text)
                }
                control.setOn(true, animated: false)
                control.sendActions(for: .valueChanged)
                try await settle(window)
                XCTAssertTrue(playback.settings.dolbyVisionFELEnabled)
                XCTAssertTrue(PlaybackSettingsStore(defaults: defaults, namespace: "guest").load().dolbyVisionFELEnabled)
                XCTAssertFalse(PlaybackSettingsStore(defaults: defaults).load().dolbyVisionFELEnabled)
                XCTAssertEqual(external.settings.player, .builtIn)
                try assertGreenOnState(control, in: window)
            }
        }
    }

    func testSpatialAudioUsesNativeSwitchAndPreservesProfileChoicesOnPhoneAndTablet() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let suite = "SpatialAudioSettingsHosted-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        let store = PlaybackSettingsStore(defaults: defaults, namespace: "guest")
        for width: CGFloat in [390, 834] {
            for scheme: ColorScheme in [.light, .dark] {
                store.save(.default)
                let playback = PlaybackSettingsModel(store: store)
                window.frame = CGRect(x: 0, y: 0, width: width, height: 900)
                window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
                window.rootViewController = UIHostingController(rootView:
                    List {
                        SettingsSectionGroup("Audio") {
                            SpatialAudioControl(isOn: Binding(
                                get: { playback.settings.trueHDAtmosEnabled },
                                set: { playback.settings.trueHDAtmosEnabled = $0 }
                            ))
                        }
                    }
                    .settingsPageSurface()
                    .environment(\.colorScheme, scheme)
                    .environment(\.themePalette, scheme == .dark ? .dark : .light)
                    .environment(\.locale, Locale(identifier: "en_US"))
                )
                window.makeKeyAndVisible()
                try await settle(window)
                let switches = listedSwitches(in: window)
                if #available(iOS 26.0, *) {
                    XCTAssertEqual(switches.count, 1)
                    let control = try XCTUnwrap(switches.first)
                    XCTAssertTrue(control.isOn)
                    try assertGreenOnState(control, in: window)
                    let text = try captureText(window, name: "spatial-audio-\(Int(width))-\(scheme)")
                    for label in ["Spatial audio", "TrueHD Atmos", "DTS:X", "AirPlay"] {
                        XCTAssertTrue(text.contains(label), text)
                    }
                    control.setOn(false, animated: false)
                    control.sendActions(for: .valueChanged)
                    try await settle(window)
                    XCTAssertFalse(playback.settings.trueHDAtmosEnabled)
                    XCTAssertFalse(PlaybackSettingsModel(store: store).settings.trueHDAtmosEnabled)
                } else {
                    XCTAssertTrue(switches.isEmpty)
                    XCTAssertTrue(store.load().trueHDAtmosEnabled)
                }
                XCTAssertTrue(PlaybackSettingsStore(defaults: defaults).load().trueHDAtmosEnabled)
            }
        }
    }

    func testSubtitleDestinationsKeepNativeGreenSwitchesAndLiveBindings() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for width: CGFloat in [390, 834] {
            for scheme: ColorScheme in [.light, .dark] {
                for page in SubtitlePage.allCases {
                    let controls = PlayerControlsModel()
                    var style = SubtitleStyle.default
                    style.usesSourcePosition = true
                    style.usesSourceColors = true
                    style.usesSourceEmphasis = true
                    style.border.isEnabled = true
                    style.background.isEnabled = true
                    style.secondary = .init()
                    style.secondary?.differentiate = true
                    controls.subtitleStyle = style
                    let preview = Model()
                    preview.isOn = true
                    var writes = 0
                    let context = SubtitleStyleEditingContext(
                        controls: controls,
                        style: Binding(
                            get: { controls.subtitleStyle },
                            set: { controls.subtitleStyle = $0; writes += 1 }
                        ),
                        secondaryPreview: preview.binding
                    )
                    window.frame = CGRect(x: 0, y: 0, width: width, height: 1100)
                    window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
                    window.rootViewController = UIHostingController(rootView: NavigationStack {
                        subtitleDestination(page, context: context)
                    }
                    .environment(\.colorScheme, scheme)
                    .tint(scheme == .dark ? .white : .black))
                    window.makeKeyAndVisible()
                    try await settle(window)
                    let switches = listedSwitches(in: window).sorted {
                        $0.convert($0.bounds, to: window).minY < $1.convert($1.bounds, to: window).minY
                    }
                    XCTAssertEqual(switches.count, page.switchCount, "\(page), width=\(width), scheme=\(scheme)")
                    for control in switches {
                        XCTAssertTrue(control.isOn)
                        XCTAssertNil(control.thumbTintColor)
                        try assertGreenOnState(control, in: window)
                    }
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "subtitle-switches-\(page)-\(Int(width))-\(scheme)"
                    attachment.lifetime = .keepAlways
                    add(attachment)

                    let first = try XCTUnwrap(switches.first)
                    first.setOn(false, animated: false)
                    first.sendActions(for: .valueChanged)
                    try await settle(window)
                    switch page {
                    case .fileFormatting: XCTAssertFalse(controls.subtitleStyle.usesSourcePosition)
                    case .outline: XCTAssertFalse(controls.subtitleStyle.border.isEnabled)
                    case .background: XCTAssertFalse(controls.subtitleStyle.background.isEnabled)
                    case .dual: XCTAssertFalse(preview.isOn)
                    }
                    XCTAssertEqual(writes, page == .dual ? 0 : 1)
                    XCTAssertEqual(preview.writes, page == .dual ? 1 : 0)
                }
            }
        }
    }

    private enum SubtitlePage: CaseIterable {
        case fileFormatting, outline, background, dual

        var switchCount: Int {
            switch self {
            case .fileFormatting: 3
            case .outline, .background: 1
            case .dual: 2
            }
        }
    }

    @ViewBuilder
    private func subtitleDestination(
        _ page: SubtitlePage, context: SubtitleStyleEditingContext
    ) -> some View {
        switch page {
        case .fileFormatting: MobileSubtitleFileFormattingView(viewModel: context)
        case .outline: MobileSubtitleShadowOutlineView(viewModel: context)
        case .background: MobileSubtitleBackgroundView(viewModel: context)
        case .dual: MobileSubtitleDualView(viewModel: context)
        }
    }

    func testProfileAndEveryoneAutomaticSignInShareOneNativeBinding() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let model = Model()
        var appearanceOpens = 0
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for profilePage in [true, false, true] {
            window.rootViewController = UIHostingController(rootView: SettingsPageList {
                if profilePage {
                    ProfileActionsList(
                        profile: .init(id: "native-signin", name: "Sample", avatarSymbol: "person.fill"),
                        syncEnabled: false, hasParentalPIN: false, restrictedActionsSealed: false,
                        groupsActions: true,
                        automaticSignIn: AutomaticSignInSettings(isEnabled: model.binding),
                        onEditAppearance: { appearanceOpens += 1 },
                        onSetLock: { _ in }, onSetKids: { _ in }, onDelete: {}
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    SettingsSectionGroup {
                        AutomaticSignInToggle(settings: AutomaticSignInSettings(isEnabled: model.binding))
                    }
                }
            })
            window.makeKeyAndVisible()
            try await settle(window)
            let controls = listedSwitches(in: window)
            XCTAssertEqual(controls.count, 1)
            let control = try XCTUnwrap(controls.first)
            XCTAssertEqual(control.isOn, model.isOn, "Both entry points must reflect the same live preference.")
            let next = !model.isOn
            let writes = model.writes
            control.setOn(next, animated: false)
            control.sendActions(for: .valueChanged)
            try await settle(window)
            XCTAssertEqual(model.isOn, next)
            XCTAssertEqual(model.writes, writes + 1)
            XCTAssertEqual(appearanceOpens, 0, "A sibling action must not own the switch's native cell.")
        }
    }

    func testHeroRootUsesInlineControlsAndShowsPageStatesAtPhoneAndTabletWidths() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for width: CGFloat in [390, 834] {
            let hero = HeroSettingsModel(store: InMemoryHeroSettingsStore())
            let background = HeroBackgroundSettingsModel(store: InMemoryHeroBackgroundSettingsStore())
            hero.settings.autoAdvance = false
            hero.settings.showsRatings = false
            background.settings.homeTrailerEnabled = false
            window.frame = CGRect(x: 0, y: 0, width: width, height: 1200)
            window.rootViewController = UIHostingController(rootView: NavigationStack {
                SettingsPageList {
                    HeroSettingsControls(libraries: [], accounts: [])
                }
                .navigationTitle("Home")
            }
            .environment(hero)
            .environment(background)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.colorScheme, .dark))
            window.makeKeyAndVisible()
            try await settle(window)
            let root = try await captureScrollableText(window, name: "hero-root-mobile-\(Int(width))")
            for label in ["Hero content sources", "Items to show",
                          "Advance automatically", "Ratings", "Off", "Trailers"] {
                XCTAssertTrue(root.contains(label), root)
            }
            for label in ["Hide watched content", "Appearance", "Rotation", "Titles shown in hero", "Show ratings", "Seconds per item",
                          "Play trailer behind the hero", "Start muted"] {
                XCTAssertFalse(root.contains(label), root)
            }
            let controls = listedSwitches(in: window).sorted {
                $0.convert($0.bounds, to: window).minY < $1.convert($1.bounds, to: window).minY
            }
            XCTAssertEqual(controls.count, 2, "Only enable and automatic changes are switches on the root.")
            let automatic = try XCTUnwrap(controls.indices.contains(1) ? controls[1] : nil)
            automatic.setOn(true, animated: false)
            automatic.sendActions(for: .valueChanged)
            try await settle(window)
            XCTAssertTrue(hero.settings.autoAdvance)
            let advanced = try await captureScrollableText(window, name: "hero-automatic-mobile-\(Int(width))")
            XCTAssertTrue(advanced.contains("Seconds per item"), advanced)
            XCTAssertFalse(advanced.localizedCaseInsensitiveContains("Automatic changes"), advanced)

            hero.settings.showsRatings = true
            background.settings.homeTrailerEnabled = true
            try await settle(window)
            let expanded = try await captureScrollableText(window, name: "hero-expanded-mobile-\(Int(width))")
            XCTAssertFalse(expanded.contains("Start muted"), expanded)
            XCTAssertTrue(expanded.contains("On"), expanded)
            XCTAssertFalse(expanded.contains("Show ratings"), expanded)
            XCTAssertFalse(expanded.contains("Show Common Sense age"), expanded)

            let enable = try XCTUnwrap(listedSwitches(in: window).min {
                $0.convert($0.bounds, to: window).minY < $1.convert($1.bounds, to: window).minY
            })
            enable.setOn(false, animated: false)
            enable.sendActions(for: .valueChanged)
            try await settle(window)
            XCTAssertFalse(hero.settings.isEnabled)
            XCTAssertEqual(listedSwitches(in: window).count, 1)
            XCTAssertTrue(hero.settings.autoAdvance)
            XCTAssertTrue(hero.settings.showsRatings)
            XCTAssertTrue(background.settings.homeTrailerEnabled)

            window.rootViewController = UIHostingController(rootView: NavigationStack {
                HeroSettingsScreen(page: .ratings, libraries: [], accounts: [])
            }
            .environment(hero)
            .environment(background)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.colorScheme, .dark))
            try await settle(window)
            XCTAssertEqual(listedSwitches(in: window).count, 2)
            let ratings = try captureText(window, name: "hero-ratings-mobile-\(Int(width))")
            XCTAssertTrue(ratings.contains("Show ratings"), ratings)
            XCTAssertTrue(ratings.contains("Show Common Sense age"), ratings)
            XCTAssertTrue(ratings.contains("Maximum ratings shown"), ratings)
            XCTAssertTrue(ratings.contains("Shows fewer when fewer ratings are available"), ratings)
            let showRatings = try XCTUnwrap(listedSwitches(in: window).min {
                $0.convert($0.bounds, to: window).minY < $1.convert($1.bounds, to: window).minY
            })
            showRatings.setOn(false, animated: false)
            showRatings.sendActions(for: .valueChanged)
            try await settle(window)
            XCTAssertFalse(hero.settings.showsRatings)
            XCTAssertEqual(listedSwitches(in: window).count, 1)

            window.rootViewController = UIHostingController(rootView: NavigationStack {
                HeroSettingsScreen(page: .trailers, libraries: [], accounts: [])
            }
            .environment(hero)
            .environment(background)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.colorScheme, .dark))
            try await settle(window)
            XCTAssertEqual(listedSwitches(in: window).count, 2)
            let trailers = try captureText(window, name: "hero-trailers-mobile-\(Int(width))")
            XCTAssertTrue(trailers.contains("Play trailer behind the hero"), trailers)
            XCTAssertTrue(trailers.contains("Start muted"), trailers)
            let playTrailer = try XCTUnwrap(listedSwitches(in: window).min {
                $0.convert($0.bounds, to: window).minY < $1.convert($1.bounds, to: window).minY
            })
            playTrailer.setOn(false, animated: false)
            playTrailer.sendActions(for: .valueChanged)
            try await settle(window)
            XCTAssertFalse(background.settings.homeTrailerEnabled)
            XCTAssertEqual(listedSwitches(in: window).count, 1)
        }
    }

    func testHeroSourceGroupsKeepNativeSwitchesSeparateFromNavigationRows() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for width: CGFloat in [390, 834] {
            let hero = HeroSettingsModel(store: InMemoryHeroSettingsStore())
            let background = HeroBackgroundSettingsModel(store: InMemoryHeroBackgroundSettingsStore())
            hero.settings.sources = [.randomFromLibrary, .collection, .featured]
            hero.settings.setEnabled(.featured, enabled: true)
            window.frame = CGRect(x: 0, y: 0, width: width, height: 1200)
            window.rootViewController = UIHostingController(rootView: NavigationStack {
                HeroSettingsScreen(page: .titles, libraries: [], accounts: [])
            }
            .environment(hero)
            .environment(background)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.colorScheme, .dark)
            .tint(.white))
            window.makeKeyAndVisible()
            try await settle(window)
            let sourceText = try captureText(window, name: "hero-sources-mobile-\(Int(width))")
            for title in ["Random from Library", "Choose libraries", "Choose collections", "Discovery providers"] {
                XCTAssertTrue(sourceText.contains(title), sourceText)
            }
            let switches = listedSwitches(in: window).sorted {
                $0.convert($0.bounds, to: window).minY < $1.convert($1.bounds, to: window).minY
            }
            XCTAssertEqual(switches.count, 6)
            for control in switches where control.isOn {
                try assertGreenOnState(control, in: window)
            }
            let random = try XCTUnwrap(switches.indices.contains(2) ? switches[2] : nil)
            var ancestor = random.superview
            while ancestor != nil && !(ancestor is UICollectionViewCell) { ancestor = ancestor?.superview }
            let cell = try XCTUnwrap(ancestor as? UICollectionViewCell)
            XCTAssertLessThan(cell.bounds.height, 90, "The source and its navigation link must be separate native rows.")
            random.setOn(false, animated: false)
            random.sendActions(for: .valueChanged)
            try await settle(window)
            XCTAssertFalse(hero.settings.sources.contains(.randomFromLibrary))
            XCTAssertTrue(hero.settings.sources.contains(.collection))
            XCTAssertTrue(hero.settings.sources.contains(.featured))
            let collapsed = try captureText(window, name: "hero-sources-collapsed-mobile-\(Int(width))")
            XCTAssertFalse(collapsed.contains("Choose libraries"), collapsed)
            XCTAssertTrue(collapsed.contains("Choose collections"), collapsed)
            XCTAssertTrue(collapsed.contains("Discovery providers"), collapsed)
        }
    }

    func testDiscoverySwitchFollowsSeerrUntilExplicitlyChanged() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for width: CGFloat in [390, 834] {
            let connection = Model()
            let hero = HeroSettingsModel(store: InMemoryHeroSettingsStore())
            hero.setSeerrConnection { connection.isOn }
            let background = HeroBackgroundSettingsModel(store: InMemoryHeroBackgroundSettingsStore())
            window.frame = CGRect(x: 0, y: 0, width: width, height: 1600)
            window.rootViewController = UIHostingController(rootView: NavigationStack {
                HeroSettingsScreen(page: .titles, libraries: [], accounts: [])
            }
            .environment(hero)
            .environment(background))
            window.makeKeyAndVisible()
            try await settle(window)
            func discoverySwitch() throws -> UISwitch {
                try XCTUnwrap(listedSwitches(in: window).max {
                    $0.convert($0.bounds, to: window).minY < $1.convert($1.bounds, to: window).minY
                })
            }
            XCTAssertFalse(try discoverySwitch().isOn)
            connection.isOn = true
            try await settle(window)
            let control = try discoverySwitch()
            XCTAssertTrue(control.isOn)
            XCTAssertTrue(hero.settings.discoveryFollowsSeerr)
            control.setOn(false, animated: false)
            control.sendActions(for: .valueChanged)
            try await settle(window)
            XCTAssertFalse(hero.settings.discoveryFollowsSeerr)
            connection.isOn = false
            try await settle(window)
            connection.isOn = true
            try await settle(window)
            XCTAssertFalse(try discoverySwitch().isOn)

            connection.isOn = false
            try await settle(window)
            let enable = try discoverySwitch()
            enable.setOn(true, animated: false)
            enable.sendActions(for: .valueChanged)
            try await settle(window)
            XCTAssertTrue(hero.effectiveSettings.isEnabled(.featured))
            XCTAssertTrue(try discoverySwitch().isOn)
        }
    }

    func testHeroSubpagesUseNativeSwitchesAndLiveKidsPolicyAtPhoneAndTabletWidths() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for width: CGFloat in [390, 834] {
            let hero = HeroSettingsModel(store: InMemoryHeroSettingsStore())
            let background = HeroBackgroundSettingsModel(store: InMemoryHeroBackgroundSettingsStore())
            window.frame = CGRect(x: 0, y: 0, width: width, height: 1200)
            window.rootViewController = UIHostingController(rootView: NavigationStack {
                HeroSettingsScreen(page: .discovery, libraries: [], accounts: [])
            }
            .environment(hero)
            .environment(background)
            .environment(\.colorScheme, .dark))
            window.makeKeyAndVisible()
            try await settle(window)
            XCTAssertEqual(listedSwitches(in: window).count, 5, "Attribution plus four providers use native switches.")
            let labels = try XCTUnwrap(listedSwitches(in: window).min {
                $0.convert($0.bounds, to: window).minY < $1.convert($1.bounds, to: window).minY
            })
            labels.setOn(true, animated: false)
            labels.sendActions(for: .valueChanged)
            try await settle(window)
            XCTAssertTrue(hero.settings.showsDiscoverySources)
            XCTAssertEqual(hero.settings.discoverySources, HeroDiscoverySource.defaultSelection)
            hero.setDiscoveryPolicy { false }
            let deadline = ContinuousClock.now + .seconds(2)
            repeat {
                try await settle(window)
            } while !listedSwitches(in: window).isEmpty && ContinuousClock.now < deadline
            let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            })
            attachment.name = "kids-discovery-mobile-\(Int(width))"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertTrue(listedSwitches(in: window).isEmpty, "An open Discovery page must lose its controls in Kids mode.")
            XCTAssertTrue(hero.settings.showsDiscoverySources, "Restricting Discovery must not erase saved preferences.")
            XCTAssertFalse(hero.effectiveSettings.showsDiscoverySources)
        }
    }

    private func verifyNativeSwitch(grouped: Bool) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for width: CGFloat in [390, 834] {
            for direction: LayoutDirection in [.leftToRight, .rightToLeft] {
                for scheme: ColorScheme in [.light, .dark] {
                    let model = Model()
                    window.frame = CGRect(x: 0, y: 0, width: width, height: 1100)
                    window.rootViewController = UIHostingController(rootView:
                        Fixture(model: model, grouped: grouped)
                            .environment(\.layoutDirection, direction)
                            .environment(\.colorScheme, scheme)
                            .environment(\.dynamicTypeSize, .accessibility1)
                            .tint(scheme == .dark ? .white : .black)
                    )
                    window.makeKeyAndVisible()
                    try await settle(window)
                    let controls = switches(in: window)
                    XCTAssertEqual(controls.count, 1, "Use one UISwitch, not a drawn button or nested toggles.")
                    let control = try XCTUnwrap(controls.first)
                    XCTAssertFalse(control.isOn)
                    XCTAssertTrue(control.isEnabled)
                    XCTAssertNil(control.thumbTintColor, "The system must own the knob's appearance.")
                    if let tint = control.onTintColor?.resolvedColor(with: control.traitCollection) {
                        var red: CGFloat = 0
                        var green: CGFloat = 0
                        var blue: CGFloat = 0
                        var alpha: CGFloat = 0
                        XCTAssertTrue(tint.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
                        XCTAssertGreaterThan(green, red, "Use the system switch tint, not the page's monochrome accent.")
                    }
                    XCTAssertGreaterThan(control.bounds.width, 0)

                    control.setOn(true, animated: false)
                    control.sendActions(for: .valueChanged)
                    try await settle(window)
                    XCTAssertTrue(model.isOn)
                    XCTAssertEqual(model.writes, 1, "A switch activation must write its binding exactly once.")
                    try assertGreenOnState(control, in: window)

                    model.isOn = false
                    model.isDisabled = true
                    try await settle(window)
                    let updated = try XCTUnwrap(switches(in: window).first)
                    XCTAssertFalse(updated.isOn, "External setting changes must reach the native control.")
                    XCTAssertFalse(updated.isEnabled)
                    XCTAssertEqual(model.writes, 1, "Rendering or disabling must not mutate the setting.")
                }
            }
        }
    }

    private struct Fixture: View {
        let model: Model
        let grouped: Bool

        var body: some View {
            SettingsPageList {
                if grouped {
                    SettingsSectionGroup {
                        Toggle("Native preference", isOn: model.binding)
                            .disabled(model.isDisabled)
                        if model.isOn {
                            Text("Additional settings")
                        }
                        Button("Separate action") {}
                    }
                } else {
                    Toggle("Native preference", isOn: model.binding)
                        .toggleStyle(SettingsSwitchToggleStyle())
                        .disabled(model.isDisabled)
                }
            }
        }
    }

    private func settle(_ window: UIWindow) async throws {
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
    }

    private func assertGreenOnState(
        _ control: UISwitch, in window: UIWindow,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let bounds = control.convert(control.bounds, to: window)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            context.cgContext.translateBy(x: -bounds.minX, y: -bounds.minY)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let cgImage = try XCTUnwrap(image.cgImage, file: file, line: line)
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), file: file, line: line)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let greenPixels = stride(from: 0, to: pixels.count, by: 4).filter {
            Int(pixels[$0 + 1]) > Int(pixels[$0]) + 35
                && Int(pixels[$0 + 1]) > Int(pixels[$0 + 2]) + 20
        }.count
        XCTAssertGreaterThan(
            Double(greenPixels) / Double(width * height), 0.08,
            "An enabled native switch must visibly remain green under the page's monochrome tint.",
            file: file, line: line
        )
    }

    private func switches(in view: UIView) -> [UISwitch] {
        (view as? UISwitch).map { [$0] } ?? view.subviews.flatMap { switches(in: $0) }
    }

    private func listedSwitches(in view: UIView) -> [UISwitch] {
        if let list = view as? UICollectionView {
            // List retains deleted rows in its reuse pool, outside the presented cells.
            return list.visibleCells.flatMap { switches(in: $0) }
        }
        return view.subviews.flatMap { listedSwitches(in: $0) }
    }

    private func captureText(_ window: UIWindow, name: String, technicalWords: [String] = []) throws -> String {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let cgImage = try XCTUnwrap(image.cgImage)
        func recognizedLines(in image: CGImage) throws -> [String] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.customWords = technicalWords
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        }
        var lines = try recognizedLines(in: cgImage)
        // Wide native rows can lose their trailing values when Vision downsamples the whole page.
        for y in stride(from: 0, to: cgImage.height, by: 1000) {
            for x in stride(from: 0, to: cgImage.width, by: 600) {
                let tile = try XCTUnwrap(cgImage.cropping(to: CGRect(
                    x: x, y: y, width: min(1200, cgImage.width - x), height: min(1200, cgImage.height - y)
                )))
                lines += try recognizedLines(in: tile)
            }
        }
        return lines.joined(separator: " ")
    }

    private func captureScrollableText(_ window: UIWindow, name: String) async throws -> String {
        func list(in view: UIView) -> UICollectionView? {
            if let list = view as? UICollectionView { return list }
            return view.subviews.lazy.compactMap { list(in: $0) }.first
        }
        let scroll = try XCTUnwrap(list(in: window))
        let original = scroll.contentOffset
        let top = try captureText(window, name: "\(name)-top")
        scroll.setContentOffset(CGPoint(
            x: original.x,
            y: max(-scroll.adjustedContentInset.top,
                   scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        ), animated: false)
        try await settle(window)
        let bottom = try captureText(window, name: "\(name)-bottom")
        scroll.setContentOffset(original, animated: false)
        try await settle(window)
        return top + " " + bottom
    }
}
#endif
