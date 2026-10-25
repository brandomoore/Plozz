import CoreModels
import CoreSecureStore
import Foundation
import XCTest
@testable import PublicMetaDBService
@testable import TestSupportNetworking

private let contributionJSON = #"{"id":"rating-a","tmdb_id":550,"media_type":"movie","label":"Acting","score":85,"contributor":"author","updated":"2026-10-24T00:00:00Z"}"#
private func ratingsJSON(_ records: [String]) -> String {
    #"{"items":[\#(records.joined(separator: ","))],"total":\#(records.count),"average":null}"#
}
private func votesJSON(_ vote: Int? = nil) -> String {
    let item = vote.map { #"{"id":"vote-a","vote":\#($0),"contributor":"viewer"}"# } ?? ""
    let up = vote == 1 ? 1 : 0
    let down = vote == -1 ? 1 : 0
    return #"{"items":[\#(item)],"total":\#(vote == nil ? 0 : 1),"summary":{"upvotes":\#(up),"downvotes":\#(down),"score":\#(up-down)},"userVote":\#(vote.map(String.init) ?? "null")}"#
}

@MainActor
final class PublicMetaDBContributionManagementTests: XCTestCase {
    private func withService(
        _ body: (PublicMetaDBService, RecordingHTTPClient, UUID) async throws -> Void
    ) async throws {
        let name = "PublicMetaDBContributionManagementTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/lists", json: #"{"items":[],"total":0,"page":1,"perPage":1,"totalPages":0}"#)
        let service = PublicMetaDBService(
            credentials: ContributionCredentials(), http: http, defaults: defaults,
            watchlistReceiptStore: try DurableLocalStateStore(secureStore: InMemorySecureStore())
        )
        let key = "pm-" + (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").prefix(60)
        await service.connect(key: key)
        try await body(service, http, XCTUnwrap(service.connectionID))
    }

    private func record(_ json: String = contributionJSON) throws -> PublicMetaDB.Record<PublicMetaDB.Rating> {
        try PublicMetaDBClient.decoder().decode(PublicMetaDB.Record<PublicMetaDB.Rating>.self, from: Data(json.utf8))
    }

    func testSubmissionPreservesLabelAndRequiresIndependentExactReadback() async throws {
        try await withService { service, http, connection in
            http.stub(pathSuffix: "/ratings", json: ratingsJSON([]))
            http.stub(pathSuffix: "/ratings", json: #"{"success":true,"item":\#(contributionJSON)}"#)
            http.stub(pathSuffix: "/ratings", json: ratingsJSON([contributionJSON]))
            try await service.submitManagedRating(record().value, expectedConnectionID: connection)
            XCTAssertEqual(http.sentPaths.suffix(3), Array(repeating: "/api/external/ratings", count: 3))
            let write = try XCTUnwrap(http.sent.first(where: { $0.body != nil }))
            XCTAssertEqual(write.json?["label"] as? String, "Acting")
            XCTAssertEqual(write.json?["score"] as? Int, 85)
            XCTAssertFalse(service.communityRatingsEnabled)
            XCTAssertNil(service.playbackConsent)
            XCTAssertNil(service.watchlistSelection)
            XCTAssertFalse(http.sentPaths.contains(where: { $0.contains("watched") || $0.contains("resume") }))
        }
    }

    func testEpisodeSubmissionUsesEpisodeIdentityRatherThanEpisodeTMDBID() async throws {
        try await withService { service, http, connection in
            let episode = contributionJSON.replacingOccurrences(
                of: #""media_type":"movie""#, with: #""media_type":"tv","season":0,"episode":1"#
            )
            http.stub(pathSuffix: "/episode-ratings", json: ratingsJSON([]))
            http.stub(pathSuffix: "/episode-ratings", json: #"{"success":true,"item":\#(episode)}"#)
            http.stub(pathSuffix: "/episode-ratings", json: ratingsJSON([episode]))
            try await service.submitManagedRating(record(episode).value, expectedConnectionID: connection)
            XCTAssertEqual(http.sentPaths.suffix(3), Array(repeating: "/api/external/episode-ratings", count: 3))
            let write = try XCTUnwrap(http.sent.first(where: { $0.body != nil }))
            XCTAssertEqual(write.json?["tmdb_id"] as? Int, 550)
            XCTAssertEqual(write.json?["season"] as? Int, 0)
            XCTAssertEqual(write.json?["episode"] as? Int, 1)
        }
    }

    func testAmbiguousSubmissionNeverAutomaticallyRepeatsOrAssumesOwnership() async throws {
        for response in ["{}", #"{"success":true,"item":{}}"#] {
            try await withService { service, http, connection in
                http.stub(pathSuffix: "/ratings", json: ratingsJSON([]))
                http.stub(pathSuffix: "/ratings", json: response)
                do {
                    try await service.submitManagedRating(record().value, expectedConnectionID: connection)
                    XCTFail("Uncertain creation accepted")
                } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .uncertainWrite) }
                XCTAssertEqual(http.sent.filter { $0.body != nil }.count, 1)
                XCTAssertEqual(http.sent.count, 3)
            }
        }
    }

    func testSubmissionRejectsMissingOrChangedReadback() async throws {
        for after in [ratingsJSON([]), ratingsJSON([contributionJSON.replacingOccurrences(of: "85", with: "84")])] {
            try await withService { service, http, connection in
                http.stub(pathSuffix: "/ratings", json: ratingsJSON([]))
                http.stub(pathSuffix: "/ratings", json: #"{"success":true,"item":\#(contributionJSON)}"#)
                http.stub(pathSuffix: "/ratings", json: after)
                do {
                    try await service.submitManagedRating(record().value, expectedConnectionID: connection)
                    XCTFail("Unconfirmed value accepted")
                } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .uncertainWrite) }
                XCTAssertEqual(http.sent.filter { $0.body != nil }.count, 1)
            }
        }
    }

    func testIncompleteOrForeignRecordsBlockWritesBeforeSubmission() async throws {
        for response in [
            ratingsJSON([contributionJSON]).replacingOccurrences(of: #""total":1"#, with: #""total":2"#),
            ratingsJSON([contributionJSON, contributionJSON]),
            ratingsJSON([contributionJSON.replacingOccurrences(of: "550", with: "999")])
        ] {
            try await withService { service, http, connection in
                http.stub(pathSuffix: "/ratings", json: response)
                do {
                    try await service.submitManagedRating(record().value, expectedConnectionID: connection)
                    XCTFail("Incomplete baseline admitted")
                } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .incompleteResponse) }
                XCTAssertFalse(http.sent.contains(where: { $0.body != nil }))
            }
        }
    }

    func testChangedRatingBlocksStaleDeletion() async throws {
        for current in [
            contributionJSON.replacingOccurrences(of: "85", with: "86"),
            contributionJSON.replacingOccurrences(of: "author", with: "different-author"),
            contributionJSON.replacingOccurrences(of: "2026-10-24", with: "2026-10-25")
        ] {
            try await withService { service, http, connection in
                http.stub(pathSuffix: "/ratings", json: ratingsJSON([current]))
                do {
                    try await service.deleteManagedRating(record(), expectedConnectionID: connection)
                    XCTFail("Stale deletion admitted")
                } catch { XCTAssertEqual(error as? AppError, .conflict) }
                XCTAssertFalse(http.sentPaths.contains("/api/external/ratings/rating-a"))
            }
        }
    }

    func testExactDeletionPreservesOtherRatingsAndConfirmsAnUncertainReply() async throws {
        try await withService { service, http, connection in
            let other = contributionJSON.replacingOccurrences(of: "rating-a", with: "rating-b")
            http.stub(pathSuffix: "/ratings", json: ratingsJSON([contributionJSON, other]))
            http.stub(pathSuffix: "/ratings", json: ratingsJSON([other]))
            http.stub(pathSuffix: "/rating-a", json: "{}", status: 503)
            try await service.deleteManagedRating(record(), expectedConnectionID: connection)
            XCTAssertEqual(http.sentPaths.suffix(3), [
                "/api/external/ratings", "/api/external/ratings/rating-a", "/api/external/ratings"
            ])
        }
    }

    func testServerOwnershipRejectionIsNotConvertedToSuccess() async throws {
        try await withService { service, http, connection in
            http.stub(pathSuffix: "/ratings", json: ratingsJSON([contributionJSON]))
            http.stub(pathSuffix: "/rating-a", json: "{}", status: 403)
            do {
                try await service.deleteManagedRating(record(), expectedConnectionID: connection)
                XCTFail("Ownership rejection ignored")
            } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .blocked) }
            XCTAssertEqual(http.sent.count, 3)
        }
    }

    func testAlreadyAbsentRatingDoesNotDeleteAnotherRecord() async throws {
        try await withService { service, http, connection in
            http.stub(pathSuffix: "/ratings", json: ratingsJSON([]))
            try await service.deleteManagedRating(record(), expectedConnectionID: connection)
            XCTAssertFalse(http.sentPaths.contains("/api/external/ratings/rating-a"))
        }
    }

    func testVoteDistinguishesNeutralFromRemovalAndUsesOwnVote() async throws {
        for value in [PublicMetaDB.Vote.up, .down, .neutral] {
            try await withService { service, http, connection in
                http.stub(pathSuffix: "/votes", json: votesJSON())
                http.stub(pathSuffix: "/votes", json: #"{"success":true}"#)
                http.stub(pathSuffix: "/votes", json: votesJSON(value.rawValue))
                try await service.changeContributionVote(
                    value, category: .ratings, recordID: "rating-a", observedVote: nil, expectedConnectionID: connection
                )
                XCTAssertEqual(http.sent.last?.queryItems.first(where: { $0.name == "all" })?.value, "false")
                XCTAssertEqual(http.sent.first(where: { $0.body != nil })?.json?["vote"] as? Int, value.rawValue)
            }
        }
        try await withService { service, http, connection in
            http.stub(pathSuffix: "/votes", json: votesJSON(0))
            http.stub(pathSuffix: "/votes", json: #"{"success":true}"#)
            http.stub(pathSuffix: "/votes", json: votesJSON())
            try await service.changeContributionVote(
                nil, category: .ratings, recordID: "rating-a", observedVote: .neutral, expectedConnectionID: connection
            )
            XCTAssertTrue(http.sent.allSatisfy { $0.body == nil })
            XCTAssertEqual(http.sent.count, 4)
        }
    }

    func testChangedOwnVotePreventsOverwritingConcurrentVote() async throws {
        try await withService { service, http, connection in
            http.stub(pathSuffix: "/votes", json: votesJSON(-1))
            do {
                try await service.changeContributionVote(
                    .up, category: .ratings, recordID: "rating-a", observedVote: nil, expectedConnectionID: connection
                )
                XCTFail("Concurrent vote overwritten")
            } catch { XCTAssertEqual(error as? AppError, .conflict) }
            XCTAssertEqual(http.sent.count, 2)
        }
    }

    func testIncompleteVoteStateIsNotInterpretedAsNoVote() async throws {
        for response in [
            votesJSON().replacingOccurrences(of: #","userVote":null"#, with: ""),
            votesJSON(1).replacingOccurrences(of: #""userVote":1"#, with: #""userVote":null"#),
            votesJSON(1).replacingOccurrences(of: #""upvotes":1"#, with: #""upvotes":0"#),
            votesJSON(1).replacingOccurrences(of: #""total":1"#, with: #""total":0"#)
        ] {
            try await withService { service, http, connection in
                http.stub(pathSuffix: "/votes", json: response)
                do {
                    _ = try await service.contributionVotes(.ratings, recordID: "rating-a", expectedConnectionID: connection)
                    XCTFail("Incomplete own-vote state accepted")
                } catch {}
                XCTAssertEqual(http.sent.count, 2)
            }
        }
    }

    func testVoteAcknowledgementWithoutReadbackRemainsUncertain() async throws {
        try await withService { service, http, connection in
            http.stub(pathSuffix: "/votes", json: votesJSON())
            http.stub(pathSuffix: "/votes", json: #"{"success":true}"#)
            http.stub(pathSuffix: "/votes", json: votesJSON())
            do {
                try await service.changeContributionVote(
                    .up, category: .ratings, recordID: "rating-a", observedVote: nil, expectedConnectionID: connection
                )
                XCTFail("Unconfirmed vote accepted")
            } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .uncertainWrite) }
            XCTAssertEqual(http.sent.filter { $0.body != nil }.count, 1)
        }
    }

    func testProfileChangeClosesTitleAndRejectsOldConfirmationWithoutRequests() async throws {
        try await withService { service, http, connection in
            let item = MediaItem(id: "server-id", title: "Curated server title", kind: .movie, providerIDs: ["Tmdb": "550"])
            try service.presentContent(for: item)
            XCTAssertEqual(service.presentedItem?.title, item.title)
            XCTAssertEqual(http.sent.count, 1)
            service.selectProfile(namespace: "different-profile")
            XCTAssertNil(service.presentedItem)
            do {
                try await service.submitManagedRating(record().value, expectedConnectionID: connection)
                XCTFail("Old confirmation admitted")
            } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .connectionChanged) }
            XCTAssertEqual(http.sent.count, 1)
        }
    }

    func testConfirmedMutationInvalidatesCachedCommunityClients() async throws {
        try await withService { service, http, connection in
            let item = MediaItem(id: "movie", title: "Movie", kind: .movie, providerIDs: ["Tmdb": "550"])
            service.setCommunityRatingsEnabled(true)
            let (oldClient, _) = try service.communityRatingsClient()
            let rating = try record().value
            service.communityRatingsCache[rating.content] = .init(expires: .distantFuture, ratings: [])
            http.stub(pathSuffix: "/ratings", json: ratingsJSON([]))
            http.stub(pathSuffix: "/ratings", json: #"{"success":true,"item":\#(contributionJSON)}"#)
            http.stub(pathSuffix: "/ratings", json: ratingsJSON([contributionJSON]))
            try await service.submitManagedRating(rating, expectedConnectionID: connection)
            XCTAssertNil(service.cachedCommunityRatings(for: item))
            let count = http.sent.count
            do { _ = try await oldClient.ratings(for: rating.content); XCTFail("Old aggregate request admitted") }
            catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .connectionChanged) }
            XCTAssertEqual(http.sent.count, count)
        }
    }

    func testSkipPublicationPreservesPhysicalReleaseAndMillisecondRanges() async throws {
        try await withService { service, http, connection in
            let json = #"{"id":"skip-a","tmdb_id":550,"media_type":"movie","source":"physical","intro_start_ms":1000.5,"intro_end_ms":5000}"#
            http.stub(pathSuffix: "/skips", json: skipPage([]))
            http.stub(pathSuffix: "/skips", json: #"{"success":true,"item":\#(json)}"#)
            http.stub(pathSuffix: "/skips", json: skipPage([json]))
            let record = try PublicMetaDBClient.decoder().decode(PublicMetaDB.Record<PublicMetaDB.Skip>.self, from: Data(json.utf8))
            try await service.submitManagedSkip(record.value, expectedConnectionID: connection)
            let body = try XCTUnwrap(http.sent.first(where: { $0.body != nil })?.json)
            XCTAssertEqual(body["source"] as? String, "physical")
            XCTAssertEqual(body["intro_start_ms"] as? Double, 1000.5)
            XCTAssertEqual(body["intro_end_ms"] as? Double, 5000)
            XCTAssertNil(body["recap_start_ms"])
            XCTAssertEqual(http.sent.count, 4)
        }
    }

    func testPlaybackTimestampsRemainSeparateContributionsAndDoNotFetchHighlightsByDefault() async throws {
        try await withService { service, http, _ in
            let source = try XCTUnwrap(service.playbackTimestampSource)
            let json = #"{"id":"skip-a","tmdb_id":550,"media_type":"movie","source":"physical","intro_start_ms":1000.5,"intro_end_ms":5000,"contributor":"author"}"#
            let other = json.replacingOccurrences(of: "skip-a", with: "skip-b")
                .replacingOccurrences(of: "physical", with: "streaming")
                .replacingOccurrences(of: "5000", with: "9000")
            http.stub(pathSuffix: "/skips", json: skipPage([json, other]))
            let item = MediaItem(id: "movie", title: "Movie", kind: .movie, providerIDs: ["Tmdb": "550"])
            let entries = try await source.timestamps(for: item, includeHighlights: false)
            XCTAssertEqual(entries.count, 2)
            XCTAssertEqual(entries[0].start, 1.0005)
            XCTAssertEqual(entries[0].end, 5)
            XCTAssertEqual(entries[0].release, .physical)
            XCTAssertEqual(entries[0].contributor, "author")
            XCTAssertEqual(entries[1].release, .streaming)
            XCTAssertEqual(entries[1].end, 9)
            XCTAssertNotEqual(entries[0].id, entries[1].id)
            XCTAssertEqual(http.sentPaths, ["/api/external/lists", "/api/external/skips"])
            XCTAssertTrue(http.sent.allSatisfy { $0.body == nil })
        }
    }

    func testPlaybackHighlightsAreExplicitAndCannotCollideWithSkipRecordIDs() async throws {
        try await withService { service, http, _ in
            let source = try XCTUnwrap(service.playbackTimestampSource)
            let skip = #"{"id":"same","tmdb_id":550,"media_type":"movie","intro_start_ms":0,"intro_end_ms":1000}"#
            let highlight = #"{"id":"same","tmdb_id":550,"media_type":"movie","highlight_start_ms":2000,"highlight_end_ms":5000,"description":"Spoiler"}"#
            http.stub(pathSuffix: "/skips", json: skipPage([skip]))
            http.stub(pathSuffix: "/highlights", json: ratingsJSON([highlight]))
            let result = try await source.timestamps(
                for: .init(id: "movie", title: "Movie", kind: .movie, providerIDs: ["Tmdb": "550"]),
                includeHighlights: true
            )
            XCTAssertEqual(result.map(\.kind), [.intro, .highlight])
            XCTAssertEqual(result.map(\.release), [.unknown, .unknown])
            XCTAssertEqual(Set(result.map(\.id)).count, 2)
            XCTAssertEqual(result[1].description, "Spoiler")
            XCTAssertEqual(result[1].start, 2)
            XCTAssertTrue(http.sent.allSatisfy { $0.body == nil })
        }
    }

    func testTimestampSourceRejectsUnknownEpisodeOrderAndConflictingMovieIdentity() async throws {
        try await withService { service, http, _ in
            let source = try XCTUnwrap(service.playbackTimestampSource)
            var episode = MediaItem(id: "episode", title: "Episode", kind: .episode, providerIDs: ["SeriesTmdb": "550"])
            episode.seasonNumber = 1
            episode.episodeNumber = 2
            let conflict = MediaItem(id: "movie", title: "Movie", kind: .movie, providerIDs: ["Tmdb": "550", "tmdb": "551"])
            for item in [episode, conflict] {
                do {
                    _ = try await source.timestamps(for: item, includeHighlights: false)
                    XCTFail("Ambiguous timestamp identity admitted")
                } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .invalidInput) }
            }
            XCTAssertEqual(http.sent.count, 1)
        }
    }

    func testRefreshingSameConnectionOrSwitchingProfileRevokesOldTimestampSource() async throws {
        try await withService { service, http, connection in
            let old = try XCTUnwrap(service.playbackTimestampSource)
            await service.refreshStatus()
            XCTAssertEqual(service.connectionID, connection)
            XCTAssertFalse(old.isCurrent)
            let current = try XCTUnwrap(service.playbackTimestampSource)
            XCTAssertTrue(current.isCurrent)
            service.selectProfile(namespace: "other")
            XCTAssertFalse(current.isCurrent)
            XCTAssertNil(service.playbackTimestampSource)
            let before = http.sent.count
            for source in [old, current] {
                do {
                    _ = try await source.timestamps(
                        for: .init(id: "movie", title: "Movie", kind: .movie, providerIDs: ["Tmdb": "550"]),
                        includeHighlights: true
                    )
                    XCTFail("Revoked source admitted")
                } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .connectionChanged) }
            }
            XCTAssertEqual(http.sent.count, before)
        }
    }

    func testHighlightPublicationRequiresExactDescriptionAndRangeReadback() async throws {
        let json = #"{"id":"highlight-a","tmdb_id":550,"media_type":"movie","highlight_start_ms":1000,"highlight_end_ms":5000,"description":"Scene"}"#
        for matches in [true, false] {
            try await withService { service, http, connection in
                http.stub(pathSuffix: "/highlights", json: ratingsJSON([]))
                http.stub(pathSuffix: "/highlights", json: #"{"success":true,"item":\#(json)}"#)
                http.stub(pathSuffix: "/highlights", json: ratingsJSON([
                    matches ? json : json.replacingOccurrences(of: "Scene", with: "Different")
                ]))
                let record = try PublicMetaDBClient.decoder().decode(PublicMetaDB.Record<PublicMetaDB.Highlight>.self, from: Data(json.utf8))
                do {
                    try await service.submitManagedHighlight(record.value, expectedConnectionID: connection)
                    XCTAssertTrue(matches)
                } catch {
                    XCTAssertFalse(matches)
                    XCTAssertEqual(error as? PublicMetaDB.Failure, .uncertainWrite)
                }
                XCTAssertEqual(http.sent.filter { $0.body != nil }.count, 1)
            }
        }
    }

    func testChangedSkipReleaseBlocksDeletionFromOldObservation() async throws {
        try await withService { service, http, connection in
            let json = #"{"id":"skip-a","tmdb_id":550,"media_type":"movie","source":"physical","intro_start_ms":1000,"intro_end_ms":5000}"#
            let record = try PublicMetaDBClient.decoder().decode(PublicMetaDB.Record<PublicMetaDB.Skip>.self, from: Data(json.utf8))
            http.stub(pathSuffix: "/skips", json: skipPage([json.replacingOccurrences(of: "physical", with: "streaming")]))
            do {
                try await service.deleteManagedSkip(record, expectedConnectionID: connection)
                XCTFail("Changed release removed")
            } catch { XCTAssertEqual(error as? AppError, .conflict) }
            XCTAssertFalse(http.sentPaths.contains("/api/external/skips/skip-a"))
        }
    }

    func testSkipDeletionConfirmsOnlyExactRecordAbsence() async throws {
        try await withService { service, http, connection in
            let json = #"{"id":"skip-a","tmdb_id":550,"media_type":"movie","source":"streaming","intro_start_ms":1000,"intro_end_ms":5000}"#
            let other = json.replacingOccurrences(of: "skip-a", with: "skip-b")
            let record = try PublicMetaDBClient.decoder().decode(PublicMetaDB.Record<PublicMetaDB.Skip>.self, from: Data(json.utf8))
            http.stub(pathSuffix: "/skips", json: skipPage([json, other]))
            http.stub(pathSuffix: "/skips", json: skipPage([other]))
            http.stub(pathSuffix: "/skip-a", json: #"{"success":true}"#)
            try await service.deleteManagedSkip(record, expectedConnectionID: connection)
            XCTAssertEqual(http.sentPaths.suffix(3), [
                "/api/external/skips", "/api/external/skips/skip-a", "/api/external/skips"
            ])
        }
    }

    func testHighlightDeletionReadbackDoesNotTreatForeignContentAsAbsence() async throws {
        try await withService { service, http, connection in
            let json = #"{"id":"highlight-a","tmdb_id":550,"media_type":"movie","highlight_start_ms":1000,"highlight_end_ms":5000}"#
            let record = try PublicMetaDBClient.decoder().decode(PublicMetaDB.Record<PublicMetaDB.Highlight>.self, from: Data(json.utf8))
            http.stub(pathSuffix: "/highlights", json: ratingsJSON([json]))
            http.stub(pathSuffix: "/highlights", json: ratingsJSON([json.replacingOccurrences(of: "550", with: "999")]))
            http.stub(pathSuffix: "/highlight-a", json: #"{"success":true}"#)
            do {
                try await service.deleteManagedHighlight(record, expectedConnectionID: connection)
                XCTFail("Foreign collection confirmed deletion")
            } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .uncertainWrite) }
            XCTAssertEqual(http.sentPaths.filter { $0.hasSuffix("/highlight-a") }.count, 1)
        }
    }

    func testForeignAndDuplicateHighlightsAreNotDisplayedAsThisTitle() async throws {
        let json = #"{"id":"highlight-a","tmdb_id":550,"media_type":"movie","highlight_start_ms":1000,"highlight_end_ms":5000}"#
        for records in [[json, json], [json.replacingOccurrences(of: "550", with: "999")]] {
            try await withService { service, http, connection in
                http.stub(pathSuffix: "/highlights", json: ratingsJSON(records))
                do {
                    _ = try await service.highlightsForManagement(.init(tmdbID: 550, mediaType: .movie), expectedConnectionID: connection)
                    XCTFail("Invalid highlights accepted")
                } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .incompleteResponse) }
            }
        }
    }

    func testSeasonIdentityRequiresConfirmedTMDBOrderingAndParentNamespace() {
        var season = MediaItem(id: "season", title: "Season", kind: .season, seasonNumber: 0, providerIDs: ["SeriesTmdb": "550"])
        XCTAssertNil(PublicMetaDB.Content.matching(season))
        season.episodeOrdering = .tmdb
        XCTAssertEqual(PublicMetaDB.Content.matching(season)?.season, 0)
        XCTAssertNil(PublicMetaDBService.ratingContent(season))
        season.providerIDs = ["Tmdb": "550"]
        XCTAssertNil(PublicMetaDB.Content.matching(season))
    }

    private func skipPage(_ records: [String]) -> String {
        #"{"items":[\#(records.joined(separator: ","))],"total":\#(records.count),"page":1,"perPage":200,"totalPages":\#(records.isEmpty ? 0 : 1)}"#
    }

    private func episodeJSON(_ episode: Int, id: String? = nil) -> String {
        #"{"id":"\#(id ?? "episode-\(episode)")","tmdb_id":550,"media_type":"tv","season":1,"episode":\#(episode),"label":"Overall","score":85,"contributor":"author"}"#
    }

    private func seasonJSON(_ records: [String]) throws -> String {
        let values = try records.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        let groups = Dictionary(grouping: values) { $0["episode"] as? Int ?? 0 }
        let episodes: [[String: Any]] = groups.keys.sorted().map { number in
            let ratings = groups[number] ?? []
            return [
                "episode": number, "total": ratings.count, "ratings": ratings,
                "aggregates": ["Overall": ["label": "Overall", "count": ratings.count, "average": 85]]
            ]
        }
        let response: [String: Any] = [
            "tmdb_id": 550, "media_type": "tv", "season": 1, "episodes": episodes,
            "totalRatings": records.count, "episodeCount": episodes.count,
            "seasonAverage": records.isEmpty ? NSNull() : 85
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
    }

    func testSeasonCompleteBoundaryRejectsPotentiallyCappedFiveThousandRecords() async throws {
        for count in [4_999, 5_000] {
            try await withService { service, http, connection in
                http.stub(pathSuffix: "/episode-ratings/batch", json: try seasonJSON(
                    (1...count).map { episodeJSON(1, id: "rating-\($0)") }
                ))
                do {
                    let result = try await service.seasonRatingsForManagement(tmdbID: 550, season: 1, expectedConnectionID: connection)
                    XCTAssertEqual(count, 4_999)
                    XCTAssertEqual(result.totalRatings, count)
                } catch {
                    XCTAssertEqual(count, 5_000)
                    XCTAssertEqual(error as? PublicMetaDB.Failure, .incompleteResponse)
                }
            }
        }
    }

    func testSeasonRejectsForeignContentAndDuplicateEpisodeRecords() async throws {
        for records in [
            [episodeJSON(1), episodeJSON(1)],
            [episodeJSON(1).replacingOccurrences(of: #""tmdb_id":550"#, with: #""tmdb_id":999"#)]
        ] {
            try await withService { service, http, connection in
                http.stub(pathSuffix: "/episode-ratings/batch", json: try seasonJSON(records))
                do {
                    _ = try await service.seasonRatingsForManagement(tmdbID: 550, season: 1, expectedConnectionID: connection)
                    XCTFail("Invalid complete season accepted")
                } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .incompleteResponse) }
            }
        }
    }

    func testEpisodeBatchPartialOutcomeKeepsConfirmedAndUnconfirmedEpisodesSeparate() async throws {
        try await withService { service, http, connection in
            let first = episodeJSON(1)
            http.stub(pathSuffix: "/episode-ratings/batch", json: try seasonJSON([]))
            http.stub(pathSuffix: "/episode-ratings/batch", json:
                #"{"success":false,"created":1,"failed":1,"total":2,"items":[\#(first)]}"#, status: 207)
            http.stub(pathSuffix: "/episode-ratings/batch", json: try seasonJSON([first]))
            do {
                try await service.submitManagedEpisodeRatings(
                    tmdbID: 550, season: 1, label: "Overall",
                    ratings: [.init(episode: 1, score: 85), .init(episode: 2, score: 85)],
                    expectedConnectionID: connection
                )
                XCTFail("Partial batch reported as full success")
            } catch {
                let partial = try XCTUnwrap(error as? PublicMetaDB.RatingBatchFailure)
                XCTAssertEqual(partial.confirmedRecordIDs, ["episode-1"])
                XCTAssertEqual(partial.unconfirmedEpisodes, [2])
                XCTAssertEqual(partial.unconfirmedCount, 1)
            }
            XCTAssertEqual(http.sent.filter { $0.body != nil }.count, 1)
        }
    }

    func testFiftyEpisodeBatchNeedsAllReturnedIDsInReadback() async throws {
        try await withService { service, http, connection in
            let records = (1...50).map { episodeJSON($0) }
            http.stub(pathSuffix: "/episode-ratings/batch", json: try seasonJSON([]))
            http.stub(pathSuffix: "/episode-ratings/batch", json:
                #"{"success":true,"created":50,"failed":0,"total":50,"items":[\#(records.joined(separator: ","))]}"#)
            http.stub(pathSuffix: "/episode-ratings/batch", json: try seasonJSON(records))
            try await service.submitManagedEpisodeRatings(
                tmdbID: 550, season: 1, label: "Overall",
                ratings: (1...50).map { try .init(episode: $0, score: 85) }, expectedConnectionID: connection
            )
            XCTAssertEqual(http.sent.filter { $0.body != nil }.count, 1)
            XCTAssertEqual((http.sent.first { $0.body != nil }?.json?["ratings"] as? [Any])?.count, 50)
        }
    }

    func testFiftyOneOrDuplicateEpisodesAreRejectedBeforeNetwork() async throws {
        try await withService { service, http, connection in
            for ratings in [
                try (1...51).map { try PublicMetaDB.EpisodeRatingInput(episode: $0, score: 85) },
                try [.init(episode: 1, score: 85), PublicMetaDB.EpisodeRatingInput(episode: 1, score: 90)]
            ] {
                do {
                    try await service.submitManagedEpisodeRatings(
                        tmdbID: 550, season: 1, label: "Overall", ratings: ratings, expectedConnectionID: connection
                    )
                    XCTFail("Invalid selection dispatched")
                } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .invalidInput) }
            }
            XCTAssertEqual(http.sent.count, 1)
        }
    }

    func testEpisodeBatchDeletionRetainsUnconfirmedIDsWithoutDeletingUnselectedRecords() async throws {
        try await withService { service, http, connection in
            let first = episodeJSON(1), second = episodeJSON(2), unselected = episodeJSON(3)
            http.stub(pathSuffix: "/episode-ratings/batch", json: try seasonJSON([first, second, unselected]))
            http.stub(pathSuffix: "/episode-ratings/batch", json:
                #"{"success":false,"deleted":1,"failed":1,"total":2,"deletedIds":["episode-1"]}"#, status: 207)
            http.stub(pathSuffix: "/episode-ratings/batch", json: try seasonJSON([second, unselected]))
            do {
                try await service.deleteManagedEpisodeRatings([record(first), record(second)], expectedConnectionID: connection)
                XCTFail("Partial deletion reported as successful")
            } catch {
                let partial = try XCTUnwrap(error as? PublicMetaDB.RatingBatchFailure)
                XCTAssertEqual(partial.confirmedRecordIDs, ["episode-1"])
                XCTAssertEqual(partial.unconfirmedRecordIDs, ["episode-2"])
            }
            XCTAssertEqual(http.sent.first(where: { $0.body != nil })?.json?["ids"] as? [String], ["episode-1", "episode-2"])
        }
    }

    func testEpisodeBatchDeletionRechecksEverySelectedRecordBeforeDispatch() async throws {
        try await withService { service, http, connection in
            let first = episodeJSON(1), second = episodeJSON(2)
            let changed = second.replacingOccurrences(of: #""score":85"#, with: #""score":86"#)
            http.stub(pathSuffix: "/episode-ratings/batch", json: try seasonJSON([first, changed]))
            do {
                try await service.deleteManagedEpisodeRatings([record(first), record(second)], expectedConnectionID: connection)
                XCTFail("Concurrent rating change overwritten")
            } catch { XCTAssertEqual(error as? AppError, .conflict) }
            XCTAssertFalse(http.sent.contains(where: { $0.body != nil }))
        }
    }
}

private final class ContributionCredentials: PublicMetaDBCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: PublicMetaDBCredentials] = [:]
    func load(namespace: String?) -> PublicMetaDBCredentials? { lock.withLock { values[namespace ?? "default"] } }
    func save(_ credentials: PublicMetaDBCredentials, namespace: String?) throws {
        lock.withLock { values[namespace ?? "default"] = credentials }
    }
    func clear(namespace: String?) throws { _ = lock.withLock { values.removeValue(forKey: namespace ?? "default") } }
}
