import CoreModels
import CoreUI
import FeatureHomeCore
import SwiftUI
import UIKit
#if os(tvOS)
import FeatureHome
#else
import FeatureAuth
@testable import AppShelliOS
#endif

/// Uses production detail views and lifecycle delivery; only server data and
/// the five-minute waiting period are replaced for bounded interaction tests.
struct ContentRefreshReturnFixture: View {
    private let provider: RefreshReturnProvider
    @State private var coordinator: ContentRefreshCoordinator
    @State private var covered = false
    @State private var trailer = HeroTrailerController()
    @State private var background = HeroBackgroundSettingsModel(store: InMemoryHeroBackgroundSettingsStore(
        HeroBackgroundSettings(homeTrailerEnabled: false, detailMode: .off)
    ))
    #if os(tvOS)
    @State private var detail: ItemDetailViewModel
    #else
    @State private var app: PlozziOSAppModel
    @State private var sidebar = PlozziOSSidebarGeometryModel()
    #endif

    init() {
        let provider = RefreshReturnProvider(
            isSeries: ProcessInfo.processInfo.arguments.contains("--refresh-series")
        )
        self.provider = provider
        let leaf = ContentRefreshRule(
            foregroundAfter: 1, surfaceReturnAfter: 1, action: .refreshWatchStateOnly
        )
        _coordinator = State(initialValue: ContentRefreshCoordinator(profile: .init(
            home: .init(foregroundAfter: 1, surfaceReturnAfter: 1, action: .reloadHome),
            seriesDetail: .init(foregroundAfter: 1, surfaceReturnAfter: 1, action: .reloadSeriesContext),
            episodeDetail: leaf, movieDetail: leaf
        )))
        #if os(tvOS)
        _detail = State(initialValue: ItemDetailViewModel(
            provider: provider, itemID: provider.seed.id, initialItem: provider.seed,
            sourceAccountID: "refresh-fixture", onlineTrailerResolver: { _ in [] }
        ))
        #else
        SyncSetupFeatureFlag().isEnabled = false
        let store = AccountStore(secureStore: InMemorySecureStore())
        let model = PlozziOSAppModel(accountStore: store, profileStore: ProfileStore(defaults: .standard))
        let profile = model.profiles.add(name: "Refresh fixture", isAwaitingSetup: false)
        model.profiles.select(profile.id)
        model.refreshActiveProfileSettings()
        model.accountsProviders.registry.register(provider.kind) { _ in provider }
        do {
            try store.add(Account(id: "refresh-fixture", from: provider.session), token: "fixture")
        } catch {
            preconditionFailure("Unable to configure refresh fixture: \(error)")
        }
        model.profiles.setActiveAccountIDs(["refresh-fixture"], for: profile.id)
        model.accountsProviders.tokenResolver = { _ in "fixture" }
        model.accountsProviders.reloadAccounts()
        model.settings.heroBackground.settings.detailMode = .off
        model.metadataProviderSettingsModel.settings = MetadataProviderSettings(
            orderMode: .custom, preferOnlineArtwork: false,
            disabledOrder: MetadataSourceAttribution.all.map(\.id)
        )
        _app = State(initialValue: model)
        #endif
    }

    var body: some View {
        NavigationStack {
            detailContent
                #if os(iOS)
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        coverButton
                    }
                }
                #endif
                .navigationDestination(isPresented: $covered) {
                    Button("Return to title") { covered = false }
                        .accessibilityIdentifier("refresh-return")
                        .onAppear { provider.advanceServerState() }
                }
        }
        .environment(coordinator)
        .environment(trailer)
        .environment(background)
        .environment(\.themePalette, .dark)
        .environment(\.locale, Locale(identifier: "en_US"))
        .preferredColorScheme(.dark)
        .background(ContentRefreshLifecycleReader(coordinator: coordinator))
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            provider.advanceServerState()
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        #if os(tvOS)
        ItemDetailView(viewModel: detail, onPlay: { _ in covered = true }, onSelectChild: { _ in })
        #else
        PlozziOSItemDetailView(appModel: app, provider: provider, item: provider.seed)
            .environment(app)
            .environment(sidebar)
        #endif
    }

    private var coverButton: some View {
        Button("Cover title") { covered = true }
            .accessibilityIdentifier("refresh-cover")
    }
}

private final class RefreshReturnProvider: MediaProvider, SeriesResumeProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var advanced = false
    let isSeries: Bool

    init(isSeries: Bool) { self.isSeries = isSeries }
    func advanceServerState() { lock.withLock { advanced = true } }
    var kind: ProviderKind { .jellyfin }
    var session: UserSession {
        UserSession(
            server: .init(id: "refresh-fixture", name: "Refresh fixture",
                          baseURL: URL(string: "https://fixture.invalid")!, provider: kind),
            userID: "fixture", userName: "Fixture", deviceID: "fixture", accessToken: ""
        )
    }
    var seed: MediaItem {
        MediaItem(
            id: "refresh-title", title: "Refresh verification", kind: isSeries ? .series : .movie,
            runtime: 1800, allowsTitleBasedMetadataMatching: false, sourceAccountID: "refresh-fixture"
        )
    }
    private func episode(_ number: Int, advanced: Bool) -> MediaItem {
        MediaItem(
            id: "episode-\(number)", title: "Episode \(number)", kind: .episode,
            seasonNumber: 1, episodeNumber: number, seriesID: seed.id, seasonID: "season",
            runtime: 1800, resumePosition: advanced && number == 2 ? 300 : nil,
            isPlayed: advanced && number == 1,
            allowsTitleBasedMetadataMatching: false, sourceAccountID: "refresh-fixture"
        )
    }
    func item(id: String) async throws -> MediaItem {
        guard id == seed.id else { throw AppError.notFound }
        var item = seed
        if !isSeries, lock.withLock({ advanced }) {
            item.resumePosition = 900
            item.playedPercentage = 0.5
        }
        return item
    }
    func children(of itemID: String) async throws -> [MediaItem] {
        guard isSeries else { return [] }
        if itemID == seed.id {
            return [MediaItem(
                id: "season", title: "Season 1", kind: .season, seasonNumber: 1, seriesID: seed.id,
                allowsTitleBasedMetadataMatching: false, sourceAccountID: "refresh-fixture"
            )]
        }
        guard itemID == "season" else { throw AppError.notFound }
        let advanced = lock.withLock { advanced }
        return [episode(1, advanced: advanced), episode(2, advanced: advanced)]
    }
    func resumeEpisode(inSeries seriesID: String) async throws -> MediaItem? {
        let advanced = lock.withLock { advanced }
        return episode(advanced ? 2 : 1, advanced: advanced)
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: 0, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
