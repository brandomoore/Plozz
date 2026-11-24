import Foundation

/// Only providers whose layout discovery already reads the complete library inventory opt in.
package protocol HomeLayoutInventoryProviding: MediaProvider {
    /// Unique to this immutable provider instance, including its server credential.
    var homeInventoryProviderID: UUID { get }
    func serverHomeLayoutWithInventory(for source: ResolvedAccount) async throws
        -> (layout: ServerHomeLayout, inventory: LibraryInventoryStore.Publication?)
}

/// Handoff from layout preparation to aggregation. Created anew by Home for each load;
/// the arranger, navigation discovery and ordinary provider reads never receive it.
@MainActor
public final class HomeLoadLibraryInventory {
    private struct Entry {
        let source: ResolvedAccount
        let providerID: UUID
        let inventory: LibraryInventoryStore.Publication

        func matches(_ consumer: ResolvedAccount) -> Bool {
            source.account == consumer.account && source.plexHomeUserID == consumer.plexHomeUserID
                && source.credentialRevision == consumer.credentialRevision
                && (consumer.provider as? any HomeLayoutInventoryProviding)?.homeInventoryProviderID == providerID
        }
    }

    private var entries: [String: Entry] = [:]
    private var accepted = false
    package init() {}

    func stage(_ inventory: LibraryInventoryStore.Publication, from source: ResolvedAccount, providerID: UUID) {
        entries[source.account.id] = Entry(source: source, providerID: providerID, inventory: inventory)
    }

    func accept() { accepted = true }

    package func take(for accounts: [ResolvedAccount]) -> [Int: LibraryInventoryStore.Publication] {
        defer { entries.removeAll() }
        guard accepted else { return [:] }
        accepted = false
        var result: [Int: LibraryInventoryStore.Publication] = [:]
        for (index, account) in accounts.enumerated() {
            if let entry = entries[account.account.id], entry.matches(account) {
                result[index] = entry.inventory
                entries.removeValue(forKey: account.account.id)
            }
        }
        return result
    }
}
