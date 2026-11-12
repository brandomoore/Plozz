import CoreModels
import CoreNetworking
import CoreUI
import FeatureHome
import FeatureHomeCore
import ProviderJellyfin
import ProviderPlex
import SwiftUI

/// Opt-in real-provider verification. The local broker supplies credentials in
/// memory; production refresh timing, views, and provider caches stay unchanged.
struct LiveContentRefreshFixture: View {
    @State private var content: LiveRefreshContent?
    @State private var failed = false
    @State private var coordinator = ContentRefreshCoordinator(profile: .tvOS)
    @State private var trailer = HeroTrailerController()
    @State private var heroRuntime = HomeHeroRuntimeState()
    @State private var background = HeroBackgroundSettingsModel(store: InMemoryHeroBackgroundSettingsStore(
        HeroBackgroundSettings(homeTrailerEnabled: false, detailMode: .off)
    ))

    var body: some View {
        NavigationStack {
            if let content {
                Group {
                    if content.scope == "home" {
                        HomeView(
                            viewModel: content.home, visibility: content.visibility,
                            heroBackground: background, heroTrailerController: trailer,
                            heroIsFrontmost: true, heroRuntime: heroRuntime,
                            onSelectItem: { _ in }, onPlayItem: { _ in },
                            onSelectLibrary: { _ in }, onBrowse: { _ in }
                        )
                    } else {
                        ItemDetailView(viewModel: content.detail, onPlay: { _ in }, onSelectChild: { _ in })
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Text(content.status)
                        .accessibilityIdentifier("live-refresh-status")
                        .allowsHitTesting(false)
                }
            } else {
                Text(failed ? "Live refresh setup failed" : "Preparing live refresh")
            }
        }
        .environment(coordinator)
        .environment(trailer)
        .environment(background)
        .environment(\.themePalette, .dark)
        .environment(\.locale, Locale(identifier: "en_US"))
        .background(ContentRefreshLifecycleReader(coordinator: coordinator))
        .task {
            do {
                content = try await LiveRefreshContent.load()
            } catch {
                failed = true
                PlozzLog.app.error("Live refresh fixture setup failed")
            }
        }
    }
}

@MainActor
private final class LiveRefreshContent {
    struct Configuration: Decodable {
        let baseURL: URL
        let serverID: String
        let userID: String
        let username: String
        let deviceID: String
        let token: String
        let movieID: String
        let seriesID: String
        let firstEpisodeID: String
        let secondEpisodeID: String
    }

    let scope: String
    let config: Configuration
    let detail: ItemDetailViewModel
    let home: HomeViewModel
    let visibility: HomeLibraryVisibilityModel

    var status: String {
        switch scope {
        case "home":
            let item = home.state.value?.continueWatching.first { $0.id == config.movieID }
            return "home:\(Int(item?.resumePosition ?? -1))"
        case "series":
            let id = detail.serverResumeEpisode?.id
            return id == config.secondEpisodeID ? "series:second"
                : id == config.firstEpisodeID ? "series:first" : "series:pending"
        default:
            return "movie:\(Int(detail.state.value?.item.resumePosition ?? 0))"
        }
    }

    init(config: Configuration, kind: ProviderKind, scope: String, provider: any MediaProvider, item: MediaItem) {
        self.config = config
        self.scope = scope
        detail = ItemDetailViewModel(
            provider: provider, itemID: item.id, initialItem: item,
            sourceAccountID: config.serverID, onlineTrailerResolver: { _ in [] }
        )
        let visibility = HomeLibraryVisibilityModel(store: LiveRefreshVisibility())
        self.visibility = visibility
        home = HomeViewModel(
            accounts: [ResolvedAccount(account: Account(id: config.serverID, from: provider.session), provider: provider)],
            layoutStore: InMemoryHomeLayoutStore(), contentStore: InMemoryHomeContentStore(),
            currentVisibility: { visibility.visibility }
        )
    }

    static func load() async throws -> LiveRefreshContent {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["PLOZZ_LIVE_REFRESH_BROKER"], let broker = URL(string: address),
              broker.scheme == "http", broker.host == "127.0.0.1", broker.port != nil,
              broker.user == nil, broker.password == nil, broker.query == nil, broker.fragment == nil,
              let rawKind = env["PLOZZ_LIVE_REFRESH_PROVIDER"],
              let kind = ProviderKind(rawValue: rawKind), [.jellyfin, .plex].contains(kind),
              let scope = env["PLOZZ_LIVE_REFRESH_SCOPE"], ["movie", "series", "home"].contains(scope)
        else { throw AppError.invalidResponse }
        let url = broker.appendingPathComponent(rawKind).appendingPathComponent("configuration").appendingPathComponent(scope)
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 30))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError.invalidResponse }
        let config = try JSONDecoder().decode(Configuration.self, from: data)
        guard ["http", "https"].contains(config.baseURL.scheme), config.baseURL.host != nil,
              config.baseURL.user == nil, config.baseURL.password == nil,
              config.baseURL.query == nil, !config.token.isEmpty else { throw AppError.invalidResponse }
        let session = UserSession(
            server: .init(id: config.serverID, name: "Internal refresh", baseURL: config.baseURL, provider: kind),
            userID: config.userID, userName: config.username, deviceID: config.deviceID, accessToken: config.token
        )
        let provider: any MediaProvider = kind == .plex
            ? PlexProvider(session: session) : JellyfinProvider(session: session)
        let item = try await provider.item(id: scope == "series" ? config.seriesID : config.movieID)
        return LiveRefreshContent(config: config, kind: kind, scope: scope, provider: provider, item: item)
    }
}

private struct LiveRefreshVisibility: HomeLibraryVisibilityStoring {
    func load() -> HomeLibraryVisibility { .default }
    func save(_ visibility: HomeLibraryVisibility) {}
}
