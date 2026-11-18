import CoreModels
import XCTest
@testable import AppRuntime

final class RelatedLibraryBatchTests: XCTestCase {
    func testMultipleServersAndSameKindAccountsKeepOverlappingIDsSeparate() async throws {
        let kinds: [ProviderKind] = [.plex, .plex, .jellyfin, .emby]
        let accounts = kinds.enumerated().map { index, kind -> ResolvedAccount in
            let id = "account-\(index)"
            let provider = BatchProvider(kind: kind, viewer: id) { ids in
                XCTAssertEqual(ids, ["1"])
                return [.init(id: "1", title: id, kind: .movie)]
            }
            return .init(account: .init(id: id, from: provider.session), provider: provider)
        }
        let loaders = relatedTitleLibraryBatchLoaders(in: accounts)
        XCTAssertEqual(loaders.count, 4)
        XCTAssertNil(loaders["inactive"])
        for account in accounts {
            let load = try XCTUnwrap(loaders[account.account.id])
            let result = await load(["1"])
            XCTAssertEqual(result.map(\.title), [account.account.id])
            XCTAssertEqual(result.map(\.sourceAccountID), [account.account.id])
        }
    }

    func testRebuiltViewerContextCannotReuseAnotherViewersResult() async throws {
        for viewer in ["first-viewer", "second-viewer"] {
            let provider = BatchProvider(kind: .plex, viewer: viewer) { _ in
                [.init(id: "1", title: viewer, kind: .movie)]
            }
            let loaders = relatedTitleLibraryBatchLoaders(in: [
                .init(account: .init(id: "same-account", from: provider.session), provider: provider)
            ])
            let load = try XCTUnwrap(loaders["same-account"])
            let result = await load(["1"])
            XCTAssertEqual(result.first?.title, viewer)
            XCTAssertEqual(result.first?.sourceAccountID, "same-account")
        }
    }

    func testMalformedBatchFailsClosedForIndividualRecovery() async throws {
        let item = MediaItem(id: "1", title: "Native", kind: .movie)
        for returned in [[item, item], [.init(id: "foreign", title: "Wrong", kind: .movie)]] {
            let provider = BatchProvider(kind: .jellyfin, viewer: "viewer") { _ in returned }
            let loaders = relatedTitleLibraryBatchLoaders(in: [
                .init(account: .init(id: "account", from: provider.session), provider: provider)
            ])
            let load = try XCTUnwrap(loaders["account"])
            let result = await load(["1"])
            XCTAssertTrue(result.isEmpty)
        }
    }

    func testBatchRequestsObserveOwnerCancellationAndDeadline() async throws {
        for cancelOwner in [true, false] {
            let started = expectation(description: "Batch started")
            let cancelled = expectation(description: "Batch cancelled")
            let provider = BatchProvider(kind: .emby, viewer: "viewer") { _ in
                started.fulfill()
                do { try await Task.sleep(for: .seconds(30)) }
                catch { cancelled.fulfill(); throw error }
                return []
            }
            let loaders = relatedTitleLibraryBatchLoaders(in: [
                .init(account: .init(id: "account", from: provider.session), provider: provider)
            ])
            let load = try XCTUnwrap(loaders["account"])
            let task = Task { await load(["1"]) }
            defer { task.cancel() }
            await fulfillment(of: [started], timeout: 2)
            if cancelOwner { task.cancel() }
            await fulfillment(of: [cancelled], timeout: cancelOwner ? 2 : 6)
            let result = await task.value
            XCTAssertTrue(result.isEmpty)
        }
    }

    private struct BatchProvider: LibraryItemBatchProviding {
        let kind: ProviderKind
        let viewer: String
        let operation: @Sendable ([String]) async throws -> [MediaItem]
        var session: UserSession {
            .init(server: .init(id: "server", name: "Fixture", baseURL: URL(string: "https://fixture.test")!,
                                provider: kind),
                  userID: viewer, userName: "Viewer", deviceID: "fixture", accessToken: "fixture")
        }
        func libraryItems(ids: [String]) async throws -> [MediaItem] { try await operation(ids) }
        func libraries() async throws -> [MediaLibrary] { [] }
        func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
        func latest(limit: Int) async throws -> [MediaItem] { [] }
        func item(id: String) async throws -> MediaItem { throw AppError.notFound }
        func children(of itemID: String) async throws -> [MediaItem] { [] }
        func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
            throw AppError.notFound
        }
        func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
        func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
        func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
        func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
    }
}
