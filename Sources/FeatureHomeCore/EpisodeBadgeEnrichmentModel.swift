import CoreModels
import Observation

@MainActor
@Observable
final class EpisodeBadgeEnrichmentModel {
    private var itemsByID: [String: MediaItem] = [:]

    subscript(id: String) -> MediaItem? { itemsByID[id] }

    func store(_ item: MediaItem) {
        itemsByID[item.id] = item
    }

    func reset() {
        itemsByID.removeAll()
    }
}
