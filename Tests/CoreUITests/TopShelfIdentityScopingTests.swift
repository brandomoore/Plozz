import XCTest
@testable import TopShelfKit

/// The Top Shelf snapshot addressed titles by a bare item id. A Plex `ratingKey` is
/// a small per-server integer, so on a device signed in to two servers two unrelated
/// titles can carry the same one — colliding as tvOS shelf identities, overwriting
/// each other's composited poster files, and producing a deep link that can open the
/// wrong title.
final class TopShelfIdentityScopingTests: XCTestCase {
    func testShelfIdentifierIsAccountScoped() {
        let plex = TopShelfSnapshot.Item(id: "12345", accountID: "plex-1", title: "Dune")
        let jellyfin = TopShelfSnapshot.Item(id: "12345", accountID: "jf-1", title: "Shogun")

        XCTAssertNotEqual(plex.shelfIdentifier, jellyfin.shelfIdentifier)
    }

    /// Old deep links still decode; an unowned snapshot is not display authority.
    func testShelfIdentifierFallsBackToTheBareIDWithoutAnAccount() {
        let legacy = TopShelfSnapshot.Item(id: "12345", title: "Dune")
        XCTAssertEqual(legacy.shelfIdentifier, "12345")
    }

    func testDeepLinkCarriesTheAccountAndRoundTrips() {
        let url = TopShelf.itemDeepLink(id: "12345", accountID: "plex-1")
        let reference = TopShelf.itemReference(from: url)

        XCTAssertEqual(reference?.id, "12345")
        XCTAssertEqual(reference?.accountID, "plex-1")
        XCTAssertEqual(reference?.action, .play)
    }

    func testAccountlessDeepLinkStillDecodes() {
        let url = TopShelf.itemDeepLink(id: "12345")
        let reference = TopShelf.itemReference(from: url)

        XCTAssertEqual(reference?.id, "12345")
        XCTAssertNil(reference?.accountID)
        XCTAssertEqual(TopShelf.itemID(from: url), "12345")
    }

    func testForeignURLIsNotAnItemLink() {
        XCTAssertNil(TopShelf.itemReference(from: URL(string: "https://example.com/item/1")!))
    }

    func testMoreInfoUsesADistinctAccountScopedAction() throws {
        let play = TopShelf.itemDeepLink(id: "folder:1/episode", accountID: "account & 2")
        let details = TopShelf.itemDeepLink(id: "folder:1/episode", accountID: "account & 2", action: .details)
        XCTAssertNotEqual(play, details)
        let reference = try XCTUnwrap(TopShelf.itemReference(from: details))
        XCTAssertEqual(reference, .init(id: "folder:1/episode", accountID: "account & 2", action: .details))
        XCTAssertEqual(TopShelf.itemReference(from: play)?.action, .play)
    }

    func testMalformedOrAmbiguousActionCannotFallThroughToPlayback() {
        for query in ["action=unknown", "action=", "action", "action=details&action=play", "account=a&account=b"] {
            XCTAssertNil(TopShelf.itemReference(from: URL(string: "plozz://item/1?\(query)")!), query)
        }
    }

    /// An older snapshot on disk must still decode after the field was added.
    func testLegacySnapshotJSONDecodes() throws {
        let json = Data(#"""
        {
          "generatedAt": 0,
          "sections": [
            { "id": "continue", "title": "Continue Watching",
              "items": [{ "id": "12345", "title": "Dune" }] }
          ]
        }
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let snapshot = try decoder.decode(TopShelfSnapshot.self, from: json)

        XCTAssertEqual(snapshot.sections.first?.items.first?.shelfIdentifier, "12345")
        XCTAssertNil(snapshot.sections.first?.items.first?.accountID)
    }

    func testExtensionRequiresCurrentUsersMatchingGrantEvenIfOldSnapshotSurvives() throws {
        let caches = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        let root = caches.appendingPathComponent("TopShelfTests-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let alice = TopShelfStore.SnapshotFiles(directory: root.appendingPathComponent("alice"))
        let bob = TopShelfStore.SnapshotFiles(directory: root.appendingPathComponent("bob"))
        var snapshot = TopShelfSnapshot(sections: [.init(
            id: "latest", title: "Latest", items: [.init(id: "1", accountID: "plex", title: "Alice only")]
        )])
        snapshot.authorizationID = UUID()
        try alice.save(snapshot)
        XCTAssertEqual(alice.load()?.sections.first?.items.first?.title, "Alice only")
        XCTAssertNil(bob.load())

        let file = TopShelf.snapshotFileName
        let bytes = try Data(contentsOf: alice.directory.appendingPathComponent(file))
        var other = TopShelfSnapshot(sections: [])
        other.authorizationID = UUID()
        try bob.save(other)
        try bytes.write(to: bob.directory.appendingPathComponent(file))
        XCTAssertNil(bob.load(), "A foreign snapshot must not match this system user's grant")
        alice.revoke()
        XCTAssertFalse(alice.isAuthorized(snapshot), "A reader which already loaded it must reject it too")
        try bytes.write(to: alice.directory.appendingPathComponent(file))
        XCTAssertNil(alice.load(), "An orphan snapshot is not a grant")

        try bob.save(other)
        let legacy = Data(#"{"generatedAt":"2025-01-01T00:00:00Z","sections":[]}"#.utf8)
        try legacy.write(to: bob.directory.appendingPathComponent(file))
        XCTAssertNil(bob.load(), "Pre-authorization snapshots cannot be displayed after upgrade")
    }
}
