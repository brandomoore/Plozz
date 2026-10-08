import CoreModels
import CoreUI
import AVFoundation
import notify
import FeatureHome
import FeatureHomeCore
import MetadataKit
import Observation
import SwiftUI
import UIKit
@testable import AppShell

@MainActor
@Observable
fileprivate final class HeldHomeArtworkState {
    static let shared = HeldHomeArtworkState()
    var started = 0
    var completed = 0
}

private actor HeldHomeArtworkLoader: ArtworkNetworkFileLoading {
    func loadArtwork(_ reference: NetworkArtworkReference, maximumBytes: Int) async throws -> Data {
        await MainActor.run { HeldHomeArtworkState.shared.started += 1 }
        try await Task.sleep(for: .seconds(300))
        await MainActor.run { HeldHomeArtworkState.shared.completed += 1 }
        return Data()
    }
}

struct ProductionHomeFixture: View {
    @State private var fixture: ProductionHomeState?
    @State private var path: [MediaItem] = []
    @State private var libraryPath = NavigationPath()
    @State private var selection = NavigationRailDestination.home
    @State private var profile = Profile(name: "Viewer")
    @State private var expectedNativeDestination: NavigationRailDestination?
    @State private var prematureNativeHomeFocusCount = 0
    @State private var nativeSidebarFocus = NavigationDestinationFocusHandoff()

    private var isPinned: Bool { ProcessInfo.processInfo.arguments.contains("--pinned-home") }
    /// `--focus-style=<name>` picks a card focus style; native system focus otherwise.
    private static var focusStyle: CardFocusStyle {
        ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix("--focus-style=") }
            .flatMap { CardFocusStyle(rawValue: String($0.dropFirst("--focus-style=".count))) } ?? .system
    }
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
                            content: ProductionHomeContent(fixture: fixture, path: $path, libraryPath: $libraryPath, isPinned: true),
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
                                    fixture: fixture, path: $path, libraryPath: $libraryPath, isPinned: false,
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
                        ProductionHomeContent(fixture: fixture, path: $path, libraryPath: $libraryPath, isPinned: false)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    VStack {
                        Text("Production Home ready")
                        if ProcessInfo.processInfo.arguments.contains("--held-home-artwork") {
                            Text(verbatim: "\(HeldHomeArtworkState.shared.started)")
                                .accessibilityIdentifier("home-held-artwork-started")
                            Text(verbatim: "\(HeldHomeArtworkState.shared.completed)")
                                .accessibilityIdentifier("home-held-artwork-completed")
                        }
                        if ProcessInfo.processInfo.arguments.contains("--library-detail-sequence") {
                            Text(verbatim: "\(libraryPath.count)")
                                .accessibilityIdentifier("detail-sequence-route-depth")
                            Text(verbatim: "\(fixture.detailDepth.depth)")
                                .accessibilityIdentifier("detail-sequence-page-depth")
                            Text(verbatim: fixture.trailer.currentItemID ?? "none")
                                .accessibilityIdentifier("detail-sequence-trailer-owner")
                        }
                        if ProcessInfo.processInfo.arguments.contains("--progressive-home-load") {
                            Text(verbatim: fixture.model.loadingRows.contains(.continueWatching) ? "pending" : "ready")
                                .accessibilityIdentifier("home-fixture-resume-state")
                            Text(verbatim: fixture.model.loadingRows.contains(.recentlyAdded) ? "pending" : "ready")
                                .accessibilityIdentifier("home-fixture-latest-state")
                        }
                        if ProcessInfo.processInfo.arguments.contains("--showcase-discover-fixture") {
                            Text(verbatim: fixture.discoveryLoad.isReady ? "ready" : "pending")
                                .accessibilityIdentifier("home-fixture-discover-state")
                        }
                    }
                    .font(.caption2)
                    .allowsHitTesting(false)
                }
            } else {
                ProgressView("Preparing local Home data")
            }
        }
        .environment(\.plozzCardFocusStyle, Self.focusStyle)
        .environment(\.gradientBackgroundsEnabled, !ProcessInfo.processInfo.arguments.contains("--gradient-off"))
        .environment(\.themePalette, ProcessInfo.processInfo.arguments.contains("--gradient-black") ? .pureBlack : .dark)
        .environment(\.plozzCardStyle, ProcessInfo.processInfo.arguments.contains("--framed-cards") ? .framed : .borderless)
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
    @Binding var libraryPath: NavigationPath
    let isPinned: Bool
    var isActive = true
    private var isLibrarySequence: Bool {
        ProcessInfo.processInfo.arguments.contains("--library-detail-sequence")
    }

    var body: some View {
        Group {
            if isLibrarySequence {
                NavigationStack(path: $libraryPath) {
                    LibraryBrowseView(
                        viewModel: fixture.library, title: Text("Movie sequence library"),
                        onSelect: { item in
                            withCinematicDetailNavigation(for: item) {
                                libraryPath.append(LibraryDetailRoute(item: item, originAccountID: "home-fixture"))
                            }
                        }
                    )
                    .navigationDestination(for: LibraryDetailRoute.self) { route in
                        detailPage(for: route.item)
                    }
                }
            } else {
                NavigationStack(path: $path) {
                    HomeView(
                        viewModel: fixture.model,
                        visibility: fixture.visibility,
                        heroSettings: fixture.heroSettings,
                        heroBackground: fixture.background,
                        heroTrailerController: fixture.trailer,
                        heroIsFrontmost: isActive && path.isEmpty,
                        heroRuntime: fixture.runtime,
                        heroFeaturedProvider: { limit in await fixture.featuredContent(limit: limit) },
                        heroArtworkProvider: { $0.backdropURL },
                        heroArtworkValidator: { _ in true },
                        navigationStyle: isPinned
                            ? .rail
                            : (ProcessInfo.processInfo.arguments.contains("--native-sidebar-home")
                                ? .sidebar : .default),
                        onSelectItem: { item in withCinematicDetailNavigation(for: item) { path.append(item) } },
                        onPlayItem: { _ in },
                        onSelectLibrary: { _ in }
                    )
                    .navigationDestination(for: MediaItem.self) { item in
                        detailPage(for: item)
                    }
                }
            }
        }
        .reportsNavigationDepth(isLibrarySequence ? libraryPath.count : path.count, to: isPinned ? fixture.chrome : nil)
        .mediaItemActionHandler(
            ProcessInfo.processInfo.arguments.contains("--home-menu-control") ? fixture.actions : nil
        )
    }

    private func detailPage(for item: MediaItem) -> some View {
        ItemDetailView(
            viewModel: fixture.detail(for: item),
            onPlay: { _ in },
            onSelectChild: { next in
                withCinematicDetailNavigation(for: next) {
                    if isLibrarySequence {
                        libraryPath.append(LibraryDetailRoute(item: next, originAccountID: "home-fixture"))
                    } else {
                        path.append(next)
                    }
                }
            },
            stackDepth: isLibrarySequence ? fixture.detailDepth : nil,
            heroTrailerResolver: { [url = fixture.trailerURL] item in
                url.map {
                    HeroTrailerSource(
                        ownerItemID: item.id, trailerItemID: "trailer-\(item.id)",
                        url: $0, duration: 60
                    )
                }
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
@Observable
private final class ProductionDiscoveryLoadState {
    var isReady = false
}

@MainActor
private final class ProductionHomeState {
    let model: HomeViewModel
    let library: LibraryBrowseViewModel
    let detailDepth = DetailStackDepth()
    let trailerURL: URL?
    let visibility = HomeLibraryVisibilityModel()
    let heroSettings = HeroSettingsModel()
    let background = HeroBackgroundSettingsModel()
    let trailer = HeroTrailerController()
    let runtime = HomeHeroRuntimeState()
    let chrome = NavigationChromeModel()
    let actions = ProductionHomeActions()
    let discoveryLoad = ProductionDiscoveryLoadState()
    private let provider: ProductionHomeProvider
    private var details: [String: ItemDetailViewModel] = [:]

    private init(poster: URL, backdrop: URL, logo: URL, trailerURL: URL?) {
        self.trailerURL = trailerURL
        let provider = ProductionHomeProvider(poster: poster, backdrop: backdrop, logo: logo)
        self.provider = provider
        library = LibraryBrowseViewModel(
            provider: provider, containerID: "detail-sequence-library", containerKind: .movie,
            sourceAccountID: "home-fixture"
        )
        let account = Account(
            id: "home-fixture", server: provider.session.server,
            userID: "fixture", userName: "Fixture", deviceID: "fixture"
        )
        let visibility = self.visibility
        visibility.setContinueWatchingShowsSeriesArtwork(
            !ProcessInfo.processInfo.arguments.contains("--episode-home-artwork")
        )
        let libraryRows = ProcessInfo.processInfo.arguments.contains("--progressive-library-rows")
        visibility.setMergeLibrariesOnHome(!libraryRows)
        for row in HomeGlobalRow.allCases {
            visibility.setGlobalRowEnabled(!libraryRows || row == .continueWatching, for: row)
        }
        if libraryRows {
            for index in 0..<20 {
                visibility.setLibraryRowEnabled(
                    true, libraryKey: "home-fixture:fixture-library-\(index)", kind: .recentlyAdded
                )
            }
        }
        model = HomeViewModel(
            accounts: [ResolvedAccount(account: account, provider: provider)],
            layoutStore: InMemoryHomeLayoutStore(),
            contentStore: InMemoryHomeContentStore(),
            currentVisibility: { visibility.visibility }
        )
        var settings = heroSettings.settings
        settings.isEnabled = !ProcessInfo.processInfo.arguments.contains("--hero-disabled-home")
        settings.sources = [.continueWatching, .recentlyAdded]
        settings.autoAdvance = false
        settings.trailersEnabled = false
        // Settings persist between launches, so every launch picks its layout.
        settings.style = ProcessInfo.processInfo.arguments.contains("--immersive-home") ? .followsFocus : .carousel
        settings.showsDiscoverRow = ProcessInfo.processInfo.arguments.contains("--showcase-discover-fixture")
        heroSettings.settings = settings
        background.settings.homeTrailerEnabled = false
        if trailerURL != nil { background.settings.detailMode = .trailer }
    }

    func detail(for item: MediaItem) -> ItemDetailViewModel {
        if let existing = details[item.id] { return existing }
        let model = ItemDetailViewModel(provider: provider, itemID: item.id, initialItem: item)
        details[item.id] = model
        return model
    }

    func featuredContent(limit: Int) async -> [MediaItem] {
        guard ProcessInfo.processInfo.arguments.contains("--showcase-discover-fixture") else { return [] }
        let items = await provider.featuredContent(limit: limit)
        discoveryLoad.isReady = true
        return items
    }

    static func load() async -> ProductionHomeState {
        let settingsStore = MetadataProviderSettingsStore()
        var settings = settingsStore.load()
        settings.preferOnlineArtwork = false
        if ProcessInfo.processInfo.arguments.contains("--held-home-artwork") {
            settings = .init(
                orderMode: .custom,
                disabledOrder: MetadataSourceAttribution.all.map(\.source.rawValue)
            )
            ArtworkImageCache.shared.configure(networkFileService: ArtworkNetworkFileService(loader: HeldHomeArtworkLoader()))
        }
        settingsStore.save(settings)
        let poster = await artwork(name: "poster", size: CGSize(width: 240, height: 360), color: .systemIndigo)
        let backdrop = await artwork(name: "backdrop", size: CGSize(width: 960, height: 540), color: .systemBlue)
        let scheduleFixture = ProcessInfo.processInfo.arguments.contains("--showcase-schedule-fixture")
        let logo = await artwork(
            name: "logo", size: scheduleFixture ? CGSize(width: 180, height: 320) : CGSize(width: 320, height: 100),
            color: .white
        )
        let trailerURL: URL?
        if ProcessInfo.processInfo.arguments.contains("--library-detail-sequence") {
            do {
                trailerURL = try await makeTrailerVideo()
            } catch {
                preconditionFailure("The detail sequence requires a playable local trailer: \(error)")
            }
        } else {
            trailerURL = nil
        }
        let state = ProductionHomeState(poster: poster, backdrop: backdrop, logo: logo, trailerURL: trailerURL)
        if ProcessInfo.processInfo.arguments.contains("--cached-home-hero") {
            state.model.cacheHeroItems([state.provider.heroSeed], for: state.heroSettings.settings)
            await state.model.waitForHeroPersistence()
        }
        if ProcessInfo.processInfo.arguments.contains("--cached-showcase-discover") {
            var discovery = state.heroSettings.settings
            discovery.isEnabled = true
            discovery.sources = [.featured]
            state.model.cacheHeroItems([state.provider.heroSeed], for: discovery)
            await state.model.waitForHeroPersistence()
        }
        if ProcessInfo.processInfo.arguments.contains("--slow-home-load")
            || ProcessInfo.processInfo.arguments.contains("--progressive-home-load") {
            // Show Home at once and let its rows arrive late, over the skeleton.
            Task { await state.model.load() }
        } else {
            await state.model.load()
        }
        return state
    }

    private static func makeTrailerVideo() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("detail-sequence-\(UUID()).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160, AVVideoHeightKey: 96
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 96
            ]
        )
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? AppError.unknown("") }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 160, 96, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
              let buffer else { throw AppError.invalidResponse }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let address = CVPixelBufferGetBaseAddress(buffer) {
            memset(address, 0x80, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let deadline = ContinuousClock.now + .seconds(10)
        for frame in 0..<60 {
            while !input.isReadyForMoreMediaData, writer.status == .writing, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard input.isReadyForMoreMediaData,
                  adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 1))
            else { throw writer.error ?? AppError.invalidResponse }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? AppError.invalidResponse }
        return url
    }

    private static func artwork(name: String, size: CGSize, color: UIColor) async -> URL {
        let url = URL(string: "https://production-home.example.test/\(name).png")!
        let complex = ProcessInfo.processInfo.arguments.contains("--complex-home-artwork")
        let image = UIGraphicsImageRenderer(size: size).image { context in
            if name == "logo", ProcessInfo.processInfo.arguments.contains("--showcase-schedule-fixture") {
                UIColor.systemGreen.setFill()
                context.fill(CGRect(x: 20, y: 10, width: 40, height: 300))
                context.fill(CGRect(x: 50, y: 10, width: 110, height: 40))
                context.fill(CGRect(x: 50, y: 140, width: 70, height: 40))
            } else if complex, name == "logo" {
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
            let referenceBytes: Data
            if ProcessInfo.processInfo.arguments.contains("--gradient-performance"),
               let value = URLComponents(url: reference, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "fixture-item" })?.value,
               let index = Int(value) {
                let tinted = UIGraphicsImageRenderer(size: size).image { context in
                    image.draw(in: CGRect(origin: .zero, size: size))
                    context.cgContext.setBlendMode(.color)
                    UIColor(hue: CGFloat(index % 12) / 12, saturation: 0.8, brightness: 0.7, alpha: 1).setFill()
                    context.fill(CGRect(origin: .zero, size: size))
                }
                referenceBytes = tinted.pngData() ?? bytes
            } else {
                referenceBytes = bytes
            }
            for variant in ArtworkImageVariant.allCases {
                let requestURL = variant.requestURL(for: reference)
                let response = HTTPURLResponse(
                    url: requestURL, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
                )!
                cache.storeCachedResponse(
                    CachedURLResponse(response: response, data: referenceBytes), for: URLRequest(url: requestURL)
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
    private let heldArtworkRevision = CredentialRevision()
    private let progressiveGate = ProductionHomeRowsGate()
    private let recentGate = ProductionHomeRowsGate(notificationKey: "PLOZZ_HOME_RECENT_RELEASE_NOTIFICATION")
    private let discoverGate = ProductionHomeRowsGate(notificationKey: "PLOZZ_HOME_DISCOVER_RELEASE_NOTIFICATION")
    private var rowCount: Int {
        ProcessInfo.processInfo.arguments.contains("--home-performance-fixture") ? 75 : 24
    }
    var heroSeed: MediaItem { movie(rowCount + 10) }

    func featuredContent(limit: Int) async -> [MediaItem] {
        await discoverGate.wait()
        return Array((rowCount..<(rowCount * 2)).prefix(limit).map(movie))
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
            id: "home-movie-\(index)", title: "Fixture movie \(index)",
            kind: ProcessInfo.processInfo.arguments.contains("--showcase-schedule-fixture") ? .series : .movie,
            posterURL: poster, backdropURL: backdrop
        )
        item.sourceAccountID = "home-fixture"
        item.logoURL = reference(logo, index: index)
        item.heroBackdropURL = backdrop
        item.runtime = 7200
        item.resumePosition = index < rowCount ? 1800 : nil
        item.overview = "A locally supplied movie for measuring the production Home view."
        if ProcessInfo.processInfo.arguments.contains("--held-home-artwork") {
            item.posterURL = nil
            item.backdropURL = nil
            item.heroBackdropURL = nil
            item.logoURL = nil
            do {
                let reference = ArtworkReference.networkFile(try NetworkArtworkReference(
                    accountID: "home-fixture", credentialRevision: heldArtworkRevision,
                    catalogArtworkID: "held-\(index)",
                    representation: RemoteFileRepresentation(
                        size: 1_024,
                        identity: RemoteFileIdentity(kind: .modificationTime, modifiedAt: .distantPast),
                        consistency: .changeDetecting
                    ),
                    sourceRevision: "held", dimensions: ArtworkDimensions(width: 960, height: 540)
                ))
                item.artworkSelections = [ArtworkPlacement.poster, .detailBackdrop, .homeHero, .logo].map {
                    .init(placement: $0, references: [reference])
                }
            } catch {
                preconditionFailure("Invalid held artwork fixture: \(error)")
            }
        }
        return item
    }

    func libraries() async throws -> [MediaLibrary] {
        guard ProcessInfo.processInfo.arguments.contains("--progressive-library-rows") else { return [] }
        return (0..<20).map {
            MediaLibrary(id: "fixture-library-\($0)", title: "Fixture library \($0)", kind: .movie)
        }
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] {
        if ProcessInfo.processInfo.arguments.contains("--progressive-home-load") {
            await progressiveGate.wait()
        }
        if ProcessInfo.processInfo.arguments.contains("--empty-home-resume") { return [] }
        try await holdForSlowLoad()
        let items = Array((0..<rowCount).prefix(limit).map(movie))
        if ProcessInfo.processInfo.arguments.contains("--showcase-schedule-fixture") {
            let now = Date()
            for item in items {
                await SeriesScheduleStore.shared.store(SeriesScheduleRecord(
                    seriesKey: MetadataQuery(item).seriesScoped.enrichmentCacheKey,
                    upcomingEpisode: UpcomingEpisode(
                        seriesIdentity: .external(source: "fixture", value: item.id),
                        airDate: now.addingTimeInterval(20 * 86_400),
                        datePrecision: .dateOnly, source: .tvdb, refreshedAt: now
                    ),
                    cadence: AirCadence(weekdays: [6]),
                    refreshedAt: now, refreshDueAt: now.addingTimeInterval(3_600)
                ))
            }
        }
        return items
    }
    func latest(limit: Int) async throws -> [MediaItem] {
        await recentGate.wait()
        try await holdForSlowLoad()
        return Array((rowCount..<(rowCount * 2)).prefix(limit).map(movie))
    }
    /// Keeps Home on its loading skeleton for a while so it can be captured.
    private func holdForSlowLoad() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--slow-home-load") else { return }
        try await Task.sleep(for: .seconds(6))
    }
    func item(id: String) async throws -> MediaItem {
        let count = ProcessInfo.processInfo.arguments.contains("--progressive-library-rows")
            ? rowCount + 400 : rowCount * 2
        guard let index = Int(id.split(separator: "-").last ?? ""), (0..<count).contains(index) else {
            throw AppError.notFound
        }
        return movie(index)
    }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        if containerID == "detail-sequence-library" {
            let end = min(page.startIndex + page.limit, rowCount * 2)
            return MediaPage(
                items: page.startIndex < end ? (page.startIndex..<end).map(movie) : [],
                startIndex: page.startIndex, totalCount: rowCount * 2
            )
        }
        guard containerID.hasPrefix("fixture-library-"),
              let index = Int(containerID.split(separator: "-").last ?? "") else {
            return MediaPage(items: [], startIndex: page.startIndex, totalCount: 0)
        }
        if index > 0 {
            await progressiveGate.wait()
        } else {
            await recentGate.wait()
        }
        let start = rowCount + index * 20
        return MediaPage(
            items: Array((start..<(start + 20)).prefix(page.limit).map(movie)),
            startIndex: page.startIndex, totalCount: 20
        )
    }

    private final class ProductionHomeRowsGate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var token: Int32 = -1

        init(notificationKey: String = "PLOZZ_HOME_ROWS_RELEASE_NOTIFICATION") {
            guard let name = ProcessInfo.processInfo.environment[notificationKey] else {
                opened = true
                return
            }
            let status = notify_register_dispatch(name, &token, .main) { [weak self] _ in self?.open() }
            precondition(status == UInt32(NOTIFY_STATUS_OK), "The progressive Home fixture needs its release notification.")
        }

        deinit { if token >= 0 { notify_cancel(token) } }

        private func open() {
            lock.lock()
            opened = true
            let pending = waiters
            waiters = []
            lock.unlock()
            pending.forEach { $0.resume() }
        }

        func wait() async {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    lock.lock()
                    if opened {
                        lock.unlock()
                        continuation.resume()
                    } else {
                        waiters.append(continuation)
                        lock.unlock()
                    }
                }
            } onCancel: {
                self.open()
            }
        }
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? {
        guard let index = Int(itemID.split(separator: "-").last ?? "") else { return poster }
        return reference(poster, index: index)
    }
}
