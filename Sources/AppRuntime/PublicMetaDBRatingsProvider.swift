import CoreModels
import CoreNetworking
import PublicMetaDBService
import RatingsService

/// Keeps optional, connection-scoped ratings outside the existing shared disk cache.
public struct PublicMetaDBRatingsProvider: CachedExternalRatingsProviding {
    private let base: any ExternalRatingsProviding
    private let service: PublicMetaDBService

    public init(base: any ExternalRatingsProviding, service: PublicMetaDBService) {
        self.base = base
        self.service = service
    }

    public func ratings(for item: MediaItem) async -> [ExternalRating] {
        async let existing = base.ratings(for: item)
        do { _ = try await service.communityRatings(for: item) }
        catch {
            if !(error is CancellationError) {
                PlozzLog.networking.error("PublicMetaDB community ratings unavailable")
            }
        }
        let ratings = await existing
        // Consent or profile can change while an unrelated rating provider finishes.
        let additional = await service.cachedCommunityRatings(for: item) ?? []
        return ratings.mergedWithAuthoritative(additional)
    }

    public func cachedRatings(for item: MediaItem) async -> [ExternalRating]? {
        let existing = await (base as? any CachedExternalRatingsProviding)?.cachedRatings(for: item)
        let additional = await service.cachedCommunityRatings(for: item)
        guard existing != nil || additional != nil else { return nil }
        return (existing ?? []).mergedWithAuthoritative(additional ?? [])
    }
}
