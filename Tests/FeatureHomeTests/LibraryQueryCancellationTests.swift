import CoreModels
import Foundation
import XCTest
@testable import FeatureHomeCore

@MainActor
final class LibraryQueryCancellationTests: XCTestCase {
    func testInvalidationDuringRecoveryCannotExcludeSourcesFromTheNewQuery() async throws {
        let provider = CancellationInventoryProvider(holdsRecovery: true)
        let session = LibraryQuerySession(provider: provider, containerID: "lib", kind: .movie)
        let request = PageRequest(filters: .init(filter: .atmos))
        let first = Task { try await session.page(request, progress: { _, _ in }) }
        await provider.waitUntilHeld()
        let invalidation = Task { await session.invalidate() }
        await provider.waitUntilRecoveryCancelled()
        await provider.release()
        await invalidation.value
        do {
            _ = try await first.value
            XCTFail("The superseded query must not publish")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let excluded = await provider.isExcluded
        XCTAssertFalse(excluded)
        let replacement = try await session.page(request, progress: { _, _ in })
        XCTAssertEqual(replacement.totalCount, 0)
    }

    func testReplacementFilterDoesNotReuseCancelledInventory() async throws {
        let provider = CancellationInventoryProvider()
        let session = LibraryQuerySession(provider: provider, containerID: "lib", kind: .movie)
        let first = Task {
            try await session.page(.init(filters: .init(filter: .atmos)), progress: { _, _ in })
        }
        await provider.waitUntilHeld()
        first.cancel()
        let preparing = expectation(description: "Replacement filter preparing")
        preparing.assertForOverFulfill = false
        let next = Task {
            try await session.page(.init(filters: .init(filter: .dolbyVision)), progress: { _, _ in
                preparing.fulfill()
            })
        }
        await fulfillment(of: [preparing], timeout: 5)
        await provider.release()
        _ = await first.result
        let page = try await next.value
        XCTAssertEqual(page.totalCount, 0)
        let requests = await provider.requests
        XCTAssertEqual(requests, 2)
    }

    func testCancellingOneCoalescedCallerDoesNotCancelTheOther() async throws {
        let provider = CancellationInventoryProvider()
        let session = LibraryQuerySession(provider: provider, containerID: "lib", kind: .movie)
        let request = PageRequest(filters: .init(filter: .atmos))
        let first = Task { try await session.page(request, progress: { _, _ in }) }
        await provider.waitUntilHeld()
        let preparing = expectation(description: "Concurrent query preparing")
        preparing.assertForOverFulfill = false
        let next = Task {
            try await session.page(request, progress: { _, _ in preparing.fulfill() })
        }
        await fulfillment(of: [preparing], timeout: 5)
        first.cancel()
        await provider.release()
        _ = await first.result
        let page = try await next.value
        XCTAssertEqual(page.totalCount, 0)
        let requests = await provider.requests
        XCTAssertEqual(requests, 2)
    }
}

private actor CancellationInventoryProvider: MediaLibraryQueryProviding, LibraryQueryFailureRecovering {
    nonisolated let kind: ProviderKind = .jellyfin
    nonisolated let session = UserSession(
        server: MediaServer(id: "query", name: "Query", baseURL: URL(string: "https://query.test")!, provider: .jellyfin),
        userID: "user", userName: "User", deviceID: "device", accessToken: "test"
    )
    private var held: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    private(set) var requests = 0
    private let holdsRecovery: Bool
    private(set) var isExcluded = false
    private var recoveryCancelled = false
    private var cancellationObserver: CheckedContinuation<Void, Never>?

    init(holdsRecovery: Bool = false) { self.holdsRecovery = holdsRecovery }

    func recoverLibraryQuery(after failure: LibrarySourceFailure) async -> Bool {
        guard holdsRecovery else { return false }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                held = continuation
                let ready = observers
                observers = []
                ready.forEach { $0.resume() }
            }
        } onCancel: {
            Task { await self.noteRecoveryCancellation() }
        }
        isExcluded = true
        return true
    }

    func resetLibraryQueryRecovery() async { isExcluded = false }

    private func noteRecoveryCancellation() {
        recoveryCancelled = true
        cancellationObserver?.resume()
        cancellationObserver = nil
    }

    func waitUntilRecoveryCancelled() async {
        guard !recoveryCancelled else { return }
        await withCheckedContinuation { cancellationObserver = $0 }
    }

    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func release() {
        held?.resume()
        held = nil
    }

    nonisolated func supportedSortFields(in containerID: String, kind: MediaItemKind) -> [SortField] { [.name] }
    nonisolated func libraryQueryCapabilities(in containerID: String, kind: MediaItemKind) -> LibraryQueryCapabilities {
        .init(filters: LibraryFilter.allCases, nativeSortFields: [.name])
    }
    func libraryQueryFacets(in containerID: String, kind: MediaItemKind) async throws -> LibraryQueryFacets { .init() }
    func libraryQueryInventory(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        requests += 1
        if requests == 1 {
            if holdsRecovery {
                throw LibrarySourceFailure(
                    underlyingError: AppError.serverUnreachable,
                    servers: [session.server], sourceKeys: ["source"])
            }
            await withCheckedContinuation { continuation in
                held = continuation
                let ready = observers
                observers = []
                for observer in ready { observer.resume() }
            }
        }
        try Task.checkCancellation()
        return .init(items: [], startIndex: page.startIndex, totalCount: 0)
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        .init(items: [], startIndex: page.startIndex, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
