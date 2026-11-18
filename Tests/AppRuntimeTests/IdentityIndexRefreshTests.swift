import CoreModels
import Foundation
import XCTest
@testable import AppRuntime
@testable import TestSupportPerformance

@MainActor
final class IdentityIndexRefreshTests: XCTestCase {
    func testPerformanceRevalidatingTwentyUnchangedServers() async throws {
        try PerformanceProbe.requireEnabled()
        let fixture = try await fixture()
        try await PerformanceProbe.measure(self, scenario: "identity-unchanged-servers") {
            let result = await self.refresh(fixture)
            XCTAssertEqual(result.model.identitySnapshot.sourceRefs(for: Self.movie(0)).count, 20)
            return result.counters
        }
    }

    func testUnchangedVerificationDoesNotRepublishRestoredMembership() async throws {
        let fixture = try await fixture()
        let result = await refresh(fixture)
        XCTAssertEqual(result.counters["publications"], 1)
        XCTAssertEqual(result.model.identitySnapshotStore.revision, 1)
        let expectedAccounts = Set(fixture.accounts.map(\.account.id))
        var memberships = 0
        for index in 0..<200 {
            let sources = result.model.identitySnapshot.sourceRefs(for: Self.movie(index))
            XCTAssertEqual(Set(sources.map(\.accountID)), expectedAccounts)
            memberships += sources.count
        }
        XCTAssertEqual(memberships, 4_000)
    }

    func testForcedUnchangedRefreshDoesNotNotifyButRealChangesStillPublish() async throws {
        let fixture = try await fixture()
        let result = await refresh(fixture)
        let model = result.model
        let revision = model.identitySnapshotStore.revision
        let publications = result.publicationCount()
        let liveSources = model.identitySourcesProvider
        model.warmIdentityIndex(force: true)
        await model.waitForIdentityWarm()
        XCTAssertEqual(model.identitySnapshotStore.revision, revision)
        XCTAssertEqual(result.publicationCount(), publications)

        await fixture.providers[0].replaceFirstMovie()
        model.warmIdentityIndex(force: true)
        await model.waitForIdentityWarm()
        XCTAssertEqual(model.identitySnapshotStore.revision, revision + 1)
        XCTAssertEqual(result.publicationCount(), publications + 1)
        XCTAssertEqual(model.identitySnapshot.sourceRefs(for: Self.movie(0)).count, 19)
        XCTAssertEqual(model.identitySnapshot.sourceRefs(for: Self.movie(999)).count, 1)
        XCTAssertEqual(liveSources(Self.movie(999)).count, 1)
    }

    func testPruningFreshAccountsAndRemovingLastMembershipPublish() async throws {
        let fixture = try await fixture()
        var active = fixture.accounts
        let model = IdentityIndexModel(
            activeAccounts: { active }, namespace: { "prune-fixture" }, onPublish: {},
            persistenceStore: InMemoryIdentityIndexStore(fixture.persisted)
        )
        model.warmIdentityIndex()
        await model.waitForIdentityWarm()
        let revision = model.identitySnapshotStore.revision
        let liveSources = model.identitySourcesProvider
        active = [fixture.accounts[0]]
        model.warmIdentityIndex()
        await model.waitForIdentityWarm()
        XCTAssertEqual(model.identitySnapshotStore.revision, revision + 1)
        XCTAssertEqual(Set(liveSources(Self.movie(0)).map(\.accountID)), [active[0].account.id])
        for provider in fixture.providers {
            let requests = await provider.requests
            XCTAssertEqual(requests, 2, "Pruning must not refetch fresh accounts.")
        }

        await fixture.providers[0].removeAllMovies()
        model.warmIdentityIndex(force: true)
        await model.waitForIdentityWarm()
        XCTAssertEqual(model.identitySnapshotStore.revision, revision + 2)
        XCTAssertTrue(model.identitySnapshot.isEmpty)
        XCTAssertTrue(liveSources(Self.movie(0)).isEmpty)

        model.warmIdentityIndex(force: true)
        await model.waitForIdentityWarm()
        XCTAssertEqual(model.identitySnapshotStore.revision, revision + 2)
    }

    func testResetStartsANewRevisionStreamWithoutFreezingLiveLookup() async throws {
        let fixture = try await fixture()
        var active = [fixture.accounts[0]]
        var namespace = "first-profile"
        let model = IdentityIndexModel(
            activeAccounts: { active }, namespace: { namespace }, onPublish: {},
            persistenceStore: InMemoryIdentityIndexStore(fixture.persisted)
        )
        let liveSources = model.identitySourcesProvider
        model.warmIdentityIndex()
        await model.waitForIdentityWarm()
        XCTAssertEqual(Set(liveSources(Self.movie(0)).map(\.accountID)), [active[0].account.id])

        model.reset()
        XCTAssertTrue(liveSources(Self.movie(0)).isEmpty)
        namespace = "second-profile"
        active = [fixture.accounts[1]]
        let revision = model.identitySnapshotStore.revision
        model.warmIdentityIndex()
        await model.waitForIdentityWarm()
        XCTAssertEqual(model.identitySnapshotStore.revision, revision + 1)
        XCTAssertEqual(Set(liveSources(Self.movie(0)).map(\.accountID)), [active[0].account.id])
    }

    func testConfirmedEmptyLibraryListReplacesRestoredMembership() async throws {
        let fixture = try await fixture()
        await fixture.providers[0].removeLibrary()
        var publications = 0
        let model = IdentityIndexModel(
            activeAccounts: { [fixture.accounts[0]] }, namespace: { "empty-library" },
            onPublish: { publications += 1 },
            persistenceStore: InMemoryIdentityIndexStore(fixture.persisted)
        )
        model.warmIdentityIndex()
        await model.waitForIdentityWarm()
        XCTAssertEqual(publications, 2, "Publish the restore, then the confirmed removal.")
        XCTAssertTrue(model.identitySnapshot.isEmpty)
        XCTAssertTrue(model.identitySnapshotStore.current.isEmpty)

        model.warmIdentityIndex()
        await model.waitForIdentityWarm()
        let requests = await fixture.providers[0].requests
        XCTAssertEqual(requests, 1, "The empty server was conclusively verified.")
        XCTAssertEqual(publications, 2)
    }

    private struct Fixture {
        let accounts: [ResolvedAccount]
        let providers: [RefreshIndexProvider]
        let persisted: PersistedIdentityIndex
    }

    private func fixture() async throws -> Fixture {
        let providers = (0..<20).map { RefreshIndexProvider(index: $0, items: (0..<200).map(Self.movie)) }
        let accounts = providers.map {
            ResolvedAccount(account: Account(id: $0.session.server.id, from: $0.session), provider: $0)
        }
        let info = accounts.sourceServerInfo()
        let seed = IdentityIndex()
        for account in accounts {
            await seed.beginRebuild(for: account.account.id)
            await seed.ingest((0..<200).map(Self.movie), accountID: account.account.id,
                              serverInfo: info[account.account.id])
            await seed.finishRebuild(for: account.account.id)
        }
        return Fixture(accounts: accounts, providers: providers, persisted: await seed.export())
    }

    private func refresh(_ fixture: Fixture) async -> (
        model: IdentityIndexModel, counters: [String: Int], publicationCount: @MainActor () -> Int
    ) {
        var before = 0
        for provider in fixture.providers { before += await provider.requests }
        var publications = 0
        let model = IdentityIndexModel(
            activeAccounts: { fixture.accounts }, namespace: { "refresh-fixture" },
            onPublish: { publications += 1 },
            persistenceStore: InMemoryIdentityIndexStore(fixture.persisted)
        )
        model.warmIdentityIndex()
        await model.waitForIdentityWarm()
        var requests = -before
        for provider in fixture.providers { requests += await provider.requests }
        XCTAssertEqual(requests, 40)
        XCTAssertEqual(model.identitySnapshot.indexedAccountIDs, Set(fixture.accounts.map(\.account.id)))
        return (model, [
            "accounts": 20, "items": 4_000, "providerRequests": requests, "publications": publications
        ], { publications })
    }

    private static func movie(_ index: Int) -> MediaItem {
        MediaItem(id: "movie-\(index)", title: "Movie \(index)", kind: .movie,
                  productionYear: 2020, providerIDs: ["Tmdb": "\(index + 1)"])
    }
}

private actor RefreshIndexProvider: MediaProvider {
    nonisolated let session: UserSession
    nonisolated let kind: ProviderKind
    nonisolated let connectionLocality: SourceLocality = .remote
    private var catalog: [MediaItem]
    private var hasLibrary = true
    private(set) var requests = 0

    init(index: Int, items: [MediaItem]) {
        kind = index.isMultiple(of: 2) ? .jellyfin : .plex
        session = UserSession(
            server: .init(id: "server-\(index)", name: "Server \(index)",
                          baseURL: URL(string: "https://example.invalid")!, provider: kind),
            userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
        )
        catalog = items
    }

    func replaceFirstMovie() {
        catalog[0] = MediaItem(id: "movie-999", title: "Movie 999", kind: .movie,
                               productionYear: 2020, providerIDs: ["Tmdb": "1000"])
    }

    func removeAllMovies() { catalog.removeAll() }
    func removeLibrary() { hasLibrary = false }

    func libraries() async throws -> [MediaLibrary] {
        requests += 1
        guard hasLibrary else { return [] }
        return [.init(id: "movies", title: "Movies", kind: .movie)]
    }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        requests += 1
        return .init(items: Array(catalog.dropFirst(page.startIndex).prefix(page.limit)),
                     startIndex: page.startIndex, totalCount: catalog.count)
    }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
