import CoreModels
import CoreUI
import FeatureLiveTV
import FeatureLiveTVCore
import SwiftUI
import UIKit
@testable import AppShell

struct LiveTVPreviewIntroductionFixture: View {
    @State private var previewStarted = false
    @State private var hidesNavigation = false
    @State private var nativeSelection = NavigationRailDestination.liveTV
    @State private var nativeHandoff = NavigationDestinationFocusHandoff()
    @State private var settings: LiveTVViewSettings
    private let store: LiveTVViewSettingsStore
    private let profileID: String
    private let namespace: String
    private let approval: LiveTVSourceApprovalContext

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let suite = String(arguments.first { $0.hasPrefix("--preview-suite=") }!
            .dropFirst("--preview-suite=".count))
        let defaults = UserDefaults(suiteName: suite)!
        if arguments.contains("--reset-preview-choice") { defaults.removePersistentDomain(forName: suite) }
        let profile = arguments.contains("--second-preview-profile") ? "second" : ProfileStore.defaultProfileID
        let store = LiveTVViewSettingsStore(
            defaults: defaults, namespace: profile == ProfileStore.defaultProfileID ? nil : profile
        )
        self.store = store
        profileID = profile
        approval = LiveTVSourceApprovalContext(
            profile: Profile(id: profile, name: "Fixture"), parentalPIN: nil, activeAccountIDs: []
        )
        namespace = suite + "." + profile
        _settings = State(initialValue: store.load())
    }

    @ViewBuilder
    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("--preview-native-sidebar") {
            TabView(selection: Binding(get: { nativeSelection }, set: { destination in
                if destination != nativeSelection { nativeHandoff.begin(destination) }
                nativeSelection = destination
            })) {
                ForEach(nativeDestinations, id: \.destination) { entry in
                    Tab(value: entry.destination) {
                        AnyView(NativeSidebarFocusDestination(
                            destination: entry.destination, selection: nativeSelection,
                            handoff: nativeHandoff,
                            content: nativeContent(for: entry.destination)
                        ).tvNavigationExitProtectionContent())
                    } label: {
                        AnyView(Label(entry.title, systemImage: entry.symbol))
                    }
                }
            }
            .tabViewStyle(.sidebarAdaptable)
            .tvNavigationExitProtection(isEnabled: true)
            .environment(\.layoutDirection, ProcessInfo.processInfo.arguments.contains("--preview-rtl")
                ? .rightToLeft : .leftToRight)
            .onDisappear { nativeHandoff.cancel() }
        } else {
            liveTV
        }
    }

    private var nativeDestinations: [(destination: NavigationRailDestination, title: String, symbol: String)] {
        [
            (.library("profile"), "Fixture profile", "person.crop.circle"),
            (.home, "Home", "house"),
            (.liveTV, "Live TV", "tv"),
            (.search, "Search", "magnifyingglass"),
            (.allLibraries, "All Libraries", "rectangle.stack"),
            (.library("movies"), "Movies", "film"),
            (.library("shows"), "TV Shows", "tv"),
            (.settings, "Settings", "gearshape")
        ]
    }

    @ViewBuilder
    private func nativeContent(for destination: NavigationRailDestination) -> some View {
        if destination == .liveTV {
            LiveTVNavigationContainer(hidesNavigation: hidesNavigation) { liveTV }
        } else {
            Button("Fixture destination") {}
        }
    }

    private var liveTV: some View {
        LiveTVPrototypeView(
            usesNativeFullscreen: ProcessInfo.processInfo.arguments.contains("--preview-native-sidebar"),
            preferencesStore: PreviewIntroductionPreferences(),
            viewSettingsStore: store,
            sourceStore: PreviewIntroductionSources(),
            onExpandedChange: { hidesNavigation = $0 },
            sourceLoader: PreviewIntroductionLoader(),
            profileID: profileID,
            preferencesNamespace: namespace,
            sourceApprovalContext: { approval }
        ) { _ in
            Color.black.onAppear { previewStarted = true }
        }
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing) {
                Text(verbatim: "\(settings.hasChosenAutoPreview ? (settings.autoPreview ? "chosen-on" : "chosen-off") : "unanswered"); playback=\(previewStarted)")
                    .accessibilityIdentifier("preview-fixture-status")
                NativeSidebarFocusVisits()
            }
            .font(.caption2)
            .padding(12)
        }
        .onReceive(NotificationCenter.default.publisher(for: LiveTVViewSettingsStore.didChange)) { _ in
            settings = store.load()
        }
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark)
        .environment(\.layoutDirection, ProcessInfo.processInfo.arguments.contains("--preview-rtl")
            ? .rightToLeft : .leftToRight)
    }
}

private struct NativeSidebarFocusVisits: View {
    @State private var count = 0

    var body: some View {
        // Diagnostics must not invalidate the TabView that owns the focus transition.
        Text(verbatim: "\(count)")
            .accessibilityIdentifier("preview-native-focus-visits")
            .onReceive(NotificationCenter.default.publisher(for: UIFocusSystem.didUpdateNotification)) { notification in
                guard let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey]
                    as? UIFocusUpdateContext else { return }
                // Guide cells cannot focus; only the native tab sidebar owns focusable cells.
                if context.nextFocusedItem is UICollectionViewCell { count += 1 }
            }
    }
}

private struct PreviewIntroductionPreferences: LiveTVPreferencesStoring {
    func load() throws -> LiveTVPreferences {
        guard ProcessInfo.processInfo.arguments.contains("--preview-saved-multiviews") else { return .empty }
        return LiveTVPreferences(favoriteMultiviews: (1...8).map { index in
            LiveTVMultiviewFavorite(
                id: "fixture-\(index)",
                name: index == 2 ? "Weekend sports and international highlights" : "Saved Multiview \(index)",
                channelIDs: ["channels-1", "channels-2"], layout: .sideBySide
            )
        })
    }
    func save(_ preferences: LiveTVPreferences) throws {}
}

private struct PreviewIntroductionSources: LiveTVSourcesStoring {
    func load() throws -> LiveTVSourcesConfiguration {
        LiveTVSourcesConfiguration(playlists: [
            LiveTVPlaylistSource(
                id: "preview-fixture", name: "Fixture",
                playlistURL: URL(string: "https://fixture.invalid/list.m3u")!
            )
        ])
    }
    func save(_ configuration: LiveTVSourcesConfiguration) throws {}
}

private struct PreviewIntroductionLoader: LiveTVSourceLoading {
    func loadPlaylist(from url: URL) async throws -> LiveTVPlaylistImport {
        try LiveTVPlaylistParser(baseURL: url).parse("""
        #EXTM3U
        #EXTINF:-1 tvg-id="first" group-title="Entertainment & Lifestyle",Fixture channel one
        https://fixture.invalid/one.m3u8
        #EXTINF:-1 tvg-id="second" group-title="United Kingdom & Ireland",Fixture channel two
        https://fixture.invalid/two.m3u8
        """)
    }
    func loadGuide(
        from url: URL, channels: [LiveTVPrototypeChannel], now: Date
    ) async throws -> LiveTVGuideImport {
        throw LiveTVSourceImportError.invalidGuide
    }
}
