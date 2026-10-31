import CoreModels
import CoreUI
import FeatureProfiles
import Observation
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import FeatureSettings

@MainActor
final class PlaybackSettingsHostedTests: XCTestCase {
    func testProfileSettingsKeepAutomaticSignInSeparateFromProfiles() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let model = ProfileSettingsControlModel()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView:
            ProfileSettingsControlFixture(model: model)
                .environment(\.themePalette, .dark)
                .environment(\.locale, Locale(identifier: "en_US"))
                .frame(width: SettingsFormMetrics.pageWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(350))
        let automatic = try visibleText(in: window, attachment: "profile-settings-sign-in-off")
        for label in ["Automatically Sign In", "Alex", "Family", "Add Profile"] {
            XCTAssertTrue(automatic.contains(label), automatic)
        }
        for removed in ["Show Profiles on Return", "Each profile keeps", "Sign in to the last-used", "Open players are unaffected"] {
            XCTAssertFalse(automatic.contains(removed), automatic)
        }
        XCTAssertNotNil(UIFocusSystem.focusSystem(for: window)?.focusedItem)
        let frames = profileFocusFrames(in: window)
        XCTAssertEqual(frames.count, 4, "Only automatic sign-in, two profiles, and Add Profile remain focusable.")
        let signIn = try XCTUnwrap(frames.first)
        let firstProfile = try XCTUnwrap(frames.dropFirst().first)
        let addProfile = try XCTUnwrap(frames.last)
        let expectedHeight = SettingsRowMetrics.minHeight(.primary)
            + 2 * SettingsRowMetrics.verticalPadding(.primary)
        for frame in [signIn, addProfile] {
            XCTAssertEqual(frame.height, expectedHeight, accuracy: 1)
            XCTAssertEqual(frame.minX, signIn.minX, accuracy: 1)
            XCTAssertEqual(frame.width, signIn.width, accuracy: 1)
        }
        XCTAssertEqual(
            firstProfile.minY - signIn.maxY,
            2 * SettingsFormMetrics.groupInset + SettingsFormMetrics.sectionSpacing,
            accuracy: 1,
            "Automatic sign-in stays in its own standard section above the profile list."
        )
        model.automaticallySignIn = true
        try await Task.sleep(for: .milliseconds(200))
        let enabled = try visibleText(in: window, attachment: "profile-settings-sign-in-on")
        XCTAssertTrue(enabled.contains("On"), enabled)
        XCTAssertFalse(enabled.contains("Show Profiles on Return"), enabled)
        XCTAssertEqual(profileFocusFrames(in: window).count, 4)
        model.automaticallySignIn = false
        try await Task.sleep(for: .milliseconds(200))
        let disabled = try visibleText(in: window, attachment: "profile-settings-sign-in-off-again")
        XCTAssertTrue(disabled.contains("Off"), disabled)
        XCTAssertFalse(disabled.contains("Show Profiles on Return"), disabled)
        XCTAssertEqual(profileFocusFrames(in: window).count, 4)
        model.signInError = "Could not save automatic sign-in."
        try await Task.sleep(for: .milliseconds(200))
        let error = try visibleText(in: window, attachment: "profile-settings-sign-in-error")
        XCTAssertTrue(error.contains("Could not save automatic sign-in"), error)
    }

    func testAudioOutputSettingsShareOneGroup() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let suite = "audio-output-settings-hosted-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let playback = PlaybackSettingsModel(store: PlaybackSettingsStore(defaults: defaults))
        let page = PlaybackDetailView(
            playback: playback,
            subtitleBehavior: SubtitleBehaviorModel(store: SubtitleBehaviorStore(defaults: defaults)),
            subtitleStyle: SubtitleStyleModel(store: SubtitleStyleStore(defaults: defaults)),
            subtitlePolicy: SubtitlePolicyModel(store: SubtitlePolicyStore(defaults: defaults)),
            audioPolicy: AudioPolicyModel(store: AudioPolicyStore(defaults: defaults))
        )
        XCTAssertEqual(page.audioRows.map(\.id), ["audio-defaults", "lossless-surround"])
        let outputRow = try XCTUnwrap(page.audioRows.first { $0.id == "lossless-surround" })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView:
            SettingsFormLayout(title: Text("Playback"), rows: [outputRow])
                .environment(\.themePalette, .dark)
                .environment(\.locale, Locale(identifier: "en_US"))
                .frame(width: SettingsFormMetrics.pageWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        try await Task.sleep(for: .milliseconds(400))
        let text = try visibleText(in: window, attachment: "Playback-audio-output-group")
        for label in ["Prefer lossless audio", "regular HDMI ARC", "compressed audio"] {
            XCTAssertTrue(text.contains(label), text)
        }
        if #available(tvOS 26.0, *) {
            for label in ["Spatial audio", "height channel support", "TrueHD Atmos",
                          "DTS:X", "PCM", "AirPlay", "lossy"] {
                XCTAssertTrue(text.contains(label), text)
            }
        } else {
            XCTAssertFalse(text.contains("Spatial audio"), text)
        }
    }

    func testSkipMarkerPagesShowEveryKindAndIndependentContentTiming() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let suite = "SkipSettingsTV-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let playback = PlaybackSettingsModel(store: PlaybackSettingsStore(defaults: defaults))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView:
            SkipMarkerSettingsView(model: playback)
            .frame(width: SettingsFormMetrics.pageWidth)
            .toggleStyle(SettingsSwitchToggleStyle())
            .environment(\.themePalette, .dark)
            .environment(\.locale, Locale(identifier: "en_US"))
            .background(.black)
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        try await Task.sleep(for: .milliseconds(400))
        let manual = try visibleText(in: window, attachment: "skip-settings-TV-manual")
        XCTAssertTrue(manual.contains("Default behavior"), manual)
        XCTAssertTrue(manual.contains("Show skip button"), manual)
        XCTAssertFalse(manual.contains("Skip after"), manual)
        for label in ["Intros, credits & more", "Movies", "TV Shows", "Anime"] {
            XCTAssertTrue(manual.contains(label), manual)
        }
        XCTAssertFalse(manual.contains("Set each marker separately"), manual)
        let page = try await allPageText(in: window, attachment: "skip-marker-page-TV")
        for label in ["Intros", "Credits", "Recaps", "Previews", "Commercials",
                      "Use community markers", "From IntroDB", "Shares"] {
            XCTAssertTrue(page.contains(label), page)
        }
        for kind in MediaSegment.Kind.skippable {
            playback.settings.setConfiguredSkipMode(.autoDelay, for: kind, category: .movie)
            playback.settings.setSkipAutomaticDelay(30, for: kind, category: .movie)
            playback.settings.setConfiguredSkipMode(.off, for: kind, category: .anime)
            window.rootViewController = UIHostingController(rootView:
                SkipMarkerContentSettingsView(model: playback, kind: kind)
                    .frame(width: SettingsFormMetrics.pageWidth)
                    .environment(\.themePalette, .dark)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .background(.black)
            )
            try await Task.sleep(for: .milliseconds(200))
            let automatic = try visibleText(in: window, attachment: "skip-\(kind.rawValue)-TV-content")
            for label in ["Movies", "TV Shows", "Anime", "Show skip button (default)",
                          "Skip after", "30 seconds", "Off"] {
                XCTAssertTrue(automatic.localizedCaseInsensitiveContains(label), automatic)
            }
            let movie = SkipMarkerRuleControls(model: playback, scope: .content(kind, .movie))
            movie.behavior.wrappedValue = .instant
            try await Task.sleep(for: .milliseconds(100))
            let immediate = try visibleText(in: window, attachment: "skip-\(kind.rawValue)-TV-immediate")
            XCTAssertTrue(immediate.contains("Skip instantly"), immediate)
            XCTAssertFalse(immediate.contains("Skip after"), immediate)
            XCTAssertEqual(playback.settings.configuredSkipMode(for: kind, category: .tvShow), .on)
            XCTAssertEqual(playback.settings.configuredSkipDelay(for: kind, category: .tvShow), 5)
            XCTAssertEqual(playback.settings.configuredSkipMode(for: kind, category: .anime), .off)
        }
    }

    func testSharedSkipDefaultAndAnimeExceptionUseTheSamePickerBindings() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let suite = "SkipDefaultTV-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = PlaybackSettingsStore(defaults: defaults, namespace: "viewer")
        let playback = PlaybackSettingsModel(store: store)
        let shared = SkipMarkerRuleControls(model: playback, scope: .defaultBehavior)
        let anime = SkipMarkerRuleControls(model: playback, scope: .content(.intro, .anime))
        XCTAssertEqual(shared.behaviors, [.manual, .instant, .delayed])
        XCTAssertEqual(anime.behaviors, [.useDefault, .manual, .instant, .delayed, .off])
        shared.behavior.wrappedValue = .off
        XCTAssertEqual(shared.behaviors, [.manual, .instant, .delayed, .off])
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView:
            SkipMarkerSettingsView(model: playback)
                .frame(width: SettingsFormMetrics.pageWidth)
                .environment(\.themePalette, .dark)
                .environment(\.locale, Locale(identifier: "en_US"))
                .background(.black)
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        shared.behavior.wrappedValue = .instant
        try await Task.sleep(for: .milliseconds(300))
        let instant = try visibleText(in: window, attachment: "skip-default-TV-instant")
        XCTAssertTrue(instant.contains("Default behavior"), instant)
        XCTAssertTrue(instant.contains("Skip instantly"), instant)
        XCTAssertFalse(instant.contains("Skip after"), instant)
        for category in [ContentCategory.movie, .tvShow, .anime] {
            for kind in MediaSegment.Kind.skippable {
                XCTAssertEqual(store.load().skipMarkerModes(for: category).mode(for: kind), .autoInstant)
            }
        }
        anime.behavior.wrappedValue = .manual
        window.rootViewController = UIHostingController(rootView:
            SkipMarkerContentSettingsView(model: playback, kind: .intro)
                .frame(width: SettingsFormMetrics.pageWidth)
                .environment(\.themePalette, .dark)
                .environment(\.locale, Locale(identifier: "en_US"))
                .background(.black)
        )
        try await Task.sleep(for: .milliseconds(300))
        let exception = try visibleText(in: window, attachment: "skip-default-TV-anime-exception")
        for label in ["Movies", "TV Shows", "Anime", "Skip instantly (default)", "Show skip button"] {
            XCTAssertTrue(exception.contains(label), exception)
        }
        XCTAssertFalse(exception.contains("Default:"), exception)
        XCTAssertFalse(exception.contains("Use default"), exception)
        shared.behavior.wrappedValue = .delayed
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(store.load().skipMarkerModes(for: .movie).delay(for: .intro), 5)
        XCTAssertEqual(anime.behavior.wrappedValue, .manual)
        anime.behavior.wrappedValue = .useDefault
        try await Task.sleep(for: .milliseconds(200))
        let inherited = try visibleText(in: window, attachment: "skip-default-TV-inherited")
        XCTAssertTrue(inherited.contains("Skip after 5 seconds (default)"), inherited)
        XCTAssertFalse(inherited.contains("Show skip button"), inherited)
        XCTAssertTrue(store.load().skipMarkerRules.isEmpty)
        shared.behavior.wrappedValue = .instant
        XCTAssertEqual(anime.behavior.wrappedValue, .useDefault)
        XCTAssertEqual(store.load().skipMarkerModes(for: .anime).mode(for: .intro), .autoInstant)
        XCTAssertEqual(PlaybackSettingsStore(defaults: defaults).load(), .default)
    }

    func testAdvancedPlaybackShowsFELControlAndAudioTradeoff() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let suite = "FELSettingsHosted-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let playback = PlaybackSettingsModel(store: PlaybackSettingsStore(defaults: defaults, namespace: "guest"))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView:
            PlaybackAdvancedSettingsView(
                playback: playback, model: ExternalPlayerSettingsModel(defaults: defaults)
            )
            .environment(\.settingsInWorkspace, true)
            .environment(\.themePalette, .dark)
            .environment(\.locale, Locale(identifier: "en_US"))
            .frame(width: SettingsFormMetrics.pageWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        try await Task.sleep(for: .milliseconds(400))
        let text = try visibleText(in: window, attachment: "FEL advanced playback setting")
        for label in ["FEL", "experimental", "May impact performance."] {
            XCTAssertTrue(text.contains(label), "The setting and tradeoff must be visible: \(text)")
        }
        if #available(tvOS 26.0, *) {
            XCTAssertFalse(text.contains("Disables spatial audio."), text)
            let page = try await allPageText(in: window, attachment: "Advanced-spatial-layout")
            for label in ["Rendering layout", "9.1.6", "DTS:X heights require 7.1.4 or 9.1.6."] {
                XCTAssertTrue(page.contains(label), page)
            }
        } else {
            XCTAssertTrue(text.contains("Disables spatial audio."), text)
            XCTAssertFalse(text.contains("DTS:X"), text)
        }
        XCTAssertFalse(text.contains("Dolby Atmos"), text)
        XCTAssertFalse(playback.settings.dolbyVisionFELEnabled)
    }

    func testSpatialLayoutControlUpdatesFromDeviceStoreAndFitsLargeText() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let suite = "SpatialLayoutHosted-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = SpatialAudioLayoutStore(defaults: defaults)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        for (size, typeSize): (CGSize, DynamicTypeSize) in [
            (.init(width: 1100, height: 440), .large),
            (.init(width: 760, height: 700), .accessibility3)
        ] {
            window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = UIHostingController(rootView:
                SpatialAudioLayoutControl(defaults: defaults)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .environment(\.dynamicTypeSize, typeSize)
                    .environment(\.themePalette, .dark)
                    .environment(\.colorScheme, .dark)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .background(.black)
            )
            window.makeKeyAndVisible()
            for layout in SpatialAudioLayout.allCases {
                store.save(layout)
                try await Task.sleep(for: .milliseconds(200))
                try await waitForHostedLayout(window)
                let text = try visibleText(in: window, attachment: "Spatial-layout-\(layout.rawValue)-\(typeSize)")
                let normalizedText = text.replacingOccurrences(of: ": ", with: ":")
                for label in ["Rendering layout", "Applies to this device.",
                              "DTS:X heights require 7.1.4 or 9.1.6."] {
                    XCTAssertTrue(normalizedText.contains(label), text)
                }
                let controlFrames = self.profileFocusFrames(in: window)
                XCTAssertEqual(controlFrames.count, 1)
                let frame = try XCTUnwrap(controlFrames.first)
                XCTAssertTrue(window.bounds.contains(frame))
                let valueText = try visibleText(
                    in: window, attachment: "Spatial-layout-value-\(layout.rawValue)-\(typeSize)",
                    crop: CGRect(x: frame.minX + frame.width * 0.65, y: frame.minY,
                                 width: frame.width * 0.35, height: frame.height)
                )
                XCTAssertTrue(valueText.contains(layout.rawValue), valueText)
                XCTAssertFalse(text.contains("…"), text)
                XCTAssertEqual(store.load(), layout)
            }
        }
    }

    func testLibrarySourcesShowConfiguredNamesAndUpdateWithProfileSelection() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let fixtures: [(String, String, ProviderKind)] = [
            ("plex", "Family Plex", .plex), ("jellyfin", "Cinema Server", .jellyfin),
            ("share", "Archive NAS", .mediaShare), ("silo", "Weekend Silo", .silo),
            ("emby", "Family Emby", .emby)
        ]
        let accounts = fixtures.map { id, name, provider in
            Account(
                id: id, server: MediaServer(
                    id: id, name: name,
                    baseURL: URL(string: "\(provider == .mediaShare ? "smb" : "https")://\(id).example/Media")!,
                    provider: provider
                ), userID: "viewer", userName: "Viewer", deviceID: "test"
            )
        }
        let selection = LibrarySourceSelection(includedIDs: Set(accounts.map(\.id)))
        var rootRenders = 0
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView:
            LibrarySummaryHost(accounts: accounts, selection: selection) {
                rootRenders += 1
            }
            .environment(SettingsNavigationModel())
            .environment(\.themePalette, .dark)
            .environment(\.locale, Locale(identifier: "en_US"))
            .frame(width: SettingsFormMetrics.pageWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(400))
        let initialRenders = rootRenders
        XCTAssertGreaterThan(initialRenders, 0)
        for included: Set<String> in [Set(accounts.map(\.id)), ["silo", "emby"], []] {
            selection.includedIDs = included
            try await Task.sleep(for: .milliseconds(200))
            let text = try visibleText(in: window, attachment: "settings-library-sources-\(included.count)")
            XCTAssertTrue(text.contains("Libraries"), text)
            let visibleNames = Array(fixtures.filter { included.contains($0.0) }.prefix(3)).map(\.1)
            for (_, name, _) in fixtures {
                XCTAssertEqual(text.contains(name), visibleNames.contains(name), text)
            }
            XCTAssertEqual(text.replacingOccurrences(of: " ", with: "").contains("+2more"),
                           included.count == 5, text)
            XCTAssertEqual(text.contains("Choose what to watch"), included.isEmpty, text)
            XCTAssertEqual(rootRenders, initialRenders, "Source selection must update only the Libraries row.")
        }
    }

    func testPlaybackShowsOnlySkipToggleAndConditionalSettingsLink() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let suite = "playback-settings-hosted-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let playback = PlaybackSettingsModel(store: PlaybackSettingsStore(defaults: defaults))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView:
            PlaybackDetailView(
                playback: playback,
                subtitleBehavior: SubtitleBehaviorModel(store: SubtitleBehaviorStore(defaults: defaults)),
                subtitleStyle: SubtitleStyleModel(store: SubtitleStyleStore(defaults: defaults)),
                subtitlePolicy: SubtitlePolicyModel(store: SubtitlePolicyStore(defaults: defaults)),
                audioPolicy: AudioPolicyModel(store: AudioPolicyStore(defaults: defaults))
            )
            .environment(\.settingsInWorkspace, true)
            .environment(\.themePalette, .dark)
            .environment(\.locale, Locale(identifier: "en_US"))
            .frame(width: SettingsFormMetrics.pageWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        try await Task.sleep(for: .milliseconds(400))
        window.layoutIfNeeded()
        let scroll = try XCTUnwrap(scrollView(in: window))
        for enabled in [false, true] {
            playback.settings.setSkipMarkersEnabled(enabled)
            try await Task.sleep(for: .milliseconds(400))
            let top = -scroll.adjustedContentInset.top
            let bottom = max(top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            var visible = ""
            for offset in stride(from: top, through: bottom + 540, by: 540) {
                scroll.setContentOffset(CGPoint(x: 0, y: min(offset, bottom)), animated: false)
                try await Task.sleep(for: .milliseconds(100))
                window.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
                let page = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                visible += " " + page
                if page.contains("Skip intros, credits")
                    || page.contains("Version selection") || page.contains("Video buffer")
                    || page.contains("Live TV buffer") || page.contains("Autoplay")
                    || page.contains("Preferred audio language") {
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "Playback-skip-enabled-\(enabled)-\(Int(offset))"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
                if offset >= bottom { break }
            }
            for label in [
                "Version selection", "Choose on first play", "Ask every time", "Choose automatically",
                "Remember series version choices",
                "Remember audio language per series",
                "Autoplay next episode", "Autoplay next playlist item",
                "Show Up Next card", "Time before the end",
                "Skip intros, credits & more",
                "Video buffer", "Live TV buffer", "Automatic", "temporary storage",
                "adds live delay", "Spatial audio", "height channel support",
                "TrueHD Atmos", "DTS:X", "PCM", "AirPlay", "lossy"
            ] {
                XCTAssertTrue(visible.contains(label), "Missing inline control \(label): \(visible)")
            }
            for option in ["1 minute", "5 minutes", "10 minutes", "Maximum available", "45 seconds"] {
                XCTAssertFalse(visible.contains(option), "Buffer choices must stay inside their menus: \(visible)")
            }
            XCTAssertFalse(visible.contains("Turn off if playback stutters"), visible)
            XCTAssertFalse(visible.contains("Applies to new playback sessions"), visible)
            XCTAssertFalse(visible.contains("How Plozz picks the audio language"), visible)
            XCTAssertFalse(visible.contains("The next episode starts when one finishes"), visible)
            XCTAssertFalse(visible.contains("The player closes when an episode finishes"), visible)
            XCTAssertFalse(visible.contains("Show a Skip button, or skip automatically"), visible)
            XCTAssertFalse(visible.contains("When your server has no intro or credits marker"), visible)
            XCTAssertTrue(playback.settings.trueHDAtmosEnabled)
            XCTAssertEqual(visible.contains("Customize"), enabled, visible)
            XCTAssertFalse(visible.contains("Skip markers"), visible)
            for label in ["Set each marker separately", "Use community markers", "Show skip button",
                          "Skip after", "Intros", "Credits", "Recaps", "Previews", "Commercials"] {
                XCTAssertFalse(visible.contains(label), "Customization belongs on the child page: \(visible)")
            }
        }
        playback.settings.autoPlayNextEpisode = false
        for showCard in [false, true] {
            playback.settings.showUpNextCard = showCard
            scroll.setContentOffset(CGPoint(x: 0, y: 540 - scroll.adjustedContentInset.top), animated: false)
            try await Task.sleep(for: .milliseconds(300))
            let text = try visibleText(in: window, attachment: "Playback-Up-Next-card-\(showCard)-autoplay-off")
            XCTAssertTrue(text.contains("Autoplay next episode"), text)
            XCTAssertTrue(text.contains("Show Up Next card"), text)
            XCTAssertEqual(text.contains("Time before the end"), showCard, text)
            XCTAssertFalse(playback.settings.autoPlayNextEpisode, "Showing the card must not enable autoplay.")
        }
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }

    private func allPageText(in window: UIWindow, attachment name: String) async throws -> String {
        let scroll = try XCTUnwrap(scrollView(in: window))
        let top = -scroll.adjustedContentInset.top
        let bottom = max(top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        var text = ""
        for offset in stride(from: top, through: bottom + 540, by: 540) {
            scroll.setContentOffset(CGPoint(x: 0, y: min(offset, bottom)), animated: false)
            try await Task.sleep(for: .milliseconds(100))
            text += " " + (try visibleText(in: window, attachment: "\(name)-\(Int(offset))"))
            if offset >= bottom { break }
        }
        return text
    }

    private func profileFocusFrames(in window: UIWindow) -> [CGRect] {
        var containers: [any UIFocusItemContainer] = [window]
        var visited = Set<ObjectIdentifier>()
        var items: [ObjectIdentifier: any UIFocusItem] = [:]
        while let container = containers.popLast() {
            guard visited.insert(ObjectIdentifier(container)).inserted else { continue }
            for item in container.focusItems(in: container.coordinateSpace.convert(window.bounds, from: window)) {
                if let child = item.focusItemContainer { containers.append(child) }
                if let view = item as? UIView { containers.append(view) }
                if item.canBecomeFocused, !(item is UIScrollView) { items[ObjectIdentifier(item)] = item }
            }
        }
        return items.values.compactMap { item in
            var environment: (any UIFocusEnvironment)? = item
            while let current = environment {
                if let container = current.focusItemContainer {
                    return container.coordinateSpace.convert(item.frame, to: window)
                }
                environment = current.parentFocusEnvironment
            }
            XCTFail("The profile control must have a native focus coordinate space.")
            return nil
        }.sorted { $0.minY < $1.minY }
    }

    private func visibleText(in window: UIWindow, attachment name: String, crop: CGRect? = nil) throws -> String {
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        if crop != nil { format.scale = 2 }
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        // Character recognition avoids prose-model corrections to numeric layouts.
        request.recognitionLevel = crop == nil ? .accurate : .fast
        request.usesLanguageCorrection = crop == nil
        request.recognitionLanguages = ["en-US"]
        var recognizedImage = try XCTUnwrap(image.cgImage)
        if let crop {
            let scale = CGFloat(recognizedImage.width) / window.bounds.width
            recognizedImage = try XCTUnwrap(recognizedImage.cropping(to: CGRect(
                x: crop.minX * scale, y: crop.minY * scale,
                width: crop.width * scale, height: crop.height * scale
            ).integral))
        }
        try VNImageRequestHandler(cgImage: recognizedImage).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}

@MainActor @Observable
final class ProfileSettingsControlModel {
    var automaticallySignIn = false
    var signInError: LocalizedStringResource?
}

private struct ProfileSettingsControlFixture: View {
    var model: ProfileSettingsControlModel

    var body: some View {
        NavigationStack {
            ProfileSettingsContent(
                profiles: [
                    Profile(id: "alex", name: "Alex"),
                    Profile(id: "family", name: "Family", avatarSymbol: "person.2.fill", colorIndex: 1)
                ],
                activeProfileID: "alex",
                automaticSignIn: AutomaticSignInSettings(
                    isEnabled: Binding(
                        get: { model.automaticallySignIn },
                        set: { model.automaticallySignIn = $0 }
                    ),
                    error: model.signInError
                ),
                onAddProfile: {}
            )
            .navigationDestination(for: SettingsRoute.self) { _ in
                Text("Profile settings")
            }
        }
    }
}

private struct LibrarySummaryHost: View {
    let accounts: [Account]
    let selection: LibrarySourceSelection
    let onRender: () -> Void

    var body: some View {
        let _ = onRender()
        SettingsLibrariesRow(
            accounts: accounts,
            isAccountIncluded: { selection.includedIDs.contains($0) }
        )
    }
}

@MainActor @Observable
private final class LibrarySourceSelection {
    var includedIDs: Set<String>

    init(includedIDs: Set<String>) {
        self.includedIDs = includedIDs
    }
}
