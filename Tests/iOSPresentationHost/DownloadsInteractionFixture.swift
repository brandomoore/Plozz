import CoreModels
import CoreUI
import MediaDownloads
import MediaTransportCore
import SwiftUI
@testable import AppShelliOS

@MainActor
struct DownloadsInteractionFixture: View {
    @State private var appModel: PlozziOSAppModel
    @State private var downloads: PlozziOSDownloadsModel

    init() {
        let sync = SyncSetupFeatureFlag()
        sync.isEnabled = false
        let app = PlozziOSAppModel()
        let records = (1...12).map { index in
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
        .environment(\.locale, Locale(identifier: "en"))
        .environment(\.themePalette, .dark)
        .environment(\.plozzMetrics, .touch(density: .standard))
        .environment(\.plozzCardStyle, .borderless)
        .preferredColorScheme(.dark)
    }
}

private struct DownloadFixtureNetworkResolver: MediaTransportNetworkFileResolving {
    func resolve(_ locator: NetworkFileLocator) async throws -> MediaTransportResolvedSource {
        throw CancellationError()
    }
}
