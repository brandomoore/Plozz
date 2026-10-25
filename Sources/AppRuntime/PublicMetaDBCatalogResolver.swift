import CoreModels
import CoreSecureStore
import Foundation
import MetadataKit
import PublicMetaDBService

public enum PublicMetaDBCatalogResolver {
    private static let limiter = ConcurrencyLimiter(limit: 4)

    public static func resolve(
        _ content: PublicMetaDB.Content, accounts: [ResolvedAccount],
        identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef],
        visibility: HomeLibraryVisibility, metadataSettings: MetadataProviderSettings,
        language: String = Locale.current.identifier,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        tmdb: TMDbDiscoveryProvider? = nil
    ) async throws -> MediaItem {
        try await limiter.runUnlessCancelled {
            guard await isCurrent() else { throw CancellationError() }
            let kind: MediaItemKind = content.mediaType == .movie ? .movie : .series
            let seed = MediaItem(
                id: "tmdb:\(kind.rawValue):\(content.tmdbID)", title: "TMDB \(content.tmdbID)", kind: kind,
                providerIDs: ["Tmdb": String(content.tmdbID)], availability: .unknown,
                locallyValidatedPlayableSource: false
            )
            let resolver = HeroDiscoveryRuntime(accounts: accounts, identitySources: identitySources)
            let library = await resolver.resolveLibraryCopies(of: [seed], hideWatched: false, visibility: visibility)
            try Task.checkCancellation()
            guard await isCurrent() else { throw CancellationError() }
            if let item = library.first, item.locallyValidatedPlayableSource { return item }
            guard MetadataEnrichmentConfig.resolved().merged(withUserOverrides: metadataSettings).isEnabled(.tmdb) else {
                throw AppError.notFound
            }
            let provider: TMDbDiscoveryProvider
            if let tmdb {
                provider = tmdb
            } else {
                let configuration = Task.detached(priority: .utility) {
                    MetadataProviderConfig.resolved().withUserToken(
                        TMDBUserKeyStore(secureStore: KeychainStore(service: "com.plozz.app.household")).load()
                    )
                }
                let config = await withTaskCancellationHandler {
                    await configuration.value
                } onCancel: {
                    configuration.cancel()
                }
                provider = TMDbDiscoveryProvider(access: config.tmdb)
            }
            guard await isCurrent() else { throw CancellationError() }
            let item = try await provider.title(
                tmdbID: content.tmdbID, kind: kind, language: language
            )
            try Task.checkCancellation()
            guard await isCurrent() else { throw CancellationError() }
            return item
        }
    }
}
