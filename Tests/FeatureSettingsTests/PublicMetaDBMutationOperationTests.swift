import Observation
import XCTest
@testable import FeatureSettings
@testable import PublicMetaDBService

@MainActor
final class PublicMetaDBMutationOperationTests: XCTestCase {
    func testAnimeChunkDraftPreservesUnspecifiedRangesAndCrossShowSpecials() throws {
        let unbounded = try PublicMetaDBAnimeChunkDraft(season: "1").chunk()
        XCTAssertNil(unbounded.tmdbEpisodeStart)
        XCTAssertNil(unbounded.tmdbEpisodeEnd)
        XCTAssertNil(unbounded.chunkTmdbID)
        let special = try PublicMetaDBAnimeChunkDraft(
            season: "0", firstEpisode: "1", lastEpisode: "2", showID: "200"
        ).chunk()
        XCTAssertEqual(special.tmdbSeason, 0)
        XCTAssertEqual(special.chunkTmdbID, 200)
        for draft in [
            PublicMetaDBAnimeChunkDraft(season: ""),
            PublicMetaDBAnimeChunkDraft(season: "-1"),
            PublicMetaDBAnimeChunkDraft(season: "1", firstEpisode: "0"),
            PublicMetaDBAnimeChunkDraft(season: "1", firstEpisode: "3", lastEpisode: "2"),
            PublicMetaDBAnimeChunkDraft(season: "1", lastEpisode: "not a number"),
            PublicMetaDBAnimeChunkDraft(season: "1", showID: "0")
        ] {
            XCTAssertThrowsError(try draft.chunk())
        }
    }

    func testEpisodeRatingDraftRequiresOneToFiftyUniquePositiveEpisodeNumbers() throws {
        XCTAssertThrowsError(try PublicMetaDBEpisodeRatingDraft.inputs([]))
        let fifty = (1...50).map { PublicMetaDBEpisodeRatingDraft(episode: String($0)) }
        XCTAssertEqual(try PublicMetaDBEpisodeRatingDraft.inputs(fifty).count, 50)
        XCTAssertThrowsError(try PublicMetaDBEpisodeRatingDraft.inputs(fifty + [.init(episode: "51")]))
        XCTAssertThrowsError(try PublicMetaDBEpisodeRatingDraft.inputs([.init(episode: "1"), .init(episode: "01")]))
        XCTAssertThrowsError(try PublicMetaDBEpisodeRatingDraft.inputs([.init(episode: "0")]))
        XCTAssertThrowsError(try PublicMetaDBEpisodeRatingDraft.inputs([.init(episode: "1.5")]))
        XCTAssertThrowsError(try PublicMetaDBEpisodeRatingDraft.inputs([.init(episode: "1", score: 101)]))
    }

    func testPartiallyConfirmedEpisodeBatchCannotBeReplayed() async {
        let model = PublicMetaDBMutationOperation()
        let done = expectation(description: "Partial rating batch finished")
        model.perform {
            defer { done.fulfill() }
            throw PublicMetaDB.RatingBatchFailure(
                confirmedRecordIDs: ["rating-a"], unconfirmedEpisodes: [2], unconfirmedRecordIDs: []
            )
        }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertFalse(model.succeeded)
        XCTAssertFalse(model.permitsWrite)
        model.perform { XCTFail("Partial batch replayed") }
    }

    func testCommunitySegmentDraftPreservesMillisecondsAndAbsentPairs() throws {
        XCTAssertNil(try PublicMetaDBSegmentDraft().segment())
        let segment = try XCTUnwrap(PublicMetaDBSegmentDraft(start: "1500.5", end: "2500").segment())
        XCTAssertEqual(segment.startMilliseconds, 1500.5)
        XCTAssertEqual(segment.endMilliseconds, 2500)
        for draft in [
            PublicMetaDBSegmentDraft(start: "1", end: ""),
            PublicMetaDBSegmentDraft(start: "", end: "2"),
            PublicMetaDBSegmentDraft(start: "2", end: "1"),
            PublicMetaDBSegmentDraft(start: "1", end: "1"),
            PublicMetaDBSegmentDraft(start: "-1", end: "2"),
            PublicMetaDBSegmentDraft(start: "nan", end: "2"),
            PublicMetaDBSegmentDraft(start: "1", end: "inf")
        ] {
            XCTAssertThrowsError(try draft.segment())
        }
    }

    func testTVHistoryDatesRequireValidCalendarFieldsAndAnExplicitTimeZone() {
        let expected = PublicMetaDBHistoryDateView.parsedDate("2026-01-15T20:30:00Z")
        XCTAssertNotNil(expected)
        XCTAssertEqual(PublicMetaDBHistoryDateView.parsedDate("2026-01-16T02:00:00+05:30"), expected)
        XCTAssertNotNil(PublicMetaDBHistoryDateView.parsedDate("2024-02-29T20:30:00.125Z"))
        for text in ["2026-01-15", "2026-01-15T20:30:00", "2026-02-30T20:30:00Z",
                     "2026-01-15T25:30:00Z", "2026-01-15T20:30:00+05:99", "2026-01-15T20:30:00Z extra"] {
            XCTAssertNil(PublicMetaDBHistoryDateView.parsedDate(text), text)
        }
    }

    func testDoubleSubmissionIsRejectedWhileOperationIsRunning() async {
        let model = PublicMetaDBMutationOperation()
        let done = expectation(description: "First operation finished")
        var calls = 0
        model.perform { calls += 1; done.fulfill() }
        model.perform { calls += 1 }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(model.succeeded)
        XCTAssertFalse(model.permitsWrite)
    }

    func testUncertainMutationCannotBeRepeatedFromTheSameScreen() async {
        let model = PublicMetaDBMutationOperation()
        let done = expectation(description: "Uncertain operation finished")
        model.perform {
            defer { done.fulfill() }
            throw PublicMetaDB.Failure.uncertainWrite
        }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertFalse(model.succeeded)
        XCTAssertFalse(model.permitsWrite)
        XCTAssertEqual(model.failure as? PublicMetaDB.Failure, .uncertainWrite)
        model.perform { XCTFail("Uncertain write repeated") }
    }

    func testCancellationBeforeTaskStartsDoesNotPerformTheWrite() async {
        let model = PublicMetaDBMutationOperation()
        let done = expectation(description: "Cancelled operation finished")
        model.perform { XCTFail("Cancelled operation performed") }
        withObservationTracking {
            _ = model.running
        } onChange: {
            done.fulfill()
        }
        model.cancel()
        await fulfillment(of: [done], timeout: 2)
        XCTAssertFalse(model.succeeded)
        XCTAssertTrue(model.failure is CancellationError)
    }

    func testPartiallyConfirmedDeletionRequiresFreshSelectionInsteadOfReplay() async {
        let model = PublicMetaDBMutationOperation()
        let done = expectation(description: "Partial operation finished")
        model.perform {
            defer { done.fulfill() }
            throw PublicMetaDB.HistoryDeletionFailure(
                confirmedIDs: ["removed"], stoppedRecordID: "unconfirmed",
                remainingIDs: ["not-attempted"], cause: PublicMetaDB.Failure.uncertainWrite
            )
        }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertFalse(model.succeeded)
        XCTAssertFalse(model.permitsWrite)
        XCTAssertEqual((model.failure as? PublicMetaDB.HistoryDeletionFailure)?.confirmedIDs, ["removed"])
        model.perform { XCTFail("Partially completed deletion replayed") }
    }
}
