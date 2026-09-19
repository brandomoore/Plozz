import CoreModels
import XCTest

final class CollectionIdentityTests: XCTestCase {
    func testCatalogueMetadataDoesNotMakeCollectionsAlternateSources() {
        let first = collection(account: "plex", id: "12")
        let second = collection(account: "jellyfin", id: "other")
        XCTAssertTrue(MediaItemIdentity.identities(for: first).isEmpty)
        XCTAssertFalse(MediaItemIdentity.hasStrongRetargetIdentity(first))
        let merged = MediaItemMerger.merge([first, second])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.map(\.sourceAccountID), ["plex", "jellyfin"])
    }

    func testSameServerCollectionStaysScopedToUserAccount() {
        let first = collection(account: "parent", id: "12")
        let second = collection(account: "child", id: "12")
        let merged = MediaItemMerger.merge(
            [first, second, first],
            serverInfo: { _ in SourceServerInfo(serverID: "shared-server") }
        )
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.map(\.sourceAccountID), ["parent", "child"])
    }

    func testStaleIdentityIndexCannotMergeOrRetargetCollections() {
        let first = collection(account: "plex", id: "12")
        let second = collection(account: "jellyfin", id: "other")
        let refs = [
            MediaSourceRef(accountID: "plex", itemID: "12", kind: .collection),
            MediaSourceRef(accountID: "jellyfin", itemID: "other", kind: .collection)
        ]
        let merged = MediaItemMerger.merge([first, second], identitySources: { _ in refs })
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged.allSatisfy { $0.additionalSourceAccountIDs.isEmpty })
        XCTAssertTrue(merged.allSatisfy { $0.sources.count <= 1 })
    }

    func testLegacyMergedCollectionDropsPeerMembershipSources() {
        var item = collection(account: "plex", id: "12")
        item.additionalSourceAccountIDs = ["jellyfin"]
        item.sources = [
            MediaSourceRef(accountID: "plex", itemID: "12", kind: .collection),
            MediaSourceRef(accountID: "jellyfin", itemID: "other", kind: .collection)
        ]
        let merged = MediaItemMerger.merge([item])
        XCTAssertEqual(merged.first?.sources.map(\.accountID), ["plex"])
        XCTAssertEqual(merged.first?.additionalSourceAccountIDs, [])
    }

    private func collection(account: String, id: String) -> MediaItem {
        MediaItem(
            id: id, title: "Same named collection", kind: .collection,
            providerIDs: ["Tmdb": "123"], sourceAccountID: account
        )
    }
}
