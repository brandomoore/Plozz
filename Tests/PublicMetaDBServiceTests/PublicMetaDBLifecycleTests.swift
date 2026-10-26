import CoreModels
import CoreNetworking
import CoreSecureStore
import Foundation
import XCTest
@testable import PublicMetaDBService
@testable import TestSupportNetworking

private let testKey = "pm-" + String(repeating: "B", count: 60)
private let verification = #"{"items":[],"total":0,"page":1,"perPage":1,"totalPages":0}"#

@MainActor
final class PublicMetaDBLifecycleTests: XCTestCase {
    func testDisconnectRequiresHistoryRevocationBeforeDeletingSavedKey() async throws {
        try await withWatchlistService { service, _, _ in
            let connection = try XCTUnwrap(service.historySyncIdentity)
            service.onHistorySyncDisconnect = { throw TrackerHistorySyncError.revocationFailed }
            XCTAssertThrowsError(try service.disconnect())
            XCTAssertEqual(service.phase, .credentialChangeFailed)
            await service.refreshStatus()
            XCTAssertEqual(service.historySyncIdentity, connection, "Failed removal must preserve the credential")
            await service.connect(key: testKey)
            XCTAssertEqual(service.phase, .credentialChangeFailed)
            await service.refreshStatus()
            XCTAssertEqual(service.historySyncIdentity, connection, "Failed replacement must preserve the credential")
            service.onHistorySyncDisconnect = nil
            try service.disconnect()
            await service.refreshStatus()
            XCTAssertNil(service.historySyncIdentity)
            XCTAssertEqual(service.phase, .disconnected)
        }
    }

    func testPlaybackRequiresSeparateConsentAndDoesNotFollowReplacedKeys() async throws {
        try await withWatchlistService { service, http, _ in
            var revocations = 0
            service.onHistorySyncDisconnect = { revocations += 1 }
            XCTAssertNil(service.playbackConnectionID)
            let connection = try XCTUnwrap(service.connectionID)
            try service.enablePlayback(expectedConnectionID: connection)
            let scope = try XCTUnwrap(service.playbackConnectionID)
            XCTAssertNil(service.watchlistSelection)
            await service.refreshStatus()
            XCTAssertEqual(service.playbackConnectionID, scope)
            await service.setActiveProfile(namespace: "other")
            XCTAssertNil(service.playbackConnectionID)
            await service.setActiveProfile(namespace: nil)
            XCTAssertEqual(service.playbackConnectionID, scope)
            service.disablePlayback()
            await service.refreshStatus()
            XCTAssertNil(service.playbackConnectionID)
            try service.enablePlayback(expectedConnectionID: connection)
            XCTAssertNotEqual(service.playbackConnectionID, scope)
            await service.connect(key: testKey)
            XCTAssertEqual(revocations, 1, "Refreshing and switching profiles must not revoke; replacing a key must")
            XCTAssertNil(service.playbackConnectionID)
            XCTAssertThrowsError(try service.enablePlayback(expectedConnectionID: connection))
            XCTAssertTrue(http.sent.allSatisfy { $0.body == nil })
        }
    }

    func testWatchlistConsentIsSeparateFromConnectionAndRestoresOnlyForSameProfileAndKey() async throws {
        try await withWatchlistService { service, http, list in
            XCTAssertNil(service.watchlistSelection)
            XCTAssertFalse(service.watchlistDestination.capabilities.write.isWritable)
            let destination = service.watchlistDestination
            let connectionID = try XCTUnwrap(service.connectionID)
            try await service.enableWatchlist(list, expectedConnectionID: connectionID)
            let selected = try XCTUnwrap(service.watchlistSelection)
            let scope = destination.reconciliationScope
            XCTAssertTrue(destination.capabilities.write.isWritable)
            XCTAssertTrue(http.sent.allSatisfy { $0.body == nil })
            await service.refreshStatus()
            XCTAssertTrue(service.watchlistDestination === destination)
            XCTAssertEqual(service.watchlistSelection, selected)
            XCTAssertEqual(destination.reconciliationScope, scope)
            service.selectProfile(namespace: "other-profile")
            XCTAssertNil(service.watchlistSelection)
            XCTAssertFalse(destination.capabilities.write.isWritable)
            await service.refreshStatus()
            XCTAssertEqual(service.phase, .disconnected)
            await service.setActiveProfile(namespace: nil)
            XCTAssertEqual(service.watchlistSelection, selected)
            await service.connect(key: testKey)
            XCTAssertNotEqual(service.connectionID, connectionID)
            XCTAssertNil(service.watchlistSelection)
            XCTAssertFalse(destination.capabilities.write.isWritable)
        }
    }

    func testStoppingWatchlistSyncRevokesItWithoutRemoteWritesAndRequiresFreshConsent() async throws {
        try await withWatchlistService { service, http, list in
            let connectionID = try XCTUnwrap(service.connectionID)
            try await service.enableWatchlist(list, expectedConnectionID: connectionID)
            let previous = service.watchlistDestination.reconciliationScope
            service.disableWatchlist()
            XCTAssertFalse(service.watchlistDestination.capabilities.read.isReadable)
            await service.refreshStatus()
            XCTAssertNil(service.watchlistSelection)
            XCTAssertEqual(service.connectionID, connectionID)
            try await service.enableWatchlist(list, expectedConnectionID: connectionID)
            XCTAssertNotEqual(service.watchlistDestination.reconciliationScope, previous)
            XCTAssertTrue(http.sent.allSatisfy { $0.body == nil })
        }
    }

    func testConsentForPreviousConnectionCannotEnableCurrentList() async throws {
        try await withWatchlistService { service, http, list in
            let count = http.sent.count
            do {
                try await service.enableWatchlist(list, expectedConnectionID: UUID())
                XCTFail("Consent moved to a different connection")
            } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .connectionChanged) }
            XCTAssertEqual(http.sent.count, count)
            XCTAssertNil(service.watchlistSelection)
        }
    }

    func testChangedListVisibilityRequiresNewConfirmation() async throws {
        try await withWatchlistService { service, http, list in
            let nowPublic = try JSONDecoder().decode(
                PublicMetaDB.List.self,
                from: Data(#"{"id":"list-a","name":"Watch later","is_public":true,"type":"watchlist"}"#.utf8)
            )
            do {
                try await service.enableWatchlist(nowPublic, expectedConnectionID: XCTUnwrap(service.connectionID))
                XCTFail("Visibility mismatch was accepted")
            } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .incompleteResponse) }
            XCTAssertNil(service.watchlistSelection)
            XCTAssertFalse(service.watchlistDestination.capabilities.write.isWritable)
            XCTAssertFalse(list.isPublic)
            XCTAssertTrue(http.sent.allSatisfy { $0.body == nil })
        }
    }

    private func withWatchlistService(
        _ body: (PublicMetaDBService, RecordingHTTPClient, PublicMetaDB.List) async throws -> Void
    ) async throws {
        let name = "PublicMetaDBWatchlistTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let http = RecordingHTTPClient()
        let listJSON = #"{"id":"list-a","name":"Watch later","is_public":false,"type":"watchlist"}"#
        http.stub(pathSuffix: "/lists", json: verification)
        http.stub(pathSuffix: "/lists", json: #"{"items":[\#(listJSON)],"total":1,"page":1,"perPage":500,"totalPages":1}"#)
        let service = PublicMetaDBService(
            credentials: CredentialStore(), http: http, defaults: defaults,
            watchlistReceiptStore: try DurableLocalStateStore(secureStore: InMemorySecureStore())
        )
        await service.connect(key: testKey)
        let list = try JSONDecoder().decode(PublicMetaDB.List.self, from: Data(listJSON.utf8))
        try await body(service, http, list)
    }

    func testCatalogNavigationIsReadOnlyAndDeliveredOnceWithoutHidingDismissal() async throws {
        try await withWatchlistService { service, http, _ in
            let content = try PublicMetaDB.Content(tmdbID: 42, mediaType: .movie)
            let item = MediaItem(id: "server-movie", title: "Curated", kind: .movie, providerIDs: ["Tmdb": "42"])
            service.resolveCatalogItem = { _ in item }
            let connection = try XCTUnwrap(service.connectionID)
            try service.presentContent(for: item)
            let before = http.sent.count
            try await service.openCatalogItem(for: content, expectedConnectionID: connection)
            XCTAssertNil(service.presentedItem)
            XCTAssertTrue(service.hasPendingCatalogNavigation)
            XCTAssertEqual(service.consumeCatalogNavigation()?.id, item.id)
            XCTAssertFalse(service.hasPendingCatalogNavigation)
            XCTAssertNil(service.consumeCatalogNavigation())
            XCTAssertNotNil(service.catalogNavigation, "Sheet dismissal observers still need the request ID.")
            XCTAssertEqual(http.sent.count, before)
            service.selectProfile(namespace: "other")
            XCTAssertNil(service.catalogNavigation)
        }
    }

    func testCatalogNavigationRejectsUnverifiedTitleIdentity() async throws {
        try await withWatchlistService { service, _, _ in
            let content = try PublicMetaDB.Content(tmdbID: 42, mediaType: .movie)
            let connection = try XCTUnwrap(service.connectionID)
            for item in [
                MediaItem(id: "wrong", title: "Wrong", kind: .movie, providerIDs: ["Tmdb": "43"]),
                MediaItem(id: "wrong", title: "Wrong", kind: .series, providerIDs: ["Tmdb": "42"]),
                MediaItem(id: "wrong", title: "Wrong", kind: .movie, providerIDs: ["Tmdb": "42", "TMDB ID": "43"])
            ] {
                service.resolveCatalogItem = { _ in item }
                do {
                    try await service.openCatalogItem(for: content, expectedConnectionID: connection)
                    XCTFail("Wrong title became a navigation request")
                } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .incompleteResponse) }
                XCTAssertNil(service.catalogNavigation)
            }
        }
    }

    func testCatalogResultCannotSurviveRefreshOfTheSameSavedConnection() async throws {
        try await withWatchlistService { service, _, _ in
            let content = try PublicMetaDB.Content(tmdbID: 42, mediaType: .movie)
            let connection = try XCTUnwrap(service.connectionID)
            service.resolveCatalogItem = { _ in
                await service.refreshStatus()
                return MediaItem(id: "m", title: "Movie", kind: .movie, providerIDs: ["Tmdb": "42"])
            }
            do {
                try await service.openCatalogItem(for: content, expectedConnectionID: connection)
                XCTFail("Result from an invalidated connection epoch was published")
            } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .connectionChanged) }
            XCTAssertEqual(service.connectionID, connection)
            XCTAssertNil(service.catalogNavigation)
        }
    }

    func testConnectionOnlyReadsAndPersistsAfterVerification() async throws {
        let store = CredentialStore()
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/lists", json: verification)
        let service = PublicMetaDBService(credentials: store, http: http)
        await service.connect(key: testKey)
        XCTAssertEqual(service.phase, .connected)
        XCTAssertNotNil(store.load(namespace: nil))
        XCTAssertEqual(http.sentPaths, ["/api/external/lists"])
        XCTAssertTrue(http.sent.allSatisfy { $0.body == nil })
        XCTAssertEqual(service.connectionID, store.load(namespace: nil)?.connectionID)
    }

    func testRejectedCandidateDoesNotOverwriteWorkingCredential() async throws {
        let saved = PublicMetaDBCredentials(key: testKey)
        let store = CredentialStore()
        try store.save(saved, namespace: nil)
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/lists", json: "{}", status: 401)
        let service = PublicMetaDBService(credentials: store, http: http)
        await service.connect(key: "pm-" + String(repeating: "C", count: 60))
        XCTAssertEqual(service.phase, .failed(.unauthorized))
        XCTAssertEqual(store.load(namespace: nil)?.connectionID, saved.connectionID)
        XCTAssertNil(service.client)
    }

    func testReplacementIsANewConnectionEvenForSameKey() async throws {
        let store = CredentialStore()
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/lists", json: verification)
        let service = PublicMetaDBService(credentials: store, http: http)
        await service.connect(key: testKey)
        let first = try XCTUnwrap(service.connectionID)
        let staleClient = try XCTUnwrap(service.client)
        await service.connect(key: testKey)
        XCTAssertNotEqual(service.connectionID, first)
        do { _ = try await staleClient.history(); XCTFail("Old connection could dispatch") }
        catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .connectionChanged) }
        XCTAssertEqual(http.sent.count, 2)
    }

    func testProfileSwitchCannotReusePreviousProfileKey() async throws {
        let store = CredentialStore()
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/lists", json: verification)
        let service = PublicMetaDBService(credentials: store, http: http)
        await service.connect(key: testKey)
        let previousClient = try XCTUnwrap(service.client)
        await service.setActiveProfile(namespace: "second-profile")
        XCTAssertEqual(service.phase, .disconnected)
        XCTAssertNil(service.client)
        XCTAssertNotNil(store.load(namespace: nil))
        XCTAssertNil(store.load(namespace: "second-profile"))
        do { _ = try await previousClient.lists(); XCTFail("Previous profile remained active") }
        catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .connectionChanged) }
        XCTAssertEqual(http.sent.count, 1)
    }

    func testDisconnectRemovesOnlyActiveNamespaceAndDoesNotPretendToRevokeRemoteKey() async throws {
        let store = CredentialStore()
        try store.save(.init(key: testKey), namespace: "other")
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/lists", json: verification)
        let service = PublicMetaDBService(credentials: store, http: http)
        await service.connect(key: testKey)
        try service.disconnect()
        XCTAssertEqual(service.phase, .disconnected)
        XCTAssertNil(store.load(namespace: nil))
        XCTAssertNotNil(store.load(namespace: "other"))
        XCTAssertEqual(http.sent.count, 1)
    }

    func testStorageFailureDoesNotClaimConnectionSuccess() async throws {
        let store = CredentialStore(failingWrites: true)
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/lists", json: verification)
        let service = PublicMetaDBService(credentials: store, http: http)
        await service.connect(key: testKey)
        XCTAssertEqual(service.phase, .credentialChangeFailed)
        XCTAssertNil(service.client)
        XCTAssertNil(service.connectionID)
        XCTAssertNil(store.load(namespace: nil))
    }

    func testHistorySnapshotPreservesFactsAndNamespacesAcrossCategories() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/lists", json: verification)
        http.stub(pathSuffix: "/watched", json: """
        {"items":[{"id":"same-id","tmdb_id":550,"media_type":"movie","watched_at":null}],
         "total":1,"page":1,"perPage":500,"totalPages":1}
        """)
        http.stub(pathSuffix: "/resume", json: """
        {"items":[{"id":"same-id","tmdb_id":42,"media_type":"tv","season":0,"episode":1,
                   "position_ms":120000,"runtime_ms":1200000,"progress":10,"updated":"2023-11-14T22:13:20.125Z"}],
         "total":1,"page":1,"perPage":500,"totalPages":1}
        """)
        let service = PublicMetaDBService(credentials: CredentialStore(), http: http)
        await service.connect(key: testKey)
        let snapshot = try await service.historySnapshot()
        XCTAssertEqual(snapshot.trackerID, "publicmetadb")
        XCTAssertEqual(snapshot.connectionID, service.connectionID?.uuidString)
        XCTAssertEqual(snapshot.observations.map(\.recordID), ["watched/same-id", "resume/same-id"])
        XCTAssertEqual(snapshot.observations[0].fact, .watched(at: nil))
        let episode = snapshot.observations[1]
        XCTAssertEqual(episode.identities, [.external(source: "series-tmdb:s0e1", value: "42")])
        XCTAssertEqual(episode.episodeOrdering, .tmdb)
        XCTAssertEqual(episode.fact, .resume(
            seconds: 120, runtime: 1_200, updatedAt: Date(timeIntervalSince1970: 1_700_000_000.125)
        ))
        XCTAssertTrue(http.sent.allSatisfy { $0.body == nil })
    }

    func testIncompleteResumeCategoryCannotProduceAnImportSnapshot() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/lists", json: verification)
        http.stub(pathSuffix: "/watched", json: """
        {"items":[{"id":"play","tmdb_id":550,"media_type":"movie","watched_at":null}],
         "total":1,"page":1,"perPage":500,"totalPages":1}
        """)
        http.stub(pathSuffix: "/resume", json: #"{"items":[],"total":1,"page":1,"perPage":500,"totalPages":1}"#)
        let service = PublicMetaDBService(credentials: CredentialStore(), http: http)
        await service.connect(key: testKey)
        do {
            _ = try await service.historySnapshot()
            XCTFail("A partial category became a complete snapshot")
        } catch {
            XCTAssertEqual(error as? PublicMetaDB.Failure, .incompleteResponse)
        }
        XCTAssertTrue(http.sent.allSatisfy { $0.body == nil })
    }
}

private final class CredentialStore: PublicMetaDBCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: PublicMetaDBCredentials] = [:]
    private let failingWrites: Bool
    init(failingWrites: Bool = false) { self.failingWrites = failingWrites }
    func load(namespace: String?) -> PublicMetaDBCredentials? { lock.withLock { values[namespace ?? ""] } }
    func save(_ credentials: PublicMetaDBCredentials, namespace: String?) throws {
        if failingWrites { throw AppError.accessRestricted }
        lock.withLock { values[namespace ?? ""] = credentials }
    }
    func clear(namespace: String?) throws { _ = lock.withLock { values.removeValue(forKey: namespace ?? "") } }
}
