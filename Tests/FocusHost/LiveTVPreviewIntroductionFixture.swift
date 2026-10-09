import CoreModels
import CoreUI
import FeatureLiveTV
import FeatureLiveTVCore
import SwiftUI

struct LiveTVPreviewIntroductionFixture: View {
    @State private var previewStarted = false
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

    var body: some View {
        LiveTVPrototypeView(
            preferencesStore: PreviewIntroductionPreferences(),
            viewSettingsStore: store,
            sourceStore: PreviewIntroductionSources(),
            sourceLoader: PreviewIntroductionLoader(),
            profileID: profileID,
            preferencesNamespace: namespace,
            sourceApprovalContext: { approval }
        ) { _ in
            Color.black.onAppear { previewStarted = true }
        }
        .overlay(alignment: .topTrailing) {
            Text(verbatim: "\(settings.hasChosenAutoPreview ? (settings.autoPreview ? "chosen-on" : "chosen-off") : "unanswered"); playback=\(previewStarted)")
                .font(.caption2)
                .padding(12)
                .accessibilityIdentifier("preview-fixture-status")
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

private struct PreviewIntroductionPreferences: LiveTVPreferencesStoring {
    func load() throws -> LiveTVPreferences { .empty }
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
