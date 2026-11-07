import CoreModels
import Foundation
import XCTest

final class LibraryInventoryStoreTests: XCTestCase {
    func testUnchangedNamesDoNotRewriteDiskButStillReturnFreshProviderMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryInventoryStore(directory: directory)
        let source = account()
        _ = try await store.refresh(for: source) { [.init(id: "movies", title: "Movies", kind: .movie)] }
        let url = directory.appendingPathComponent("library-inventory-v1.json")
        let originalDate = Date(timeIntervalSince1970: 1)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: url.path)
        let fresh = MediaLibrary(
            id: "movies", title: "Movies", kind: .movie, imageURL: URL(string: "https://fixture.invalid/new-art")
        )
        let result = try await store.refresh(for: source) { [fresh] }
        XCTAssertEqual(result, [fresh])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, originalDate)
        XCTAssertNil(store.load(for: source)?.first?.imageURL)
        _ = try await store.refresh(for: source) { [.init(id: "movies", title: "Renamed", kind: .movie)] }
        XCTAssertEqual(LibraryInventoryStore(directory: directory).load(for: source)?.first?.title, "Renamed")
    }

    func testPersistsOnlyLibraryMetadataAndDistinguishesEmptyFromMissing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryInventoryStore(directory: directory)
        let source = account()
        var library = MediaLibrary(
            id: "movies", title: "Movies", kind: .movie,
            imageURL: URL(string: "https://fixture.invalid/art?token=FIXTURE-ART"),
            hasCollections: true, isMusic: false
        )
        library.sourceAccountID = "another-account"
        library.additionalSourceAccountIDs = ["another-account"]
        library.sourceContainerIDByAccount = ["another-account": "container"]
        let input = library
        _ = try await store.refresh(for: source) { [input] }
        let restored = LibraryInventoryStore(directory: directory)
        let cached = try XCTUnwrap(restored.load(for: source))
        XCTAssertEqual(cached.map(\.id), ["movies"])
        XCTAssertEqual(cached.first?.title, "Movies")
        XCTAssertEqual(cached.first?.hasCollections, true)
        XCTAssertNil(cached.first?.imageURL)
        XCTAssertNil(cached.first?.sourceAccountID)
        XCTAssertTrue(cached.first?.additionalSourceAccountIDs.isEmpty == true)
        XCTAssertTrue(cached.first?.sourceContainerIDByAccount.isEmpty == true)
        let data = try Data(contentsOf: directory.appendingPathComponent("library-inventory-v1.json"))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("FIXTURE-ART"))
        XCTAssertFalse(text.contains("FIXTURE-TOKEN"))
        XCTAssertNil(restored.load(for: account()))
        _ = try await restored.refresh(for: source) { [] }
        XCTAssertEqual(LibraryInventoryStore(directory: directory).load(for: source), [])
    }

    func testIdentitySeparatesConnectionsUsersAndCredentialsButNotPlexActivationTokens() async throws {
        let store = LibraryInventoryStore(directory: nil)
        let source = account()
        _ = try await store.refresh(for: source) { [.init(id: "movies", title: "Movies", kind: .movie)] }
        for change in [
            { (account: inout Account) in account.id = "other" },
            { (account: inout Account) in account.server.id = "other" },
            { (account: inout Account) in account.userID = "other" },
            { (account: inout Account) in account.server.provider = .emby },
            { (account: inout Account) in account.server.baseURL = URL(string: "https://other.invalid")! },
            { (account: inout Account) in account.credentialRevision = CredentialRevision() }
        ] {
            var changed = source.account
            change(&changed)
            XCTAssertNil(store.load(for: account(changed)))
        }
        XCTAssertNil(store.load(for: account(source.account, revision: CredentialRevision())))

        var plex = source.account
        plex.server.provider = .plex
        let viewer = account(plex, viewer: "child", revision: CredentialRevision())
        _ = try await store.refresh(for: viewer) { [.init(id: "kids", title: "Kids", kind: .movie)] }
        XCTAssertEqual(
            store.load(for: account(plex, viewer: "child", revision: CredentialRevision()))?.map(\.id), ["kids"]
        )
        XCTAssertNil(store.load(for: account(plex, viewer: "sibling")))
        XCTAssertNil(store.load(for: account(plex)))
        plex.credentialRevision = CredentialRevision()
        XCTAssertNil(store.load(for: account(plex, viewer: "child")))
    }

    func testOfflineFailureRetainsInventoryButAuthorizationRefusalsRemoveIt() async throws {
        for error in [AppError.serverUnreachable, .unauthorized, .invalidCredentials, .accessRestricted] {
            let store = LibraryInventoryStore(directory: nil)
            let source = account()
            _ = try await store.refresh(for: source) { [.init(id: "movies", title: "Movies", kind: .movie)] }
            do {
                _ = try await store.refresh(for: source) { throw error }
                XCTFail("The refresh must surface its error")
            } catch let actual as AppError {
                XCTAssertEqual(actual, error)
            }
            if error == .serverUnreachable {
                XCTAssertEqual(store.load(for: source)?.map(\.id), ["movies"])
            } else {
                XCTAssertNil(store.load(for: source))
            }
        }
    }

    func testOlderResponseCannotOverwriteNewerSuccessOrAuthorizationRefusal() async throws {
        for deny in [false, true] {
            let store = LibraryInventoryStore(directory: nil)
            let source = account()
            let started = expectation(description: "Old request started")
            let gate = InventoryGate()
            let old = Task { try await store.refresh(for: source) { await gate.load(started: started) } }
            await fulfillment(of: [started], timeout: 5)
            do {
                _ = try await store.refresh(for: source) {
                    if deny { throw AppError.unauthorized }
                    return [.init(id: "new", title: "New", kind: .movie)]
                }
            } catch {
                XCTAssertTrue(deny)
                XCTAssertEqual(error as? AppError, .unauthorized)
            }
            await gate.finish()
            _ = try await old.value
            XCTAssertEqual(store.load(for: source)?.map(\.id), deny ? nil : ["new"])
        }
    }

    func testCancelledNewRequestDoesNotStrandOlderLiveRequest() async throws {
        let store = LibraryInventoryStore(directory: nil)
        let source = account()
        let firstStarted = expectation(description: "First request started")
        let secondStarted = expectation(description: "Second request started")
        let firstGate = InventoryGate()
        let secondGate = InventoryGate()
        let first = Task { try await store.refresh(for: source) { await firstGate.load(started: firstStarted) } }
        await fulfillment(of: [firstStarted], timeout: 5)
        let second = Task { try await store.refresh(for: source) { await secondGate.load(started: secondStarted) } }
        await fulfillment(of: [secondStarted], timeout: 5)
        second.cancel()
        await secondGate.finish()
        do {
            _ = try await second.value
            XCTFail("Cancellation must not cache a late provider answer")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(store.load(for: source))
        await firstGate.finish()
        _ = try await first.value
        XCTAssertEqual(store.load(for: source)?.map(\.id), ["old"])
    }

    func testInventoryAndAccountCountAreBounded() async throws {
        let store = LibraryInventoryStore(directory: nil)
        let source = account()
        let libraries = (0..<600).map { MediaLibrary(id: "\($0)", title: "Library \($0)", kind: .movie) }
        _ = try await store.refresh(for: source) { libraries }
        XCTAssertEqual(store.load(for: source)?.count, 512)
        var sources: [ResolvedAccount] = []
        for _ in 0..<129 {
            let next = account()
            sources.append(next)
            _ = try await store.refresh(for: next) { [] }
        }
        XCTAssertNil(store.load(for: source))
        XCTAssertEqual(sources.filter { store.load(for: $0) != nil }.count, 128)
    }

    func testOversizedInventoryStaysCompleteInLiveResultButCannotExceedDiskBudget() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryInventoryStore(directory: directory)
        let source = account()
        let libraries = (0..<512).map {
            MediaLibrary(id: "\($0)", title: String(repeating: "x", count: 8_192), kind: .movie)
        }
        let live = try await store.refresh(for: source) { libraries }
        XCTAssertEqual(live, libraries)
        XCTAssertNil(store.load(for: source))
        let data = try Data(contentsOf: directory.appendingPathComponent("library-inventory-v1.json"))
        XCTAssertLessThanOrEqual(data.count, 2 * 1_024 * 1_024)
    }

    private func account(
        _ metadata: Account? = nil, viewer: String? = nil, revision: CredentialRevision? = nil
    ) -> ResolvedAccount {
        let metadata = metadata ?? Account(
            server: .init(id: "server", name: "Server", baseURL: URL(string: "https://fixture.invalid")!, provider: .jellyfin),
            userID: "viewer", userName: "Viewer", deviceID: "fixture"
        )
        return .init(
            account: metadata, provider: InventoryProvider(session: metadata.session(token: "FIXTURE-TOKEN")),
            plexHomeUserID: viewer, credentialRevision: revision
        )
    }
}

private actor InventoryGate {
    private var continuation: CheckedContinuation<[MediaLibrary], Never>?
    func load(started: XCTestExpectation) async -> [MediaLibrary] {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }
    func finish() {
        continuation?.resume(returning: [.init(id: "old", title: "Old", kind: .movie)])
        continuation = nil
    }
}

private struct InventoryProvider: MediaProvider {
    let session: UserSession
    var kind: ProviderKind { session.server.provider }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        .init(items: [], startIndex: 0, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
