import CoreModels
import CoreNetworking
import CoreUI
import FeatureAuth
import FeatureHomeCore
import SwiftUI
import UIKit
@testable import AppShelliOS

struct ContinueWatchingDetailsFixture: View {
    @State private var appModel: PlozziOSAppModel
    @State private var home: HomeViewModel
    @State private var trailer = HeroTrailerController()
    @State private var sidebar = PlozziOSSidebarGeometryModel()
    @State private var homeViewModelBox = LazyViewState<HomeViewModel>()
    // Harness upgrade (evidence work, not product change): the real iOS shell owns a
    // ContentRefreshCoordinator (PlozziOSRootView.swift:30) and injects it with its
    // lifecycle reader (PlozziOSRootView.swift:347-348). Without this the fixture's
    // refresh surfaces were inert, so the simulator never exercised the phone's reload lane.
    @State private var contentRefreshCoordinator = ContentRefreshCoordinator(profile: .iOS)

    init() {
        SyncSetupFeatureFlag().isEnabled = false
        let accounts = AccountStore(secureStore: InMemorySecureStore())
        // Harness upgrade (evidence work, not product change): the phone wires PERSISTENT
        // home stores (RootView.swift:751-752); the fixture used in-memory ones plus a random
        // UserDefaults suite per launch, so warm restarts never reproduced the phone's
        // persisted-store first paint. Fixed suite + persistent stores mirror the real wiring.
        let testsHorizontalBack = ProcessInfo.processInfo.arguments.contains("--back-interaction")
        let revisitID = ProcessInfo.processInfo.environment["PLOZZ_TEST_REVISIT_ID"]
        let suite = revisitID.map { "DetailArtworkRevisit.\($0)" }
            ?? (testsHorizontalBack ? "HorizontalHomeBack" : "ContinueWatchingDetails")
        let defaults = UserDefaults(suiteName: suite)!
        if testsHorizontalBack {
            // A previous launch's additional persona would require the launch
            // picker. This route starts at an already selected Home tab.
            defaults.removePersistentDomain(forName: suite)
        }
        let homeLayoutStore = HomeLayoutStore(defaults: defaults, namespace: "fixture")
        let homeContentStore = HomeContentStore(namespace: "fixture")
        let model = PlozziOSAppModel(accountStore: accounts, profileStore: ProfileStore(defaults: defaults))
        let profile = revisitID != nil ? model.profiles.activeProfile : model.profiles.add(name: "Details", isAwaitingSetup: false)
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
        let serverFilms = ProcessInfo.processInfo.arguments.contains("--browse-server-films")
        model.settings.hero.settings.isEnabled = serverFilms
        if serverFilms {
            model.settings.hero.settings.sources = testsHorizontalBack
                ? [.continueWatching] : [.continueWatching, .recentlyAdded]
            if testsHorizontalBack { model.settings.hero.settings.autoAdvance = false }
            ContinueWatchingDetailsProvider.prepareArtwork()
        }
        model.settings.heroBackground.settings.detailMode = .off
        model.settings.spoilers.settings = .default
        model.settings.cardStyle.captions = .init(preference: .show)
        if revisitID != nil {
            model.settings.cardStyle.artwork = ArtworkSettings(preference: .library)
            if ProcessInfo.processInfo.arguments.contains("--seed-revisit-bytes") {
                ContinueWatchingDetailsProvider.prepareArtwork(url: ContinueWatchingDetailsProvider.revisitURL("backdrop"))
                ContinueWatchingDetailsProvider.prepareArtwork(url: ContinueWatchingDetailsProvider.revisitURL("logo"), isLogo: true)
            }
        }
        model.settings.homeVisibility.useRowDefaults(.combined)
        if ProcessInfo.processInfo.arguments.contains("--browse-library-movies") {
            model.settings.homeVisibility.useRowDefaults(.provider)
            model.settings.homeVisibility.setGlobalRowEnabled(true, for: .continueWatching)
        }
        if serverFilms {
            model.settings.homeVisibility.useRowDefaults(.matchServer)
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
            layoutStore: homeLayoutStore, contentStore: homeContentStore,
            currentVisibility: { visibility.visibility }
        ))
        _appModel = State(initialValue: model)
    }

    var body: some View {
        Group {
            if ProcessInfo.processInfo.arguments.contains("--details-search") {
                NavigationStack {
                    PlozziOSSearchView(appModel: appModel, onShowSettings: {})
                        .plozziOSItemNavigation(appModel: appModel)
                }
            } else if ProcessInfo.processInfo.arguments.contains("--browse-server-films") {
                PlozziOSTabShell(
                    appModel: appModel, homeViewModelBox: homeViewModelBox,
                    onAddServer: {}, showingSettings: .constant(false),
                    showingProfileSwitcher: .constant(false), deferredPairingURL: .constant(nil),
                    systemColorScheme: .dark
                )
            } else {
                homePage
            }
        }
        .environment(appModel)
        .environment(trailer)
        .environment(sidebar)
        .environment(contentRefreshCoordinator)
        .background(ContentRefreshLifecycleReader(coordinator: contentRefreshCoordinator))
        .background(HarnessForegroundSessionDriver(coordinator: contentRefreshCoordinator))
        .background(HarnessConfigurationChurnDriver(appModel: appModel))
        .environment(\.themePalette, .dark)
        .environment(\.plozzMetrics, .touch(density: .standard))
        .environment(\.locale, Locale(identifier:
            ProcessInfo.processInfo.arguments.contains("--detail-route-parity") ? "fr" : "en_US"
        ))
        .preferredColorScheme(.dark)
    }

    private var homePage: some View {
        NavigationStack {
            PlozziOSHomeView(appModel: appModel, viewModel: home, onAddServer: {}, onShowSettings: {})
                .plozziOSItemNavigation(appModel: appModel)
        }
    }
}

/// Evidence-only harness driver (not product code): `simctl launch` always starts a
/// fresh process, so the phone's background→foreground reopen (UIKit's
/// willResignActive/didBecomeActive notifications, which the real
/// `ContentRefreshLifecycleReader` forwards to the coordinator) can never fire on the
/// simulator. This drives the identical coordinator calls on real clock timing: resign
/// shortly after surfaces register, then return after 16 s (> the home rule's 15 s
/// `foregroundAfter`) so the `reloadHome` lane runs exactly as it does on the phone.
private struct HarnessForegroundSessionDriver: View {
    let coordinator: ContentRefreshCoordinator

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task {
                // Opt-out flag: without the driver the natural surface-return
                // lane runs, which is what the phone's flicker signature came from.
                if ProcessInfo.processInfo.arguments.contains("--harness-no-session-driver") {
                    while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)) }
                    return
                }
                // Timing overrides let a lane put the resign/return AFTER content has
                // settled (the slow fixture needs ~25 s), which is the only way to see
                // a return-time repaint rather than a return during the first load.
                let resignAfter = Self.seconds("--harness-resign-seconds", fallback: 2)
                let returnAfter = Self.seconds("--harness-return-seconds", fallback: 16)
                try? await Task.sleep(for: .seconds(resignAfter))
                coordinator.applicationWillResignActive()
                try? await Task.sleep(for: .seconds(returnAfter))
                coordinator.applicationDidBecomeActive()
            }
    }

    private static func seconds(_ flag: String, fallback: Double) -> Double {
        let args = ProcessInfo.processInfo.arguments
        guard let at = args.firstIndex(of: flag), at + 1 < args.count,
              let value = Double(args[at + 1]) else { return fallback }
        return value
    }
}

/// Evidence-only harness driver (not product code): the phone's foreground sync path
/// (`PlozziOSAppModel+CloudSync` → `refreshActiveProfileConfiguration`) REPLACES
/// `appModel.settings` and reloads accounts + identity index while Home is on screen.
/// No harness stage reproduced that, so the simulator could never show the "another
/// render of Home appears, then reflows a few times" signature. Gated behind
/// `--harness-config-churn` so the existing lanes are unchanged.
private struct HarnessConfigurationChurnDriver: View {
    let appModel: PlozziOSAppModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task {
                guard ProcessInfo.processInfo.arguments.contains("--harness-config-churn") else {
                    return
                }
                // Land after the first paint (and after the fixture seeded settings) so
                // the churn happens against a settled page, as on the phone.
                try? await Task.sleep(for: .seconds(6))
                appModel.refreshActiveProfileConfiguration()
                try? await Task.sleep(for: .seconds(3))
                appModel.refreshActiveProfileSettings()
            }
    }
}

private struct ContinueWatchingDetailsProvider: MediaProvider, SeriesResumeProviding {
    let kind: ProviderKind
    private var serverFilms: Bool {
        ProcessInfo.processInfo.arguments.contains("--browse-server-films")
    }
    private static let artworkURL = URL(string: "https://continue-details.example.invalid/artwork.png")!

    static func revisitURL(_ name: String) -> URL {
        artworkURL.deletingLastPathComponent()
            .appendingPathComponent(ProcessInfo.processInfo.environment["PLOZZ_TEST_REVISIT_ID"]!)
            .appendingPathComponent("\(name).png")
    }

    @MainActor static func prepareArtwork(url: URL = artworkURL, isLogo: Bool = false) {
        let size = isLogo ? CGSize(width: 240, height: 80) : CGSize(width: 600, height: 900)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            (isLogo ? UIColor.red : UIColor.green).setFill()
            context.fill(CGRect(origin: .zero, size: size).insetBy(dx: isLogo ? 12 : 0, dy: isLogo ? 8 : 0))
        }
        guard let data = image.pngData(),
              let cache = ArtworkSession.shared.configuration.urlCache,
              let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=86400"]
              ) else {
            fatalError("Could not prepare Films fixture artwork")
        }
        cache.storeCachedResponse(
            CachedURLResponse(response: response, data: data), for: URLRequest(url: url)
        )
    }
    var session: UserSession {
        .init(
            server: .init(id: "continue-details", name: "Details fixture",
                          baseURL: URL(string: "https://continue-details.example.invalid")!, provider: kind),
            userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
        )
    }

    private var slowPageSeconds: Double {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--harness-slow-pages") else { return 0 }
        if let at = args.firstIndex(of: "--harness-slow-seconds"),
           at + 1 < args.count, let value = Double(args[at + 1]) {
            return value
        }
        return 4
    }
    func slowPage() async {
        let seconds = slowPageSeconds
        guard seconds > 0 else { return }
        try? await Task.sleep(for: .seconds(seconds))
    }
    func libraries() async throws -> [MediaLibrary] {
        await slowPage()
        return ProcessInfo.processInfo.arguments.contains("--browse-library-movies") || serverFilms
            ? [MediaLibrary(id: "movies", title: serverFilms ? "Films" : "Movies", kind: .movie)] : []
    }
    func serverHomeLayout() async throws -> ServerHomeLayout? {
        await slowPage()
        guard serverFilms else { return nil }
        return .init(sections: [
            .init(id: "web:1:resume", kind: .continueWatching),
            .init(id: "web:6:latestmedia:movies", kind: .recentlyAdded, title: "Films", libraryID: "movies")
        ], source: .webPreferences)
    }
    func serverHomeItems(
        section: ServerHomeSection, limit: Int, excludingLibraryIDs: Set<String>
    ) async throws -> [MediaItem] {
        await slowPage()
        switch section.kind {
        case .continueWatching: return try await continueWatching(limit: limit)
        case .recentlyAdded: return (0..<100).prefix(limit).map(browseMovie)
        default: throw AppError.notFound
        }
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] {
        await slowPage()
        if ProcessInfo.processInfo.arguments.contains("--back-interaction") {
            return [try await item(id: "movie")]
        }
        if ProcessInfo.processInfo.arguments.contains("--detail-route-parity") {
            return [try await item(id: "recent-episode")]
        }
        return [try await item(id: "episode"), try await item(id: "movie")]
    }
    func resumeEpisode(inSeries seriesID: String) async throws -> MediaItem? {
        await slowPage()
        return try await item(id: "episode")
    }
    func latest(limit: Int) async throws -> [MediaItem] {
        await slowPage()
        if ProcessInfo.processInfo.arguments.contains("--browse-movies") {
            return (0..<100).prefix(limit).map(browseMovie)
        }
        return [try await item(id: "recent-episode")]
    }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        await slowPage()
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
        if serverFilms {
            movie.posterURL = Self.artworkURL
            movie.backdropURL = Self.artworkURL
        }
        return movie
    }
    func item(id: String) async throws -> MediaItem {
        await slowPage()
        var item: MediaItem
        switch id {
        case "episode", "recent-episode":
            item = .init(id: id, title: id == "episode" ? "Continuing episode" : "Recent episode", kind: .episode)
            item.parentTitle = "Fixture show"
            item.seriesID = "series"
            item.seasonID = "season"
            item.seasonNumber = 1
            item.episodeNumber = id == "episode" ? 2 : 3
            if id == "episode" {
                var resume = 300.0
                if ProcessInfo.processInfo.arguments.contains("--harness-slow-pages") {
                    // Test-only drift: real servers tick the resume position
                    // between reload folds, so re-fetched copies differ by a
                    // volatile field. Reproduce that on the slow lane.
                    resume += Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 600)
                }
                item.resumePosition = resume
            } else if id == "recent-episode" {
                item.resumePosition = nil
            }
            item.overview = id == "episode" ? "Episode-specific synopsis." : "Recent episode synopsis."
        case "movie":
            item = .init(id: id, title: "Continuing movie", kind: .movie)
            item.resumePosition = 600
            item.overview = "Movie-specific synopsis."
        case "browse-0" where ProcessInfo.processInfo.environment["PLOZZ_TEST_REVISIT_ID"] != nil:
            item = browseMovie(0)
            item.posterURL = Self.revisitURL("backdrop")
            item.backdropURL = item.posterURL
            item.logoURL = Self.revisitURL("logo")
            item.overview = "Revisited movie synopsis."
        case "series":
            item = .init(id: id, title: "Fixture show", kind: .series)
            item.overview = ProcessInfo.processInfo.arguments.contains("--detail-route-parity")
                ? "Description FR de la serie." : "Whole-show synopsis."
        case "season":
            item = .init(id: id, title: "Season 1", kind: .season)
            item.seriesID = "series"
            item.seasonNumber = 1
        default:
            throw AppError.notFound
        }
        item.sourceAccountID = "continue-details"
        item.runtime = 2_400
        if serverFilms {
            item.posterURL = Self.artworkURL
            item.backdropURL = Self.artworkURL
        }
        return item
    }
    func children(of itemID: String) async throws -> [MediaItem] {
        if itemID == "series" { return [try await item(id: "season")] }
        if itemID == "season" { return [try await item(id: "episode"), try await item(id: "recent-episode")] }
        return []
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] {
        ProcessInfo.processInfo.arguments.contains("--detail-route-parity")
            ? [try await item(id: "series")] : []
    }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
