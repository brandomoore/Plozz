import CoreModels
import CoreUI
import FeatureHome
import FeatureHomeCore
import SwiftUI
import UIKit
@testable import AppShell

struct ProductionHomeFixture: View {
    @State private var fixture: ProductionHomeState?
    @State private var path: [MediaItem] = []
    @State private var selection = NavigationRailDestination.home
    @State private var profile = Profile(name: "Viewer")

    private var isPinned: Bool { ProcessInfo.processInfo.arguments.contains("--pinned-home") }

    var body: some View {
        Group {
            if let fixture {
                Group {
                    if isPinned {
                        NavigationRailShell(
                            profile: profile, entries: [], destinations: [.home, .search, .settings],
                            selection: $selection, onOpenProfileSwitcher: {},
                            chrome: fixture.chrome,
                            content: ProductionHomeContent(fixture: fixture, path: $path, isPinned: true),
                            contentDestination: .home
                        )
                    } else {
                        ProductionHomeContent(fixture: fixture, path: $path, isPinned: false)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Text("Production Home ready")
                        .font(.caption2)
                        .allowsHitTesting(false)
                }
            } else {
                ProgressView("Preparing local Home data")
            }
        }
        .environment(\.plozzCardFocusStyle, .system)
        .environment(\.plozzCardStyle, .borderless)
        .task {
            guard fixture == nil else { return }
            fixture = await ProductionHomeState.load()
        }
    }
}

private struct ProductionHomeContent: View {
    let fixture: ProductionHomeState
    @Binding var path: [MediaItem]
    let isPinned: Bool

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(
                viewModel: fixture.model,
                visibility: fixture.visibility,
                heroSettings: fixture.heroSettings,
                heroBackground: fixture.background,
                heroTrailerController: fixture.trailer,
                heroIsFrontmost: path.isEmpty,
                heroRuntime: fixture.runtime,
                heroArtworkProvider: { $0.backdropURL },
                heroArtworkValidator: { _ in true },
                navigationStyle: isPinned ? .rail : .default,
                onSelectItem: { item in withCinematicDetailNavigation(for: item) { path.append(item) } },
                onPlayItem: { _ in },
                onSelectLibrary: { _ in }
            )
            .navigationDestination(for: MediaItem.self) { item in
                ItemDetailView(
                    viewModel: fixture.detail(for: item),
                    onPlay: { _ in },
                    onSelectChild: { next in
                        withCinematicDetailNavigation(for: next) { path.append(next) }
                    }
                )
                .environment(fixture.trailer)
                .environment(fixture.background)
                .overlay(alignment: .topTrailing) {
                    Text("Detail fixture \(item.title)")
                        .font(.caption2)
                        .allowsHitTesting(false)
                }
            }
        }
        .reportsNavigationDepth(path.count, to: isPinned ? fixture.chrome : nil)
    }
}

@MainActor
private final class ProductionHomeState {
    let model: HomeViewModel
    let visibility = HomeLibraryVisibilityModel()
    let heroSettings = HeroSettingsModel()
    let background = HeroBackgroundSettingsModel()
    let trailer = HeroTrailerController()
    let runtime = HomeHeroRuntimeState()
    let chrome = NavigationChromeModel()
    private let provider: ProductionHomeProvider
    private var details: [String: ItemDetailViewModel] = [:]

    private init(poster: URL, backdrop: URL, logo: URL) {
        let provider = ProductionHomeProvider(poster: poster, backdrop: backdrop, logo: logo)
        self.provider = provider
        let account = Account(
            id: "home-fixture", server: provider.session.server,
            userID: "fixture", userName: "Fixture", deviceID: "fixture"
        )
        model = HomeViewModel(
            accounts: [ResolvedAccount(account: account, provider: provider)],
            layoutStore: InMemoryHomeLayoutStore(),
            contentStore: InMemoryHomeContentStore()
        )
        var settings = heroSettings.settings
        settings.sources = [.continueWatching, .recentlyAdded]
        settings.autoAdvance = false
        settings.trailersEnabled = false
        heroSettings.settings = settings
        background.settings.homeTrailerEnabled = false
    }

    func detail(for item: MediaItem) -> ItemDetailViewModel {
        if let existing = details[item.id] { return existing }
        let model = ItemDetailViewModel(provider: provider, itemID: item.id, initialItem: item)
        details[item.id] = model
        return model
    }

    static func load() async -> ProductionHomeState {
        let settingsStore = MetadataProviderSettingsStore()
        var settings = settingsStore.load()
        settings.preferOnlineArtwork = false
        settingsStore.save(settings)
        let poster = await artwork(name: "poster", size: CGSize(width: 240, height: 360), color: .systemIndigo)
        let backdrop = await artwork(name: "backdrop", size: CGSize(width: 960, height: 540), color: .systemBlue)
        let logo = await artwork(name: "logo", size: CGSize(width: 320, height: 100), color: .white)
        let state = ProductionHomeState(poster: poster, backdrop: backdrop, logo: logo)
        await state.model.load()
        return state
    }

    private static func artwork(name: String, size: CGSize, color: UIColor) async -> URL {
        let url = URL(string: "https://production-home.example.test/\(name).png")!
        let image = UIGraphicsImageRenderer(size: size).image {
            color.setFill()
            $0.fill(CGRect(origin: .zero, size: size))
        }
        guard let bytes = image.pngData(), let cache = ArtworkSession.shared.configuration.urlCache else {
            preconditionFailure("The isolated Home fixture requires its local artwork cache.")
        }
        for variant in ArtworkImageVariant.allCases {
            let requestURL = variant.requestURL(for: url)
            let response = HTTPURLResponse(
                url: requestURL, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
            )!
            cache.storeCachedResponse(
                CachedURLResponse(response: response, data: bytes), for: URLRequest(url: requestURL)
            )
            guard await ArtworkImageCache.shared.image(for: url, variant: variant) != nil else {
                preconditionFailure("The isolated Home fixture artwork failed to decode.")
            }
        }
        return url
    }
}

private struct ProductionHomeProvider: MediaProvider {
    let poster: URL
    let backdrop: URL
    let logo: URL
    var kind: ProviderKind { .jellyfin }
    var session: UserSession {
        UserSession(
            server: MediaServer(id: "home-fixture", name: "Fixture", baseURL: backdrop, provider: .jellyfin),
            userID: "fixture", userName: "Fixture", deviceID: "fixture", accessToken: ""
        )
    }

    private func movie(_ index: Int) -> MediaItem {
        var item = MediaItem(
            id: "home-movie-\(index)", title: "Fixture movie \(index)", kind: .movie,
            posterURL: poster, backdropURL: backdrop
        )
        item.sourceAccountID = "home-fixture"
        item.logoURL = logo
        item.heroBackdropURL = backdrop
        item.runtime = 7200
        item.resumePosition = index < 24 ? 1800 : nil
        item.overview = "A locally supplied movie for measuring the production Home view."
        return item
    }

    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { Array((0..<24).prefix(limit).map(movie)) }
    func latest(limit: Int) async throws -> [MediaItem] { Array((24..<48).prefix(limit).map(movie)) }
    func item(id: String) async throws -> MediaItem {
        guard let index = Int(id.split(separator: "-").last ?? ""), (0..<48).contains(index) else {
            throw AppError.notFound
        }
        return movie(index)
    }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: page.startIndex, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { poster }
}
