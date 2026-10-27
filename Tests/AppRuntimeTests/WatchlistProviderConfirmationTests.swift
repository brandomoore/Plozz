import CoreModels
import XCTest
@testable import AppRuntime

@MainActor
final class WatchlistProviderConfirmationTests: XCTestCase {
    func testLegacyProviderRefreshFollowsSuccessfulWriteNotOptimisticIntent() async throws {
        let provider = ConfirmationProvider()
        var changes: [WatchlistProviderChange] = []
        let observer = NotificationCenter.default.addObserver(
            forName: WatchlistProviderChange.notification, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                if let change = note.object as? WatchlistProviderChange { changes.append(change) }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let change = WatchlistProviderChange(profileNamespace: "p", accountID: "a", serverUserID: "viewer")
        var currentChange = change
        var failureCount = 0
        let coordinator = MediaItemActionCoordinator(
            providerResolver: { _ in provider }, primaryAccountID: { "a" },
            crossServerWatchSyncEnabled: { false }, enqueueWatchMutation: { _ in },
            watchlistProviderChange: { account in account == "a" ? currentChange : nil },
            makeWatchlistFailureFeedback: { { failureCount += 1 } }
        )
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie, sourceAccountID: "a")
        coordinator.perform(.addToWatchlist, on: item, context: .none)
        try await waitUntil { await provider.attempts == 1 }
        XCTAssertTrue(changes.isEmpty)
        currentChange = .init(profileNamespace: "another-profile", accountID: "a", serverUserID: "another-viewer")
        await provider.finish(failure: false)
        try await waitUntil { changes.count == 1 }
        XCTAssertEqual(changes, [change], "An in-flight write belongs to its original profile and viewer.")

        currentChange = change
        await provider.hold()
        coordinator.perform(.removeFromWatchlist, on: item, context: .none)
        try await waitUntil { await provider.attempts == 2 }
        await provider.finish(failure: true)
        try await waitUntil { failureCount == 1 }
        XCTAssertEqual(changes, [change], "A rejected write must not schedule collection reads.")

        await provider.hold()
        coordinator.perform(.removeFromWatchlist, on: item, context: .none)
        try await waitUntil { await provider.attempts == 3 }
        await provider.finish(failure: false)
        try await waitUntil { changes.count == 2 }
        XCTAssertEqual(changes, [change, change], "Successful removal must refresh collections too.")
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Watchlist write did not finish")
                throw AppError.invalidResponse
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor ConfirmationProvider: MediaProvider, WatchlistProviding {
    nonisolated let kind = ProviderKind.jellyfin
    nonisolated let session = UserSession(
        server: .init(id: "server", name: "Server", baseURL: URL(string: "https://example.com")!, provider: .jellyfin),
        userID: "viewer", userName: "Viewer", deviceID: "device", accessToken: "test-token"
    )
    private var paused = true
    private var failure = false
    private(set) var attempts = 0
    func hold() { paused = true }
    func finish(failure: Bool) { self.failure = failure; paused = false }
    func setWatchlisted(_ on: Bool, item: MediaItem) async throws {
        attempts += 1
        while paused { try await Task.sleep(for: .milliseconds(5)) }
        if failure { throw AppError.serverUnreachable }
    }
    func watchlist() async throws -> [MediaItem] { [] }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage { throw AppError.notFound }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
