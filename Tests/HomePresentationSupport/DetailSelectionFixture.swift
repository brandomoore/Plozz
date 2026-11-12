import CoreModels
import CoreUI
import FeatureHomeCore
import Observation
import SwiftUI
import UIKit
#if os(tvOS)
import FeatureHome
#else
import FeatureAuth
@testable import AppShelliOS
#endif

/// Real detail views and picker actions, with deterministic providers. Mobile
/// records the actual streaming request, then refuses before starting a decoder.
struct DetailSelectionFixture: View {
    @State private var probe: DetailSelectionProbe
    private let providers: [DetailSelectionProvider]
    @State private var trailer = HeroTrailerController()
    @State private var background = HeroBackgroundSettingsModel(store: InMemoryHeroBackgroundSettingsStore(
        HeroBackgroundSettings(homeTrailerEnabled: false, detailMode: .off)
    ))
    @State private var coordinator = ContentRefreshCoordinator(profile: .init(
        home: .init(foregroundAfter: 1, surfaceReturnAfter: 1, action: .reloadHome),
        seriesDetail: .init(foregroundAfter: 1, surfaceReturnAfter: 1, action: .reloadSeriesContext),
        episodeDetail: .init(foregroundAfter: 1, surfaceReturnAfter: 1, action: .refreshWatchStateOnly),
        movieDetail: .init(foregroundAfter: 1, surfaceReturnAfter: 1, action: .refreshWatchStateOnly)
    ))
    #if os(tvOS)
    @State private var detail: ItemDetailViewModel
    private let preferences = VersionPreferenceStore(namespace: UUID().uuidString)
    #else
    @State private var app: PlozziOSAppModel
    @State private var sidebar = PlozziOSSidebarGeometryModel()
    #endif

    init() {
        let probe = DetailSelectionProbe()
        _probe = State(initialValue: probe)
        let series = ProcessInfo.processInfo.arguments.contains("--selection-series")
        let single = ProcessInfo.processInfo.arguments.contains("--selection-single")
        let providers = (single ? [ProviderKind.plex] : [.plex, .jellyfin]).map {
            DetailSelectionProvider(kind: $0, series: series, probe: probe)
        }
        self.providers = providers
        let primary = providers[0]
        var seed = primary.seed
        seed.sources = providers.map { $0.source(for: $0.seed) }
        #if os(tvOS)
        _detail = State(initialValue: ItemDetailViewModel(
            provider: primary, itemID: seed.id, initialItem: seed,
            sourceAccountID: primary.accountID, onlineTrailerResolver: { _ in [] },
            initialSources: seed.sources,
            alternateProviderResolver: { id in providers.first { $0.accountID == id } }
        ))
        #else
        SyncSetupFeatureFlag().isEnabled = false
        let store = AccountStore(secureStore: InMemorySecureStore())
        let model = PlozziOSAppModel(accountStore: store, profileStore: ProfileStore(defaults: .standard))
        let profile = model.profiles.add(name: "Selection fixture", isAwaitingSetup: false)
        model.profiles.select(profile.id)
        model.refreshActiveProfileSettings()
        for provider in providers {
            model.accountsProviders.registry.register(provider.kind) { _ in provider }
            do {
                try store.add(Account(id: provider.accountID, from: provider.session), token: "fixture")
            } catch {
                preconditionFailure("Unable to configure selection fixture: \(error)")
            }
        }
        model.profiles.setActiveAccountIDs(providers.map(\.accountID), for: profile.id)
        model.accountsProviders.tokenResolver = { _ in "fixture" }
        model.accountsProviders.reloadAccounts()
        model.settings.playback.settings.askBeforeResuming = false
        model.settings.playback.settings.resumeRewindInterval = .off
        model.settings.playback.settings.versionSelectionMode = .automatic
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
            #if os(tvOS)
            ItemDetailView(viewModel: detail, onPlay: { item in
                probe.record(account: item.sourceAccountID, item: item.id,
                             version: item.selectedVersionID, position: item.resumePosition)
            }, onSelectChild: { _ in }, versionPreferences: preferences)
            #else
            PlozziOSItemDetailView(appModel: app, provider: providers[0], item: seed)
                .environment(app)
                .environment(sidebar)
            #endif
        }
        .overlay(alignment: .topTrailing) {
            Text(verbatim: probe.receipt).accessibilityIdentifier("selection-receipt")
                .allowsHitTesting(false)
        }
        .environment(coordinator)
        .environment(trailer)
        .environment(background)
        .environment(\.themePalette, .dark)
        .environment(\.locale, Locale(identifier: "en_US"))
        .preferredColorScheme(.dark)
        .background(ContentRefreshLifecycleReader(coordinator: coordinator))
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            for provider in providers { provider.advanceProgress() }
        }
    }

    private var seed: MediaItem {
        var item = providers[0].seed
        item.sources = providers.map { $0.source(for: $0.seed) }
        return item
    }
}

@MainActor @Observable
private final class DetailSelectionProbe {
    var receipt = "No handoff"
    func record(account: String?, item: String, version: String?, position: TimeInterval?) {
        receipt = "\(account ?? "nil")|\(item)|\(version ?? "nil")|\(Int(position ?? 0))"
    }
}

private final class DetailSelectionProvider: MediaProvider, SeriesResumeProviding,
    StreamingQualityProviding, @unchecked Sendable {
    let kind: ProviderKind
    let series: Bool
    let probe: DetailSelectionProbe
    private let lock = NSLock()
    private var progress = false
    var accountID: String { kind.rawValue }

    init(kind: ProviderKind, series: Bool, probe: DetailSelectionProbe) {
        self.kind = kind
        self.series = series
        self.probe = probe
    }

    func advanceProgress() { lock.withLock { progress.toggle() } }
    var session: UserSession {
        .init(server: .init(id: accountID, name: "Fixture \(kind == .plex ? "Plex" : "Jellyfin")",
                            baseURL: URL(string: "https://selection.example.invalid")!, provider: kind),
              userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture")
    }
    var seed: MediaItem { media(series ? "series" : "movie") }
    private func media(_ id: String) -> MediaItem {
        let kind: MediaItemKind = id == "series" ? .series : id == "season" ? .season
            : id == "episode" ? .episode : .movie
        let playable = kind == .movie || kind == .episode
        let advanced = lock.withLock { progress }
        return MediaItem(
            id: "\(accountID)-\(id)", title: playable ? "Selection title" : "Selection show", kind: kind,
            seasonNumber: kind == .episode || kind == .season ? 1 : nil,
            episodeNumber: kind == .episode ? 1 : nil,
            seriesID: kind == .episode || kind == .season ? "\(accountID)-series" : nil,
            seasonID: kind == .episode ? "\(accountID)-season" : nil,
            runtime: playable ? 1800 : nil,
            resumePosition: playable && advanced ? 900 : nil,
            playedPercentage: playable && advanced ? 0.5 : nil,
            allowsTitleBasedMetadataMatching: false, sourceAccountID: accountID,
            versions: playable ? [
                MediaVersion(id: "file-small", height: 720, videoCodec: "h264"),
                MediaVersion(id: "file-large", height: 1080, videoCodec: "h264")
            ] : []
        )
    }
    func source(for item: MediaItem) -> MediaSourceRef {
        .init(accountID: accountID, itemID: item.id, kind: item.kind, providerKind: kind,
              serverName: session.server.name, versions: item.versions,
              resumePosition: item.resumePosition, playedPercentage: item.playedPercentage)
    }
    func item(id: String) async throws -> MediaItem {
        guard let key = ["movie", "series", "season", "episode"].first(where: {
            id == "\(accountID)-\($0)"
        }) else { throw AppError.notFound }
        return media(key)
    }
    func children(of itemID: String) async throws -> [MediaItem] {
        itemID == "\(accountID)-series" ? [media("season")]
            : itemID == "\(accountID)-season" ? [media("episode")] : []
    }
    func resumeEpisode(inSeries seriesID: String) async throws -> MediaItem? { media("episode") }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        .init(items: [], startIndex: 0, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        await probe.record(account: accountID, item: itemID, version: nil, position: nil)
        throw AppError.notFound
    }
    func playbackInfo(
        for itemID: String, mediaSourceID: String?, forceTranscode: Bool,
        streaming: StreamingPlaybackOptions
    ) async throws -> PlaybackRequest {
        await probe.record(account: accountID, item: itemID, version: mediaSourceID, position: streaming.startPosition)
        throw AppError.notFound
    }
    func releaseStreamingSession(_ request: PlaybackRequest) async {}
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
