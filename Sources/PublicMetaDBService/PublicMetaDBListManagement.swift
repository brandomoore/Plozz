import CoreModels
import CoreNetworking
import Foundation

public extension PublicMetaDBService {
    func createOwnedList(
        name: String, description: String?, isPublic: Bool, type: PublicMetaDB.ListKind,
        expectedConnectionID: UUID
    ) async throws -> PublicMetaDB.List {
        let client = try confirmedClient(expectedConnectionID)
        let created = try await client.createList(
            name: name, description: description, isPublic: isPublic, type: type
        )
        do {
            let lists = try await completeOwnedLists(client)
            _ = try confirmedClient(expectedConnectionID)
            guard let confirmed = lists.first(where: { $0.id == created.id }),
                  confirmed.name == name, confirmed.description == description,
                  confirmed.isPublic == isPublic, confirmed.type == type else {
                throw PublicMetaDB.Failure.uncertainWrite
            }
            return confirmed
        } catch {
            PlozzLog.networking.error("PublicMetaDB list creation readback failed")
            throw PublicMetaDB.Failure.uncertainWrite
        }
    }

    func deleteOwnedList(_ list: PublicMetaDB.List, expectedConnectionID: UUID) async throws {
        let client = try confirmedClient(expectedConnectionID)
        try await requireOwnedList(list, client: client)
        _ = try confirmedClient(expectedConnectionID)
        if watchlistSelection?.listID == list.id { disableWatchlist() }
        do { try await client.deleteList(id: list.id) }
        catch PublicMetaDB.Failure.uncertainWrite {
            // A missing list in a complete independent read can confirm deletion.
        }
        do {
            let lists = try await completeOwnedLists(client)
            _ = try confirmedClient(expectedConnectionID)
            guard !lists.contains(where: { $0.id == list.id }) else { throw PublicMetaDB.Failure.uncertainWrite }
        } catch {
            PlozzLog.networking.error("PublicMetaDB list deletion readback failed")
            throw PublicMetaDB.Failure.uncertainWrite
        }
    }

    func addToOwnedList(
        _ content: PublicMetaDB.Content, list: PublicMetaDB.List, expectedConnectionID: UUID
    ) async throws {
        let client = try confirmedClient(expectedConnectionID)
        try await requireOwnedList(list, client: client)
        let before = try await completeListItems(list, client: client)
        _ = try confirmedClient(expectedConnectionID)
        guard !before.contains(where: { $0.value == content }) else { return }
        do { _ = try await client.addListItem(content, listID: list.id) }
        catch PublicMetaDB.Failure.uncertainWrite {
            // Only the complete membership read below can confirm the attempted add.
        }
        do {
            let after = try await completeListItems(list, client: client)
            _ = try confirmedClient(expectedConnectionID)
            guard after.filter({ $0.value == content }).count == 1 else { throw PublicMetaDB.Failure.uncertainWrite }
        } catch {
            PlozzLog.networking.error("PublicMetaDB list addition readback failed")
            throw PublicMetaDB.Failure.uncertainWrite
        }
    }

    func removeFromOwnedList(
        _ entry: PublicMetaDB.Record<PublicMetaDB.Content>, list: PublicMetaDB.List, expectedConnectionID: UUID
    ) async throws {
        let client = try confirmedClient(expectedConnectionID)
        try await requireOwnedList(list, client: client)
        let before = try await completeListItems(list, client: client)
        _ = try confirmedClient(expectedConnectionID)
        guard let current = before.first(where: { $0.id == entry.id }) else { return }
        guard current.value == entry.value else { throw PublicMetaDB.Failure.incompleteResponse }
        do { try await client.removeListItem(listID: list.id, itemID: entry.id) }
        catch PublicMetaDB.Failure.uncertainWrite {
            // Only the exact entry's absence below can confirm the attempted removal.
        }
        do {
            let after = try await completeListItems(list, client: client)
            _ = try confirmedClient(expectedConnectionID)
            guard !after.contains(where: { $0.id == entry.id }) else { throw PublicMetaDB.Failure.uncertainWrite }
        } catch {
            PlozzLog.networking.error("PublicMetaDB list removal readback failed")
            throw PublicMetaDB.Failure.uncertainWrite
        }
    }

    private func completeOwnedLists(_ client: PublicMetaDBClient) async throws -> [PublicMetaDB.List] {
        try await client.completePages(maximumPages: 100) {
            try await client.lists(page: $0, perPage: 500)
        }
    }

    private func requireOwnedList(_ list: PublicMetaDB.List, client: PublicMetaDBClient) async throws {
        let owned = try await completeOwnedLists(client)
        guard let current = owned.first(where: { $0.id == list.id }),
              current.name == list.name, current.isPublic == list.isPublic else {
            throw PublicMetaDB.Failure.incompleteResponse
        }
    }

    private func completeListItems(
        _ list: PublicMetaDB.List, client: PublicMetaDBClient
    ) async throws -> [PublicMetaDB.Record<PublicMetaDB.Content>] {
        let items = try await client.completePages(maximumPages: 100) { page in
            let response = try await client.listItems(id: list.id, page: page, perPage: 500)
            guard response.list.name == list.name, response.list.isPublic == list.isPublic else {
                throw PublicMetaDB.Failure.incompleteResponse
            }
            return response.page
        }
        guard Set(items.map(\.value)).count == items.count else { throw PublicMetaDB.Failure.incompleteResponse }
        return items
    }
}
