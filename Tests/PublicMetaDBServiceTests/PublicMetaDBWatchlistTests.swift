import CoreModels
import CoreNetworking
import CoreSecureStore
import FeatureWatchlistCore
import Foundation
import XCTest
@testable import PublicMetaDBService
@testable import TestSupportNetworking

private let listJSON = #"{"id":"list-a","name":"Watch later","is_public":false,"type":"watchlist"}"#
private let movie = #"{"id":"movie-row","tmdb_id":550,"media_type":"movie"}"#
private let show = #"{"id":"show-row","tmdb_id":550,"media_type":"tv"}"#

private func page(_ items: [String], page: Int = 1, total: Int? = nil, perPage: Int = 500) -> String {
    let count = total ?? items.count
    let totalPages = count == 0 ? 0 : (count - 1) / perPage + 1
    return """
    {"list":\(listJSON),"items":[\(items.joined(separator: ","))],"page":\(page),
     "total":\(count),"perPage":\(perPage),"totalPages":\(totalPages)}
    """
}

private func credentials() -> PublicMetaDBCredentials {
    let value = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
    return .init(key: "pm-" + value.prefix(60))
}

private func selection(_ saved: PublicMetaDBCredentials) throws -> PublicMetaDBWatchlistSelection {
    .init(
        list: try JSONDecoder().decode(PublicMetaDB.List.self, from: Data(listJSON.utf8)),
        connectionID: saved.connectionID
    )
}

private func receiptStore() throws -> DurableLocalStateStore {
    try DurableLocalStateStore(secureStore: InMemorySecureStore())
}

private func target() -> WatchlistMutationTarget {
    .init(aliasID: .init(), kind: .movie, externalIDs: [.init(namespace: .tmdb, value: "550")!])!
}

private func configure(
    _ destination: PublicMetaDBWatchlistDestination, http: any HTTPClient,
    saved: PublicMetaDBCredentials, selected: PublicMetaDBWatchlistSelection
) throws {
    try destination.configure(credentials: saved, selection: selected, http: http, connectionIsCurrent: { true })
}

private func apply(
    _ desired: WatchlistDesiredState, to destination: PublicMetaDBWatchlistDestination,
    deliveryID: String = "delivery-a"
) async throws {
    let resolved = try await destination.resolve(target())
    let binding = try XCTUnwrap(resolved)
    let results = try await destination.apply(
        desired, to: [binding], idempotencyKey: deliveryID,
        expectedReconciliationScope: destination.reconciliationScope
    )
    XCTAssertEqual(results.count, 1)
    try results[0].get()
}

final class PublicMetaDBWatchlistTests: XCTestCase {
    func testProductionOutboxDoesNotScheduleUnconfirmedDeliveryAgain() async throws {
        let saved = credentials()
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/items", json: page([]))
        http.stub(pathSuffix: "/items", json: "{}", status: 503)
        http.stub(pathSuffix: "/items", json: page([]))
        let destination = PublicMetaDBWatchlistDestination(receiptStore: try receiptStore())
        let backing = InMemoryWatchlistMutationStateStore()
        let mutations = try DurableWatchlistMutationStore(store: backing)
        let registry = WatchlistDestinationRegistry([destination])
        let reconciler = WatchlistReconciler(registry: registry, mutationStore: mutations)
        let title = target()
        try await reconciler.enqueueFanOut(profileID: "test-profile", desiredState: .present, target: title)
        XCTAssertTrue(try backing.load().mutations.isEmpty)
        try configure(destination, http: http, saved: saved, selected: selection(saved))
        try await reconciler.enqueueFanOut(profileID: "test-profile", desiredState: .present, target: title)
        _ = await reconciler.drain(profileID: "test-profile")
        XCTAssertEqual(try backing.load().mutations.map(\.phase), [.permanentlyFailed])
        let calls = http.sent.count
        let restored = WatchlistReconciler(
            registry: registry, mutationStore: try DurableWatchlistMutationStore(store: backing)
        )
        _ = await restored.drain(profileID: "test-profile")
        XCTAssertEqual(http.sent.count, calls)
        XCTAssertEqual(http.sent.filter { $0.body != nil }.count, 1)
    }

    func testUnconfiguredDestinationCannotReadOrWrite() async throws {
        let destination = PublicMetaDBWatchlistDestination()
        XCTAssertFalse(destination.capabilities.read.isReadable)
        XCTAssertFalse(destination.capabilities.write.isWritable)
        let entries = try await destination.fetchEntries()
        let resolved = try await destination.resolve(target())
        XCTAssertTrue(entries.isEmpty)
        XCTAssertNil(resolved)
    }

    func testReadsCompleteListWithoutCollapsingMovieAndSeriesNamespaces() async throws {
        let saved = credentials()
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/items", json: page([movie], total: 2, perPage: 1))
        http.stub(pathSuffix: "/items", json: page([show], page: 2, total: 2, perPage: 1))
        let destination = PublicMetaDBWatchlistDestination(receiptStore: try receiptStore())
        try configure(destination, http: http, saved: saved, selected: selection(saved))
        let entries = try await destination.fetchEntries()
        XCTAssertEqual(entries.map(\.kind), [.movie, .series])
        XCTAssertTrue(entries.allSatisfy { $0.externalIDs == [.init(namespace: .tmdb, value: "550")!] })
        XCTAssertEqual(http.sent.count, 2)
        XCTAssertTrue(http.sent.allSatisfy { $0.body == nil })
    }

    func testDuplicateContentCannotBecomeCompleteMembershipEvidence() async throws {
        let saved = credentials()
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/items", json: page([movie, movie.replacingOccurrences(of: "movie-row", with: "duplicate")]))
        let destination = PublicMetaDBWatchlistDestination(receiptStore: try receiptStore())
        try configure(destination, http: http, saved: saved, selected: selection(saved))
        do { _ = try await destination.fetchEntries(); XCTFail("Duplicate membership accepted") }
        catch { XCTAssertEqual(error as? WatchlistDestinationError, .transient) }
    }

    func testIncompleteSnapshotCannotAuthorizeAnAdd() async throws {
        let saved = credentials()
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/items", json: page([show], total: 2, perPage: 1))
        http.stub(pathSuffix: "/items", json: page([], page: 2, total: 2, perPage: 1))
        let destination = PublicMetaDBWatchlistDestination(receiptStore: try receiptStore())
        try configure(destination, http: http, saved: saved, selected: selection(saved))
        do { try await apply(.present, to: destination); XCTFail("Partial list authorized a write") }
        catch { XCTAssertEqual(error as? WatchlistDestinationError, .transient) }
        XCTAssertTrue(http.sent.allSatisfy { $0.body == nil })
    }

    func testPrivateListBecomingPublicCannotReceiveAnUnapprovedWrite() async throws {
        let saved = credentials()
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/items", json: page([]).replacingOccurrences(of: #""is_public":false"#, with: #""is_public":true"#))
        let destination = PublicMetaDBWatchlistDestination(receiptStore: try receiptStore())
        try configure(destination, http: http, saved: saved, selected: selection(saved))
        do { try await apply(.present, to: destination); XCTFail("New public visibility was not approved") }
        catch { XCTAssertEqual(error as? WatchlistDestinationError, .permanent) }
        XCTAssertEqual(http.sent.count, 1)
        XCTAssertNil(http.sent[0].body)
    }

    func testAddsOnlyWhenAbsentAndConfirmsIndependentReadback() async throws {
        let saved = credentials()
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/items", json: page([]))
        http.stub(pathSuffix: "/items", json: #"{"success":true,"item":\#(movie)}"#)
        http.stub(pathSuffix: "/items", json: page([movie]))
        let destination = PublicMetaDBWatchlistDestination(receiptStore: try receiptStore())
        try configure(destination, http: http, saved: saved, selected: selection(saved))
        try await apply(.present, to: destination)
        try await apply(.present, to: destination)
        XCTAssertEqual(http.sent.filter { $0.body != nil }.count, 1)
        XCTAssertEqual(http.sent.count, 4)
        XCTAssertEqual(http.sent[1].json?["tmdb_id"] as? Int, 550)
    }

    func testLostWriteReplyCanOnlyBeAcknowledgedByReadback() async throws {
        let saved = credentials()
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/items", json: page([]))
        http.stub(pathSuffix: "/items", json: "{}", status: 503)
        http.stub(pathSuffix: "/items", json: page([movie]))
        let destination = PublicMetaDBWatchlistDestination(receiptStore: try receiptStore())
        try configure(destination, http: http, saved: saved, selected: selection(saved))
        try await apply(.present, to: destination)
        XCTAssertEqual(http.sent.filter { $0.body != nil }.count, 1)
        XCTAssertEqual(http.sent.count, 3)
    }

    func testFailedReadbackAndRelaunchDoNotRepeatAnUncertainWrite() async throws {
        let saved = credentials()
        let selected = try selection(saved)
        let store = try receiptStore()
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/items", json: page([]))
        http.stub(pathSuffix: "/items", json: "{}", status: 503)
        http.stub(pathSuffix: "/items", json: "{}", status: 503)
        http.stub(pathSuffix: "/items", json: page([]))
        let first = PublicMetaDBWatchlistDestination(receiptStore: store)
        try configure(first, http: http, saved: saved, selected: selected)
        do { try await apply(.present, to: first); XCTFail("Failed readback acknowledged") }
        catch { XCTAssertEqual(error as? WatchlistDestinationError, .permanent) }
        let restored = PublicMetaDBWatchlistDestination(receiptStore: store)
        try configure(restored, http: http, saved: saved, selected: selected)
        do { try await apply(.present, to: restored); XCTFail("Uncertain POST replayed") }
        catch { XCTAssertEqual(error as? WatchlistDestinationError, .permanent) }
        XCTAssertEqual(http.sent.filter { $0.body != nil }.count, 1)
    }

    func testCrashAfterDurableAttemptBeforeResponseRemainsReadOnly() async throws {
        let saved = credentials()
        let selected = try selection(saved)
        let store = try receiptStore()
        let receipts = PublicMetaDBWatchlistReceipts(store: store, selectionID: selected.id)
        try receipts.begin(deliveryID: "delivery-a", content: .init(tmdbID: 550, mediaType: .movie), desiredState: .present)
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/items", json: page([]))
        let destination = PublicMetaDBWatchlistDestination(receiptStore: store)
        try configure(destination, http: http, saved: saved, selected: selected)
        do { try await apply(.present, to: destination); XCTFail("Crash caused a blind replay") }
        catch { XCTAssertEqual(error as? WatchlistDestinationError, .permanent) }
        XCTAssertEqual(http.sent.count, 1)
        XCTAssertNil(http.sent[0].body)
    }

    func testLaterReadCanResolvePriorUncertaintyBeforeANewOppositeIntent() async throws {
        let saved = credentials()
        let selected = try selection(saved)
        let store = try receiptStore()
        let receipts = PublicMetaDBWatchlistReceipts(store: store, selectionID: selected.id)
        try receipts.begin(deliveryID: "old-add", content: .init(tmdbID: 550, mediaType: .movie), desiredState: .present)
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/items", json: page([movie]))
        http.stub(pathSuffix: "/items/movie-row", json: #"{"success":true}"#)
        http.stub(pathSuffix: "/items", json: page([]))
        let destination = PublicMetaDBWatchlistDestination(receiptStore: store)
        try configure(destination, http: http, saved: saved, selected: selected)
        try await apply(.absent, to: destination, deliveryID: "new-remove")
        XCTAssertEqual(http.sent.count, 3)
        XCTAssertTrue(http.sent.allSatisfy { $0.body == nil })
        XCTAssertTrue(http.sentPaths.contains("/api/external/lists/list-a/items/movie-row"))
    }

    func testRemovalUsesObservedRecordIDAndDoesNotDeleteList() async throws {
        let saved = credentials()
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/items", json: page([movie, show]))
        http.stub(pathSuffix: "/items/movie-row", json: #"{"success":true}"#)
        http.stub(pathSuffix: "/items", json: page([show]))
        let destination = PublicMetaDBWatchlistDestination(receiptStore: try receiptStore())
        try configure(destination, http: http, saved: saved, selected: selection(saved))
        try await apply(.absent, to: destination)
        XCTAssertEqual(http.sentPaths, [
            "/api/external/lists/list-a/items", "/api/external/lists/list-a/items/movie-row",
            "/api/external/lists/list-a/items"
        ])
    }

    func testChangedSelectionRejectsOldBindingAndScopeBeforeNetwork() async throws {
        let saved = credentials()
        let http = RecordingHTTPClient()
        let destination = PublicMetaDBWatchlistDestination(receiptStore: try receiptStore())
        try configure(destination, http: http, saved: saved, selected: selection(saved))
        let oldScope = destination.reconciliationScope
        let resolved = try await destination.resolve(target())
        let binding = try XCTUnwrap(resolved)
        try configure(destination, http: http, saved: saved, selected: selection(saved))
        for scope in [oldScope, destination.reconciliationScope] {
            do {
                try await destination.apply(.present, to: binding, expectedReconciliationScope: scope)
                XCTFail("Previous consent authorized a write")
            } catch { XCTAssertEqual(error as? WatchlistDestinationError, .authenticationRequired) }
        }
        XCTAssertTrue(http.sent.isEmpty)
    }

    func testConnectionChangeAfterWriteKeepsDurableUncertainty() async throws {
        let saved = credentials()
        let selected = try selection(saved)
        let store = try receiptStore()
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/items", json: page([]))
        http.stub(pathSuffix: "/items", json: #"{"success":true,"item":\#(movie)}"#)
        http.stub(pathSuffix: "/items", json: page([]))
        let destination = PublicMetaDBWatchlistDestination(receiptStore: store)
        let fence = InvalidatingHTTPClient(underlying: http) { destination.disable() }
        try configure(destination, http: fence, saved: saved, selected: selected)
        do { try await apply(.present, to: destination); XCTFail("Stale write response accepted") }
        catch { XCTAssertEqual(error as? WatchlistDestinationError, .permanent) }
        try configure(destination, http: http, saved: saved, selected: selected)
        do { try await apply(.present, to: destination); XCTFail("Stale response made POST retryable") }
        catch { XCTAssertEqual(error as? WatchlistDestinationError, .permanent) }
        XCTAssertEqual(http.sent.filter { $0.body != nil }.count, 1)
    }
}

private final class InvalidatingHTTPClient: HTTPClient, Sendable {
    let underlying: RecordingHTTPClient
    let invalidate: @Sendable () -> Void
    init(underlying: RecordingHTTPClient, invalidate: @Sendable @escaping () -> Void) {
        self.underlying = underlying
        self.invalidate = invalidate
    }
    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        try await sendRaw(endpoint, baseURL: baseURL)
    }
    func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let result = try await underlying.sendRaw(endpoint, baseURL: baseURL)
        if endpoint.body != nil { invalidate() }
        return result
    }
}
