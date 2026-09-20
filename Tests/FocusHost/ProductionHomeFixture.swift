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
    @State private var expectedNativeDestination: NavigationRailDestination?
    @State private var prematureNativeHomeFocusCount = 0
    @State private var nativeSidebarFocus = NavigationDestinationFocusHandoff()

    private var isPinned: Bool { ProcessInfo.processInfo.arguments.contains("--pinned-home") }
    private var isNativeSidebar: Bool {
        ProcessInfo.processInfo.arguments.contains("--native-sidebar-home")
    }

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
                    } else if isNativeSidebar {
                        TabView(selection: Binding(
                            get: { selection },
                            set: { destination in
                                if destination != selection { nativeSidebarFocus.begin(destination) }
                                selection = destination
                            }
                        )) {
                            Tab("Home", systemImage: "house", value: NavigationRailDestination.home) {
                                AnyView(NativeSidebarFocusDestination(
                                    destination: .home, selection: selection, handoff: nativeSidebarFocus,
                                    content: ProductionHomeContent(
                                    fixture: fixture, path: $path, isPinned: false,
                                    isActive: selection == .home
                                )
                                .background {
                                    // Native tabs can share a hosting ancestor. Keep the
                                    // measured hero region disjoint from Settings' target.
                                    GeometryReader { geometry in
                                        NativeFocusRegionObserver {
                                            if expectedNativeDestination == .settings {
                                                prematureNativeHomeFocusCount += 1
                                            }
                                        }
                                        .frame(height: geometry.size.height / 2)
                                        .frame(maxHeight: .infinity, alignment: .bottom)
                                    }
                                })
                                .tvNavigationExitProtectionContent())
                            }
                            Tab("Settings", systemImage: "gearshape", value: NavigationRailDestination.settings) {
                                AnyView(NativeSidebarFocusDestination(
                                    destination: .settings, selection: selection, handoff: nativeSidebarFocus,
                                    content: Button("Native settings content") {}
                                    .accessibilityIdentifier("native-production-settings")
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                ).tvNavigationExitProtectionContent())
                            }
                        }
                        .tabViewStyle(.sidebarAdaptable)
                        .tvNavigationExitProtection(isEnabled: true)
                        .onPlayPauseCommand {
                            expectedNativeDestination = .settings
                            prematureNativeHomeFocusCount = 0
                        }
                        .overlay(alignment: .bottomTrailing) {
                            VStack {
                                Text(expectedNativeDestination?.storageValue ?? "idle")
                                    .accessibilityIdentifier("native-production-armed")
                                Text("\(prematureNativeHomeFocusCount)")
                                    .accessibilityIdentifier("native-production-premature-focus")
                            }
                            .allowsHitTesting(false)
                        }
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
        .task {
            guard ProcessInfo.processInfo.arguments.contains("--home-hitch-positive-control") else { return }
            for _ in 0..<200 {
                do { try await Task.sleep(for: .milliseconds(450)) }
                catch is CancellationError { return }
                catch { preconditionFailure("Unexpected fixture control delay failure: \(error)") }
                Self.blockForHitchControl()
            }
        }
    }

    @MainActor
    private static func blockForHitchControl() {
        Thread.sleep(forTimeInterval: 0.12)
    }
}

private struct ProductionHomeContent: View {
    let fixture: ProductionHomeState
    @Binding var path: [MediaItem]
    let isPinned: Bool
    var isActive = true

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(
                viewModel: fixture.model,
                visibility: fixture.visibility,
                heroSettings: fixture.heroSettings,
                heroBackground: fixture.background,
                heroTrailerController: fixture.trailer,
                heroIsFrontmost: isActive && path.isEmpty,
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
        .mediaItemActionHandler(
            ProcessInfo.processInfo.arguments.contains("--home-menu-control") ? fixture.actions : nil
        )
    }
}

@MainActor
private final class ProductionHomeActions: MediaItemActionHandling {
    private(set) var performed: [MediaItemAction] = []

    func actions(for item: MediaItem, context: MediaItemActionContext) -> [MediaItemAction] {
        [.markWatched, .addToWatchlist, .removeFromContinueWatching]
    }

    func perform(_ action: MediaItemAction, on item: MediaItem, context: MediaItemActionContext) {
        performed.append(action)
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
    let actions = ProductionHomeActions()
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
        settings.isEnabled = !ProcessInfo.processInfo.arguments.contains("--hero-disabled-home")
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
        let complex = ProcessInfo.processInfo.arguments.contains("--complex-home-artwork")
        let image = UIGraphicsImageRenderer(size: size).image { context in
            if complex, name == "logo" {
                for index in 0..<8 {
                    UIColor(hue: CGFloat(index) / 8, saturation: 0.85, brightness: 0.95, alpha: 1).setFill()
                    UIBezierPath(roundedRect: CGRect(
                        x: CGFloat(index) * size.width / 8 + 2, y: 15,
                        width: size.width / 8 - 4, height: 70 - CGFloat(index % 3) * 9
                    ), cornerRadius: 5).fill()
                }
            } else if complex {
                NativeComparisonPattern.makeImage().draw(in: CGRect(origin: .zero, size: size))
            } else {
                color.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
        }
        guard let bytes = image.pngData(), let cache = ArtworkSession.shared.configuration.urlCache else {
            preconditionFailure("The isolated Home fixture requires its local artwork cache.")
        }
        let references = ProcessInfo.processInfo.arguments.contains("--distinct-home-artwork")
            ? [url] + (0..<150).map { ProductionHomeProvider.artworkURL(url, index: $0) }
            : [url]
        for reference in references {
            for variant in ArtworkImageVariant.allCases {
                let requestURL = variant.requestURL(for: reference)
                let response = HTTPURLResponse(
                    url: requestURL, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
                )!
                cache.storeCachedResponse(
                    CachedURLResponse(response: response, data: bytes), for: URLRequest(url: requestURL)
                )
            }
        }
        for variant in ArtworkImageVariant.allCases {
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
    private var rowCount: Int {
        ProcessInfo.processInfo.arguments.contains("--home-performance-fixture") ? 75 : 24
    }

    static func artworkURL(_ base: URL, index: Int) -> URL {
        base.appending(queryItems: [URLQueryItem(name: "fixture-item", value: String(index))])
    }

    private func reference(_ base: URL, index: Int) -> URL {
        ProcessInfo.processInfo.arguments.contains("--distinct-home-artwork")
            ? Self.artworkURL(base, index: index) : base
    }
    var kind: ProviderKind { .jellyfin }
    var session: UserSession {
        UserSession(
            server: MediaServer(id: "home-fixture", name: "Fixture", baseURL: backdrop, provider: .jellyfin),
            userID: "fixture", userName: "Fixture", deviceID: "fixture", accessToken: ""
        )
    }

    private func movie(_ index: Int) -> MediaItem {
        let poster = reference(self.poster, index: index)
        let backdrop = reference(self.backdrop, index: index)
        var item = MediaItem(
            id: "home-movie-\(index)", title: "Fixture movie \(index)", kind: .movie,
            posterURL: poster, backdropURL: backdrop
        )
        item.sourceAccountID = "home-fixture"
        item.logoURL = reference(logo, index: index)
        item.heroBackdropURL = backdrop
        item.runtime = 7200
        item.resumePosition = index < rowCount ? 1800 : nil
        item.overview = "A locally supplied movie for measuring the production Home view."
        return item
    }

    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { Array((0..<rowCount).prefix(limit).map(movie)) }
    func latest(limit: Int) async throws -> [MediaItem] { Array((rowCount..<(rowCount * 2)).prefix(limit).map(movie)) }
    func item(id: String) async throws -> MediaItem {
        guard let index = Int(id.split(separator: "-").last ?? ""), (0..<(rowCount * 2)).contains(index) else {
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
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? {
        guard let index = Int(itemID.split(separator: "-").last ?? "") else { return poster }
        return reference(poster, index: index)
    }
}
