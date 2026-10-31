import CoreModels
import CoreUI
import FeatureAuth
import FeatureHomeCore
import MediaDownloads
import MediaTransportCore
import SwiftUI
@testable import AppShelliOS

@MainActor
struct DownloadsInteractionFixture: View {
    @State private var appModel: PlozziOSAppModel
    @State private var downloads: PlozziOSDownloadsModel
    @State private var trailer = HeroTrailerController()

    init() {
        let sync = SyncSetupFeatureFlag()
        sync.isEnabled = false
        let accounts = AccountStore(secureStore: InMemorySecureStore())
        let app = PlozziOSAppModel(accountStore: accounts)
        if ProcessInfo.processInfo.arguments.contains("--download-details") {
            let provider = DownloadFixtureProvider()
            app.accountsProviders.registry.register(.jellyfin) { _ in provider }
            do {
                try accounts.add(provider.account, token: "fixture")
            } catch {
                fatalError("Could not prepare the Downloads fixture account: \(error)")
            }
            app.accountsProviders.reloadAccounts()
            app.settings.heroBackground.settings.detailMode = .off
            app.metadataProviderSettingsModel.settings = MetadataProviderSettings(
                orderMode: .custom, preferOnlineArtwork: false,
                disabledOrder: MetadataSourceAttribution.all.map(\.id)
            )
        }
        var records = (1...12).map { index in
            DownloadedMediaRecord(
                identity: .external(source: "plozz-account:fixture", value: "episode-\(index)"),
                sourceKind: .managedHTTP, status: index == 1 ? .downloading : .completed,
                localFileName: "episode-\(index).mkv",
                bytesDownloaded: index == 1 ? 38_000_000 : 100_000_000,
                totalBytes: 100_000_000,
                snapshot: .init(
                    title: index == 1 ? "One Year Later" : "Episode \(index)",
                    kind: .episode, sourceAccountID: "fixture", sourceItemID: "episode-\(index)",
                    seriesTitle: index <= 3 ? "Andor" : "Downloaded Show \(index)",
                    seriesID: index <= 3 ? "andor" : "show-\(index)",
                    seasonNumber: 2, episodeNumber: index
                )
            )
        }
        if ProcessInfo.processInfo.arguments.contains("--download-movie") {
            records = [
                DownloadedMediaRecord(
                    identity: .external(source: "plozz-account:fixture", value: "movie"),
                    sourceKind: .managedHTTP, status: .completed,
                    localFileName: "movie.mkv", bytesDownloaded: 100_000_000,
                    totalBytes: 100_000_000,
                    snapshot: .init(
                        title: "Downloaded Movie", kind: .movie,
                        sourceAccountID: "fixture", sourceItemID: "movie"
                    )
                )
            ]
        }
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore(.init(
            records: Dictionary(uniqueKeysWithValues: records.map { ($0.identityKey, $0) })
        )))
        _appModel = State(initialValue: app)
        _downloads = State(initialValue: PlozziOSDownloadsModel(
            profileID: "download-interaction-\(UUID())", registry: registry,
            storage: PlatformDownloadStorageLocator(subdirectory: "DownloadsInteractionFixture"),
            networkObserver: StaticDownloadNetworkObserver(),
            networkFileResolver: DownloadFixtureNetworkResolver(),
            providerKind: { _ in .emby }, preferredAudioLanguages: { _ in [] },
            startsActive: false, activityScheduler: nil,
            managedURLResolver: { _, _, _ in throw CancellationError() }
        ))
    }

    var body: some View {
        NavigationStack {
            PlozziOSDownloadsView(model: downloads, appModel: appModel, onShowSettings: {})
        }
        .environment(appModel)
        .environment(trailer)
        .environment(\.locale, Locale(identifier: "en"))
        .environment(\.themePalette, .dark)
        .environment(\.plozzMetrics, .touch(density: .standard))
        .environment(
            \.plozzCardStyle,
            ProcessInfo.processInfo.arguments.contains("--framed-downloads") ? .framed : .borderless
        )
        .preferredColorScheme(.dark)
    }
}

private struct DownloadFixtureProvider: MediaProvider {
    let kind = ProviderKind.jellyfin
    var account: Account {
        Account(
            id: "fixture",
            server: MediaServer(
                id: "fixture", name: "Downloads fixture",
                baseURL: URL(string: "https://downloads.invalid")!, provider: kind
            ),
            userID: "viewer", userName: "Viewer", deviceID: "fixture"
        )
    }
    var session: UserSession { account.session(token: "fixture") }

    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: 0, totalCount: 0)
    }
    func item(id: String) async throws -> MediaItem {
        guard id.hasPrefix("episode-"), let index = Int(id.dropFirst("episode-".count)) else {
            throw AppError.notFound
        }
        return MediaItem(
            id: id, title: index == 1 ? "One Year Later" : "Episode \(index)", kind: .episode,
            overview: "Downloaded episode fixture details.",
            parentTitle: index <= 3 ? "Andor" : "Downloaded Show \(index)",
            seasonNumber: 2, episodeNumber: index,
            seriesID: index <= 3 ? "andor" : "show-\(index)",
            allowsTitleBasedMetadataMatching: false, sourceAccountID: "fixture"
        )
    }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

private struct DownloadFixtureNetworkResolver: MediaTransportNetworkFileResolving {
    func resolve(_ locator: NetworkFileLocator) async throws -> MediaTransportResolvedSource {
        throw CancellationError()
    }
}
