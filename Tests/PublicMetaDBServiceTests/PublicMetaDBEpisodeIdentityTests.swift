import CoreModels
import CoreNetworking
import CoreSecureStore
import Foundation
import XCTest
@testable import PublicMetaDBService
@testable import TestSupportNetworking

private func serverEpisode() -> MediaItem {
    MediaItem(
        id: "server-episode", title: "Episode", kind: .episode, seasonNumber: 1, episodeNumber: 2,
        providerIDs: ["SeriesTmdb": "42", "SeriesImdb": "tt7654321", "Imdb": "tt1234567",
                      "SeriesTvdb": "789", "Tvdb": "456"]
    )
}

private func catalogEpisode() -> MediaItem {
    var item = serverEpisode()
    item.id = "catalog-episode"
    item.episodeOrdering = .tmdb
    item.providerIDs["Tmdb"] = "123"
    return item
}

private func episodeDelivery(item: MediaItem = serverEpisode(), position: Double = 300) throws -> TrackerPlaybackDelivery {
    let date = Date(timeIntervalSince1970: 1_735_689_600)
    return TrackerPlaybackDelivery(
        sample: try TrackerPlaybackSample(
            sessionID: UUID(), startedAt: date, capturedAt: date.addingTimeInterval(400),
            item: item, position: position, duration: 1_000, isFinal: true
        ),
        trackerID: "publicmetadb", connectionID: "consent",
        serverScope: .init(profile: .init(id: "profile", name: "Test"), accounts: [])
    )
}

final class PublicMetaDBEpisodeIdentityTests: XCTestCase {
    func testExactEpisodeAndParentEvidenceCanConfirmUnspecifiedOrder() throws {
        let content = try PublicMetaDB.Content(tmdbID: 42, mediaType: .tv, season: 1, episode: 2)
        let evidence = try PublicMetaDBEpisodeIdentity(content: content, item: catalogEpisode())
        for ordering: EpisodeOrdering? in [nil, .aired, .dvd, .absolute, .unknown] {
            var item = serverEpisode()
            item.episodeOrdering = ordering
            XCTAssertTrue(evidence.matches(item))
            XCTAssertEqual(try PublicMetaDBPlaybackReporter.content(
                episodeDelivery(item: item).sample, confirmedEpisode: evidence
            ), content)
            XCTAssertEqual(item.episodeOrdering, ordering)
            XCTAssertEqual(item.id, "server-episode")
        }
    }

    func testOtherEpisodeParentConflictsAndInheritedIDsDoNotConfirm() throws {
        let content = try PublicMetaDB.Content(tmdbID: 42, mediaType: .tv, season: 1, episode: 2)
        let evidence = try PublicMetaDBEpisodeIdentity(content: content, item: catalogEpisode())
        var candidates: [MediaItem] = []
        var wrongEpisode = serverEpisode()
        wrongEpisode.providerIDs["Imdb"] = "tt9999999"
        candidates.append(wrongEpisode)
        var wrongParent = serverEpisode()
        wrongParent.providerIDs["SeriesTvdb"] = "999"
        candidates.append(wrongParent)
        var adjacent = serverEpisode()
        adjacent.episodeNumber = 3
        candidates.append(adjacent)
        var combined = serverEpisode()
        combined.episodeNumberEnd = 3
        candidates.append(combined)
        var inherited = serverEpisode()
        inherited.providerIDs["Imdb"] = inherited.providerIDs["SeriesImdb"]
        inherited.providerIDs["Tvdb"] = inherited.providerIDs["SeriesTvdb"]
        candidates.append(inherited)
        var aliases = serverEpisode()
        aliases.providerIDs["imdbid"] = "tt9999999"
        candidates.append(aliases)
        for item in candidates {
            XCTAssertFalse(evidence.matches(item))
            XCTAssertThrowsError(try PublicMetaDBPlaybackReporter.content(
                episodeDelivery(item: item).sample, confirmedEpisode: evidence
            ))
        }
    }

    @MainActor
    func testRealShapeResumeWriteRetainsVerifiedIdentityAcrossReporterRestart() async throws {
        let http = RecordingHTTPClient()
        let empty = #"{"items":[],"total":0,"page":1,"perPage":500,"totalPages":0}"#
        let row = #"{"id":"resume","tmdb_id":42,"media_type":"tv","season":1,"episode":2,"position_ms":300000,"runtime_ms":1000000}"#
        http.stub(pathSuffix: "/resume", json: empty)
        http.stub(pathSuffix: "/watched", json: empty)
        http.stub(pathSuffix: "/resume", json: #"{"action":"saved","item":\#(row)}"#)
        http.stub(pathSuffix: "/resume", json: #"{"items":[\#(row)],"total":1,"page":1,"perPage":500,"totalPages":1}"#)
        let key = "pm-" + String(repeating: "a", count: 60)
        let client = try PublicMetaDBClient(key: key, http: http)
        let store = try DurableLocalStateStore(secureStore: InMemorySecureStore())
        let delivery = try episodeDelivery()
        var lookups = 0
        for _ in 0..<2 {
            let reporter = PublicMetaDBPlaybackReporter(
                client: client, store: store, resolveEpisodeIdentity: { content in
                    lookups += 1
                    XCTAssertEqual(content.tmdbID, 42)
                    return catalogEpisode()
                }
            )
            try await reporter.report(delivery)
        }
        XCTAssertEqual(lookups, 1)
        let writes = http.sent.filter { $0.body != nil }
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.json?["tmdb_id"] as? Int, 42)
        XCTAssertEqual(writes.first?.json?["season"] as? Int, 1)
        XCTAssertEqual(writes.first?.json?["episode"] as? Int, 2)
    }

    func testUnavailableOrMismatchedIdentityDoesNotContactTracker() async throws {
        for lookup: PublicMetaDBEpisodeIdentity.Resolving in [
            { _ in nil },
            { _ in var item = catalogEpisode(); item.providerIDs["Tvdb"] = "999"; return item }
        ] {
            let http = RecordingHTTPClient()
            let client = try PublicMetaDBClient(key: "pm-" + String(repeating: "a", count: 60), http: http)
            let reporter = try PublicMetaDBPlaybackReporter(
                client: client, store: DurableLocalStateStore(secureStore: InMemorySecureStore()),
                resolveEpisodeIdentity: lookup
            )
            do {
                try await reporter.report(episodeDelivery())
                XCTFail("Unconfirmed identity accepted")
            } catch {
                XCTAssertEqual(error as? TrackerPlaybackDeliveryError, .unsupportedIdentity)
            }
            XCTAssertTrue(http.sent.isEmpty)
        }
    }
}
