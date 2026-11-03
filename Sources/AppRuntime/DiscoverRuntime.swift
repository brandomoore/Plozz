import CoreModels
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
        isCurrent: @escaping @MainActor @Sendable () -> Bool
    ) -> DiscoverBrowseModel {
        let revision = seer.connectionRevision
        let configured = seer.isConfigured
        let publicDiscovery = TMDbDiscoveryProvider()
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
                    result = try await publicDiscovery.browse(feed, page: page, language: language)
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
}
