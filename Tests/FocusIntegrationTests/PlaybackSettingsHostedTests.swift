import CoreModels
import CoreUI
import Observation
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import FeatureSettings

@MainActor
final class PlaybackSettingsHostedTests: XCTestCase {
    func testSkipControlsRevealAutomaticTimingAndHideConfigurationWhenDisabled() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let suite = "SkipSettingsTV-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let playback = PlaybackSettingsModel(store: PlaybackSettingsStore(defaults: defaults))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView:
            ScrollView {
                SkipMarkerSettingsControl(model: playback)
                    .frame(width: SettingsFormMetrics.pageWidth)
                    .padding(40)
            }
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
        XCTAssertTrue(manual.contains("Show skip button"), manual)
        XCTAssertFalse(manual.contains("Skip after"), manual)
        for label in ["Enable skipping", "Movies", "TV Shows", "Anime"] {
            XCTAssertTrue(manual.contains(label), manual)
        }
        playback.settings.setConfiguredSkipMode(.autoDelay)
        playback.settings.setSkipAutomaticDelay(30)
        try await Task.sleep(for: .milliseconds(200))
        let automatic = try visibleText(in: window, attachment: "skip-settings-TV-automatic")
        XCTAssertTrue(automatic.contains("Skip automatically"), automatic)
        XCTAssertTrue(automatic.contains("Skip after"), automatic)
        XCTAssertTrue(automatic.contains("30 seconds"), automatic)
        playback.settings.setSkipAutomaticDelay(0)
        try await Task.sleep(for: .milliseconds(500))
        let immediate = try visibleText(in: window, attachment: "skip-settings-TV-immediate")
        XCTAssertTrue(immediate.contains("Immediately"), immediate)
        playback.settings.setSkipMarkersEnabled(false)
        try await Task.sleep(for: .milliseconds(200))
        let disabled = try visibleText(in: window, attachment: "skip-settings-TV-disabled")
        XCTAssertTrue(disabled.contains("Enable skipping"), disabled)
        for label in ["Behavior", "Skip after", "Movies", "Set each marker separately", "Use community markers"] {
            XCTAssertFalse(disabled.contains(label), disabled)
        }
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
        } else {
            XCTAssertTrue(text.contains("Disables spatial audio."), text)
        }
        XCTAssertFalse(text.contains("Dolby Atmos"), text)
        XCTAssertFalse(text.contains("DTS:X"), text)
        XCTAssertFalse(playback.settings.dolbyVisionFELEnabled)
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

    func testSkipMarkerControlsAreInlineOnPlaybackPage() async throws {
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
        for separate in [false, true] {
            if separate {
                playback.settings.skipModeOverrides = Dictionary(
                    uniqueKeysWithValues: MediaSegment.Kind.skippable.map { ($0, .on) }
                )
                try await Task.sleep(for: .milliseconds(400))
            }
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
                if page.contains("Skip intros") || page.contains("Use community markers")
                    || page.contains("Version selection") || page.contains("Video buffer")
                    || page.contains("Live TV buffer") || page.contains("Autoplay")
                    || page.contains("Preferred audio language") {
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "Playback-inline-skip-separate-\(separate)-\(Int(offset))"
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
                "Skip intros, credits", "Enable skipping", "Movies", "TV Shows", "Anime",
                "Show skip button", "Set each marker separately", "Use community markers",
                "From IntroDB", "your server has none", "Shares",
                "Video buffer", "Live TV buffer", "Automatic", "temporary storage",
                "adds live delay", "Spatial audio", "height channel support",
                "TrueHD Atmos", "DTS:X", "Apple spatial audio", "lossy"
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
            if separate {
                for label in ["Intros", "Credits", "Recaps", "Previews", "Commercials"] {
                    XCTAssertTrue(visible.contains(label), "Missing inline per-kind control \(label)")
                }
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

    private func visibleText(in window: UIWindow, attachment name: String) throws -> String {
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
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
