import CoreModels
import CoreNetworking
import FeatureHomeCore
import Foundation
import ProviderJellyfin
import ProviderPlex
import XCTest
@testable import AppShell
@testable import FeatureHome

@MainActor
final class ShowcaseEnrichmentPerformanceTests: XCTestCase {
    func testJellyfin() async throws { try await measure(.jellyfin) }
    func testEmby() async throws { try await measure(.emby) }
    func testPlex() async throws { try await measure(.plex) }

    private func measure(_ kind: ProviderKind) async throws {
        try await PerformanceProbe.measure(self, scenario: "showcase-enrichment-\(kind.rawValue)") {
            let accountID = "fixture-\(kind.rawValue)"
            let session = UserSession(
                server: .init(id: accountID, name: "Fixture", baseURL: URL(string: "https://fixture.invalid")!,
                              provider: kind), userID: "viewer", userName: "Viewer", deviceID: "fixture",
                accessToken: "fixture"
            )
            let http = ShowcaseHTTP(kind: kind)
            let provider: any MediaProvider = kind == .plex
                ? PlexProvider(session: session, http: http, interactiveHTTP: http, probe: http)
                : JellyfinProvider(session: session, http: http, interactiveHTTP: http, addressProbe: http)
            let account = ResolvedAccount(account: Account(id: accountID, from: session), provider: provider)
            let enrich = makeHeroMetadataEnricher(accounts: [account], identitySources: { _ in [] })
            let row = (1...16).map {
                MediaItem(id: "show-\($0)", title: "Row \($0)", kind: .series, sourceAccountID: accountID)
            }
            let metadata = FocusHeroMetadata()
            // Exercise the real .store path, including the batch's pinned-series scope.
            // Checking just item(for:) would hide erroneous replacement by a playable episode.
            await metadata.prefetch([row]) { batch in
                let full = await enrich(batch)
                XCTAssertEqual(full.map(\.id), batch.map(\.id))
                XCTAssertTrue(full.allSatisfy { $0.kind == .series && $0.sourceAccountID == accountID })
                return full
            }
            let cold = await http.takeCounts()
            XCTAssertEqual(cold, .init(details: row.count, series: 0, seasons: 0))
            for item in row {
                let presented = metadata.item(for: item)
                XCTAssertEqual(presented.overview, "Overview \(item.id)")
                XCTAssertEqual(presented.officialRating, "TV-PG")
                XCTAssertEqual(presented.genres, ["Drama"])
                XCTAssertEqual(presented.title, item.title)
            }
            for index in [0, 1, 0] { await metadata.load(row[index], using: enrich) }
            let refocus = await http.takeCounts()
            XCTAssertEqual(refocus.total, 0)

            let displayed = metadata.item(for: row[0])
            let play = await HeroPlayTargetResolver.playbackTarget(for: displayed, provider: provider)
            XCTAssertEqual(play?.id, "show-1-s2-e")
            XCTAssertEqual(play?.kind, .episode)
            XCTAssertEqual(play?.sourceAccountID, accountID)
            let selected = await http.takeCounts()
            XCTAssertEqual(selected, .init(details: 0, series: 1, seasons: 2))

            // Carousel uses the same closure, but (without a pinned slide) publishes
            // the actual resume episode, not its parent. Capture its cost separately.
            let carousel = await HeroMetadataEnricher.withPinnedSeries({ [] }) { await enrich([row[0]]) }
            XCTAssertEqual(carousel.first?.id, play?.id)
            XCTAssertEqual(carousel.first?.kind, .episode)
            XCTAssertEqual(carousel.first?.seriesID, row[0].id)
            XCTAssertEqual(carousel.first?.sourceAccountID, accountID)
            let unpinned = await http.takeCounts()
            XCTAssertEqual(unpinned, .init(details: 1, series: 1, seasons: 2))

            let movie = MediaItem(id: "film", title: "Film", kind: .movie, sourceAccountID: accountID)
            let episode = MediaItem(id: "show-1-s2-e", title: "Episode", kind: .episode,
                                    overview: "Episode text", seriesID: row[0].id,
                                    resumePosition: 12, sourceAccountID: accountID)
            await metadata.load(movie, using: enrich)
            await metadata.load(episode, using: enrich)
            XCTAssertEqual(metadata.item(for: movie).overview, "Overview film")
            let shownEpisode = metadata.item(for: episode)
            XCTAssertEqual(shownEpisode.seriesSynopsis?.overview, "Overview show-1")
            XCTAssertEqual(shownEpisode.overview, episode.overview)
            XCTAssertEqual(shownEpisode.resumePosition, episode.resumePosition)
            XCTAssertEqual(shownEpisode.id, episode.id)
            let other = await http.takeCounts()
            XCTAssertEqual(other, .init(details: 3, series: 0, seasons: 0))
            return ["showcaseItemDetails": cold.details, "showcaseSeriesChildren": cold.series,
                    "showcaseSeasonChildren": cold.seasons, "warmRefocusRequests": refocus.total,
                    "selectedSeriesPlayRequests": selected.total, "carouselRequests": unpinned.total,
                    "movieAndEpisodeRequests": other.total]
        }
    }
}

@MainActor
final class ShowcaseEnrichmentRegressionTests: XCTestCase {
    func testSeriesAndEpisodePresentParentRatingWithoutWalkingChildren() async throws {
        for kind: ProviderKind in [.jellyfin, .emby, .plex] {
            let accountID = "rated-\(kind.rawValue)"
            let session = UserSession(
                server: .init(id: accountID, name: "Fixture", baseURL: URL(string: "https://fixture.invalid")!,
                              provider: kind), userID: "viewer", userName: "Viewer", deviceID: "fixture",
                accessToken: "fixture"
            )
            let http = RatedDetailHTTP(kind: kind)
            let provider: any MediaProvider = kind == .plex
                ? PlexProvider(session: session, http: http, interactiveHTTP: http, probe: http)
                : JellyfinProvider(session: session, http: http, interactiveHTTP: http, addressProbe: http)
            let account = ResolvedAccount(account: Account(id: accountID, from: session), provider: provider)
            let enrich = makeHeroMetadataEnricher(accounts: [account], identitySources: { _ in [] })
            let row = (1...16).map {
                MediaItem(id: "show-\($0)", title: "Show \($0)", kind: .series, sourceAccountID: accountID)
            }
            let parentRatings = [ExternalRating(source: .community, value: 8.5, scale: .outOfTen)]
            let metadata = FocusHeroMetadata()
            await metadata.prefetch([row], using: enrich)
            let cold = await http.detailIDs
            XCTAssertEqual(cold.sorted(), row.map(\.id).sorted(), "Exactly one detail per series: \(kind)")
            for show in row {
                XCTAssertEqual(metadata.item(for: show).ratings, parentRatings, "\(kind): \(show.id)")
            }

            // Prove the provider really maps a different episode score. The sparse row
            // has no score; enrichment must use its series' rating, not its own detail.
            let leaf = try await provider.item(id: "episode")
            XCTAssertEqual(leaf.ratings, [.init(source: .community, value: 3.5, scale: .outOfTen)])
            let sparse = MediaItem(id: leaf.id, title: "Episode", kind: .episode,
                                   seriesID: row[0].id, sourceAccountID: accountID)
            await metadata.load(sparse, using: enrich)
            let presented = metadata.item(for: sparse)
            XCTAssertEqual(presented.ratings, parentRatings)
            XCTAssertEqual(presented.id, sparse.id)
            XCTAssertEqual(presented.sourceAccountID, accountID)
            let all = await http.detailIDs
            XCTAssertEqual(Array(all.dropFirst(cold.count)), [leaf.id, leaf.id, row[0].id])
        }
    }
}

/// Deliberately accepts no children endpoints: even a failed, swallowed walk fails the test.
private actor RatedDetailHTTP: HTTPClient {
    let kind: ProviderKind
    private(set) var detailIDs: [String] = []
    init(kind: ProviderKind) { self.kind = kind }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let prefix = kind == .plex ? "/library/metadata/" : "/Users/viewer/Items/"
        let id = String(endpoint.path.dropFirst(prefix.count))
        guard endpoint.method == .get, endpoint.path.hasPrefix(prefix), !id.isEmpty,
              !id.contains("/"), id == "episode" || id.hasPrefix("show-") else {
            XCTFail("Unexpected request outside the detail-only fixture: \(kind)")
            throw AppError.invalidResponse
        }
        detailIDs.append(id)
        let episode = id == "episode"
        let score = episode ? 3.5 : 8.5
        let body: [String: Any]
        if kind == .plex {
            var record: [String: Any] = ["ratingKey": id, "title": id, "type": episode ? "episode" : "show",
                                         "audienceRating": score]
            if episode { record["grandparentRatingKey"] = "show-1" }
            body = ["MediaContainer": ["size": 1, "Metadata": [record]]]
        } else {
            var record: [String: Any] = ["Id": id, "Name": id, "Type": episode ? "Episode" : "Series",
                                         "CommunityRating": score]
            if episode { record["SeriesId"] = "show-1" }
            body = record
        }
        return (try JSONSerialization.data(withJSONObject: body),
                HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"])!)
    }
}

/// Real providers map these responses. Series have two seasons; the resume
/// episode is in season two, so returning the first available episode fails.
private actor ShowcaseHTTP: HTTPClient {
    struct Counts: Equatable {
        var details = 0
        var series = 0
        var seasons = 0
        var total: Int { details + series + seasons }
    }

    let kind: ProviderKind
    private var counts = Counts()
    init(kind: ProviderKind) { self.kind = kind }

    func takeCounts() -> Counts {
        defer { counts = Counts() }
        return counts
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let parts = endpoint.path.split(separator: "/").map(String.init)
        let id: String
        let children: Bool
        if kind == .plex, parts.starts(with: ["library", "metadata"]),
           parts.count == 3 || (parts.count == 4 && parts.last == "children") {
            id = parts[2]
            children = parts.count == 4
        } else if kind != .plex, parts.starts(with: ["Users", "viewer", "Items"]), parts.count == 4 {
            id = parts[3]
            children = false
        } else if kind != .plex, parts == ["Users", "viewer", "Items"],
                  let parent = endpoint.queryItems.first(where: { $0.name == "ParentId" })?.value {
            id = parent
            children = true
        } else {
            XCTFail("Unexpected request outside Showcase fixture")
            throw AppError.invalidResponse
        }
        let ids: [String]
        if !children {
            counts.details += 1
            ids = [id]
        } else if id.hasSuffix("-s1") || id.hasSuffix("-s2") {
            counts.seasons += 1
            ids = ["\(id)-e"]
        } else {
            counts.series += 1
            ids = ["\(id)-s1", "\(id)-s2"]
        }
        let records = ids.map(record)
        let body: [String: Any]
        if kind == .plex { body = ["MediaContainer": ["size": records.count, "Metadata": records]] }
        else if children { body = ["Items": records, "TotalRecordCount": records.count] }
        else { body = records[0] }
        let data = try JSONSerialization.data(withJSONObject: body)
        return (data, HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil,
                                      headerFields: ["Content-Type": "application/json"])!)
    }

    private func record(_ id: String) -> [String: Any] {
        let episode = id.hasSuffix("-e")
        let season = !episode && (id.hasSuffix("-s1") || id.hasSuffix("-s2"))
        let root = id.components(separatedBy: "-s")[0]
        let ordinal = id.contains("-s2") ? 2 : 1
        if kind == .plex {
            var value: [String: Any] = [
                "ratingKey": id, "title": id, "type": episode ? "episode" : season ? "season" : id == "film" ? "movie" : "show",
                "summary": "Overview \(id)", "Genre": [["tag": "Drama"]], "contentRating": "TV-PG"
            ]
            if season { value["index"] = ordinal; value["parentRatingKey"] = root }
            if episode {
                value["grandparentRatingKey"] = root
                value["parentRatingKey"] = "\(root)-s\(ordinal)"
                value["duration"] = 1_800_000
                value["viewOffset"] = ordinal == 2 ? 90_000 : 0
            }
            return value
        }
        var value: [String: Any] = [
            "Id": id, "Name": id, "Type": episode ? "Episode" : season ? "Season" : id == "film" ? "Movie" : "Series",
            "Overview": "Overview \(id)", "Genres": ["Drama"], "OfficialRating": "TV-PG"
        ]
        if season { value["IndexNumber"] = ordinal; value["SeriesId"] = root }
        if episode {
            value["SeriesId"] = root
            value["SeasonId"] = "\(root)-s\(ordinal)"
            value["RunTimeTicks"] = Int64(18_000_000_000)
            value["UserData"] = ["PlaybackPositionTicks": ordinal == 2 ? 900_000_000 : 0]
        }
        return value
    }
}
