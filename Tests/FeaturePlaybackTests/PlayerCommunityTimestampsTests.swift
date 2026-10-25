import CoreModels
import Foundation
import XCTest
@testable import FeaturePlayback

@MainActor
final class PlayerCommunityTimestampsTests: XCTestCase {
    private let item = MediaItem(id: "movie", title: "Movie", kind: .movie)

    func testBrowsingDoesNotSeekAndConfirmedSelectionUsesExactSeconds() async {
        let source = TimestampTestSource()
        var seeks: [Double] = []
        let model = PlayerCommunityTimestampsModel(
            item: item, source: source, duration: { 120 }, isCurrent: { true }, requestSeek: { seeks.append($0) }
        )
        await model.load(includeHighlights: false)
        XCTAssertTrue(model.loaded)
        XCTAssertTrue(seeks.isEmpty)
        XCTAssertEqual(source.highlightsRequests, [false])
        XCTAssertTrue(model.seek(source.entry, toEnd: false))
        XCTAssertTrue(model.seek(source.entry, toEnd: true))
        XCTAssertEqual(seeks, [1.0005, 5])
    }

    func testUnknownInvalidOrShortRuntimeNeverAuthorizesAJump() async {
        for duration in [0, -1, .nan, .infinity, 4.999] {
            let source = TimestampTestSource()
            var seeks = 0
            let model = PlayerCommunityTimestampsModel(
                item: item, source: source, duration: { duration }, isCurrent: { true }, requestSeek: { _ in seeks += 1 }
            )
            await model.load(includeHighlights: false)
            XCTAssertFalse(model.canSeek(source.entry))
            XCTAssertFalse(model.seek(source.entry, toEnd: false))
            XCTAssertFalse(model.seek(source.entry, toEnd: true))
            XCTAssertEqual(seeks, 0)
        }
    }

    func testEndOfRuntimeDoesNotBecomeCompletionSeekButStartIsAvailable() async {
        let source = TimestampTestSource()
        let model = PlayerCommunityTimestampsModel(
            item: item, source: source, duration: { 5 }, isCurrent: { true }, requestSeek: { _ in }
        )
        await model.load(includeHighlights: false)
        XCTAssertTrue(model.canSeek(source.entry))
        XCTAssertFalse(model.canSeek(source.entry, toEnd: true))
        XCTAssertFalse(model.seek(source.entry, toEnd: true))
    }

    func testTimelineChangeConnectionRevocationAndUnknownSelectionBlockJump() async {
        let source = TimestampTestSource()
        var current = true
        var duration = 120.0
        var seeks = 0
        let model = PlayerCommunityTimestampsModel(
            item: item, source: source, duration: { duration }, isCurrent: { current }, requestSeek: { _ in seeks += 1 }
        )
        await model.load(includeHighlights: false)
        let forged = CommunityPlaybackTimestamp(
            id: source.entry.id, kind: .intro, start: 20, end: 40, release: .physical
        )
        XCTAssertFalse(model.seek(forged, toEnd: false))
        current = false
        XCTAssertFalse(model.seek(source.entry, toEnd: false))
        current = true
        duration = 2
        XCTAssertFalse(model.seek(source.entry, toEnd: false))
        duration = 120
        source.isCurrent = false
        XCTAssertFalse(model.seek(source.entry, toEnd: false))
        XCTAssertEqual(seeks, 0)
    }

    func testCancellationAndPlaybackChangeDiscardAnInFlightRead() async {
        for cancelled in [true, false] {
            let source = TimestampTestSource()
            let started = expectation(description: "Read started")
            var continuation: CheckedContinuation<[CommunityPlaybackTimestamp], Never>?
            source.onLoad = {
                started.fulfill()
                return await withCheckedContinuation { continuation = $0 }
            }
            var current = true
            let model = PlayerCommunityTimestampsModel(
                item: item, source: source, duration: { 120 }, isCurrent: { current }, requestSeek: { _ in XCTFail("Automatic seek") }
            )
            let task = Task { await model.load(includeHighlights: false) }
            await fulfillment(of: [started], timeout: 2)
            if cancelled { model.cancel(); task.cancel() } else { current = false }
            continuation?.resume(returning: [source.entry])
            await task.value
            XCTAssertTrue(model.entries.isEmpty)
            XCTAssertFalse(model.loaded)
            XCTAssertFalse(model.isLoading)
            XCTAssertFalse(model.canSeek(source.entry))
        }
    }

    func testNewReadWinsAndOldCompletionCannotRestoreHiddenHighlights() async {
        let source = TimestampTestSource()
        let started = expectation(description: "Old read started")
        var continuation: CheckedContinuation<[CommunityPlaybackTimestamp], Never>?
        source.onLoad = {
            started.fulfill()
            return await withCheckedContinuation { continuation = $0 }
        }
        let model = PlayerCommunityTimestampsModel(
            item: item, source: source, duration: { 120 }, isCurrent: { true }, requestSeek: { _ in }
        )
        let old = Task { await model.load(includeHighlights: true) }
        await fulfillment(of: [started], timeout: 2)
        source.onLoad = nil
        await model.load(includeHighlights: false)
        continuation?.resume(returning: [.init(
            id: "old-highlight", kind: .highlight, start: 8, end: 10, release: .unknown
        )])
        await old.value
        XCTAssertEqual(model.entries, [source.entry])
        XCTAssertEqual(source.highlightsRequests, [true, false])
    }

    func testErrorsAndDuplicateRecordsAreNotSuccessfulEmptyResults() async {
        let source = TimestampTestSource()
        let model = PlayerCommunityTimestampsModel(
            item: item, source: source, duration: { 120 }, isCurrent: { true }, requestSeek: { _ in }
        )
        source.onLoad = { throw AppError.serverUnreachable }
        await model.load(includeHighlights: false)
        XCTAssertEqual(model.failure, .serverUnreachable)
        XCTAssertFalse(model.loaded)
        source.onLoad = { [source] in [source.entry, source.entry] }
        await model.load(includeHighlights: false)
        XCTAssertEqual(model.failure, .invalidResponse)
        XCTAssertFalse(model.loaded)
        XCTAssertTrue(model.entries.isEmpty)
        source.onLoad = nil
    }

    func testInvalidRangesAreNeverClippedIntoPlayableTimestamps() {
        for (start, end) in [(-1.0, 5.0), (5, 5), (5, 4), (.nan, 5), (1, .infinity)] {
            XCTAssertFalse(CommunityPlaybackTimestamp(
                id: "invalid", kind: .intro, start: start, end: end, release: .unknown
            ).fits(duration: 120))
        }
    }
}

@MainActor
final class TimestampTestSource: CommunityPlaybackTimestampProviding {
    let name = "Fixture"
    var isCurrent = true
    var highlightsRequests: [Bool] = []
    var onLoad: (() async throws -> [CommunityPlaybackTimestamp])?
    let entry = CommunityPlaybackTimestamp(
        id: "intro-a", kind: .intro, start: 1.0005, end: 5, release: .physical
    )

    func timestamps(for item: MediaItem, includeHighlights: Bool) async throws -> [CommunityPlaybackTimestamp] {
        highlightsRequests.append(includeHighlights)
        return try await onLoad?() ?? [entry]
    }
}
