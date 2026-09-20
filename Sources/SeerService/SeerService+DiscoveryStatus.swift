import CoreModels
import Foundation

public extension SeerService {
    /// Identity support only; request permissions and quotas remain server-owned.
    func hasRequestIdentity(for item: MediaItem) -> Bool {
        guard SeerMapper.requestMediaType(for: item) != nil,
              let id = SeerMapper.tmdbID(for: item) else { return false }
        return id > 0
    }

    /// Status for the visible carousel, not another fetch of trending's first page.
    /// Returns completed updates in input order within one overall response budget
    /// (five seconds by default). Cancellation or a replaced connection discards
    /// the batch; timeouts and individual failures preserve completed statuses.
    func availabilityUpdates(for items: [MediaItem]) async -> [MediaItem] {
        guard isConfigured, !Task.isCancelled else { return [] }
        let revision = connectionRevision
        let candidates = Array(items.lazy.filter {
            $0.availability != nil && self.hasRequestIdentity(for: $0)
        }.prefix(HeroSettings.maxItemsRange.upperBound))
        guard !candidates.isEmpty else { return [] }
        let updates = await discoveryStatusCoordinator.updates(for: candidates)
        guard !Task.isCancelled, connectionRevision == revision else { return [] }
        return updates
    }
}
