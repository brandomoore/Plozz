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

    func testGroupedSettingsUseNativeSwitchesAndPreserveBindings() async throws {
        try await verifyNativeSwitch(grouped: true)
    }

    func testSharedSettingsStyleUsesNativeSwitchesOnMobile() async throws {
        try await verifyNativeSwitch(grouped: false)
    }

    func testSkipControlsRevealNativeConfigurationAndRetainProfileChoices() async throws {
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
            window.frame = CGRect(x: 0, y: 0, width: width, height: 1000)
            window.rootViewController = UIHostingController(rootView:
                List { SkipMarkerSettingsControl(model: model) }
                    .environment(\.themePalette, .dark)
                    .environment(\.colorScheme, .dark)
                    .environment(\.locale, Locale(identifier: "en_US"))
            )
            window.makeKeyAndVisible()
            try await settle(window)
            XCTAssertEqual(listedSwitches(in: window).count, 1)
            let master = try XCTUnwrap(listedSwitches(in: window).first)
            master.setOn(true, animated: false)
            master.sendActions(for: .valueChanged)
            try await settle(window)
            XCTAssertTrue(model.settings.skipMarkersEnabled)
            XCTAssertEqual(listedSwitches(in: window).count, 6)
            let automatic = try captureText(window, name: "skip-settings-automatic-\(Int(width))")
            for label in ["Enable skipping", "Behavior", "Skip automatically", "Skip after", "12 seconds",
                          "Movies", "TV Shows", "Anime", "Set each marker separately",
                          "Use community markers", "From IntroDB", "your server has none", "Shares"] {
                XCTAssertTrue(automatic.contains(label), "Missing \(label): \(automatic)")
            }
            XCTAssertFalse(automatic.contains("When your server has no intro or credits marker"), automatic)
            let stepper = try XCTUnwrap(firstStepper(in: window))
            stepper.value += stepper.stepValue
            stepper.sendActions(for: .valueChanged)
            try await settle(window)
            XCTAssertEqual(model.settings.skipAutomaticDelaySeconds, 13)
            XCTAssertEqual(store.load().skipAutomaticDelaySeconds, 13)
            model.settings.setSkipAutomaticDelay(29)
            try await settle(window)
            for _ in 0..<2 {
                stepper.value += stepper.stepValue
                stepper.sendActions(for: .valueChanged)
                try await settle(window)
                XCTAssertEqual(model.settings.skipAutomaticDelaySeconds, 30)
            }
            let categories = listedSwitches(in: window).sorted {
                $0.convert($0.bounds, to: window).minY < $1.convert($1.bounds, to: window).minY
            }
            let movies = try XCTUnwrap(categories.dropFirst().first)
            XCTAssertFalse(movies.isOn)
            movies.setOn(true, animated: false)
            movies.sendActions(for: .valueChanged)
            try await settle(window)
            XCTAssertEqual(model.settings.skipContentCategories, [.movie, .tvShow, .anime])
            movies.setOn(false, animated: false)
            movies.sendActions(for: .valueChanged)
            model.settings.setSkipAutomaticDelay(1)
            try await settle(window)
            for _ in 0..<2 {
                stepper.value -= stepper.stepValue
                stepper.sendActions(for: .valueChanged)
                try await settle(window)
                XCTAssertEqual(model.settings.skipAutomaticDelaySeconds, 0)
                XCTAssertEqual(model.settings.skipMarkerModes.mode(for: .intro), .autoInstant)
            }
            try await settle(window)
            XCTAssertTrue(try captureText(window, name: "skip-settings-immediate-\(Int(width))").contains("Immediately"))
            model.settings.setConfiguredSkipMode(.on)
            try await settle(window)
            let manual = try captureText(window, name: "skip-settings-manual-\(Int(width))")
            XCTAssertTrue(manual.contains("Show skip button"), manual)
            XCTAssertFalse(manual.contains("Skip after"), manual)
            model.settings.setSkipMarkersEnabled(false)
            try await settle(window)
            XCTAssertEqual(listedSwitches(in: window).count, 1)
            XCTAssertEqual(store.load().skipContentCategories, [.tvShow, .anime])
            XCTAssertEqual(store.load().skipAutomaticDelaySeconds, 0)
            XCTAssertEqual(PlaybackSettingsStore(defaults: defaults).load(), .default)
        }
    }

    private func firstStepper(in view: UIView) -> UIStepper? {
        if let stepper = view as? UIStepper { return stepper }
        return view.subviews.lazy.compactMap { self.firstStepper(in: $0) }.first
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
                for label in ["FEL", "experimental", "May impact performance.", "Disables spatial audio."] {
                    XCTAssertTrue(text.contains(label), "The setting and tradeoff must be visible: \(text)")
                }
                XCTAssertFalse(text.contains("Dolby Atmos"), text)
                XCTAssertFalse(text.contains("DTS:X"), text)
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
                .navigationTitle("Customize Home")
            }
            .environment(hero)
            .environment(background)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.colorScheme, .dark))
            window.makeKeyAndVisible()
            try await settle(window)
            let root = try captureText(window, name: "hero-root-mobile-\(Int(width))")
            for label in ["Hero content sources", "Hide watched content", "Items to show",
                          "Advance automatically", "Ratings", "Off", "Trailers"] {
                XCTAssertTrue(root.contains(label), root)
            }
            for label in ["Appearance", "Rotation", "Titles shown in hero", "Show ratings", "Seconds per item",
                          "Play trailer behind the hero", "Start muted"] {
                XCTAssertFalse(root.contains(label), root)
            }
            let controls = listedSwitches(in: window).sorted {
                $0.convert($0.bounds, to: window).minY < $1.convert($1.bounds, to: window).minY
            }
            XCTAssertEqual(controls.count, 3, "Only enable, watched, and automatic changes are switches on the root.")
            let automatic = try XCTUnwrap(controls.indices.contains(2) ? controls[2] : nil)
            automatic.setOn(true, animated: false)
            automatic.sendActions(for: .valueChanged)
            try await settle(window)
            XCTAssertTrue(hero.settings.autoAdvance)
            let advanced = try captureText(window, name: "hero-automatic-mobile-\(Int(width))")
            XCTAssertTrue(advanced.contains("Seconds per item"), advanced)
            XCTAssertFalse(advanced.localizedCaseInsensitiveContains("Automatic changes"), advanced)

            hero.settings.showsRatings = true
            background.settings.homeTrailerEnabled = true
            try await settle(window)
            let expanded = try captureText(window, name: "hero-expanded-mobile-\(Int(width))")
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
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.customWords = technicalWords
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}
#endif
