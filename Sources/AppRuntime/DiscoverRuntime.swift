import CoreModels
import CoreSecureStore
import FeatureHomeCore
import Foundation
import MetadataKit
import SeerService

@MainActor
public enum DiscoverRuntime {
    public static func makeModel(
        namespace: String?,
        accounts: [ResolvedAccount],
        identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef],
        visibility: HomeLibraryVisibility,
        seer: SeerService,
        language: String,
        pendingWatchMutations: @escaping @Sendable () async -> [WatchMutation],
        isCurrent: @escaping @MainActor @Sendable () -> Bool
    ) -> DiscoverBrowseModel {
        let revision = seer.connectionRevision
        let configured = seer.isConfigured
        let current: @MainActor @Sendable () -> Bool = {
            isCurrent() && seer.connectionRevision == revision
        }
        let resolver = HeroDiscoveryRuntime(
            accounts: accounts, identitySources: identitySources,
            allowsDiscovery: { await current() }
        )
        return DiscoverBrowseModel(
            store: DiscoverFiltersStore(namespace: namespace),
            isCurrent: current,
            pendingWatchedStates: {
                await pendingWatchMutations()
                    .sorted { $0.capturedAt < $1.capturedAt }
                    .compactMap(MediaItemMutation.init(watchMutation:))
            },
            resolveLibrarySources: { items in
                await resolver.resolveLibrarySources(in: items, visibility: visibility)
            }
        ) { feed, page in
            guard current() else { throw CancellationError() }
            let result: DiscoverPage
            if configured {
                result = try await seer.discover(feed, page: page, language: language)
            } else {
                do {
                    result = try await publicPage(feed, page: page, language: language)
                } catch let error as MetadataDiscoveryHTTPError {
                    switch error {
                    case .status(429, let delay): throw AppError.rateLimited(retryAfter: delay)
                    case .status(401, _), .status(403, _): throw DiscoverFeedError.metadataUnavailable
                    case .status: throw AppError.serverUnreachable
                    case .invalidResponse, .responseTooLarge: throw AppError.invalidResponse
                    }
                }

            }
            try Task.checkCancellation()
            guard current() else { throw CancellationError() }
            let items = await resolver.resolveLibrarySources(in: result.items, visibility: visibility)
            try Task.checkCancellation()
            guard current() else { throw CancellationError() }
            return DiscoverPage(items: items, nextPage: result.nextPage)
        }
    }

    static func publicPage(
        _ feed: DiscoverFeed, page: Int, language: String,
        configurationLoader: @escaping @Sendable () -> MetadataProviderConfig = {
            let keys = TMDBUserKeyStore(secureStore: KeychainStore(service: "com.plozz.app.household"))
            return MetadataProviderConfig.resolved().withUserToken(keys.load())
        },
        browse: @escaping @Sendable (DiscoverFeed, Int, String, MetadataProviderConfig) async throws -> DiscoverPage = {
            try await TMDbDiscoveryProvider(access: $3.tmdb).browse($0, page: $1, language: $2)
        }
    ) async throws -> DiscoverPage {
        try Task.checkCancellation()
        let configuration = Task.detached(priority: .utility) { configurationLoader() }
        return try await withTaskCancellationHandler {
            let config = await configuration.value
            try Task.checkCancellation()
            return try await browse(feed, page, language, config)
        } onCancel: {
            configuration.cancel()
        }
    }
}
