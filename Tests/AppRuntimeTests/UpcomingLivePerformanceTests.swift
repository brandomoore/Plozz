import CoreModels
import CoreNetworking
import FeatureHomeCore
import Foundation
import MetadataKit
import ProviderJellyfin
import ProviderPlex
import XCTest

@testable import AppRuntime

/// Explicit internal-server measurement; credentials and media identities never enter results.
@MainActor
final class UpcomingLivePerformanceTests: XCTestCase {
    func testLivePersonalReleaseLoading() async throws {
        guard let address = ProcessInfo.processInfo.environment["PLOZZ_LIVE_HERO_BROKER"] else {
            throw XCTSkip("An authorized, ephemeral internal-server broker is required.")
        }
        let url = try XCTUnwrap(URL(string: address))
        guard url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
            url.user == nil, url.password == nil, url.query == nil
        else { throw AppError.invalidResponse }
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 10))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let configuration = try JSONDecoder().decode(Configuration.self, from: data)
        XCTAssertEqual(
            Set(configuration.accounts.map(\.provider)), [.jellyfin, .plex],
            "The performance fixture must cover both dedicated provider identities"
        )
        let metadata = MetadataProviderConfig(tmdb: .directToken(configuration.tmdbToken))
        let tvdb = TVDBConfig(apiKey: configuration.tvdbKey)
        for connection in configuration.accounts {
            let http = UpcomingLiveHTTP()
            let session = UserSession(
                server: .init(
                    id: connection.serverID, name: "Internal Upcoming measurement",
                    baseURL: connection.baseURL, provider: connection.provider),
                userID: connection.userID, userName: connection.username,
                deviceID: connection.deviceID, accessToken: connection.token
            )
            if ProcessInfo.processInfo.environment["PLOZZ_UPCOMING_SEED"] == "1" {
                guard connection.allowWatchStateWrites == true else { throw AppError.unauthorized }
                try await seedReturningSeries(provider: makeProvider(session: session, http: http))
                await http.reset()
            }
            let provider = try makeProvider(session: session, http: http)
            let account = ResolvedAccount(
                account: Account(id: connection.provider.rawValue, from: session), provider: provider)
            let schedules = SeriesScheduleResolver(
                pipeline: ProductionMetadataProviders.makePipeline(providerConfig: metadata, tvdbConfig: tvdb)
            )
            let movies = ExternalTitleMetadataResolver(providerConfig: metadata, tvdbConfig: tvdb)
            let model = UpcomingFeedModel()
            let interval = UpcomingFeedLoader.window()
            let counter = UpcomingLiveScheduleCounter()
            let clock = UpcomingLiveClock()
            let load:
                @Sendable (
                    @escaping @MainActor @Sendable ([UpcomingRelease]) -> Void
                ) async throws -> UpcomingFeedSnapshot = { progress in
                    try await UpcomingFeedLoader.load(
                        accounts: [account], watchlist: [], regionCode: "US", interval: interval,
                        requestedMovies: { [] }, isCurrent: { true },
                        onProgress: {
                            progress($0)
                            clock.record($0)
                        },
                        schedule: { item, interval in
                            await counter.began()
                            return try await schedules.calendarEpisodes(for: MetadataQuery(item), in: interval)
                        },
                        movieAvailability: { item, region in await movies.availability(for: item, regionCode: region) }
                    )
                }
            let started = ContinuousClock.now
            await model.refresh(
                scope: "internal-\(connection.provider)", namespace: nil, isCurrent: { true }, load: load)
            let cold = Self.milliseconds(started.duration(to: .now))
            let coldRequests = await http.requests
            let releaseCount = model.releases.count
            let failureCount = model.failedSourceCount
            let repeatStarted = ContinuousClock.now
            await model.refresh(
                scope: "internal-\(connection.provider)", namespace: nil, isCurrent: { true }, load: load)
            let repeated = Self.milliseconds(repeatStarted.duration(to: .now))
            let requests = await http.requests
            let bytes = await http.bytes
            let titles = await counter.titles
            XCTAssertGreaterThan(titles, 0, "The dedicated viewer needs actual watched-series history")
            XCTAssertNotNil(
                clock.firstUpcomingMilliseconds,
                "The fixture must include a watched returning show with announced future episodes"
            )
            XCTAssertGreaterThan(releaseCount, 0)
            XCTAssertEqual(model.releases.count, releaseCount)
            XCTAssertEqual(
                requests, coldRequests, "A repeat visit must reuse the shared feed, even with a partial failure")
            XCTAssertFalse(model.isLoading)
            print(
                "UpcomingLive provider=\(connection.provider.rawValue) firstContentMs=\(clock.firstContentMilliseconds ?? -1) firstUpcomingMs=\(clock.firstUpcomingMilliseconds ?? -1) coldMs=\(cold) repeatMs=\(repeated) coldRequests=\(coldRequests) repeatRequests=\(requests - coldRequests) serverBytes=\(bytes) watchedTitles=\(titles) releases=\(releaseCount) failures=\(failureCount)"
            )
        }
    }

    private func makeProvider(session: UserSession, http: any HTTPClient) throws -> any MediaProvider {
        switch session.server.provider {
        case .jellyfin: JellyfinProvider(session: session, http: http)
        case .plex: PlexProvider(session: session, http: http)
        default: throw AppError.invalidResponse
        }
    }

    private func seedReturningSeries(provider: any MediaProvider) async throws {
        let shows = try await provider.search(query: "The Simpsons", limit: 10)
        let show = try XCTUnwrap(shows.first { $0.kind == .series && $0.title == "The Simpsons" })
        let seasons = try await provider.children(of: show.id)
        let season = try XCTUnwrap(seasons.first { $0.kind == .season && $0.seasonNumber != 0 })
        let episodes = try await provider.children(of: season.id)
        let episode = try XCTUnwrap(episodes.first { $0.kind == .episode })
        let watch = try XCTUnwrap(provider as? any WatchStateProviding)
        try await watch.setPlayed(true, itemID: episode.id)
    }

    @MainActor
    private final class UpcomingLiveClock {
        private let started = ContinuousClock.now
        private(set) var firstContentMilliseconds: Double?
        private(set) var firstUpcomingMilliseconds: Double?

        func record(_ releases: [UpcomingRelease]) {
            let duration = started.duration(to: .now).components
            let elapsed = Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
            if firstContentMilliseconds == nil, !releases.isEmpty { firstContentMilliseconds = elapsed }
            if firstUpcomingMilliseconds == nil,
                releases.contains(where: { $0.date >= Calendar.current.startOfDay(for: Date()) })
            {
                firstUpcomingMilliseconds = elapsed
            }
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    private struct Configuration: Decodable {
        let accounts: [Connection]
        let tmdbToken: String
        let tvdbKey: String
    }

    private struct Connection: Decodable {
        let provider: ProviderKind
        let baseURL: URL
        let serverID: String
        let userID: String
        let username: String
        let deviceID: String
        let token: String
        let allowWatchStateWrites: Bool?
    }
}

private actor UpcomingLiveHTTP: HTTPClient {
    private let client = URLSessionHTTPClient()
    private(set) var requests = 0
    private(set) var bytes = 0
    func reset() {
        requests = 0
        bytes = 0
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        requests += 1
        guard requests <= 400 else { throw AppError.invalidResponse }
        let result = try await client.send(endpoint, baseURL: baseURL)
        bytes += result.0.count
        return result
    }
}

private actor UpcomingLiveScheduleCounter {
    private(set) var titles = 0
    func began() { titles += 1 }
}
