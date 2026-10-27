import CoreModels
import Foundation
import Observation

@MainActor
@Observable
final class DetailPlaybackInventoryState {
    var noStreamItemIDs: Set<String> = []
    var authoritativeSourceIDs: Set<String> = []
    var retryingItemIDs: Set<String> = []
    var retryError: LocalizedStringResource?

    func reset() {
        noStreamItemIDs.removeAll()
        authoritativeSourceIDs.removeAll()
        retryingItemIDs.removeAll()
        retryError = nil
    }
}

@MainActor
@Observable
final class EpisodeBadgeEnrichmentModel {
    private var itemsByID: [String: MediaItem] = [:]
    private var authoritativeItemIDs: Set<String> = []

    subscript(id: String) -> MediaItem? { itemsByID[id] }

    func hasAuthoritativeInventory(for id: String) -> Bool { authoritativeItemIDs.contains(id) }

    func store(_ item: MediaItem, authoritativeVersions: Bool = false) {
        var item = item
        if authoritativeVersions {
            authoritativeItemIDs.insert(item.id)
        } else if authoritativeItemIDs.contains(item.id), let previous = itemsByID[item.id] {
            item.versions = previous.versions
            item.sources = previous.sources
        }
        itemsByID[item.id] = item
    }

    func reset() {
        itemsByID.removeAll()
        authoritativeItemIDs.removeAll()
    }
}
