import AppRuntime
import CoreModels
import CoreUI
import FeatureHomeCore
import FeatureAuth
import MetadataKit
import SwiftUI
import UIKit
#if os(tvOS)
@testable import AppShell
import FeatureHome
#else
@testable import AppShelliOS
#endif

struct UpcomingCaptureFixture: View {
    @State private var fixture = UpcomingCaptureState()
    @State private var isLoaded = false
    #if os(tvOS)
    @State private var tvSelection: NavigationRailDestination =
        ProcessInfo.processInfo.arguments.contains("--capture-home") ? .home : .upcoming
    #endif
    private let palette = ThemePalette.dark

    var body: some View {
        Group {
            #if os(tvOS)
            TopBarNavigation(
                destinations: [.home, .upcoming, .watchlist, .search],
                selection: $tvSelection, preventsAccidentalExit: true,
                content: { destination, _ in
                    AnyView(page(home: destination == .home))
                },
                label: { destination in
                    switch destination {
                    case .home: AnyView(Label("Home", systemImage: "house"))
                    case .upcoming: AnyView(Label("Upcoming", systemImage: "calendar"))
                    case .watchlist: AnyView(Label("Watchlist", systemImage: "bookmark"))
                    default: AnyView(Label("Search", systemImage: "magnifyingglass"))
                    }
                },
                profile: Profile(name: "Viewer"), onOpenProfileSwitcher: {}
            )
            #else
            if isLoaded {
                fixture.shell
                    .environment(fixture.app)
                    .environment(fixture.trailer)
                    .environment(fixture.sidebar)
                    .environment(\.plozzMetrics, .touch(density: .standard))
            } else {
                Color.clear
            }
            #endif
        }
        .environment(\.themePalette, palette)
        .environment(\.plozzCardStyle, .borderless)
        .preferredColorScheme(.dark)
        .tint(palette.primaryText)
        .environment(\.plozzReduceTransparency, ProcessInfo.processInfo.arguments.contains("--capture-opaque"))
        .task {
            await fixture.load()
            isLoaded = true
            #if os(iOS)
            do {
                try await Task.sleep(for: .milliseconds(500))
                fixture.app.screenshotDirector.tab =
                    ProcessInfo.processInfo.arguments.contains("--capture-home") ? "home" : "upcoming"
                try await prepareCapture()
            } catch is CancellationError {
                return
            } catch {
                preconditionFailure("Upcoming capture failed: \(error)")
            }
            #endif
        }
    }

    #if os(iOS)
    @MainActor
    private func prepareCapture() async throws {
        let arguments = ProcessInfo.processInfo.arguments
        let showsCalendar = arguments.contains("--capture-calendar") || arguments.contains("--capture-selection")
        guard arguments.contains("--capture-scrolled") || showsCalendar else { return }
        try await Task.sleep(for: .seconds(1))
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) else {
            preconditionFailure("Upcoming capture has no window")
        }
        precondition(fixture.home.upcoming.failedSourceCount == 0, "Preview data was replaced by a live refresh")
        if arguments.contains("--capture-landscape") {
            window.frame = CGRect(x: 0, y: 0, width: 1194, height: 834)
            try await Task.sleep(for: .milliseconds(500))
            precondition(window.bounds.size == CGSize(width: 1194, height: 834), "Landscape test window was not resized")
        }
        func descendants(_ view: UIView) -> [UIView] {
            [view] + view.subviews.flatMap(descendants)
        }
        func controllers(_ controller: UIViewController) -> [UIViewController] {
            [controller] + controller.children.flatMap(controllers)
        }
        if arguments.contains("--capture-landscape") {
            for controller in window.rootViewController.map(controllers) ?? [] {
                (controller as? UITabBarController)?.sidebar.isHidden = true
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        var barItems: [UIBarButtonItem] = []
        for controller in window.rootViewController.map(controllers) ?? [] {
            let item = controller.navigationItem
            barItems += item.leftBarButtonItems ?? []
            barItems += item.rightBarButtonItems ?? []
            let groups = item.leadingItemGroups + item.centerItemGroups + item.trailingItemGroups
            barItems += groups.flatMap(\.barButtonItems)
        }
        for title in ["Today", "Calendar", "Filters"] {
            precondition(barItems.contains { $0.title == title }, "Missing Upcoming action: \(title)")
        }
        guard let today = barItems.first(where: { $0.title == "Today" })?.customView, today.window === window else {
            preconditionFailure("Upcoming Today action must be visible in the production toolbar")
        }
        let before = today.convert(today.bounds, to: window)
        precondition(before.minY < window.safeAreaInsets.top + 20, "Upcoming toolbar occupies a second row")
        if arguments.contains("--capture-scrolled") {
            guard let scroll = descendants(window).compactMap({ $0 as? UIScrollView }).first(where: {
                $0.bounds.height > 200 && $0.contentSize.height > $0.bounds.height + 250
            }) else {
                preconditionFailure("Upcoming capture requires a scrollable agenda")
            }
            scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentOffset.y + 250), animated: false)
            try await Task.sleep(for: .milliseconds(500))
            precondition(abs(today.convert(today.bounds, to: window).minY - before.minY) < 2,
                         "Upcoming actions moved while scrolling")
            guard let backdrop = descendants(window).first(where: {
                $0.accessibilityIdentifier == "upcoming.navigationBackdrop"
            }) as? UIVisualEffectView else {
                preconditionFailure("Upcoming requires a real native navigation backdrop")
            }
            let backdropFrame = backdrop.convert(backdrop.bounds, to: window)
            precondition(abs(backdropFrame.minX) < 1 && abs(backdropFrame.width - window.bounds.width) < 1)
            precondition(abs(backdropFrame.minY) < 1 && backdropFrame.maxY > before.maxY)
            precondition(!backdrop.isUserInteractionEnabled, "The backdrop must not intercept toolbar actions")
            precondition((backdrop.effect is UIBlurEffect) != arguments.contains("--capture-opaque"))
            if #available(iOS 26.0, *) {
                precondition(
                    scroll.topEdgeEffect.isHidden == arguments.contains("--capture-opaque"),
                    "Upcoming must respect the shell's scroll-edge transparency policy"
                )
                precondition(scroll.topEdgeEffect.style == .soft, "Upcoming must use a soft native scroll edge")
            }
            if arguments.contains("--capture-backdrop-comparison") {
                for enabled in [true, false] {
                    backdrop.effect = enabled ? UIBlurEffect(style: .systemUltraThinMaterial) : nil
                    try await Task.sleep(for: .milliseconds(500))
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        precondition(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                    }
                    let path = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent(enabled ? "upcoming-backdrop-enabled.png" : "upcoming-backdrop-disabled.png")
                    try image.pngData()!.write(to: path)
                }
                backdrop.effect = UIBlurEffect(style: .systemUltraThinMaterial)
            }
        }
        if showsCalendar {
            guard let button = barItems.first(where: { $0.title == "Calendar" }), let action = button.action else {
                preconditionFailure("Upcoming calendar must expose its native action")
            }
            precondition(UIApplication.shared.sendAction(action, to: button.target, from: button, for: nil),
                         "Upcoming calendar action was not handled")
            try await Task.sleep(for: .seconds(1))
            guard let picker = descendants(window).compactMap({ $0 as? UIDatePicker }).first else {
                preconditionFailure("Upcoming calendar did not present a native date picker")
            }
            precondition(picker.bounds.width >= 280 && picker.bounds.width <= 400, "Unexpected calendar width")
            precondition(picker.bounds.height > 250 && picker.bounds.height < 450, "Unexpected calendar height")
            let frame = picker.convert(picker.bounds, to: window)
            precondition(window.bounds.contains(frame), "Calendar extends outside the window")
            if arguments.contains("--capture-selection") {
                let day = Calendar.current.date(byAdding: .day, value: 1, to: picker.date)!
                picker.setDate(day, animated: false)
                picker.sendActions(for: .valueChanged)
                try await Task.sleep(for: .seconds(1))
                precondition(picker.window == nil, "Choosing a date must dismiss the calendar")
            }
        }
        if arguments.contains("--capture-landscape") {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                precondition(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true), "Could not render landscape window")
            }
            let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("upcoming-landscape.png")
            try image.pngData()!.write(to: path)
        }
        FileHandle.standardOutput.write(Data("Upcoming capture ready\n".utf8))
    }
    #endif

    #if os(tvOS)
    private func page(home: Bool) -> some View {
        NavigationStack {
            Group {
                if home {
                    homeContent
                } else {
                    UpcomingView(
                        model: fixture.home.upcoming,
                        interval: DateInterval(
                            start: Date().addingTimeInterval(-30 * 86_400),
                            end: Date().addingTimeInterval(90 * 86_400)
                        )
                    )
                }
            }
            .background { AppBackground(palette: palette) }
        }
    }

    @ViewBuilder
    private var homeContent: some View {
        HomeView(
            viewModel: fixture.home, visibility: fixture.visibility,
            heroSettings: fixture.hero,
            heroBackground: fixture.background,
            heroTrailerController: fixture.trailer,
            heroIsFrontmost: true, heroRuntime: fixture.heroRuntime,
            navigationStyle: .tabBar,
            onSelectItem: { _ in }, onPlayItem: { _ in },
            onSelectLibrary: { _ in }, onBrowse: { destination in
                if case .upcoming = destination { tvSelection = .upcoming }
            }
        )
    }
    #endif
}

@MainActor
final class UpcomingCaptureState {
    let home: HomeViewModel
    let releases: [UpcomingRelease]
    let visibility: HomeLibraryVisibilityModel
    let hero = HeroSettingsModel(store: InMemoryHeroSettingsStore())
    let background = HeroBackgroundSettingsModel(store: InMemoryHeroBackgroundSettingsStore())
    let trailer = HeroTrailerController()
    #if os(tvOS)
    let heroRuntime = HomeHeroRuntimeState()
    #else
    let app: PlozziOSAppModel
    let shell: PlozziOSTabShell
    let sidebar = PlozziOSSidebarGeometryModel()
    #endif

    init(releases: [UpcomingRelease]? = nil) {
        let releases = releases ?? UpcomingCaptureProvider.releases
        self.releases = releases
        let provider = UpcomingCaptureProvider()
        let account = Account(id: "upcoming-capture", from: provider.session)
        let defaults = UserDefaults(suiteName: "UpcomingCapture.\(UUID().uuidString)")!
        #if os(tvOS)
        visibility = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults))
        #else
        SyncSetupFeatureFlag().isEnabled = false
        let accounts = AccountStore(secureStore: InMemorySecureStore())
        app = PlozziOSAppModel(accountStore: accounts, profileStore: ProfileStore(defaults: defaults))
        let profile = app.profiles.add(name: "Preview", isAwaitingSetup: false)
        app.profiles.select(profile.id)
        app.refreshActiveProfileSettings()
        app.accountsProviders.registry.register(.jellyfin) { _ in provider }
        do {
            try accounts.add(account, token: "fixture")
        } catch {
            preconditionFailure("Could not prepare Upcoming preview: \(error)")
        }
        app.profiles.setActiveAccountIDs([account.id], for: profile.id)
        app.accountsProviders.tokenResolver = { _ in "fixture" }
        app.accountsProviders.reloadAccounts()
        app.settings.hero.settings.isEnabled = false
        app.settings.cardStyle.style = .borderless
        app.settings.cardStyle.captions = .default
        app.settings.theme.theme = .dark
        app.settings.heroBackground.settings.detailMode = .off
        let destinations = [
            NavigationLibraryLayout.homeKey, NavigationLibraryLayout.musicKey,
            NavigationLibraryLayout.upcomingKey, NavigationLibraryLayout.downloadsKey,
            NavigationLibraryLayout.searchKey, NavigationLibraryLayout.watchlistKey,
            NavigationLibraryLayout.settingsKey
        ]
        app.settings.navigation.applyLibrarySections(
            .init(enabled: destinations, disabled: NavigationDestinationDefaults.iOS.filter { !destinations.contains($0) }),
            available: NavigationDestinationDefaults.iOS
        )
        app.metadataProviderSettingsModel.settings = MetadataProviderSettings(
            orderMode: .custom, preferOnlineArtwork: false,
            disabledOrder: MetadataSourceAttribution.all.map(\.id)
        )
        visibility = app.settings.homeVisibility
        #endif
        hero.settings.isEnabled = false
        hero.settings.style = .carousel
        visibility.useRowDefaults(.combined)
        visibility.setContinueWatchingLayout(.landscape)
        let rows: [HomeRowID] = [.global(.continueWatching), .global(.comingSoon), .global(.recentlyAdded)]
        visibility.applyRows(
            .init(enabled: rows, disabled: HomeRowChoice.shared.map(\.id).filter { !rows.contains($0) }),
            choices: HomeRowChoice.shared
        )
        #if os(tvOS)
        let visibility = visibility
        home = HomeViewModel(
            accounts: [.init(account: account, provider: provider)],
            profileNamespace: "upcoming-capture",
            layoutStore: InMemoryHomeLayoutStore(), contentStore: InMemoryHomeContentStore(),
            currentVisibility: { visibility.visibility }
        )
        #else
        var shell = PlozziOSTabShell(
            appModel: app, homeViewModelBox: LazyViewState<HomeViewModel>(), onAddServer: {},
            showingSettings: .constant(false), showingProfileSwitcher: .constant(false),
            deferredPairingURL: .constant(nil), systemColorScheme: .dark
        )
        shell.upcomingFeedLoader = { _ in UpcomingFeedSnapshot(releases: releases) }
        self.shell = shell
        home = shell.sharedHomeViewModel
        #endif
    }

    func load() async {
        await home.load()
        #if os(tvOS)
        let scope = "upcoming-capture"
        let namespace: String? = "upcoming-capture"
        #else
        let scope = UpcomingFeedLoader.scopeKey(
            profileID: app.profiles.activeProfileID, accounts: app.upcomingAccounts,
            requestIdentity: app.profiles.activeProfile.seerrRequestIdentity,
            connectionRevision: app.seerService.connectionRevision,
            language: Locale.current.identifier, regionCode: Locale.current.region?.identifier
        )
        let namespace = app.profiles.activeNamespace
        #endif
        let releases = releases
        await home.upcoming.refresh(scope: scope, namespace: namespace, isCurrent: { true }) {
            UpcomingFeedSnapshot(releases: releases)
        }
    }
}

private struct UpcomingCaptureProvider: MediaProvider {
    let kind: ProviderKind = .jellyfin
    var session: UserSession {
        .init(
            server: .init(
                id: "upcoming-capture", name: "Preview",
                baseURL: URL(string: "https://upcoming-preview.example.invalid")!, provider: .jellyfin
            ),
            userID: "preview", userName: "Preview", deviceID: "fixture", accessToken: "fixture"
        )
    }

    static let series: [MediaItem] = [
        ("The Simpsons", "637/1594614", "218/547446"),
        ("Severance", "548/1371406", "384/960581"),
        ("Silo", "631/1577677", "459/1149869"),
        ("Slow Horses", "641/1604425", "471/1178812"),
        ("Foundation", "573/1433544", "262/656371")
    ].enumerated().map { index, example in
        var item = MediaItem(
            id: "capture-show-\(index)", title: example.0, kind: .series,
            allowsTitleBasedMetadataMatching: false
        )
        item.sourceAccountID = "upcoming-capture"
        item.libraryID = "shows"
        item.posterURL = URL(string: "https://static.tvmaze.com/uploads/images/original_untouched/\(example.1).jpg")
        item.backdropURL = URL(string: "https://static.tvmaze.com/uploads/images/original_untouched/\(example.2).jpg")
        return item
    }

    func libraries() async throws -> [MediaLibrary] {
        [.init(id: "shows", title: "Shows", kind: .series)]
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] {
        Array(Self.series.suffix(3).enumerated().map { index, series in
            var episode = series
            episode.id = "continue-\(series.id)"
            episode.kind = .episode
            episode.seriesID = series.id
            episode.seriesPosterURL = series.posterURL
            episode.fallbackArtworkURL = series.backdropURL
            episode.parentTitle = series.title
            episode.seasonNumber = 1
            episode.episodeNumber = index + 3
            episode.resumePosition = TimeInterval((index + 1) * 400)
            episode.runtime = 3_000
            return episode
        }.prefix(limit))
    }
    func latest(limit: Int) async throws -> [MediaItem] { Array(Self.series.reversed().prefix(limit)) }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        .init(
            items: Array(Self.series.dropFirst(page.startIndex).prefix(page.limit)),
            startIndex: page.startIndex, totalCount: Self.series.count
        )
    }
    func item(id: String) async throws -> MediaItem {
        guard let item = Self.series.first(where: { $0.id == id }) else { throw AppError.notFound }
        return item
    }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }

    static var releases: [UpcomingRelease] {
        let today = Calendar.current.startOfDay(for: Date())
        var result = Self.series.prefix(3).enumerated().flatMap { index, item -> [UpcomingRelease] in
            let day = Calendar.current.date(byAdding: .day, value: index == 0 ? 0 : 1, to: today)!
            let episodes = (0..<(index == 1 ? 3 : 1)).map { offset in
                UpcomingEpisode(
                    seriesIdentity: .external(source: "capture", value: "\(index)"),
                    seasonNumber: index == 0 ? 38 : 3, episodeNumber: (index == 0 ? 6 : 1) + offset,
                    title: nil, airDate: day, datePrecision: .dateOnly,
                    source: .tvmaze, sourceURL: nil, refreshedAt: today
                )
            }
            return UpcomingReleaseBuilder.episodes(episodes, for: item)
        }
        let movie = MediaItem(id: "capture-movie", title: "A saved movie", kind: .movie)
        result += UpcomingReleaseBuilder.movies(
            [.init(kind: .digital, date: Calendar.current.date(byAdding: .day, value: 2, to: today)!, regionCode: "US")],
            for: movie, interests: [.watchlist], regionCode: "US"
        )
        if ProcessInfo.processInfo.arguments.contains("--capture-scrolled") {
            for index in 3..<20 {
                let item = series[index % series.count]
                result += UpcomingReleaseBuilder.episodes(
                    [.init(
                        seriesIdentity: .external(source: "capture", value: item.id),
                        seasonNumber: 1, episodeNumber: index,
                        title: nil, airDate: Calendar.current.date(byAdding: .day, value: index, to: today)!,
                        datePrecision: .dateOnly,
                        source: .tvmaze, sourceURL: nil, refreshedAt: today
                    )],
                    for: item
                )
            }
        }
        return UpcomingReleaseBuilder.merging(result)
    }
}
