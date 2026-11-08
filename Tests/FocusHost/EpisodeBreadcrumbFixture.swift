import CoreModels
import CoreUI
import FeatureHome
import FeatureHomeCore
import MetadataKit
import Observation
import SwiftUI
import UIKit

struct EpisodeBreadcrumbFixture: View {
    @State private var path: [MediaItem] = []
    @State private var entered = false
    @State private var model = EpisodeBreadcrumbModel()
    @State private var playCount = 0
    @State private var requestCount = 0
    private let seriesNavigation = ProcessInfo.processInfo.arguments.contains("--series-navigation")
    private var focusStyle: CardFocusStyle {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--outlined") { return .outlined }
        if arguments.contains("--highlight") { return .highlight }
        return .system
    }

    var body: some View {
        NavigationStack(path: $path) {
            Button("Go to Episode") { path.append(model.provider.episode) }
                .navigationDestination(for: MediaItem.self) { item in
                    ItemDetailView(
                        viewModel: item.kind == .episode ? model.episode : model.show,
                        onPlay: { _ in playCount += 1 }, onSelectChild: { path.append($0) },
                        onNavigate: { path.append($0) },
                        seerConnected: model.provider.isDiscovery,
                        requestAvailabilityRefresh: requestAvailabilityRefresh,
                        onRequestSeasons: requestSeasons
                    )
                    .environment(model.trailer)
                    .environment(model.background)
                    .mediaItemActionHandler(model.actions)
                    .environment(\.seasonRequestContextID, model.actions.contextID)
                    .overlay(alignment: .topTrailing) {
                        Text(verbatim: "\(item.id)|\(item.seasonID ?? "-")|\(item.sourceAccountID ?? "-")")
                            .accessibilityIdentifier("breadcrumb-route")
                            .allowsHitTesting(false)
                    }
                }
        }
        .overlay(alignment: .topLeading) {
            if ProcessInfo.processInfo.arguments.contains("--episode-menu") {
                VStack {
                    Text(verbatim: model.actions.performedActions.isEmpty
                         ? "none" : model.actions.performedActions.joined(separator: ","))
                        .accessibilityIdentifier("episode-menu-performed-actions")
                    Text(verbatim: "\(playCount)")
                        .accessibilityIdentifier("episode-menu-play-count")
                }
                .allowsHitTesting(false)
            }
            if ProcessInfo.processInfo.arguments.contains("--delayed-series-entry") || model.provider.isDiscovery {
                VStack {
                    Text(verbatim: "\(playCount)").accessibilityIdentifier("detail-entry-play-count")
                    Text(verbatim: "\(requestCount)").accessibilityIdentifier("detail-entry-request-count")
                    Text(verbatim: model.hasLoadedEpisodes ? "ready" : "loading")
                        .accessibilityIdentifier("detail-entry-load-state")
                    Text(verbatim: model.actions.contextID).accessibilityIdentifier("detail-entry-context")
                }
                .allowsHitTesting(false)
            }
        }
        .environment(\.themePalette, .dark)
        .environment(\.plozzCardFocusStyle, focusStyle)
        .environment(\.plozzCardCaptionSettings, CardCaptionSettings(
            episodeDescriptionsOnFocus: ProcessInfo.processInfo.arguments.contains("--descriptions-on-focus")
        ))
        .preferredColorScheme(.dark)
        .detailNavigationZoom(isEnabled: true)
        .background {
            if ProcessInfo.processInfo.arguments.contains("--trace-menu-appearance") {
                MenuAppearanceProbe()
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
            }
        }
        .task {
            guard !entered else { return }
            entered = true
            if seriesNavigation {
                await model.prepareRelated()
                DetailTransitionNavigation.prepare(for: model.provider.series)
                path.append(model.provider.series)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--from-show") {
                path.append(model.provider.series)
            }
            path.append(model.provider.episode)
        }
        .task {
            guard ProcessInfo.processInfo.arguments.contains("--refresh-episode-progress") else { return }
            for revision in 0..<1000 {
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { return }
                model.show.applyWatchedState(MediaItemMutation(
                    itemIDs: ["episode-1", "episode-2", "episode-3"],
                    resumePosition: Double(revision % 2 + 1) / 10
                ))
            }
        }
    }

    private var requestAvailabilityRefresh: (@Sendable (MediaItem) async -> MediaRequestAvailability?)? {
        guard model.provider.isDiscovery else { return nil }
        return { _ in
            do { try await Task.sleep(for: .seconds(16)) }
            catch { return nil }
            if ProcessInfo.processInfo.arguments.contains("--fail-season-lookup") { return nil }
            return MediaRequestAvailability(status: .unknown, seasons: [
                .init(number: 1, title: "Season 1", status: .unknown),
                .init(number: 2, title: "Season 2", status: .unknown)
            ])
        }
    }

    private var requestSeasons: ((MediaItem, [Int]) async -> MediaRequestActionResult)? {
        guard model.provider.isDiscovery else { return nil }
        return { _, _ in
            requestCount += 1
            return .success(.pending)
        }
    }
}

@MainActor
private final class EpisodeBreadcrumbModel {
    let provider: EpisodeBreadcrumbProvider
    let episode: ItemDetailViewModel
    let show: ItemDetailViewModel
    let relatedStore = RelatedTitlesStore(directory: nil)
    let actions = EpisodeBreadcrumbActions()
    let trailer = HeroTrailerController()
    let background = HeroBackgroundSettingsModel(store: InMemoryHeroBackgroundSettingsStore(
        HeroBackgroundSettings(homeTrailerEnabled: false, detailMode: .off)
    ))

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        provider = EpisodeBreadcrumbProvider(
            isUpcoming: arguments.contains("--upcoming"),
            hasBrowser: arguments.contains("--series-navigation"),
            delaysChildren: arguments.contains("--delayed-series-entry"),
            isDiscovery: arguments.contains("--request-primary"),
            relatedCount: arguments.contains("--related-empty") ? 0 : (arguments.contains("--related-single") ? 1 : 3)
        )
        episode = Self.detail(provider.episode, provider: provider)
        let related = provider.related
        let loader = RelatedTitlesLoader(
            resolver: RelatedTitlesResolver(providers: []), store: relatedStore,
            search: { _, _ in related }
        )
        show = Self.detail(provider.series, provider: provider, relatedTitlesLoader: loader)
    }

    var hasLoadedEpisodes: Bool {
        if case .loaded = show.seasonLoadState(for: "season-2") { return true }
        return false
    }

    func prepareRelated() async {
        await relatedStore.store(RelatedTitlesRecord(
            seedKey: MetadataQuery(provider.series).seriesScoped.enrichmentCacheKey,
            titles: provider.related.map {
                RelatedTitle(title: $0.title, year: nil, kind: .series,
                             providerIDs: $0.providerIDs, source: .tmdb)
            },
            refreshedAt: Date()
        ))
    }

    private static func detail(
        _ item: MediaItem, provider: EpisodeBreadcrumbProvider,
        relatedTitlesLoader: RelatedTitlesLoader? = nil
    ) -> ItemDetailViewModel {
        ItemDetailViewModel(
            provider: provider.isDiscovery ? nil : provider, itemID: item.id, initialItem: item,
            isDiscoveryItem: provider.isDiscovery,
            externalMetadataResolver: { _, region in
                ExternalTitleMetadata(enrichment: MetadataEnrichment(),
                                      availability: ExternalTitleAvailability(regionCode: region))
            },
            sourceAccountID: "breadcrumb-account",
            onlineTrailerResolver: { _ in [] }, playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache(), relatedTitlesLoader: relatedTitlesLoader
        )
    }
}

@MainActor @Observable
private final class EpisodeBreadcrumbActions: MediaItemActionHandling {
    var contextID = "original"
    var performedActions: [String] = []

    func actions(for item: MediaItem, context: MediaItemActionContext) -> [MediaItemAction] {
        if ProcessInfo.processInfo.arguments.contains("--delayed-series-entry") { return [.addToWatchlist] }
        return MediaItemActionCatalog.actions(
            for: item, supportsWatchState: ProcessInfo.processInfo.arguments.contains("--episode-menu"),
            supportsWatchlist: ProcessInfo.processInfo.arguments.contains("--episode-menu"),
            supportsMetadataRefresh: ProcessInfo.processInfo.arguments.contains("--episode-menu"),
            context: context
        )
    }
    func perform(_ action: MediaItemAction, on item: MediaItem, context: MediaItemActionContext) {
        performedActions.append(action.rawValue)
        if ProcessInfo.processInfo.arguments.contains("--change-context-on-watchlist") {
            contextID = "changed"
        }
    }
}

private struct MenuAppearanceProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> MenuAppearanceObserver {
        let view = MenuAppearanceObserver()
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "episode-menu-appearance-result"
        view.accessibilityLabel = "Menu appearance trace"
        view.accessibilityValue = "pending"
        return view
    }

    func updateUIView(_ uiView: MenuAppearanceObserver, context: Context) {}
}

private final class MenuAppearanceObserver: UIView {
    private var timer: Timer?
    private var firstFrame: CFTimeInterval?
    private var deadline: CFTimeInterval = 0
    private var lists: Set<ObjectIdentifier> = []
    private var labels: Set<ObjectIdentifier> = []
    private var minimumOpacity: Float = 1
    private var samples = 0

    override func didMoveToWindow() {
        super.didMoveToWindow()
        timer?.invalidate()
        guard window != nil else { return }
        deadline = CACurrentMediaTime() + 30
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func sample() {
        let now = CACurrentMediaTime()
        var foundMenu = false
        func visit(_ view: UIView, insideMenu: Bool) {
            let name = String(describing: type(of: view))
            // Read-only observation of UIKit's menu subtree, never a styling hook.
            let menu = insideMenu || name.contains("ContextMenu")
            if menu {
                if view is UICollectionView {
                    foundMenu = true
                    lists.insert(ObjectIdentifier(view))
                    minimumOpacity = min(minimumOpacity, view.layer.presentation()?.opacity ?? view.layer.opacity)
                }
                if let label = view as? UILabel, label.text?.isEmpty == false {
                    labels.insert(ObjectIdentifier(label))
                }
            }
            for child in view.subviews { visit(child, insideMenu: menu) }
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows { visit(window, insideMenu: false) }
        }
        if foundMenu {
            if firstFrame == nil { firstFrame = now }
            samples += 1
        }
        if now > deadline || firstFrame.map({ now - $0 > 2 }) == true {
            timer?.invalidate()
            timer = nil
            do {
                let summary: [String: Any] = [
                    "lists": lists.count, "labels": labels.count,
                    "minimumOpacity": minimumOpacity, "samples": samples
                ]
                accessibilityValue = String(
                    decoding: try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]),
                    as: UTF8.self
                )
            } catch {
                accessibilityValue = "failed"
                assertionFailure("Menu appearance trace failed: \(error)")
            }
        }
    }
}

private struct EpisodeBreadcrumbProvider: MediaProvider {
    let isUpcoming: Bool
    let hasBrowser: Bool
    let delaysChildren: Bool
    let isDiscovery: Bool
    let relatedCount: Int

    var kind: ProviderKind { .jellyfin }
    var session: UserSession {
        UserSession(
            server: MediaServer(id: "breadcrumb-account", name: "Fixture",
                               baseURL: URL(string: "https://fixture.invalid")!, provider: kind),
            userID: "fixture", userName: "Fixture", deviceID: "fixture", accessToken: ""
        )
    }
    var series: MediaItem {
        var item = MediaItem(id: "show", title: "Fixture Show", kind: .series, overview: "Series plot",
                             providerIDs: isDiscovery ? ["Tmdb": "123"] : [:],
                             sourceAccountID: "breadcrumb-account")
        item.locallyValidatedPlayableSource = !isDiscovery
        if hasBrowser {
            item.people = (1...12).map {
                MediaPerson(id: "actor-\($0)", name: "Fixture Actor \($0)", role: "Character \($0)")
            }
        }
        return item
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
    var related: [MediaItem] {
        guard hasBrowser else { return [] }
        return (0..<relatedCount).map {
            MediaItem(id: "related-\($0)", title: "Related Show \($0)", kind: .series,
                      providerIDs: ["Tmdb": "\(100 + $0)"], allowsTitleBasedMetadataMatching: false)
        }
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { id == "show" ? series : episode }
    func children(of itemID: String) async throws -> [MediaItem] {
        guard hasBrowser else { return [] }
        if delaysChildren { try await Task.sleep(for: .seconds(8)) }
        if itemID == "show" {
            return [MediaItem(id: "season-2", title: "Season 2", kind: .season,
                              seasonNumber: 2, seriesID: "show")]
        }
        return (1...12).map { index in
            var item = episode
            item.id = "episode-\(index)"
            item.episodeNumber = index
            item.title = "Fixture Episode \(index)"
            return item
        }
    }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: 0, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
