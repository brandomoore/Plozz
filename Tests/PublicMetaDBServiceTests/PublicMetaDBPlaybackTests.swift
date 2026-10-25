import CoreModels
import CoreNetworking
import CoreSecureStore
import Foundation
import XCTest
@testable import PublicMetaDBService
@testable import TestSupportNetworking

private let emptyPage = #"{"items":[],"total":0,"page":1,"perPage":500,"totalPages":0}"#
private let watchRow = #"{"id":"play-a","tmdb_id":550,"media_type":"movie","watched_at":"2025-01-01T00:15:00.000Z"}"#
private let resumeRow = #"{"id":"resume-a","tmdb_id":550,"media_type":"movie","position_ms":300000,"runtime_ms":1000000,"updated":"2025-01-01T00:05:01.000Z"}"#

private func page(_ row: String) -> String {
    #"{"items":[\#(row)],"total":1,"page":1,"perPage":500,"totalPages":1}"#
}

private func delivery(position: Double = 900, seconds: Double = 900, sessionID: UUID = UUID()) throws -> TrackerPlaybackDelivery {
    let start = ISO8601DateFormatter().date(from: "2025-01-01T00:00:00Z")!
    return TrackerPlaybackDelivery(
        sample: try .init(
            sessionID: sessionID, startedAt: start, capturedAt: start.addingTimeInterval(seconds),
            item: .init(id: "movie", title: "Test", kind: .movie, providerIDs: ["Tmdb": "550"]),
            position: position, duration: 1_000, isFinal: true
        ),
        trackerID: "publicmetadb", connectionID: "consent-a",
        serverScope: .init(profile: .init(id: "profile", name: "Test"), accounts: [])
    )
}

private func reporter(_ http: RecordingHTTPClient, store: DurableLocalStateStore? = nil) throws -> PublicMetaDBPlaybackReporter {
    let key = "pm-" + (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").prefix(60)
    return try PublicMetaDBPlaybackReporter(
        client: PublicMetaDBClient(key: key, http: http),
        store: store ?? DurableLocalStateStore(secureStore: InMemorySecureStore())
    )
}

final class PublicMetaDBPlaybackTests: XCTestCase {
    func testNinetyPercentCreatesOneWatchWithOriginalDateAndIndependentReadback() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/resume", json: emptyPage)
        http.stub(pathSuffix: "/watched", json: emptyPage)
        http.stub(pathSuffix: "/watched", json: #"{"success":true,"item":\#(watchRow)}"#)
        http.stub(pathSuffix: "/watched", json: page(watchRow))
        let writer = try reporter(http)
        let play = try delivery()
        try await writer.report(play)
        try await writer.report(play)
        XCTAssertEqual(http.sent.filter { $0.body != nil }.count, 1)
        let post = try XCTUnwrap(http.sent.first { $0.body != nil })
        XCTAssertEqual(post.json?["watched_at"] as? String, "2025-01-01T00:15:00.000Z")
        XCTAssertNil(post.json?["dedupe"])
        XCTAssertEqual(http.sentPaths, ["/api/external/resume", "/api/external/watched", "/api/external/watched", "/api/external/watched"])
    }

    func testEightyPercentDoesNotCreateWatchedPlay() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/resume", json: emptyPage)
        try await reporter(http).report(delivery(position: 800))
        XCTAssertEqual(http.sentPaths, ["/api/external/resume"])
        XCTAssertTrue(http.sent.allSatisfy { $0.body == nil })
    }

    func testResumeUsesMillisecondsAndSeparateReadback() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/resume", json: emptyPage)
        http.stub(pathSuffix: "/resume", json: #"{"success":true,"action":"saved","item":\#(resumeRow)}"#)
        http.stub(pathSuffix: "/resume", json: page(resumeRow))
        http.stub(pathSuffix: "/watched", json: emptyPage)
        try await reporter(http).report(delivery(position: 300, seconds: 300))
        let post = try XCTUnwrap(http.sent.first { $0.body != nil })
        XCTAssertEqual(post.json?["position_ms"] as? Int, 300_000)
        XCTAssertEqual(post.json?["runtime_ms"] as? Int, 1_000_000)
        XCTAssertEqual(http.sentPaths, ["/api/external/resume", "/api/external/watched", "/api/external/resume", "/api/external/resume"])
    }

    func testNewerRemoteResumeBlocksOlderOfflineSample() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/resume", json: page(resumeRow.replacingOccurrences(of: "300000", with: "400000")))
        do {
            try await reporter(http).report(delivery(position: 300, seconds: 300))
            XCTFail("Newer remote progress overwritten")
        } catch { XCTAssertEqual(error as? TrackerPlaybackDeliveryError, .remoteConflict) }
        XCTAssertTrue(http.sent.allSatisfy { $0.body == nil })
    }

    func testNewerRemoteWatchPreventsResurrectingAnOldResume() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/resume", json: emptyPage)
        http.stub(pathSuffix: "/watched", json: page(watchRow))
        do {
            try await reporter(http).report(delivery(position: 300, seconds: 300))
            XCTFail("Old offline resume resurrected after newer remote completion")
        } catch { XCTAssertEqual(error as? TrackerPlaybackDeliveryError, .remoteConflict) }
        XCTAssertTrue(http.sent.allSatisfy { $0.body == nil })
    }

    func testPossiblePluginWatchBlocksDuplicatePlay() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/resume", json: emptyPage)
        http.stub(pathSuffix: "/watched", json: page(watchRow))
        do { try await reporter(http).report(delivery()); XCTFail("Plugin watch duplicated") }
        catch { XCTAssertEqual(error as? TrackerPlaybackDeliveryError, .remoteConflict) }
        XCTAssertTrue(http.sent.allSatisfy { $0.body == nil })
    }

    func testLostReplyIsConfirmedOnlyByNewExactDatedRecord() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/resume", json: emptyPage)
        http.stub(pathSuffix: "/watched", json: emptyPage)
        http.stub(pathSuffix: "/watched", json: "{}", status: 503)
        http.stub(pathSuffix: "/watched", json: page(watchRow))
        try await reporter(http).report(delivery())
        XCTAssertEqual(http.sent.filter { $0.body != nil }.count, 1)
    }

    func testUnconfirmedWatchIsNotReplayedAfterRelaunch() async throws {
        let http = RecordingHTTPClient()
        let store = try DurableLocalStateStore(secureStore: InMemorySecureStore())
        let play = try delivery()
        http.stub(pathSuffix: "/resume", json: emptyPage)
        http.stub(pathSuffix: "/watched", json: emptyPage)
        http.stub(pathSuffix: "/watched", json: "{}", status: 503)
        http.stub(pathSuffix: "/watched", json: emptyPage)
        for _ in 0..<2 {
            do { try await reporter(http, store: store).report(play); XCTFail("Unconfirmed write acknowledged") }
            catch { XCTAssertEqual(error as? TrackerPlaybackDeliveryError, .unconfirmed) }
        }
        XCTAssertEqual(http.sent.filter { $0.body != nil }.count, 1)
    }

    func testLaterGenuineRewatchCreatesAnotherRecord() async throws {
        let http = RecordingHTTPClient()
        let nextRow = watchRow.replacingOccurrences(of: "play-a", with: "play-b")
            .replacingOccurrences(of: "00:15:00", with: "00:30:00")
        http.stub(pathSuffix: "/resume", json: emptyPage)
        http.stub(pathSuffix: "/watched", json: page(watchRow))
        http.stub(pathSuffix: "/watched", json: #"{"success":true,"item":\#(nextRow)}"#)
        http.stub(pathSuffix: "/watched", json: #"{"items":[\#(watchRow),\#(nextRow)],"total":2,"page":1,"perPage":500,"totalPages":1}"#)
        let sample = try delivery(seconds: 1_800).sample
        let later = TrackerPlaybackDelivery(
            sample: try TrackerPlaybackSample(
                sessionID: UUID(), startedAt: sample.startedAt.addingTimeInterval(901), capturedAt: sample.capturedAt,
                item: .init(id: "movie", title: "Test", kind: .movie, providerIDs: ["Tmdb": "550"]),
                position: 900, duration: 1_000, isFinal: true
            ),
            trackerID: "publicmetadb", connectionID: "consent-a",
            serverScope: .init(profile: .init(id: "profile", name: "Test"), accounts: [])
        )
        try await reporter(http).report(later)
        XCTAssertEqual(http.sent.filter { $0.body != nil }.count, 1)
    }

    func testEpisodesRequireSeriesIDAndConfirmedSingleEpisodeOrder() throws {
        let date = Date()
        for ordering: EpisodeOrdering? in [nil, .tmdb] {
            for end: Int? in [nil, 3] {
                let item = MediaItem(
                    id: "episode", title: "Test", kind: .episode,
                    seasonNumber: 1, episodeNumber: 2,
                    providerIDs: ["Tmdb": "999", "SeriesTmdb": "550"]
                )
                var episode = item
                episode.episodeNumberEnd = end
                episode.episodeOrdering = ordering
                let sample = try TrackerPlaybackSample(
                    sessionID: UUID(), startedAt: date, item: episode,
                    position: 900, duration: 1_000, isFinal: true
                )
                if ordering == .tmdb && end == nil {
                    XCTAssertEqual(try PublicMetaDBPlaybackReporter.content(sample).tmdbID, 550)
                } else {
                    XCTAssertThrowsError(try PublicMetaDBPlaybackReporter.content(sample))
                }
            }
        }
    }
}
