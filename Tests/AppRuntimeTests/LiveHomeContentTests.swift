import CoreModels
import Foundation
import ProviderJellyfin
import ProviderPlex
import XCTest

/// Read-only production-provider checks using a private, ephemeral credential broker.
final class LiveHomeContentTests: XCTestCase {
    func testJellyfinCustomRowSourcesAndPaging() async throws { try await verify(.jellyfin) }
    func testEmbyCustomRowSourcesAndPaging() async throws { try await verify(.emby) }
    func testPlexCustomRowSourcesAndPaging() async throws { try await verify(.plex) }

    func testCombinedPlexJellyfinAndEmbyLibraries() async throws {
        var accounts: [ResolvedAccount] = []
        var sources: [HomeContentSource] = []
        for kind: ProviderKind in [.plex, .jellyfin, .emby] {
            let provider = try await provider(kind)
            let account = ResolvedAccount(account: .init(id: "live-\(kind.rawValue)", from: provider.session), provider: provider)
            let libraries = try await provider.libraries()
            let library = try XCTUnwrap(libraries.first { $0.kind == .movie && !$0.isMusic })
            accounts.append(account)
            sources.append(.init(
                feed: .library(.movie), accountID: account.account.id, serverUserID: provider.session.userID,
                libraryID: library.id, title: "Internal library"
            ))
        }
        let session = HomeContentPageLoader.Session(accounts: accounts, visibility: .default) { _ in
            XCTFail("Library sources must not fetch snapshots")
            return []
        }
        let pager = HomeContentPager(sources: sources, serverInfo: accounts.sourceServerInfo()) {
            try await session.load($0, start: $1, limit: $2)
        }
        let allowed = Set(accounts.map(\.account.id))
        var shared = 0
        for limit in [20, 60] {
            let page = try await pager.loadNext(limit: limit)
            XCTAssertTrue(page.failures.isEmpty, "Combined servers must not silently lose a source")
            XCTAssertFalse(page.items.isEmpty)
            XCTAssertEqual(Set(page.items.map(\.stablePresentationID)).count, page.items.count)
            XCTAssertTrue(page.items.allSatisfy { item in
                item.sources.allSatisfy { allowed.contains($0.accountID) }
            })
            shared = page.items.filter { Set($0.sources.map(\.accountID)).count > 1 }.count
        }
        print("LiveHomeContent combinedProviders=3 sharedTitles=\(shared)")
    }

    private struct Configuration: Decodable {
        let baseURL: URL
        let username: String
        let userID: String
        let serverID: String
        let deviceID: String
        let token: String
    }

    private enum ConfigurationError: Error { case invalid }

    private func provider(_ kind: ProviderKind) async throws -> any MediaProvider {
        guard let input = ProcessInfo.processInfo.environment["PLOZZ_LIVE_HOME_BROKER"] else {
            throw XCTSkip("Set PLOZZ_LIVE_HOME_BROKER for dedicated internal read-only Home checks.")
        }
        guard let broker = URL(string: input), broker.scheme == "http", broker.host == "127.0.0.1",
              broker.user == nil, broker.password == nil, broker.query == nil else {
            throw ConfigurationError.invalid
        }
        let (data, response) = try await URLSession.shared.data(for: URLRequest(
            url: broker.appendingPathComponent(kind.rawValue), timeoutInterval: 10
        ))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ConfigurationError.invalid }
        let config = try JSONDecoder().decode(Configuration.self, from: data)
        guard !config.token.isEmpty, ["http", "https"].contains(config.baseURL.scheme),
              config.baseURL.host != nil, config.baseURL.user == nil,
              config.baseURL.password == nil, config.baseURL.query == nil else {
            throw ConfigurationError.invalid
        }
        let session = UserSession(
            server: .init(id: config.serverID, name: "Internal Home verification", baseURL: config.baseURL, provider: kind),
            userID: config.userID, userName: config.username, deviceID: config.deviceID, accessToken: config.token
        )
        if kind == .plex {
            try await PlexProvider.verifyAddress(config.baseURL, serverID: config.serverID)
            return PlexProvider(session: session)
        }
        return JellyfinProvider(session: session, playbackRequests: .init())
    }

    private func verify(_ kind: ProviderKind) async throws {
        let provider = try await provider(kind)
        let account = ResolvedAccount(account: .init(id: "live-\(kind.rawValue)", from: provider.session), provider: provider)
        var stage = "libraries"
        do {
            let libraries = try await provider.libraries()
            let library = try XCTUnwrap(libraries.first { $0.kind == .movie && !$0.isMusic })
            func source(_ feed: HomeContentSource.Feed) -> HomeContentSource {
                .init(feed: feed, accountID: account.account.id, serverUserID: provider.session.userID,
                      libraryID: library.id, title: "Internal source")
            }
            var sources = [source(.library(.movie))]
            stage = "recommendation discovery"
            let shelves = try await provider.homeHubs(
                libraryID: library.id, kind: .movie, limit: 20, includeUnpromoted: true
            )
            sources += shelves.prefix(2).map { source(.recommendation(sectionID: $0.id, kind: .movie)) }
            stage = "collection discovery"
            let collections = try await provider.collections(in: library.id, page: .init(limit: 3))
            sources += collections.items.prefix(1).map { source(.collection($0.id)) }
            stage = "playlist discovery"
            let playlists = try await provider.videoPlaylists(in: library.id, page: .init(limit: 3))
            sources += playlists.items.prefix(1).map { source(.playlist($0.id)) }
            stage = "history snapshot"
            let history = try await provider.continueWatching(limit: 20).map {
                $0.taggingSource(account.account.id)
            }
            sources.append(.init(home: .continueWatching))
            let snapshot: HomeContentPageLoader.HomeSnapshot = { _ in history }

            var fetchedPages = 0
            for source in sources {
                stage = "individual \(feedName(source))"
                let began = ContinuousClock.now
                let session = HomeContentPageLoader.Session(accounts: [account], visibility: .default, homeSnapshot: snapshot)
                var start = 0
                var seen = Set<String>()
                for limit in [1, 5, 20] {
                    let page = try await session.load(source, start: start, limit: limit)
                    fetchedPages += 1
                    XCTAssertLessThanOrEqual(page.items.count, limit, "\(kind): \(stage)")
                    XCTAssertTrue(page.items.allSatisfy { !$0.id.isEmpty }, "\(kind): \(stage)")
                    XCTAssertTrue(page.items.allSatisfy { seen.insert($0.stablePresentationID).inserted },
                                  "\(kind): \(stage) repeated items across pages")
                    guard let next = page.nextOffset else { break }
                    XCTAssertGreaterThan(next, start, "\(kind): \(stage)")
                    start = next
                }
                print("LiveHomeContent provider=\(kind.rawValue) source=\(feedName(source))"
                      + " elapsedMs=\(elapsedMilliseconds(since: began))")
            }

            stage = "combined preview and browse"
            let session = HomeContentPageLoader.Session(accounts: [account], visibility: .default, homeSnapshot: snapshot)
            let pager = HomeContentPager(sources: sources, serverInfo: [account].sourceServerInfo()) {
                try await session.load($0, start: $1, limit: $2)
            }
            var previous: [MediaItem] = []
            var count = 0
            for limit in [20, 60, 60] {
                let began = ContinuousClock.now
                let page = try await pager.loadNext(limit: limit)
                XCTAssertTrue(page.failures.isEmpty, "\(kind): combined row had \(page.failures.count) failed sources")
                let ids = page.items.map(\.stablePresentationID)
                XCTAssertEqual(Set(ids).count, ids.count, "\(kind): duplicate cards")
                // Richer copies may become the display primary. Native source
                // references must survive in their original relative order.
                let retainedPositions = previous.compactMap { old in
                    page.items.firstIndex { item in
                        item.stablePresentationID == old.stablePresentationID
                            || item.sources.contains { $0.accountID == old.sourceAccountID && $0.itemID == old.id }
                    }
                }
                XCTAssertEqual(retainedPositions.count, previous.count, "\(kind): lost earlier content")
                XCTAssertEqual(retainedPositions, retainedPositions.sorted(), "\(kind): prior content changed order")
                XCTAssertFalse(page.items.isEmpty, "\(kind): the nonempty movie library must contribute cards")
                previous = page.items
                count = page.items.count
                print("LiveHomeContent provider=\(kind.rawValue) combinedLimit=\(limit)"
                      + " items=\(count) elapsedMs=\(elapsedMilliseconds(since: began))")
                if !page.hasMore { break }
            }
            print("LiveHomeContent provider=\(kind.rawValue) sources=\(sources.count)"
                  + " recommendations=\(min(2, shelves.count)) collections=\(min(1, collections.items.count))"
                  + " playlists=\(min(1, playlists.items.count)) history=\(history.count)"
                  + " individualPages=\(fetchedPages) combinedItems=\(count)")
        } catch {
            XCTFail("LiveHomeContent provider=\(kind.rawValue) stage=\(stage)"
                    + " error=\(HandoffDiagnostics.errorCode((error as? AppError) ?? .unknown("")))")
        }
    }

    private func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int64 {
        let duration = start.duration(to: .now).components
        return duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000
    }

    private func feedName(_ source: HomeContentSource) -> String {
        switch source.feed {
        case .collection: "collection"
        case .playlist: "playlist"
        case .library: "library"
        case .recommendation: "recommendation"
        case .server: "server"
        case .home: "snapshot"
        }
    }
}
