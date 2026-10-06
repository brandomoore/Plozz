import CoreModels
import CoreUI
import FeatureHome
import FeatureHomeCore
import MetadataKit
import SwiftUI

struct EpisodeBreadcrumbFixture: View {
    @State private var path: [MediaItem] = []
    @State private var entered = false
    @State private var model = EpisodeBreadcrumbModel()

    var body: some View {
        NavigationStack(path: $path) {
            Button("Go to Episode") { path.append(model.provider.episode) }
                .navigationDestination(for: MediaItem.self) { item in
                    ItemDetailView(
                        viewModel: item.kind == .episode ? model.episode : model.show,
                        onPlay: { _ in }, onSelectChild: { path.append($0) },
                        onNavigate: { path.append($0) }
                    )
                    .environment(model.trailer)
                    .environment(model.background)
                    .mediaItemActionHandler(model.actions)
                    .overlay(alignment: .topTrailing) {
                        Text(verbatim: "\(item.id)|\(item.seasonID ?? "-")|\(item.sourceAccountID ?? "-")")
                            .accessibilityIdentifier("breadcrumb-route")
                            .allowsHitTesting(false)
                    }
                }
        }
        .environment(\.themePalette, .dark)
        .preferredColorScheme(.dark)
        .onAppear {
            guard !entered else { return }
            entered = true
            if ProcessInfo.processInfo.arguments.contains("--from-show") {
                path.append(model.provider.series)
            }
            path.append(model.provider.episode)
        }
    }
}

@MainActor
private final class EpisodeBreadcrumbModel {
    let provider: EpisodeBreadcrumbProvider
    let episode: ItemDetailViewModel
    let show: ItemDetailViewModel
    let actions = EpisodeBreadcrumbActions()
    let trailer = HeroTrailerController()
    let background = HeroBackgroundSettingsModel(store: InMemoryHeroBackgroundSettingsStore(
        HeroBackgroundSettings(homeTrailerEnabled: false, detailMode: .off)
    ))

    init() {
        provider = EpisodeBreadcrumbProvider(
            isUpcoming: ProcessInfo.processInfo.arguments.contains("--upcoming")
        )
        episode = Self.detail(provider.episode, provider: provider)
        show = Self.detail(provider.series, provider: provider)
    }

    private static func detail(_ item: MediaItem, provider: EpisodeBreadcrumbProvider) -> ItemDetailViewModel {
        ItemDetailViewModel(
            provider: provider, itemID: item.id, initialItem: item,
            sourceAccountID: "breadcrumb-account",
            onlineTrailerResolver: { _ in [] }, playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache()
        )
    }
}

@MainActor
private final class EpisodeBreadcrumbActions: MediaItemActionHandling {
    func actions(for item: MediaItem, context: MediaItemActionContext) -> [MediaItemAction] {
        MediaItemActionCatalog.actions(for: item, supportsWatchState: false, context: context)
    }
    func perform(_ action: MediaItemAction, on item: MediaItem, context: MediaItemActionContext) {}
}

private struct EpisodeBreadcrumbProvider: MediaProvider {
    let isUpcoming: Bool

    var kind: ProviderKind { .jellyfin }
    var session: UserSession {
        UserSession(
            server: MediaServer(id: "breadcrumb-account", name: "Fixture",
                               baseURL: URL(string: "https://fixture.invalid")!, provider: kind),
            userID: "fixture", userName: "Fixture", deviceID: "fixture", accessToken: ""
        )
    }
    var series: MediaItem {
        MediaItem(id: "show", title: "Fixture Show", kind: .series, overview: "Series plot",
                  sourceAccountID: "breadcrumb-account")
    }
    var episode: MediaItem {
        var item = MediaItem(
            id: "episode", title: "Fixture Episode", kind: .episode,
            overview: "Episode plot", parentTitle: "Fixture Show",
            seasonNumber: 2, episodeNumber: 3, seriesID: "show", seasonID: "season-2",
            runtime: 1800, allowsTitleBasedMetadataMatching: false, sourceAccountID: "breadcrumb-account"
        )
        if isUpcoming { item.scheduledAirDate = .distantFuture }
        return item
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { id == "show" ? series : episode }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: 0, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
