import CoreModels
import CoreUI
import FeatureAuth
import FeatureHomeCore
import HeroUI
import Observation
import SwiftUI
import UIKit
@testable import AppShelliOS

struct FeaturedCardInteractionFixture: View {
    @State private var controller = HeroTrailerController()
    @State private var coordinator = FeaturedTrailerCoordinator()
    @State private var selections = 0
    @State private var actions = HeroInteractionActions()
    private static let artworkURL = URL(string: "https://featured.invalid/artwork.png")!
    private static let logoURL = URL(string: "https://featured.invalid/logo.png")!

    init() {
        for (url, size, logo) in [
            (Self.artworkURL, CGSize(width: 600, height: 338), false),
            (Self.logoURL, CGSize(width: 300, height: 70), true)
        ] {
            let image = UIGraphicsImageRenderer(size: size).image { context in
                if logo {
                    ("FEATURED" as NSString).draw(at: CGPoint(x: 8, y: 8), withAttributes: [
                        .font: UIFont.boldSystemFont(ofSize: 44), .foregroundColor: UIColor.black
                    ])
                } else {
                    UIColor(white: 0.3, alpha: 1).setFill()
                    context.fill(CGRect(origin: .zero, size: size))
                }
            }
            guard let data = image.pngData(), let cache = ArtworkSession.shared.configuration.urlCache,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
                    "Content-Type": "image/png", "Cache-Control": "max-age=86400"
                  ]) else { fatalError("Could not prepare Featured card artwork") }
            cache.storeCachedResponse(CachedURLResponse(response: response, data: data), for: URLRequest(url: url))
        }
    }

    var body: some View {
        ScrollView {
            FeaturedMediaRow(
                title: Text("Featured"), items: [
                    MediaItem(id: "featured-touch", title: "Featured title", kind: .movie,
                              productionYear: 2026, officialRating: "PG", genres: ["Adventure"],
                              backdropURL: Self.artworkURL, logoURL: Self.logoURL,
                              allowsTitleBasedMetadataMatching: false)
                ],
                scope: ObjectIdentifier(controller), coordinator: coordinator, controller: controller,
                settings: .default, resolver: { _ in nil }, isActive: false,
                onSelect: { _ in selections += 1 }
            )
            Text("Following row").accessibilityIdentifier("featured-following-row")
            Color.clear.frame(height: 1_000)
        }
        .overlay(alignment: .bottomTrailing) {
            Text(verbatim: "\(selections)")
                .accessibilityIdentifier("featured-selection-count")
                .allowsHitTesting(false)
        }
        .environment(\.themePalette, .light)
        .environment(\.mediaItemActionHandler, actions)
        .environment(\.plozzMetrics, .touch(density: .standard))
        .preferredColorScheme(.light)
    }
}

struct HomeHeroInteractionFixture: View {
    @Environment(\.plozziOSUsesVerticalToolbar) private var usesVerticalToolbar
    private var colorScheme: ColorScheme {
        ProcessInfo.processInfo.arguments.contains("--hero-light") ? .light : .dark
    }
    @State private var appModel: PlozziOSAppModel
    @State private var trailer = HeroTrailerController()
    @State private var sidebar = PlozziOSSidebarGeometryModel()
    @State private var pull = PlozziOSHomeHeroPullModel()
    @State private var actions = HeroInteractionActions()
    @State private var playCount = 0
    @State private var presentsSeasons = false
    @State private var pinnedIDs = ""
    private var testsAutoAdvance: Bool {
        ProcessInfo.processInfo.arguments.contains("--hero-auto-advance")
    }
    private var usesNativeChrome: Bool {
        ProcessInfo.processInfo.arguments.contains("--hero-native-chrome")
    }

    init() {
        SyncSetupFeatureFlag().isEnabled = false
        if ProcessInfo.processInfo.arguments.contains("--hero-native-chrome") {
            let size = CGSize(width: 900, height: 1200)
            let image = UIGraphicsImageRenderer(size: size).image { context in
                UIColor(red: 0.15, green: 0.75, blue: 0.95, alpha: 1).setFill()
                context.fill(CGRect(origin: .zero, size: size))
                UIColor(red: 0.25, green: 0.85, blue: 0.95, alpha: 1).setFill()
                for x in stride(from: 0, to: 900, by: 100) {
                    context.fill(CGRect(x: x, y: 0, width: 20, height: 1200))
                }
            }
            guard let data = image.pngData(),
                  let cache = ArtworkSession.shared.configuration.urlCache,
                  let response = HTTPURLResponse(
                    url: HeroInteractionProvider.artworkURL, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=86400"]
                  ) else {
                fatalError("Unable to prepare full-width hero artwork")
            }
            cache.storeCachedResponse(
                CachedURLResponse(response: response, data: data),
                for: URLRequest(url: HeroInteractionProvider.artworkURL)
            )
        }
        if ProcessInfo.processInfo.arguments.contains("--hero-logo") {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 560, height: 100)).image { _ in
                ("HERO MOVIE" as NSString).draw(
                    at: CGPoint(x: 8, y: 8),
                    withAttributes: [.font: UIFont.boldSystemFont(ofSize: 72), .foregroundColor: UIColor.systemTeal]
                )
            }
            guard let data = image.pngData(),
                  let cache = ArtworkSession.shared.configuration.urlCache,
                  let response = HTTPURLResponse(
                    url: HeroInteractionProvider.logoURL, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=86400"]
                  ) else {
                fatalError("Unable to prepare hero logo")
            }
            cache.storeCachedResponse(
                CachedURLResponse(response: response, data: data),
                for: URLRequest(url: HeroInteractionProvider.logoURL)
            )
        }
        let accounts = AccountStore(secureStore: InMemorySecureStore())
        let defaults = UserDefaults(suiteName: "HomeHeroInteractionFixture")!
        defaults.removePersistentDomain(forName: "HomeHeroInteractionFixture")
        let model = PlozziOSAppModel(accountStore: accounts, profileStore: ProfileStore(defaults: defaults))
        for kind in [ProviderKind.jellyfin, .emby] {
            let provider = HeroInteractionProvider(kind: kind)
            model.accountsProviders.registry.register(kind) { _ in provider }
            do {
                try accounts.add(provider.account, token: "fixture")
            } catch {
                fatalError("Unable to prepare hero account: \(error)")
            }
        }
        model.accountsProviders.reloadAccounts()
        model.settings.heroBackground.settings.homeTrailerEnabled = false
        model.settings.heroBackground.settings.detailMode = .off
        _appModel = State(initialValue: model)
    }

    private var home: some View {
        NavigationStack {
            PlozziOSHomeScrollView(heroActive: true) {
                PlozziOSHomeHeroCarousel(
                    items: HeroInteractionProvider.slides,
                    autoAdvance: testsAutoAdvance,
                    autoAdvanceSeconds: 3,
                    onPlay: { _ in playCount += 1 },
                    onPinnedItemsChanged: { pinnedIDs = $0.sorted().joined(separator: ",") },
                    isFrontmost: !presentsSeasons,
                    pullModel: pull
                )
            } rows: {
                Text("Below the hero").accessibilityIdentifier("hero-following-row")
                Color.clear.frame(height: 1_200)
            }
            .overlay(alignment: .topTrailing) {
                if testsAutoAdvance {
                    Button("Open Seasons") { presentsSeasons = true }
                }
            }
            .plozzSheet(isPresented: $presentsSeasons) {
                PlozziOSSeasonRequestSheet(
                    series: MediaItem(id: "series", title: "Fixture Series", kind: .series),
                    availability: HeroRequestControlsFixture.availableSeasons,
                    isRequesting: false, isRefreshing: false, refreshFailed: false, actingName: nil,
                    onRefresh: {}, onRequest: { _ in }
                )
                .overlay(alignment: .bottom) {
                    Text(verbatim: pinnedIDs).accessibilityIdentifier("sheet-hero-selection")
                }
            }
            .navigationTitle(usesNativeChrome ? "" : "Home fixture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar(usesVerticalToolbar ? .visible : .automatic, for: .navigationBar)
            .toolbar {
                if usesNativeChrome {
                    PlozziOSSettingsToolbarItem {}
                }
            }
        }
    }

    var body: some View {
        HeroInteractionNavigationChrome(enabled: usesNativeChrome, sidebar: sidebar) {
            home
        }
        .overlay(alignment: .bottomTrailing) {
            VStack {
                Text(verbatim: "\(playCount)").accessibilityIdentifier("hero-play-count")
                Text(verbatim: "\(actions.watchlistCount)").accessibilityIdentifier("hero-watchlist-count")
            }
            .allowsHitTesting(false)
        }
        .environment(appModel)
        .environment(trailer)
        .environment(sidebar)
        .environment(\.mediaItemActionHandler, actions)
        .environment(\.plozzMetrics, .touch(density: .standard))
        .environment(\.locale, Locale(identifier: "en_US"))
        .environment(\.themePalette, colorScheme == .dark ? .dark : .light)
        .environment(\.colorScheme, colorScheme)
        .preferredColorScheme(colorScheme)
        .plozziOSTracksHeroContainerHeight()
    }
}

private struct HeroInteractionNavigationChrome<Content: View>: View {
    let enabled: Bool
    let sidebar: PlozziOSSidebarGeometryModel
    @ViewBuilder let content: Content
    @State private var selection = 0

    var body: some View {
        if enabled {
            TabView(selection: $selection) {
                Tab("Home", systemImage: "house", value: 0) { content }
                Tab("Live TV", systemImage: "antenna.radiowaves.left.and.right", value: 1) { Text("Live TV fixture") }
                Tab("Downloads", systemImage: "arrow.down.circle", value: 2) { Text("Downloads fixture") }
                Tab("Search", systemImage: "magnifyingglass", value: 3, role: .search) { Text("Search fixture") }
            }
            .tabViewStyle(.sidebarAdaptable)
            .background {
                PlozziOSHomeSidebarOverlapProbe(enabled: selection == 0, geometryModel: sidebar)
                    .frame(width: 0, height: 0)
            }
        } else {
            content
        }
    }
}

@MainActor
@Observable
private final class HeroInteractionActions: MediaItemActionHandling {
    var watchlistCount = 0

    func actions(for item: MediaItem, context: MediaItemActionContext) -> [MediaItemAction] {
        [.addToWatchlist]
    }

    func perform(_ action: MediaItemAction, on item: MediaItem, context: MediaItemActionContext) {
        if action == .addToWatchlist { watchlistCount += 1 }
    }
}

private struct HeroInteractionProvider: MediaProvider {
    let kind: ProviderKind
    static let logoURL = URL(string: "https://hero.invalid/logo.png")!
    static let artworkURL = URL(string: "https://hero.invalid/full-width.png")!

    var account: Account {
        Account(
            id: kind.rawValue,
            server: MediaServer(
                id: kind.rawValue, name: kind.rawValue,
                baseURL: URL(string: "https://hero.invalid")!, provider: kind
            ),
            userID: "viewer", userName: "Viewer", deviceID: "fixture"
        )
    }
    var session: UserSession { account.session(token: "fixture") }

    static var slides: [MediaItem] {
        [
            MediaItem(
                id: "movie", title: "Hero Movie", kind: .movie,
                overview: "A movie description in the Home hero.",
                backdropURL: ProcessInfo.processInfo.arguments.contains("--hero-native-chrome") ? artworkURL : nil,
                logoURL: ProcessInfo.processInfo.arguments.contains("--hero-logo") ? logoURL : nil
            ).taggingSource(ProviderKind.jellyfin.rawValue),
            MediaItem(
                id: "episode", title: "Hero Episode", kind: .episode,
                overview: "An episode description in the Home hero.",
                parentTitle: "Hero Series", seasonNumber: 1, episodeNumber: 2, seriesID: "series"
            ).taggingSource(ProviderKind.emby.rawValue)
        ]
    }

    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: 0, totalCount: 0)
    }
    func item(id: String) async throws -> MediaItem {
        if id == "series" {
            return MediaItem(
                id: id, title: "Hero Series", kind: .series,
                overview: "Details for series from \(account.id)"
            ).taggingSource(account.id)
        }
        guard var item = Self.slides.first(where: { $0.id == id && $0.sourceAccountID == account.id }) else {
            throw AppError.notFound
        }
        item.overview = "Details for \(item.id) from \(account.id)"
        return item
    }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
