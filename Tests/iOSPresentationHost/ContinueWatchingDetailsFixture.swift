import CoreModels
import CoreUI
import FeatureAuth
import FeatureHomeCore
import SwiftUI
@testable import AppShelliOS

struct ContinueWatchingDetailsFixture: View {
    @State private var appModel: PlozziOSAppModel
    @State private var home: HomeViewModel
    @State private var trailer = HeroTrailerController()
    @State private var sidebar = PlozziOSSidebarGeometryModel()

    init() {
        SyncSetupFeatureFlag().isEnabled = false
        let accounts = AccountStore(secureStore: InMemorySecureStore())
        let defaults = UserDefaults(suiteName: "ContinueWatchingDetails.\(UUID().uuidString)")!
        let model = PlozziOSAppModel(accountStore: accounts, profileStore: ProfileStore(defaults: defaults))
        let profile = model.profiles.add(name: "Details", isAwaitingSetup: false)
        model.profiles.select(profile.id)
        model.refreshActiveProfileSettings()
        let provider = ContinueWatchingDetailsProvider(
            kind: ProcessInfo.processInfo.arguments.contains("--plex") ? .plex : .jellyfin
        )
        let account = Account(id: "continue-details", from: provider.session)
        model.accountsProviders.registry.register(provider.kind) { _ in provider }
        do {
            try accounts.add(account, token: "fixture")
        } catch {
            fatalError("Could not prepare Continue Watching fixture: \(error)")
        }
        model.profiles.setActiveAccountIDs([account.id], for: profile.id)
        model.accountsProviders.tokenResolver = { _ in "fixture" }
        model.accountsProviders.reloadAccounts()
        model.settings.hero.settings.isEnabled = false
        model.settings.heroBackground.settings.detailMode = .off
        model.settings.spoilers.settings = .default
        model.settings.cardStyle.captions = .init(preference: .show)
        model.settings.homeVisibility.useRowDefaults(.combined)
        if ProcessInfo.processInfo.arguments.contains("--browse-library-movies") {
            model.settings.homeVisibility.useRowDefaults(.provider)
            model.settings.homeVisibility.setGlobalRowEnabled(true, for: .continueWatching)
        }
        model.settings.homeVisibility.setContinueWatchingLayout(
            ProcessInfo.processInfo.arguments.contains("--portrait") ? .portrait : .landscape
        )
        model.metadataProviderSettingsModel.settings = MetadataProviderSettings(
            orderMode: .custom, preferOnlineArtwork: false,
            disabledOrder: MetadataSourceAttribution.all.map(\.id)
        )
        let visibility = model.settings.homeVisibility
        _home = State(initialValue: HomeViewModel(
            accounts: model.accountsProviders.homeAccounts,
            layoutStore: InMemoryHomeLayoutStore(), contentStore: InMemoryHomeContentStore(),
            currentVisibility: { visibility.visibility }
        ))
        _appModel = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            PlozziOSHomeView(appModel: appModel, viewModel: home, onAddServer: {}, onShowSettings: {})
                .plozziOSItemNavigation(appModel: appModel)
        }
        .environment(appModel)
        .environment(trailer)
        .environment(sidebar)
        .environment(\.themePalette, .dark)
        .environment(\.plozzMetrics, .touch(density: .standard))
        .environment(\.locale, Locale(identifier: "en_US"))
        .preferredColorScheme(.dark)
    }
}

private struct ContinueWatchingDetailsProvider: MediaProvider {
    let kind: ProviderKind
    var session: UserSession {
        .init(
            server: .init(id: "continue-details", name: "Details fixture",
                          baseURL: URL(string: "https://continue-details.example.invalid")!, provider: kind),
            userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
        )
    }

    func libraries() async throws -> [MediaLibrary] {
        ProcessInfo.processInfo.arguments.contains("--browse-library-movies")
            ? [MediaLibrary(id: "movies", title: "Movies", kind: .movie)] : []
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] {
        [try await item(id: "episode"), try await item(id: "movie")]
    }
    func latest(limit: Int) async throws -> [MediaItem] {
        if ProcessInfo.processInfo.arguments.contains("--browse-movies") {
            return (0..<100).prefix(limit).map(browseMovie)
        }
        return [try await item(id: "recent-episode")]
    }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        if containerID == "movies" {
            return .init(
                items: (0..<100).dropFirst(page.startIndex).prefix(page.limit).map(browseMovie),
                startIndex: page.startIndex, totalCount: 100
            )
        }
        return .init(items: [], startIndex: 0, totalCount: 0)
    }
    private func browseMovie(_ index: Int) -> MediaItem {
        var movie = MediaItem(id: "browse-\(index)", title: "Browse movie \(index)", kind: .movie)
        movie.sourceAccountID = "continue-details"
        movie.libraryID = "movies"
        return movie
    }
    func item(id: String) async throws -> MediaItem {
        var item: MediaItem
        switch id {
        case "episode", "recent-episode":
            item = .init(id: id, title: id == "episode" ? "Continuing episode" : "Recent episode", kind: .episode)
            item.parentTitle = "Fixture show"
            item.seriesID = "series"
            item.seasonID = "season"
            item.seasonNumber = 1
            item.episodeNumber = id == "episode" ? 2 : 3
            item.resumePosition = id == "episode" ? 300 : nil
            item.overview = id == "episode" ? "Episode-specific synopsis." : "Recent episode synopsis."
        case "movie":
            item = .init(id: id, title: "Continuing movie", kind: .movie)
            item.resumePosition = 600
            item.overview = "Movie-specific synopsis."
        case "series":
            item = .init(id: id, title: "Fixture show", kind: .series)
            item.overview = "Whole-show synopsis."
        case "season":
            item = .init(id: id, title: "Season 1", kind: .season)
            item.seriesID = "series"
            item.seasonNumber = 1
        default:
            throw AppError.notFound
        }
        item.sourceAccountID = "continue-details"
        item.runtime = 2_400
        return item
    }
    func children(of itemID: String) async throws -> [MediaItem] {
        if itemID == "series" { return [try await item(id: "season")] }
        if itemID == "season" { return [try await item(id: "episode"), try await item(id: "recent-episode")] }
        return []
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
