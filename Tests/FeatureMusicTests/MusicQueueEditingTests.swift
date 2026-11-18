import XCTest
import CoreModels
@testable import FeatureMusic

@MainActor
final class MusicQueueEditingTests: XCTestCase {
    private func tracks() -> [MusicTrack] {
        (0..<5).map { index in
            var track = MusicTrack(id: "song", title: "Occurrence \(index)", sourceAccountID: "account")
            track.playlistEntryID = "\(index)"
            return track
        }
    }

    func testReorderUsesFinalPositionsAndPreservesCurrentOccurrence() {
        let controller = AudioPlaybackController()
        defer { controller.stop() }
        controller.play(tracks: tracks(), startIndex: 1, resolveStreamURL: { _ in nil })
        let transport = controller.transportGeneration
        controller.moveUpNext(fromOffset: 0, toOffset: 2)
        XCTAssertEqual(controller.queue.map(\.playlistEntryID), ["0", "1", "3", "4", "2"])
        XCTAssertEqual(controller.currentTrack?.playlistEntryID, "1")
        XCTAssertEqual(controller.transportGeneration, transport)
        controller.toggleShuffle()
        controller.toggleShuffle()
        XCTAssertEqual(controller.queue.map(\.playlistEntryID), ["0", "1", "3", "4", "2"])
        XCTAssertEqual(controller.transportGeneration, transport)
    }

    func testClearHistoryAndUpNextDoNotResurrectAfterUnshuffle() {
        let controller = AudioPlaybackController()
        defer { controller.stop() }
        controller.play(tracks: tracks(), startIndex: 2, resolveStreamURL: { _ in nil })
        controller.clearHistory()
        XCTAssertEqual(controller.index, 0)
        XCTAssertEqual(controller.queue.map(\.playlistEntryID), ["2", "3", "4"])
        controller.toggleShuffle()
        controller.clearUpNext()
        controller.toggleShuffle()
        XCTAssertEqual(controller.queue.map(\.playlistEntryID), ["2"])
        XCTAssertEqual(controller.currentTrack?.playlistEntryID, "2")
    }

    func testInvalidMoveCannotChangeQueue() {
        let controller = AudioPlaybackController()
        defer { controller.stop() }
        controller.play(tracks: tracks(), startIndex: 3, resolveStreamURL: { _ in nil })
        let before = controller.queue
        controller.moveUpNext(fromOffset: -1, toOffset: 0)
        controller.moveUpNext(fromOffset: 0, toOffset: 1)
        XCTAssertEqual(controller.queue, before)
    }

    func testResolutionFailureIsVisibleAndRetryable() async {
        let controller = AudioPlaybackController()
        defer { controller.stop() }
        let failed = expectation(description: "Initial resolution")
        controller.play(tracks: tracks(), startIndex: 0, resolveStreamURL: { _ in
            failed.fulfill()
            return nil
        })
        XCTAssertTrue(controller.isBuffering)
        await fulfillment(of: [failed], timeout: 2)
        let deadline = Date().addingTimeInterval(2)
        while !controller.playbackFailed && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(controller.playbackFailed)
        XCTAssertFalse(controller.isBuffering)
        controller.stop()
        XCTAssertFalse(controller.playbackFailed)
    }
}
