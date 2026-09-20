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
    func availabilityUpdates(for items: [MediaItem]) async -> [MediaItem] {
        guard isConfigured else { return [] }
        let revision = connectionRevision
        let candidates = Array(items.filter {
            $0.availability != nil && hasRequestIdentity(for: $0)
        }.prefix(HeroSettings.maxItemsRange.upperBound))
        guard !candidates.isEmpty else { return [] }
        let updates = await withTaskGroup(
            of: (Int, MediaItem?).self, returning: [Int: MediaItem].self
        ) { group in
            var next = 0
            func addNext() {
                guard next < candidates.count, !Task.isCancelled else { return }
                let index = next
                let item = candidates[index]
                next += 1
                group.addTask {
                    guard let (status, progress) = await self.availability(for: item) else {
                        return (index, nil)
                    }
                    var updated = item
                    updated.availability = status
                    updated.downloadProgress = progress
                    return (index, updated)
                }
            }
            for _ in 0..<min(4, candidates.count) { addNext() }
            var result: [Int: MediaItem] = [:]
            for await (index, item) in group {
                if let item { result[index] = item }
                addNext()
            }
            return result
        }
        guard !Task.isCancelled, connectionRevision == revision else { return [] }
        return candidates.indices.compactMap { updates[$0] }
    }
}
