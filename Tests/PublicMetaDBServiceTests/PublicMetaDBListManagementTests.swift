import CoreModels
import CoreNetworking
import CoreSecureStore
import Foundation
import XCTest
@testable import PublicMetaDBService
@testable import TestSupportNetworking

private let listJSON = #"{"id":"list-a","name":"Test list","description":null,"is_public":false,"type":"custom"}"#
private let entryJSON = #"{"id":"entry-a","tmdb_id":550,"media_type":"movie"}"#
private func page(_ items: [String]) -> String {
    #"{"items":[\#(items.joined(separator: ","))],"total":\#(items.count),"page":1,"perPage":500,"totalPages":\#(items.isEmpty ? 0 : 1)}"#
}
private func itemPage(_ items: [String], list: String = listJSON) -> String {
    #"{"list":\#(list),\#(page(items).dropFirst())"#
}

@MainActor
final class PublicMetaDBListManagementTests: XCTestCase {
    private func withService(
        configure: (RecordingHTTPClient) -> Void = { _ in },
        _ body: (PublicMetaDBService, RecordingHTTPClient, PublicMetaDB.List, UUID) async throws -> Void
    ) async throws {
        let name = "PublicMetaDBListManagementTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/lists", json: page([listJSON]))
        configure(http)
        let service = PublicMetaDBService(
            credentials: ListCredentials(), http: http, defaults: defaults,
            watchlistReceiptStore: try DurableLocalStateStore(secureStore: InMemorySecureStore())
        )
        let key = "pm-" + (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").prefix(60)
        await service.connect(key: key)
        let list = try JSONDecoder().decode(PublicMetaDB.List.self, from: Data(listJSON.utf8))
        try await body(service, http, list, XCTUnwrap(service.connectionID))
    }

    func testCreationExplicitlySendsPrivateVisibilityAndRequiresReadback() async throws {
        try await withService(configure: { http in
            http.stub(pathSuffix: "/lists", json: #"{"success":true,"item":\#(listJSON)}"#)
            http.stub(pathSuffix: "/lists", json: page([listJSON]))
        }) { service, http, _, connection in
            let result = try await service.createOwnedList(
                name: "Test list", description: nil, isPublic: false, type: .custom,
                expectedConnectionID: connection
            )
            XCTAssertEqual(result.id, "list-a")
            XCTAssertFalse(result.isPublic)
            XCTAssertEqual(http.sent.count, 3)
            XCTAssertEqual(http.sent[1].json?["is_public"] as? Bool, false)
            XCTAssertNil(service.watchlistSelection)
        }
    }

    func testCreationReadbackMismatchRemainsUncertainAndNeverRepeatsPost() async throws {
        try await withService(configure: { http in
            http.stub(pathSuffix: "/lists", json: #"{"success":true,"item":\#(listJSON)}"#)
            http.stub(pathSuffix: "/lists", json: page([]))
        }) { service, http, _, connection in
            do {
                _ = try await service.createOwnedList(
                    name: "Test list", description: nil, isPublic: false, type: .custom,
                    expectedConnectionID: connection
                )
                XCTFail("Unconfirmed creation acknowledged")
            } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .uncertainWrite) }
            XCTAssertEqual(http.sent.filter { $0.body != nil }.count, 1)
        }
    }

    func testAddConfirmsVisibilityMembershipAndReadback() async throws {
        try await withService { service, http, list, connection in
            http.stub(pathSuffix: "/items", json: itemPage([]))
            http.stub(pathSuffix: "/items", json: #"{"success":true,"item":\#(entryJSON)}"#)
            http.stub(pathSuffix: "/items", json: itemPage([entryJSON]))
            try await service.addToOwnedList(
                .init(tmdbID: 550, mediaType: .movie), list: list, expectedConnectionID: connection
            )
            XCTAssertEqual(http.sent.filter { $0.body != nil }.count, 1)
            XCTAssertEqual(http.sentPaths.suffix(3), [
                "/api/external/lists/list-a/items", "/api/external/lists/list-a/items", "/api/external/lists/list-a/items"
            ])
        }
    }

    func testChangedVisibilityRefusesWrite() async throws {
        try await withService { service, http, list, connection in
            http.stub(pathSuffix: "/items", json: itemPage(
                [], list: listJSON.replacingOccurrences(of: #""is_public":false"#, with: #""is_public":true"#)
            ))
            do {
                try await service.addToOwnedList(
                    .init(tmdbID: 550, mediaType: .movie), list: list, expectedConnectionID: connection
                )
                XCTFail("Visibility change was accepted")
            } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .incompleteResponse) }
            XCTAssertTrue(http.sent.allSatisfy { $0.body == nil })
        }
    }

    func testRemoteListNotOwnedByConnectionCannotBeMutated() async throws {
        try await withService(configure: { http in
            http.stub(pathSuffix: "/lists", json: page([]))
        }) { service, http, list, connection in
            do { try await service.deleteOwnedList(list, expectedConnectionID: connection); XCTFail("Non-owned list deleted") }
            catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .incompleteResponse) }
            XCTAssertFalse(http.sentPaths.contains("/api/external/lists/list-a"))
        }
    }

    func testDeletionDisablesSelectedDestinationAndConfirmsAbsence() async throws {
        try await withService(configure: { http in
            http.stub(pathSuffix: "/lists", json: page([listJSON]))
            http.stub(pathSuffix: "/lists", json: page([listJSON]))
            http.stub(pathSuffix: "/lists", json: page([]))
            http.stub(pathSuffix: "/list-a", json: #"{"success":true}"#)
        }) { service, http, list, connection in
            try await service.enableWatchlist(list, expectedConnectionID: connection)
            try await service.deleteOwnedList(list, expectedConnectionID: connection)
            XCTAssertNil(service.watchlistSelection)
            XCTAssertFalse(service.watchlistDestination.capabilities.write.isWritable)
            XCTAssertEqual(http.sentPaths.last, "/api/external/lists")
        }
    }

    func testRemovalAddressesOnlyExactObservedEntryAndChecksAbsence() async throws {
        try await withService { service, http, list, connection in
            let entry = try PublicMetaDBClient.decoder().decode(
                PublicMetaDB.Record<PublicMetaDB.Content>.self, from: Data(entryJSON.utf8)
            )
            http.stub(pathSuffix: "/items", json: itemPage([entryJSON]))
            http.stub(pathSuffix: "/items", json: itemPage([]))
            http.stub(pathSuffix: "/entry-a", json: #"{"success":true}"#)
            try await service.removeFromOwnedList(entry, list: list, expectedConnectionID: connection)
            XCTAssertTrue(http.sentPaths.contains("/api/external/lists/list-a/items/entry-a"))
            XCTAssertFalse(http.sentPaths.contains("/api/external/lists/list-a"))
        }
    }

    func testOldConnectionApprovalCannotBeRetargeted() async throws {
        try await withService { service, http, list, _ in
            let count = http.sent.count
            do { try await service.deleteOwnedList(list, expectedConnectionID: UUID()); XCTFail("Stale approval admitted") }
            catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .connectionChanged) }
            XCTAssertEqual(http.sent.count, count)
        }
    }
}

private final class ListCredentials: PublicMetaDBCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var saved: PublicMetaDBCredentials?
    func load(namespace: String?) -> PublicMetaDBCredentials? { lock.withLock { saved } }
    func save(_ credentials: PublicMetaDBCredentials, namespace: String?) throws { lock.withLock { saved = credentials } }
    func clear(namespace: String?) throws { lock.withLock { saved = nil } }
}
