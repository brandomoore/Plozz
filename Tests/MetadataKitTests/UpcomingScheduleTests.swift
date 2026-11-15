import CoreModels
import XCTest

@testable import MetadataKit

final class UpcomingScheduleTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_900_000_000)

    func testLiveTVmazeCalendarMatchesItsCompleteEpisodeListing() async throws {
        guard ProcessInfo.processInfo.environment["PLOZZ_UPCOMING_LIVE"] == "1" else {
            throw XCTSkip("Opt in to the public live scheduling source with PLOZZ_UPCOMING_LIVE=1")
        }
        struct Episode: Decodable {
            let season: Int
            let number: Int?
            let airstamp: String
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://api.tvmaze.com/shows/83/episodes")!)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let listing = try JSONDecoder().decode([Episode].self, from: data)
        XCTAssertGreaterThan(listing.count, 500)
        let today = Calendar.current.startOfDay(for: Date())
        let interval = DateInterval(
            start: Calendar.current.date(byAdding: .day, value: -30, to: today)!,
            end: Calendar.current.date(byAdding: .day, value: 91, to: today)!
        )
        let formatter = ISO8601DateFormatter()
        let expected = Set(
            listing.compactMap { episode -> String? in
                guard episode.season > 0, let number = episode.number,
                    let date = formatter.date(from: episode.airstamp),
                    date >= interval.start, date < interval.end
                else { return nil }
                return "\(episode.season):\(number)"
            })
        let resolver = SeriesScheduleResolver(
            pipeline: MetadataEnrichmentPipeline(providers: [TVmazeEnrichmentProvider(client: TVmazeClient())])
        )
        let result = try await resolver.calendarEpisodes(
            for: MetadataQuery(
                MediaItem(
                    id: "calendar-live", title: "The Simpsons", kind: .series, providerIDs: ["Tvmaze": "83"]
                )),
            in: interval
        )
        XCTAssertEqual(
            Set(
                result.compactMap { episode -> String? in
                    guard let season = episode.seasonNumber, let number = episode.episodeNumber else { return nil }
                    return "\(season):\(number)"
                }), expected)
        XCTAssertTrue(result.allSatisfy { $0.source == .tvmaze })
    }

    func testCalendarScopeSurvivesQueryRefinementAndDoesNotShareNextEpisodeCacheKey() {
        let item = MediaItem(id: "episode", title: "Episode", kind: .episode)
        let query = MetadataQuery(item).forScheduleStarting(at: day)
        XCTAssertEqual(query.seriesScoped.scheduleStartDate, day)
        XCTAssertEqual(query.mergingProviderIDs(["Tvmaze": "42"]).scheduleStartDate, day)
        XCTAssertEqual(query.offering(titleAlternates: ["Show"]).scheduleStartDate, day)
        XCTAssertNotEqual(query.enrichmentCacheKey, MetadataQuery(item).enrichmentCacheKey)
    }

    func testCalendarCanIncludeYesterdayWithoutOverwritingDetailNextEpisode() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolver = SeriesScheduleResolver(
            pipeline: MetadataEnrichmentPipeline(providers: [CalendarScheduleFixture(day: day)]),
            store: SeriesScheduleStore(directory: directory), now: { Date(timeIntervalSince1970: 1_900_000_000) }
        )
        let query = MetadataQuery(
            MediaItem(
                id: "show", title: "Show", kind: .series, providerIDs: ["Tvmaze": "42"]
            ))
        let normal = await resolver.refresh(query, tier: .visiblePrefetch)
        XCTAssertEqual(normal.upcomingEpisode?.episodeNumber, 2)
        let calendar = try await resolver.calendarEpisodes(
            for: query, in: DateInterval(start: day.addingTimeInterval(-86_400), duration: 3 * 86_400)
        )
        XCTAssertEqual(calendar.map(\.episodeNumber), [1])
        let retained = await resolver.cachedRecord(for: query)
        XCTAssertEqual(retained, normal)
    }

    func testUnavailableDateProvidersAreNotASuccessfulEmptyCalendar() async {
        let resolver = SeriesScheduleResolver(pipeline: MetadataEnrichmentPipeline(providers: []))
        do {
            _ = try await resolver.calendarEpisodes(
                for: MetadataQuery(MediaItem(id: "show", title: "Show", kind: .series)),
                in: DateInterval(start: day, duration: 86_400)
            )
            XCTFail("An unavailable calendar must remain retryable")
        } catch {
            XCTAssertEqual(error as? AppError, .notFound)
        }
    }

    func testSuccessfulEmptyCalendarsStayAvailableOnCacheHits() async throws {
        let client = try CalendarListingFixture()
        for provider in calendarProviders(client) {
            let resolver = SeriesScheduleResolver(
                pipeline: MetadataEnrichmentPipeline(providers: [
                    ResilientEnrichmentProvider(
                        base: provider, breaker: ProviderCircuitBreaker(), cache: ProviderResultCache()
                    )
                ])
            )
            let callsBefore = await client.calls
            let interval = DateInterval(start: day, duration: 86_400)
            let first = try await resolver.calendarEpisodes(for: calendarQuery, in: interval)
            let cached = try await resolver.calendarEpisodes(for: calendarQuery, in: interval)
            XCTAssertTrue(first.isEmpty, "\(provider.id)")
            XCTAssertEqual(cached, first, "\(provider.id)")
            let callsAfter = await client.calls
            XCTAssertEqual(callsAfter, callsBefore + 1, "\(provider.id) must retain successful-empty evidence")
        }
    }

    func testCalendarOutageDoesNotPoisonRetry() async throws {
        let client = try CalendarListingFixture()
        for provider in calendarProviders(client) {
            let resolver = SeriesScheduleResolver(
                pipeline: MetadataEnrichmentPipeline(providers: [
                    ResilientEnrichmentProvider(
                        base: provider, breaker: ProviderCircuitBreaker(), cache: ProviderResultCache()
                    )
                ])
            )
            let callsBefore = await client.calls
            let interval = DateInterval(start: day, duration: 86_400)
            await client.setAvailable(false)
            do {
                _ = try await resolver.calendarEpisodes(for: calendarQuery, in: interval)
                XCTFail("\(provider.id) must not turn an outage into an empty calendar")
            } catch {
                XCTAssertEqual(error as? AppError, .notFound)
            }

            await client.setAvailable(true)
            let recovered = try await resolver.calendarEpisodes(for: calendarQuery, in: interval)
            XCTAssertTrue(recovered.isEmpty, "\(provider.id)")
            let callsAfter = await client.calls
            XCTAssertEqual(callsAfter, callsBefore + 2, "\(provider.id) must retry after an unavailable listing")
        }
    }

    func testCompleteEmptyCalendarStopsFallbackButSingleEpisodeSourceDoesNot() async throws {
        for order: [MetadataSource] in [[.tvmaze, .tvdb], [.anilist, .tvmaze, .tvdb]] {
            let client = try CalendarListingFixture()
            let resolver = SeriesScheduleResolver(pipeline: MetadataEnrichmentPipeline(
                providers: calendarProviders(client),
                config: MetadataEnrichmentConfig(order: order, usesGlobalOrder: true)
            ))
            let result = try await resolver.calendarEpisodes(
                for: calendarQuery, in: DateInterval(start: day, duration: 86_400)
            )
            XCTAssertTrue(result.isEmpty)
            let calls = await client.calls
            XCTAssertEqual(calls, order.first == .anilist ? 2 : 1)
        }
    }

    func testUnmatchedTitleIsNotAnOutageButMalformedOrFailedRequestsRemainRetryable() async throws {
        let query = MetadataQuery(MediaItem(id: "unknown", title: "Unlisted show", kind: .series))
        for reply: PublicFeedDiscoveryTestTransport.Reply in [
            .response("", 404, [:]), .response("", 503, [:]), .response("", 429, [:]),
            .json("not a show"), .networkFailure
        ] {
            let fixture = PublicFeedDiscoveryTestTransport([reply])
            let resolver = SeriesScheduleResolver(pipeline: MetadataEnrichmentPipeline(providers: [
                TVmazeEnrichmentProvider(client: TVmazeClient(http: fixture.http))
            ]))
            do {
                let result = try await resolver.calendarEpisodes(for: query, in: DateInterval(start: day, duration: 86_400))
                XCTAssertTrue(result.isEmpty)
                guard case .response(_, 404, _) = reply else {
                    return XCTFail("Only an authoritative unmatched title is a successful empty lookup")
                }
            } catch {
                if case .response(_, 404, _) = reply { XCTFail("An unlisted title is not a source outage") }
            }
        }
    }

    func testKnownTVmazeIdentityOnlyFetchesTheCalendarListing() async throws {
        let fixture = PublicFeedDiscoveryTestTransport([.json("[]")])
        let resolver = SeriesScheduleResolver(pipeline: MetadataEnrichmentPipeline(providers: [
            TVmazeEnrichmentProvider(client: TVmazeClient(http: fixture.http))
        ]))
        let result = try await resolver.calendarEpisodes(for: calendarQuery, in: DateInterval(start: day, duration: 86_400))
        XCTAssertTrue(result.isEmpty)
        let requests = await fixture.requests
        XCTAssertEqual(requests.compactMap { $0.url?.path }, ["/shows/42/episodes"])
    }

    func testUnmatchedProviderCannotHideFallbackOutage() async throws {
        let fixture = PublicFeedDiscoveryTestTransport([.response("", 404, [:]), .response("", 404, [:])])
        let unavailable = try CalendarListingFixture()
        await unavailable.setAvailable(false)
        let resolver = SeriesScheduleResolver(pipeline: MetadataEnrichmentPipeline(
            providers: [
                TVmazeEnrichmentProvider(client: TVmazeClient(http: fixture.http)),
                ResilientEnrichmentProvider(
                    base: TVDBEnrichmentProvider(client: unavailable),
                    breaker: ProviderCircuitBreaker(), cache: ProviderResultCache()
                )
            ],
            config: MetadataEnrichmentConfig(order: [.tvmaze, .tvdb], usesGlobalOrder: true)
        ))
        let query = MetadataQuery(MediaItem(id: "show", title: "Unlisted show", kind: .series, providerIDs: ["Tvdb": "42"]))
        do {
            _ = try await resolver.calendarEpisodes(for: query, in: DateInterval(start: day, duration: 86_400))
            XCTFail("A fallback outage must not be hidden by an unmatched primary lookup")
        } catch {
            XCTAssertEqual(error as? AppError, .notFound)
        }
    }

    private var calendarQuery: MetadataQuery {
        MetadataQuery(
            contentType: .anime, kind: .series, title: "Show", alternateTitle: nil, year: nil,
            seasonNumber: nil, episodeNumber: nil, animeIDs: AnimeIDs(),
            providerIDs: ["Tvmaze": "42", "Tvdb": "42", "AniList": "42"]
        )
    }

    private func calendarProviders(_ client: CalendarListingFixture) -> [any MetadataEnrichmentProvider] {
        [
            TVmazeEnrichmentProvider(client: client),
            TVDBEnrichmentProvider(client: client),
            AniListEnrichmentProvider(client: client),
        ]
    }
}

private struct CalendarScheduleFixture: MetadataEnrichmentProvider {
    let day: Date
    let id: MetadataSource = .tvmaze
    let capabilities: Set<MetadataCapability> = [.nextAiringEpisode]
    let policy = ProviderPolicy()

    func enrich(_ query: MetadataQuery, missing: Set<MetadataField>) async -> MetadataEnrichment {
        let historical = query.scheduleStartDate != nil
        var result = MetadataEnrichment()
        result.upcomingEpisode = .init(
            seriesIdentity: .external(source: "tvmaze", value: "42"),
            seasonNumber: 1, episodeNumber: historical ? 1 : 2,
            airDate: day.addingTimeInterval(historical ? -86_400 : 86_400),
            datePrecision: .dateOnly, source: .tvmaze, refreshedAt: day
        )
        return result
    }
}

private actor CalendarListingFixture: TVmazeEnriching, TVDBEnriching, AniListEnriching {
    private var available = true
    private let media: AniListArtworkProvider.Media
    private(set) var calls = 0

    init() throws {
        media = try JSONDecoder().decode(AniListArtworkProvider.Media.self, from: Data(#"{"id":42}"#.utf8))
    }

    func setAvailable(_ available: Bool) { self.available = available }

    func upcomingEpisodes(_ query: MetadataQuery, limit: Int) async -> TVmazeUpcoming? {
        calls += 1
        return available ? TVmazeUpcoming(showID: 42, episodes: []) : nil
    }

    func upcomingEpisodes(byTVDBID id: String, limit: Int) async -> TVDBUpcomingSchedule? {
        calls += 1
        return available ? TVDBUpcomingSchedule(episodes: []) : nil
    }

    func fetchMedia(for query: MetadataQuery) async -> AniListArtworkProvider.Media? {
        calls += 1
        return available ? media : nil
    }

    func resolve(_ query: MetadataQuery, wantEpisodeStill: Bool, wantOverview: Bool) async -> TVmazeResolved? { nil }
    func nextEpisode(_ query: MetadataQuery) async -> TVmazeNextEpisode? { nil }
    func resolve(byTVDBID id: String, isMovie: Bool) async -> TVDBMetadata? { nil }
    func resolve(titles: [String], year: Int?, isMovie: Bool, episodeHints: [SeriesEpisodeHint]) async -> TVDBMetadata?
    { nil }
    func backdropURL(title: String, year: Int?, isMovie: Bool, tvdbID: String?) async -> URL? { nil }
    func nextAired(byTVDBID id: String) async -> ProviderNextEpisode? { nil }
}
