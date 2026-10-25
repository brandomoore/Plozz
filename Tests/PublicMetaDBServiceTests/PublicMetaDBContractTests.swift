import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import PublicMetaDBService
@testable import TestSupportNetworking

private let testKey = "pm-" + String(repeating: "A", count: 60)
private let emptyPage = #"{"items":[],"total":0,"page":1,"perPage":100,"totalPages":0}"#
private let watch = #"{"id":"play1","tmdb_id":550,"media_type":"movie","watched_at":null}"#

private func client(_ http: RecordingHTTPClient) throws -> PublicMetaDBClient {
    try PublicMetaDBClient(key: testKey, http: http, gate: .init())
}

final class PublicMetaDBContractTests: XCTestCase {
    func testRejectsInvalidKeysBeforeNetwork() {
        for key in ["", "pm-short", "pm-" + String(repeating: "-", count: 60), "pm-" + String(repeating: "é", count: 60)] {
            XCTAssertThrowsError(try PublicMetaDBClient(key: key))
        }
        XCTAssertNoThrow(try PublicMetaDBClient(key: " \n" + testKey + "\n"))
    }

    func testContentValidationPreservesNamespacesAndSpecials() throws {
        let movie = try PublicMetaDB.Content(tmdbID: 1, mediaType: .movie)
        let show = try PublicMetaDB.Content(tmdbID: 1, mediaType: .tv)
        XCTAssertNotEqual(movie, show)
        XCTAssertTrue(movie.isPlayable)
        XCTAssertFalse(show.isPlayable)
        XCTAssertTrue(try PublicMetaDB.Content(tmdbID: 1, mediaType: .tv, season: 0, episode: 1).isPlayable)
        XCTAssertThrowsError(try PublicMetaDB.Content(tmdbID: 0, mediaType: .movie))
        XCTAssertThrowsError(try PublicMetaDB.Content(tmdbID: 1, mediaType: .movie, season: 1))
        XCTAssertThrowsError(try PublicMetaDB.Content(tmdbID: 1, mediaType: .tv, episode: 1))
        XCTAssertThrowsError(try PublicMetaDB.Content(tmdbID: 1, mediaType: .tv, season: -1, episode: 1))
        XCTAssertThrowsError(try PublicMetaDB.Content(tmdbID: 1, mediaType: .tv, season: 1, episode: 0))
    }

    func testReadUsesDocumentedOriginAuthorizationAndPagination() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/watched", json: emptyPage)
        _ = try await client(http).history()
        let request = try XCTUnwrap(http.sent.first)
        XCTAssertEqual(request.baseURL.absoluteString, "https://publicmetadb.com")
        XCTAssertEqual(request.path, "/api/external/watched")
        XCTAssertEqual(request.headers["Authorization"], "Bearer " + testKey)
        XCTAssertEqual(request.queryItems, [.init(name: "page", value: "1"), .init(name: "perPage", value: "100")])
        XCTAssertNil(request.body)
    }

    func testWatchDateOmittedNullAndKnownRemainDistinct() async throws {
        let content = try PublicMetaDB.Content(tmdbID: 550, mediaType: .movie)
        let http = RecordingHTTPClient()
        let dated = watch.replacingOccurrences(of: "null", with: #""2023-11-14T22:13:20.125Z""#)
        http.stub(pathSuffix: "/watched", json: #"{"success":true,"item":\#(dated)}"#)
        http.stub(pathSuffix: "/watched", json: #"{"success":true,"item":\#(watch)}"#)
        http.stub(pathSuffix: "/watched", json: #"{"success":true,"item":\#(dated)}"#)
        let api = try client(http)
        _ = try await api.recordWatch(content, at: .now)
        _ = try await api.recordWatch(content, at: .unknown)
        _ = try await api.recordWatch(content, at: .known(Date(timeIntervalSince1970: 1_700_000_000.125)))
        XCTAssertNil(http.sent[0].json?["watched_at"])
        XCTAssertTrue(http.sent[1].json?["watched_at"] is NSNull)
        XCTAssertEqual(http.sent[2].json?["watched_at"] as? String, "2023-11-14T22:13:20.125Z")
        XCTAssertTrue(http.sent.allSatisfy { $0.queryItems.isEmpty })
    }

    func testWatchReadRequiresExplicitDateAndPlayableContent() async throws {
        for row in [
            #"{"id":"play","tmdb_id":550,"media_type":"movie"}"#,
            #"{"id":"play","tmdb_id":550,"media_type":"tv","watched_at":null}"#,
            #"{"id":"","tmdb_id":550,"media_type":"movie","watched_at":null}"#
        ] {
            let http = RecordingHTTPClient()
            http.stub(pathSuffix: "/watched", json: #"{"items":[\#(row)],"total":1,"page":1,"perPage":100,"totalPages":1}"#)
            do { _ = try await client(http).history(); XCTFail("Invalid watch accepted") }
            catch { XCTAssertEqual(error as? AppError, .decoding) }
        }
    }

    func testUnknownDateAndFractionalDateDecode() throws {
        let decoder = PublicMetaDBClient.decoder()
        let unknown = try decoder.decode(PublicMetaDB.Record<PublicMetaDB.Watch>.self, from: Data(watch.utf8))
        XCTAssertNil(unknown.value.watchedAt)
        let dated = watch.replacingOccurrences(of: "null", with: #""2023-11-14T22:13:20.125Z""#)
        let row = try decoder.decode(PublicMetaDB.Record<PublicMetaDB.Watch>.self, from: Data(dated.utf8))
        XCTAssertEqual(try XCTUnwrap(row.value.watchedAt).timeIntervalSince1970, 1_700_000_000.125, accuracy: 0.001)
    }

    func testMissingNonIdempotentResponseIsUncertainAndNeverRetried() async throws {
        let http = RecordingHTTPClient()
        http.error = .serverUnreachable
        let api = try client(http)
        do {
            _ = try await api.recordWatch(.init(tmdbID: 550, mediaType: .movie), at: .unknown)
            XCTFail("Missing delivery evidence was accepted")
        } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .uncertainWrite) }
        XCTAssertEqual(http.sent.count, 1)
    }

    func testServerFailureOrMalformedWriteReplyIsUncertain() async throws {
        for (status, body) in [(503, "{}"), (201, "not-json"), (200, #"{"success":true}"#)] {
            let http = RecordingHTTPClient()
            http.stub(pathSuffix: "/watched", json: body, status: status)
            do {
                _ = try await client(http).recordWatch(.init(tmdbID: 550, mediaType: .movie), at: .unknown)
                XCTFail("Unconfirmed write accepted")
            } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .uncertainWrite) }
            XCTAssertEqual(http.sent.count, 1)
        }
    }

    func test403DoesNotMasqueradeAsInvalidCredential() async throws {
        for (status, expected) in [(401, PublicMetaDB.Failure.invalidKey), (403, .blocked)] {
            let http = RecordingHTTPClient()
            http.stub(pathSuffix: "/lists", json: "{}", status: status)
            do { _ = try await client(http).lists(); XCTFail("Rejection ignored") }
            catch { XCTAssertEqual(error as? PublicMetaDB.Failure, expected) }
        }
    }

    func testRetryAfterPreventsAnotherRequestWithoutSleepingThroughQuota() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/lists", json: "{}", status: 429, headers: ["Retry-After": "3600"])
        let api = try client(http)
        for _ in 0..<2 {
            do { _ = try await api.lists(); XCTFail("Quota ignored") }
            catch AppError.rateLimited(let delay) { XCTAssertGreaterThan(try XCTUnwrap(delay), 3_500) }
        }
        XCTAssertEqual(http.sent.count, 1)
    }

    func testConnectionFencePreventsDispatch() async throws {
        let http = RecordingHTTPClient()
        let api = try PublicMetaDBClient(key: testKey, http: http, gate: .init(), isCurrent: { false })
        do { _ = try await api.history(); XCTFail("Stale connection used") }
        catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .connectionChanged) }
        XCTAssertTrue(http.sent.isEmpty)
    }

    func testResumeThresholdsAreExactAndIndependentOfAppCompletion() throws {
        let content = try PublicMetaDB.Content(tmdbID: 1, mediaType: .movie)
        for (position, expected) in [
            (19.99, PublicMetaDB.Resume.Disposition.ignored), (20, .saved),
            (799.99, .saved), (800, .completed), (899, .completed), (1_000, .completed)
        ] {
            let resume = try PublicMetaDB.Resume(content: content, positionMilliseconds: position, runtimeMilliseconds: 1_000)
            XCTAssertEqual(resume.expectedDisposition, expected)
        }
        XCTAssertThrowsError(try PublicMetaDB.Resume(content: content, positionMilliseconds: .nan, runtimeMilliseconds: 1_000))
        XCTAssertThrowsError(try PublicMetaDB.Resume(content: content, positionMilliseconds: 1, runtimeMilliseconds: 0))
        XCTAssertThrowsError(try PublicMetaDB.Resume(content: content, positionMilliseconds: 1_001, runtimeMilliseconds: 1_000))
    }

    func testResumeSavedAndCompletedResponsesStayDifferent() async throws {
        let content = try PublicMetaDB.Content(tmdbID: 550, mediaType: .movie)
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/resume", json: #"{"action":"saved","item":{"id":"resume1","tmdb_id":550,"media_type":"movie","position_ms":500,"runtime_ms":1000,"progress":50}}"#)
        http.stub(pathSuffix: "/resume", json: #"{"action":"completed","progress":80,"tmdb_id":550,"media_type":"movie"}"#)
        let api = try client(http)
        let saved = try await api.saveResume(.init(content: content, positionMilliseconds: 500, runtimeMilliseconds: 1_000))
        let completed = try await api.saveResume(.init(content: content, positionMilliseconds: 800, runtimeMilliseconds: 1_000))
        XCTAssertEqual(saved.item?.id, "resume1")
        XCTAssertEqual(completed.action, .completed)
        XCTAssertNil(completed.item)
        XCTAssertTrue(http.sentPaths.allSatisfy { $0 == "/api/external/resume" })
        XCTAssertEqual(http.sent[1].json?["position_ms"] as? Double, 800)
    }

    func testBatchLimitsFailBeforeDispatch() async throws {
        let http = RecordingHTTPClient()
        let api = try client(http)
        let resume = try PublicMetaDB.Resume(content: .init(tmdbID: 1, mediaType: .movie), positionMilliseconds: 50, runtimeMilliseconds: 100)
        for items in [[], [resume, resume], Array(repeating: resume, count: 51)] {
            do { _ = try await api.saveResumeBatch(items); XCTFail("Invalid batch accepted") }
            catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .invalidInput) }
        }
        XCTAssertTrue(http.sent.isEmpty)
    }

    func testBatchResumePartialFailureIsNotSuccess() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/resume/batch", json: #"{"results":[{"tmdb_id":1,"media_type":"movie","action":"saved","progress":50},{"action":"error"}],"summary":{"saved":1,"completed":0,"ignored":0,"errors":1}}"#, status: 207)
        let resumes = try [1, 2].map {
            try PublicMetaDB.Resume(content: .init(tmdbID: $0, mediaType: .movie), positionMilliseconds: 50, runtimeMilliseconds: 100)
        }
        let result = try await client(http).saveResumeBatch(resumes)
        XCTAssertFalse(result.isCompleteSuccess)
        XCTAssertEqual(result.summary.errors, 1)
    }

    func testHistoryRejectsMissingPagesAndChangedTotals() async throws {
        for json in [
            #"{"items":[],"total":1,"page":1,"perPage":100,"totalPages":1}"#,
            #"{"items":[\#(watch)],"total":501,"page":1,"perPage":500,"totalPages":2}"#,
            #"{"items":[],"total":0,"page":2,"perPage":100,"totalPages":0}"#,
            #"{"items":[\#(watch)],"total":1,"page":1,"perPage":100,"totalPages":2}"#
        ] {
            let http = RecordingHTTPClient()
            http.stub(pathSuffix: "/watched", json: json)
            do { _ = try await client(http).completeHistory(); XCTFail("Incomplete history accepted") }
            catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .incompleteResponse) }
        }
    }

    func testHistoryRejectsDuplicateRecordIDs() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/watched", json: #"{"items":[\#(watch),\#(watch)],"total":2,"page":1,"perPage":500,"totalPages":1}"#)
        do { _ = try await client(http).completeHistory(); XCTFail("Duplicates accepted") }
        catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .incompleteResponse) }
    }

    func testCompleteHistoryPreservesRewatchesAndUnknownDates() async throws {
        let http = RecordingHTTPClient()
        let second = watch.replacingOccurrences(of: "play1", with: "play2")
        http.stub(pathSuffix: "/watched", json: #"{"items":[\#(watch),\#(second)],"total":2,"page":1,"perPage":500,"totalPages":1}"#)
        let rows = try await client(http).completeHistory()
        XCTAssertEqual(rows.map(\.id), ["play1", "play2"])
        XCTAssertTrue(rows.allSatisfy { $0.value.watchedAt == nil })
    }

    func testPrivateListVisibilityIsExplicit() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/lists", json: #"{"success":true,"item":{"id":"list1","name":"Private","is_public":false,"type":"custom"}}"#)
        let list = try await client(http).createList(name: "Private", isPublic: false, type: .custom)
        XCTAssertFalse(list.isPublic)
        XCTAssertEqual(http.sent.first?.json?["is_public"] as? Bool, false)
    }

    func testListURLAndRecordPathRejectScopeEscapes() throws {
        let address = try PublicMetaDB.ListAddress(url: XCTUnwrap(URL(string: "https://publicmetadb.com/lists/u/alex/my-list")))
        XCTAssertEqual(address.username, "alex")
        XCTAssertEqual(address.slug, "my-list")
        for value in [
            "https://publicmetadb.com.evil.test/lists/u/alex/my-list",
            "http://publicmetadb.com/lists/u/alex/my-list",
            "https://publicmetadb.com/lists/u/alex/my-list?key=secret",
            "https://user@publicmetadb.com/lists/u/alex/my-list"
        ] {
            XCTAssertThrowsError(try PublicMetaDB.ListAddress(url: XCTUnwrap(URL(string: value))))
        }
        for id in ["", ".", "..", "../watched", "a/b", "a\\b", "bad\n"] {
            XCTAssertThrowsError(try PublicMetaDBClient.component(id))
        }
        XCTAssertEqual(try PublicMetaDBClient.component("élise"), "élise")
    }

    func testMarkersPreserveNullAndRejectHalfRanges() throws {
        let decoder = PublicMetaDBClient.decoder()
        let prefix = #""id":"skip1","tmdb_id":1,"media_type":"tv","season":0,"episode":1,"source":"physical""#
        let valid = try decoder.decode(PublicMetaDB.Record<PublicMetaDB.Skip>.self, from:
            Data(#"{\#(prefix),"intro_start_ms":0,"intro_end_ms":1000,"credits_start_ms":null,"credits_end_ms":null}"#.utf8))
        XCTAssertEqual(valid.value.source, .physical)
        XCTAssertEqual(valid.value.intro?.startMilliseconds, 0)
        XCTAssertNil(valid.value.credits)
        for suffix in [#""intro_start_ms":0"#, #""intro_start_ms":1000,"intro_end_ms":1000"#] {
            XCTAssertThrowsError(try decoder.decode(PublicMetaDB.Record<PublicMetaDB.Skip>.self, from: Data(#"{\#(prefix),\#(suffix)}"#.utf8)))
        }
    }

    func testMovieCannotPublishRecapOrPreview() throws {
        let content = try PublicMetaDB.Content(tmdbID: 1, mediaType: .movie)
        let segment = try PublicMetaDB.Segment(startMilliseconds: 0, endMilliseconds: 1_000)
        XCTAssertThrowsError(try PublicMetaDB.Skip(content: content, source: .streaming, recap: segment))
        XCTAssertThrowsError(try PublicMetaDB.Skip(content: content, source: .streaming, preview: segment))
        XCTAssertThrowsError(try PublicMetaDB.Skip(content: content, source: .streaming))
        XCTAssertNoThrow(try PublicMetaDB.Skip(content: content, source: .streaming, intro: segment))
    }

    func testAllSixVoteCategoriesUseTheirOwnRecordPaths() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/votes", json: #"{"success":true,"vote":{"id":"vote1","vote":-1,"contributor":"test"}}"#)
        let api = try client(http)
        for category in PublicMetaDB.Contribution.allCases {
            try await api.setVote(.down, for: category, id: "record1")
        }
        XCTAssertEqual(http.sentPaths, PublicMetaDB.Contribution.allCases.map { "/api/external/\($0.rawValue)/record1/votes" })
        XCTAssertTrue(http.sent.allSatisfy { $0.json?["vote"] as? Int == -1 })
    }

    func testRatingBatch207PreservesPartialOutcomes() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/episode-ratings/batch", json: #"{"success":true,"created":1,"failed":1,"total":2,"items":[{"id":"rating1","tmdb_id":1,"season":1,"episode":1,"score":80,"label":"Overall"}]}"#, status: 207)
        let result = try await client(http).submitEpisodeRatings(
            tmdbID: 1, season: 1, label: "Overall",
            ratings: [.init(episode: 1, score: 80), .init(episode: 2, score: 70)]
        )
        XCTAssertFalse(result.isCompleteSuccess)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.items.map(\.episode), [1])
    }

    func testRatingBatchRejectsFalseAccounting() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/episode-ratings/batch", json: #"{"success":true,"deleted":2,"failed":0,"total":2,"deletedIds":["rating1"]}"#)
        do { _ = try await client(http).deleteEpisodeRatings(ids: ["rating1", "rating2"]); XCTFail("False batch success accepted") }
        catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .uncertainWrite) }
    }

    func testAnimeGroupsRetainCrossShowChunksAndSpecials() throws {
        let json = #"{"tmdb_id":1,"seasons":[{"pmdb_id":"group1","season_number":2,"season_name":"Arc","source":"community","contributor":"pmdb","votes":3,"recommended":true,"chunks":[{"id":"chunk1","tmdb_season":0,"tmdb_episode_start":1,"tmdb_episode_end":2,"chunk_tmdb_id":2}]}],"total":1}"#
        let result = try PublicMetaDBClient.decoder().decode(PublicMetaDB.AnimeSeasons.self, from: Data(json.utf8))
        XCTAssertEqual(result.seasons.first?.id, "group1")
        XCTAssertEqual(result.seasons.first?.chunks.first?.value.chunkTmdbID, 2)
        XCTAssertEqual(result.seasons.first?.chunks.first?.value.tmdbSeason, 0)
        XCTAssertEqual(result.seasons.first?.recommended, true)
    }

    func testLookupDoesNotPickAnAmbiguousIdentity() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/mappings/lookup", json: #"{"results":[{"tmdb_id":1,"media_type":"movie"},{"tmdb_id":1,"media_type":"tv"}],"total":2}"#)
        let result = try await client(http).lookup(idType: .imdb, idValue: "tt123")
        XCTAssertFalse(result.isUnambiguous)
        XCTAssertEqual(result.results.count, 2)
    }

    func testPicksRejectPageOutsideDocumentedWindowWithoutRequest() async throws {
        let http = RecordingHTTPClient()
        for page in [0, 6] {
            do { _ = try await client(http).pickItems(id: "pick1", page: page); XCTFail("Unsupported page sent") }
            catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .invalidInput) }
        }
        XCTAssertTrue(http.sent.isEmpty)
    }

    func testSeasonOnlyRatingsUseEpisodeEndpointAndRetainIncompleteCounts() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/episode-ratings", json: #"{"items":[],"total":501,"average":80}"#)
        let api = try client(http)
        let result = try await api.ratings(for: .init(tmdbID: 42, mediaType: .tv, season: 0))
        XCTAssertFalse(result.isComplete)
        _ = try await api.episodeRatings(tmdbID: 42, label: "Overall")
        XCTAssertEqual(http.sentPaths, ["/api/external/episode-ratings", "/api/external/episode-ratings"])
        XCTAssertTrue(http.sent[0].queryItems.contains(.init(name: "season", value: "0")))
        XCTAssertFalse(http.sent[0].queryItems.contains { $0.name == "episode" })
        XCTAssertTrue(http.sent[1].queryItems.contains(.init(name: "perPage", value: "500")))
    }

    func testExternalResumeLookupPreservesIDAndCoordinatesWithoutInventingTMDBID() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/resume", json: emptyPage)
        _ = try await client(http).resumePoints(idType: .mal, idValue: "5114", mediaType: .tv, season: 0, episode: 1)
        let query = try XCTUnwrap(http.sent.first).queryItems
        XCTAssertTrue(query.contains(.init(name: "id_type", value: "mal")))
        XCTAssertTrue(query.contains(.init(name: "id_value", value: "5114")))
        XCTAssertTrue(query.contains(.init(name: "season", value: "0")))
        XCTAssertFalse(query.contains { $0.name == "tmdb_id" })
    }

    func testContributionWritesRejectMismatchedValuesEvenWithSuccessFlag() async throws {
        let content = try PublicMetaDB.Content(tmdbID: 550, mediaType: .movie)
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/ratings", json: #"{"success":true,"item":{"id":"r","tmdb_id":550,"media_type":"movie","score":50,"label":"Overall"}}"#)
        http.stub(pathSuffix: "/mappings", json: #"{"success":true,"item":{"id":"m","tmdb_id":550,"media_type":"movie","id_type":"imdb","id_value":"tt999"}}"#)
        http.stub(pathSuffix: "/highlights", json: #"{"success":true,"item":{"id":"h","tmdb_id":550,"media_type":"movie","highlight_start_ms":1,"highlight_end_ms":1000}}"#)
        http.stub(pathSuffix: "/skips", json: #"{"success":true,"item":{"id":"s","tmdb_id":550,"media_type":"movie","source":"physical","intro_start_ms":0,"intro_end_ms":1000}}"#)
        let api = try client(http)
        do { _ = try await api.submitRating(.init(content: content, score: 90, label: "Overall")); XCTFail("Wrong score accepted") }
        catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .uncertainWrite) }
        do { _ = try await api.submitMapping(.init(content: content, idType: .imdb, idValue: "tt123")); XCTFail("Wrong identity accepted") }
        catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .uncertainWrite) }
        let segment = try PublicMetaDB.Segment(startMilliseconds: 0, endMilliseconds: 1000)
        do { _ = try await api.submitHighlight(.init(content: content, segment: segment)); XCTFail("Wrong segment accepted") }
        catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .uncertainWrite) }
        do { _ = try await api.submitSkip(.init(content: content, source: .streaming, intro: segment)); XCTFail("Wrong release source accepted") }
        catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .uncertainWrite) }
        XCTAssertEqual(http.sent.count, 4)
    }

    func testAnimeReplacementChecksChunkContentsRatherThanOnlyCount() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/anime-seasons", json: #"{"success":true,"tmdb_id":1,"season_number":1,"chunks":[{"id":"chunk","tmdb_season":1,"tmdb_episode_start":1,"tmdb_episode_end":12,"chunk_tmdb_id":999}]}"#)
        do {
            _ = try await client(http).replaceAnimeMapping(.init(
                tmdbID: 1, seasonNumber: 1,
                chunks: [.init(tmdbSeason: 1, tmdbEpisodeStart: 1, tmdbEpisodeEnd: 12, chunkTmdbID: 2)]
            ))
            XCTFail("Wrong cross-show chunk accepted")
        } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .uncertainWrite) }
    }

    func testListCreationCannotConfirmAnUnexpectedPublicList() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/lists", json: #"{"success":true,"item":{"id":"list1","name":"Private","is_public":true,"type":"custom"}}"#)
        do {
            _ = try await client(http).createList(name: "Private", isPublic: false, type: .custom)
            XCTFail("Public list reported as the requested private list")
        } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .uncertainWrite) }
    }

    func testPicksPreserveOpenRecipeMetadataAndRecommendationFields() throws {
        let pick = try PublicMetaDBClient.decoder().decode(PublicMetaDB.Pick.self, from: Data("""
        {"id":"p","slug":"picks","name":"Picks","seed_type":"taste","seed_params":{"list_ids":["a","b"]},
         "filters":{"media_type":"movie","new_filter":{"enabled":true,"value":null}},
         "weights":{"genre":0.75},"exclude_watched":true,"exclude_watchlist":false}
        """.utf8))
        XCTAssertEqual(pick.seedParameters?["list_ids"], .array([.string("a"), .string("b")]))
        XCTAssertEqual(pick.filters?["new_filter"], .object(["enabled": .bool(true), "value": .null]))
        XCTAssertEqual(pick.weights?["genre"], .number(Decimal(string: "0.75")!))
        let recommendation = try PublicMetaDBClient.decoder().decode(PublicMetaDB.PickItem.self, from: Data("""
        {"tmdb_id":550,"media_type":"movie","title":"Movie","genre_ids":[18],"vote_average":8.4,
         "vote_count":100,"popularity":15,"original_language":"en","reasons":["Genre match"]}
        """.utf8))
        XCTAssertEqual(recommendation.genreIDs, [18])
        XCTAssertEqual(recommendation.voteCount, 100)
        XCTAssertEqual(recommendation.originalLanguage, "en")
    }
}
