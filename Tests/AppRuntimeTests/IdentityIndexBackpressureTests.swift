import CoreModels
import Foundation
import XCTest
@testable import AppRuntime

@MainActor
final class IdentityIndexBackpressureTests: XCTestCase {
    func testRateLimitedEnrichmentStopsPagesAndLibrariesWithoutCompletingIndex() async {
        let provider = ThrottledIndexProvider(failsPage: false)
        let store = BackpressureIndexStore()
        let account = ResolvedAccount(account: Account(id: "silo", from: provider.session), provider: provider)
        let model = IdentityIndexModel(
            activeAccounts: { [account] }, namespace: { "backpressure" }, onPublish: {},
            persistenceStore: store
        )
        model.warmIdentityIndex()
        await model.waitForIdentityWarm()
        let pages = await provider.pageRequests
        let details = await provider.detailRequests
        XCTAssertEqual(pages, ["first:0"])
        XCTAssertGreaterThan(details, 0)
        XCTAssertLessThanOrEqual(details, 5)
        XCTAssertFalse(model.identitySnapshot.indexedAccountIDs.contains("silo"))
        XCTAssertTrue(store.snapshot.entriesByAccount.isEmpty)

        await provider.recover()
        model.warmIdentityIndex()
        await model.waitForIdentityWarm()
        XCTAssertTrue(model.identitySnapshot.indexedAccountIDs.contains("silo"))
        XCTAssertFalse(store.snapshot.entriesByAccount.isEmpty)
    }

    func testRateLimitedCatalogPageDoesNotContinueToAnotherLibrary() async {
        let provider = ThrottledIndexProvider(failsPage: true)
        let store = BackpressureIndexStore()
        let account = ResolvedAccount(account: Account(id: "silo", from: provider.session), provider: provider)
        let model = IdentityIndexModel(
            activeAccounts: { [account] }, namespace: { "backpressure" }, onPublish: {},
            persistenceStore: store
        )
        model.warmIdentityIndex()
        await model.waitForIdentityWarm()
        let pages = await provider.pageRequests
        let details = await provider.detailRequests
        XCTAssertEqual(pages, ["first:0"])
        XCTAssertEqual(details, 0)
        XCTAssertFalse(model.identitySnapshot.indexedAccountIDs.contains("silo"))
        XCTAssertTrue(store.snapshot.entriesByAccount.isEmpty)

        await provider.recover()
        model.warmIdentityIndex()
        await model.waitForIdentityWarm()
        XCTAssertTrue(model.identitySnapshot.indexedAccountIDs.contains("silo"))
        XCTAssertFalse(store.snapshot.entriesByAccount.isEmpty)
    }
}

private final class BackpressureIndexStore: IdentityIndexStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value = PersistedIdentityIndex.empty
    var snapshot: PersistedIdentityIndex { lock.withLock { value } }
    func load() -> PersistedIdentityIndex { snapshot }
    func save(_ snapshot: PersistedIdentityIndex) throws { lock.withLock { value = snapshot } }
}

private actor ThrottledIndexProvider: MediaProvider {
    nonisolated let kind = ProviderKind.silo
    nonisolated let catalogIdentityRequiresEnrichment = true
    nonisolated let session = UserSession(
        server: .init(id: "silo", name: "Fixture", baseURL: URL(string: "https://silo.test")!, provider: .silo),
        userID: "user", userName: "Fixture", deviceID: "fixture", accessToken: "fixture"
    )
    private let failsPage: Bool
    private var throttled = true
    private(set) var pageRequests: [String] = []
    private(set) var detailRequests = 0

    init(failsPage: Bool) { self.failsPage = failsPage }
    func recover() { throttled = false }
    func libraries() async throws -> [MediaLibrary] {
        ["first", "second"].map { .init(id: $0, title: $0, kind: .movie) }
    }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        pageRequests.append("\(containerID):\(page.startIndex)")
        if throttled && failsPage { throw AppError.rateLimited(retryAfter: 60) }
        let total = 201
        let end = min(total, page.startIndex + page.limit)
        let items = (page.startIndex..<end).map {
            MediaItem(id: "movie:\($0)", title: "Fixture", kind: .movie, providerIDs: ["Tmdb": "\($0 + 1)"])
        }
        return MediaPage(items: items, startIndex: page.startIndex, totalCount: total)
    }
    func item(id: String) async throws -> MediaItem {
        detailRequests += 1
        if throttled { throw AppError.rateLimited(retryAfter: 60) }
        return MediaItem(id: id, title: "Fixture", kind: .movie, providerIDs: ["Imdb": "tt123"])
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
