import CoreModels
import CoreNetworking
import FeatureHomeCore
import Foundation
import ProviderJellyfin
import ProviderPlex
import ProviderSilo
import XCTest
@testable import TestSupportPerformance

private actor LiveQueryPages {
    private(set) var requests = 0
    private(set) var populated = Set<HomeContentSource.ID>()

    func load(
        _ session: HomeContentPageLoader.Session, source: HomeContentSource, start: Int, limit: Int
    ) async throws -> HomeRowPage {
        requests += 1
        guard requests <= 600 else { throw AppError.invalidResponse }
        do {
            let page = try await session.load(source, start: start, limit: limit)
            if !page.items.isEmpty { populated.insert(source.id) }
            return page
        } catch {
            XCTFail("Live page request failed at offset \(start), limit \(limit): \(type(of: error))")
            throw error
        }
    }
}

private actor LiveRecommendationHTTP: HTTPClient {
    private let client = URLSessionHTTPClient()
    private(set) var count = 0

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        if endpoint.path.hasSuffix("/Movies/Recommendations") { count += 1 }
        return try await client.send(endpoint, baseURL: baseURL)
    }
}

/// Read-only production-provider checks using a private, ephemeral credential broker.
final class LiveHomeContentTests: XCTestCase {
    @MainActor
    func testPerformanceJellyfinSavedQueries() async throws {
        try await measureSavedQueries([.jellyfin], scenario: "home-live-jellyfin-queries")
    }

    @MainActor
    func testPerformanceEmbySavedQueries() async throws {
        try await measureSavedQueries([.emby], scenario: "home-live-emby-queries")
    }

    @MainActor
    func testPerformancePlexSavedQueries() async throws {
        try await measureSavedQueries([.plex], scenario: "home-live-plex-queries")
    }

    @MainActor
    func testPerformanceSiloSavedQueries() async throws {
        try await measureSavedQueries([.silo], scenario: "home-live-silo-queries")
    }

    @MainActor
    func testPerformanceCombinedSavedQueries() async throws {
        try await measureSavedQueries([.plex, .jellyfin, .emby], scenario: "home-live-combined-queries")
    }

    @MainActor
    private func measureSavedQueries(_ kinds: [ProviderKind], scenario: String) async throws {
        var verifiedBatchParity = false
        try await PerformanceProbe.measure(self, scenario: scenario) {
            var accounts: [ResolvedAccount] = []
            var sources: [HomeContentSource] = []
            for kind in kinds {
                let provider = try await self.provider(kind)
                let account = ResolvedAccount(account: .init(id: "live-\(kind.rawValue)", from: provider.session),
                                              provider: provider)
                accounts.append(account)
                let libraries = try await provider.libraries()
                let movies = try XCTUnwrap(libraries.first { $0.kind == .movie && !$0.isMusic })
                let shows = try XCTUnwrap(libraries.first { $0.kind == .series && !$0.isMusic })
                func source(_ feed: HomeContentSource.Feed, library: MediaLibrary) -> HomeContentSource {
                    .init(feed: feed, accountID: account.account.id, serverUserID: provider.session.userID,
                          libraryID: library.id, title: "Internal query source")
                }
                sources += [source(.library(.movie), library: movies), source(.library(.series), library: shows)]
                if kind != .silo {
                    let collections = try await provider.collections(in: movies.id, page: .init(limit: 2))
                    let playlists = try await provider.videoPlaylists(in: movies.id, page: .init(limit: 2))
                    XCTAssertEqual(collections.items.count, 2)
                    XCTAssertEqual(playlists.items.count, 2)
                    sources += collections.items.map { source(.collection($0.id), library: movies) }
                    sources += playlists.items.map { source(.playlist($0.id), library: movies) }
                }
            }
            let session = HomeContentPageLoader.Session(accounts: accounts, visibility: .default) { _ in
                XCTFail("These live sources must not substitute synthetic Home snapshots")
                return []
            }
            let pages = LiveQueryPages()
            let pager = HomeContentPager(sources: sources, serverInfo: accounts.sourceServerInfo()) {
                try await pages.load(session, source: $0, start: $1, limit: $2)
            }
            let initialQuery = HomeContentQuery(sort: .init(field: .name, direction: .descending))
            let started = ContinuousClock.now
            let preview = try await pager.load(limit: 20, query: initialQuery)
            let cold = Self.nanoseconds(started.duration(to: .now))
            XCTAssertTrue(preview.failures.isEmpty)
            XCTAssertFalse(preview.hasMore, "Explicit sorting must complete membership")
            XCTAssertGreaterThan(preview.items.count, 20)
            let inventory = try await pager.loadAll().items
            if !verifiedBatchParity {
                let referencePages = LiveQueryPages()
                let reference = HomeContentPager(sources: sources, serverInfo: accounts.sourceServerInfo()) {
                    let page = try await referencePages.load(
                        session, source: $0, start: $1, limit: min($2, PageRequest.defaultLimit)
                    )
                    return .init(items: page.items, nextOffset: page.nextOffset)
                }
                let original: HomeContentPager.Snapshot
                do { original = try await reference.loadAll() }
                catch {
                    XCTFail("The 60-item reference inventory failed: \(type(of: error))")
                    throw error
                }
                XCTAssertTrue(inventory == original.items,
                              "Bulk requests must preserve every item and its complete presentation/playback metadata")
                verifiedBatchParity = true
            }
            let dated = inventory.compactMap { $0.librarySortValues?.dateAdded }
            let released = inventory.compactMap(\.productionYear)
            let runtimes = inventory.compactMap(\.runtime)
            XCTAssertGreaterThan(Set(dated).count, 1, "Date Added must exercise real differing timestamps")
            XCTAssertGreaterThan(Set(released).count, 1, "Release ordering must exercise real differing years")
            XCTAssertGreaterThan(Set(runtimes).count, 1, "Runtime ordering must exercise real differing durations")
            let fetched = await pages.requests
            let populated = await pages.populated
            XCTAssertEqual(populated, Set(sources.map(\.id)), "Every selected live source must contribute actual data")
            XCTAssertEqual(Set(inventory.map(\.stablePresentationID)).count, inventory.count)
            let model = HomeRowBrowseModel(title: "Live query", contentPager: pager, query: initialQuery)
            await model.load()
            XCTAssertNil(model.error)
            XCTAssertTrue(model.items == preview.items, "Editor and opened grid must use the same ordering")

            var warm = 0
            var maximumGap = 0
            var ticks = 0
            let heartbeat = Task { @MainActor in
                var previous = ContinuousClock.now
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(2)) } catch { break }
                    let now = ContinuousClock.now
                    maximumGap = max(maximumGap, Self.nanoseconds(previous.duration(to: now)))
                    previous = now
                    ticks += 1
                }
            }
            defer { heartbeat.cancel() }
            for field in HomeContentQuery.sortFields {
                for direction in [SortDirection.ascending, .descending] {
                    let sort = SortDescriptor(field: field, direction: direction)
                    // The original comparator is an independent path from the cached-key index sort.
                    let expected = await Task.detached {
                        inventory.sorted { MediaItemSortOrder.isOrderedBefore($0, $1, sort: sort) }
                            .map(\.stablePresentationID)
                    }.value
                    model.query = .init(sort: sort)
                    let began = ContinuousClock.now
                    await model.load()
                    warm += Self.nanoseconds(began.duration(to: .now))
                    XCTAssertNil(model.error)
                    XCTAssertTrue(model.items.map(\.stablePresentationID) == expected,
                                  "Live order differs for \(field) \(direction)")
                }
            }
            for media in [WatchlistMediaFilter.movies, .shows] {
                for filter in [LibraryFilter.unwatched, .inProgress] {
                    model.query = .init(media: media, filters: .init(filter: filter))
                    await model.load()
                    let expected = inventory.filter { item in
                        let matchesMedia = media == .movies ? item.kind == .movie
                            : [.series, .season, .episode].contains(item.kind)
                        let matchesWatch = filter == .unwatched
                            ? !(item.librarySortValues?.watched ?? item.isPlayed)
                            : !item.isPlayed && ((item.resumePosition ?? 0) > 0 || (item.playedPercentage ?? 0) > 0)
                        return matchesMedia && matchesWatch
                    }
                    XCTAssertNil(model.error)
                    XCTAssertTrue(model.items.map(\.stablePresentationID) == expected.map(\.stablePresentationID),
                                  "Live filter differs for \(media) \(filter)")
                }
            }
            model.query = .init(sort: .init(field: .runtime, direction: .descending))
            let abandoned = Task { await model.load() }
            await Task.yield()
            abandoned.cancel()
            model.query = initialQuery
            await model.load()
            await abandoned.value
            XCTAssertNil(model.error)
            XCTAssertEqual(model.appliedQuery, initialQuery)
            XCTAssertTrue(model.items == preview.items, "Cancelled query must not replace the current result")
            let finalRequests = await pages.requests
            XCTAssertEqual(finalRequests, fetched, "Warm sorting and filtering must not refetch real-server pages")
            XCTAssertGreaterThan(ticks, 0)
            return ["items": inventory.count, "sources": sources.count, "pages": fetched,
                    "datedItems": dated.count, "releaseYearItems": released.count, "runtimeItems": runtimes.count,
                    "coldNanoseconds": cold, "warmEightQueriesNanoseconds": warm,
                    "maximumMainActorGapNanoseconds": maximumGap]
        }
    }

    private static func nanoseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds) * 1_000_000_000 + Int(duration.components.attoseconds / 1_000_000_000)
    }

    func testJellyfinCustomRowSourcesAndPaging() async throws { try await verify(.jellyfin) }
    func testEmbyCustomRowSourcesAndPaging() async throws { try await verify(.emby) }
    func testPlexCustomRowSourcesAndPaging() async throws { try await verify(.plex) }

    func testSiloLibraryAndServerRowComposition() async throws {
        let provider = try await provider(.silo)
        let account = ResolvedAccount(account: .init(id: "live-silo", from: provider.session), provider: provider)
        let libraries = try await provider.libraries()
        let library = try XCTUnwrap(libraries.first { $0.kind == .movie && !$0.isMusic })
        let layout = try await provider.serverHomeLayout()
        let sections = try XCTUnwrap(layout).sections
        XCTAssertFalse(sections.isEmpty, "Native server rows must actually be present")
        var sources: [HomeContentSource] = [.init(
            feed: .library(.movie), accountID: account.account.id, serverUserID: provider.session.userID,
            libraryID: library.id, title: "Internal library"
        )]
        sources += sections.prefix(2).map {
            .init(feed: .server($0), accountID: account.account.id, serverUserID: provider.session.userID,
                  libraryID: $0.libraryID, title: "Internal server row")
        }
        let session = HomeContentPageLoader.Session(accounts: [account], visibility: .default) { _ in
            XCTFail("Silo library and server rows must not fetch global snapshots")
            return []
        }
        for source in sources {
            let page = try await session.load(source, start: 0, limit: 5)
            XCTAssertLessThanOrEqual(page.items.count, 5)
        }
        let pager = HomeContentPager(sources: sources, serverInfo: [account].sourceServerInfo()) {
            try await session.load($0, start: $1, limit: $2)
        }
        for limit in [1, 5, 20, 60] {
            let page = try await pager.loadNext(limit: limit)
            XCTAssertTrue(page.failures.isEmpty, "Native Silo sources must not silently disappear")
            XCTAssertFalse(page.items.isEmpty)
            XCTAssertEqual(Set(page.items.map(\.stablePresentationID)).count, page.items.count)
            print("LiveHomeContent provider=silo sources=\(sources.count) combinedLimit=\(limit) items=\(page.items.count)")
            if !page.hasMore { break }
        }
    }

    func testJellyfinScopedRecommendationReuse() async throws {
        let http = LiveRecommendationHTTP()
        let provider = try await provider(.jellyfin, http: http)
        let libraries = try await provider.libraries()
        let library = try XCTUnwrap(libraries.first { $0.kind == .movie && !$0.isMusic })
        let account = ResolvedAccount(account: .init(id: "live-jellyfin", from: provider.session), provider: provider)
        for sample in 0..<5 {
            let scope = HomeRecommendationScope()
            let before = await http.count
            let began = ContinuousClock.now
            let cold = try await HomeRecommendationScope.$current.withValue(scope) {
                try await provider.homeHubs(libraryID: library.id, kind: .movie, limit: 20, includeUnpromoted: true)
            }
            let coldTime = began.duration(to: .now)
            let shelf = try XCTUnwrap(cold.first { !$0.items.isEmpty })
            let source = HomeContentSource(
                feed: .recommendation(sectionID: shelf.id, kind: .movie), accountID: account.account.id,
                serverUserID: provider.session.userID, libraryID: library.id, title: "Internal recommendation"
            )
            let reusedAt = ContinuousClock.now
            for _ in 0..<3 {
                let loader = HomeContentPageLoader.Session(
                    accounts: [account], visibility: .default, recommendationScope: scope
                ) { _ in [] }
                let page = try await loader.load(source, start: 0, limit: 5)
                XCTAssertEqual(page.items.map(\.id), Array(shelf.items.prefix(5)).map(\.id))
            }
            let reusedTime = reusedAt.duration(to: .now)
            let afterReuse = await http.count
            XCTAssertEqual(afterReuse - before, 1, "Separate consumers must reuse the exact discovery response")
            scope.refresh()
            let refreshed = try await HomeRecommendationScope.$current.withValue(scope) {
                try await provider.homeHubs(libraryID: library.id, kind: .movie, limit: 20, includeUnpromoted: true)
            }
            XCTAssertFalse(refreshed.isEmpty)
            let afterRefresh = await http.count
            XCTAssertEqual(afterRefresh - before, 2, "Refresh must make a new authenticated request")
            func milliseconds(_ value: Duration) -> Double {
                Double(value.components.seconds) * 1_000 + Double(value.components.attoseconds) / 1e15
            }
            print("LiveHomeRecommendation sample=\(sample) coldMilliseconds=\(milliseconds(coldTime)) "
                  + "threeReusedConsumersMilliseconds=\(milliseconds(reusedTime)) requests=\(afterRefresh - before)")
            scope.invalidate()
        }
    }

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
        let siloTokens: SiloTokenPair?
        let siloProfile: SiloProfile?
    }

    private struct LiveHomeCredentialStore: RotatingCredentialStoring {
        let context: ProviderResolutionContext

        func credential(accountID: String, revision: CredentialRevision) throws -> String {
            guard accountID == context.accountID, revision == context.credentialRevision else {
                throw AppError.unauthorized
            }
            return context.session.accessToken
        }

        func rotateCredential(
            accountID: String, revision: CredentialRevision, expected: String, replacement: String
        ) throws {
            throw ConfigurationError.unexpectedCredentialRotation
        }
    }

    private enum ConfigurationError: Error { case invalid, unexpectedCredentialRotation }

    private func provider(_ kind: ProviderKind, http: any HTTPClient = URLSessionHTTPClient()) async throws -> any MediaProvider {
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
        if kind == .silo {
            let tokens = try XCTUnwrap(config.siloTokens)
            let profile = try XCTUnwrap(config.siloProfile)
            XCTAssertFalse(profile.has_pin)
            let session = try await SiloAuthentication(baseURL: config.baseURL, http: http).makeSession(
                tokens: tokens, profile: profile, profileToken: nil, deviceID: config.deviceID
            )
            let context = ProviderResolutionContext(
                session: session, accountID: "live-silo", credentialRevision: CredentialRevision()
            )
            return try SiloProvider(
                context: context, credentials: LiveHomeCredentialStore(context: context), http: http
            )
        }
        let session = UserSession(
            server: .init(id: config.serverID, name: "Internal Home verification", baseURL: config.baseURL, provider: kind),
            userID: config.userID, userName: config.username, deviceID: config.deviceID, accessToken: config.token
        )
        if kind == .plex {
            try await PlexProvider.verifyAddress(config.baseURL, serverID: config.serverID)
            return PlexProvider(session: session)
        }
        return JellyfinProvider(session: session, http: http, playbackRequests: .init())
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
            XCTAssertGreaterThanOrEqual(collections.items.count, 2,
                                        "\(kind): live acceptance requires two discoverable populated collections")
            let collectionSources = collections.items.prefix(2).map { source(.collection($0.id)) }
            sources += collectionSources
            stage = "playlist discovery"
            let playlists = try await provider.videoPlaylists(in: library.id, page: .init(limit: 3))
            XCTAssertGreaterThanOrEqual(playlists.items.count, 2,
                                        "\(kind): live acceptance requires two discoverable populated video playlists")
            let playlistSources = playlists.items.prefix(2).map { source(.playlist($0.id)) }
            sources += playlistSources
            stage = "history snapshot"
            let history = try await provider.continueWatching(limit: 20).map {
                $0.taggingSource(account.account.id)
            }
            sources.append(.init(home: .continueWatching))
            let snapshot: HomeContentPageLoader.HomeSnapshot = { _ in history }

            var fetchedPages = 0
            var containerItems: [HomeContentSource: [MediaItem]] = [:]
            for source in sources {
                stage = "individual \(feedName(source))"
                let began = ContinuousClock.now
                let session = HomeContentPageLoader.Session(accounts: [account], visibility: .default, homeSnapshot: snapshot)
                var start = 0
                var seen = Set<String>()
                var loaded: [MediaItem] = []
                for limit in [1, 5, 20] {
                    let page = try await session.load(source, start: start, limit: limit)
                    loaded += page.items
                    fetchedPages += 1
                    XCTAssertLessThanOrEqual(page.items.count, limit, "\(kind): \(stage)")
                    XCTAssertTrue(page.items.allSatisfy { !$0.id.isEmpty }, "\(kind): \(stage)")
                    XCTAssertTrue(page.items.allSatisfy { seen.insert($0.stablePresentationID).inserted },
                                  "\(kind): \(stage) repeated items across pages")
                    guard let next = page.nextOffset else { break }
                    XCTAssertGreaterThan(next, start, "\(kind): \(stage)")
                    start = next
                }
                switch source.feed {
                case .collection, .playlist:
                    XCTAssertFalse(loaded.isEmpty, "\(kind): \(stage) requires populated live content")
                    containerItems[source] = loaded
                default: break
                }
                print("LiveHomeContent provider=\(kind.rawValue) source=\(feedName(source))"
                      + " elapsedMs=\(elapsedMilliseconds(since: began))")
            }

            for (name, selected) in [
                ("collections", collectionSources),
                ("playlists", playlistSources),
                ("collections-and-playlists", collectionSources + playlistSources)
            ] {
                stage = name
                guard !selected.isEmpty else { continue }
                let session = HomeContentPageLoader.Session(accounts: [account], visibility: .default, homeSnapshot: snapshot)
                let pager = HomeContentPager(sources: selected, serverInfo: [account].sourceServerInfo()) {
                    try await session.load($0, start: $1, limit: $2)
                }
                var result: [MediaItem] = []
                for limit in [1, 5, 20, 60] {
                    let page = try await pager.loadNext(limit: limit)
                    XCTAssertTrue(page.failures.isEmpty, "\(kind): \(stage) source failure")
                    XCTAssertEqual(Set(page.items.map(\.stablePresentationID)).count, page.items.count)
                    result = page.items
                    if !page.hasMore { break }
                }
                let nativeIDs = Set(result.flatMap { [$0.id] + $0.sources.map(\.itemID) })
                for selectedSource in selected {
                    let expected = containerItems[selectedSource] ?? []
                    XCTAssertTrue(expected.allSatisfy { nativeIDs.contains($0.id) },
                                  "\(kind): \(stage) dropped a container member")
                }
                print("LiveHomeContent provider=\(kind.rawValue) composition=\(name)"
                      + " sources=\(selected.count) items=\(result.count)")
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
                  + " recommendations=\(min(2, shelves.count)) collections=\(collectionSources.count)"
                  + " playlists=\(playlistSources.count) history=\(history.count)"
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
