#if canImport(UIKit)
@testable import FeaturePlayback
import XCTest

@MainActor
final class DiscMenuPlaybackStateTests: XCTestCase {
    func testPresentationMessagesRetainLocalizationResources() {
        let state = DiscMenuPlaybackState()
        let failure: LocalizedStringResource = "The disc menu could not be opened."
        let notice: LocalizedStringResource = "Wait for the disc video before selecting a track."
        state.failure = failure
        state.notice = notice
        XCTAssertEqual(state.failure, failure)
        XCTAssertEqual(state.notice, notice)
        state.notice = nil
        state.audioSelectionUnavailable = true
        let audioWarning: LocalizedStringResource = "The disc's selected audio track is unavailable."
        XCTAssertEqual(state.notice, audioWarning)
    }

    func testRecoveredTrackClearsOnlyItsOwnWarning() {
        let state = DiscMenuPlaybackState()
        state.audioSelectionUnavailable = true
        let audioWarning = state.notice
        XCTAssertNotNil(audioWarning)
        state.subtitleSelectionUnavailable = true
        state.audioSelectionUnavailable = false
        let subtitleWarning = state.notice
        XCTAssertNotNil(subtitleWarning)
        XCTAssertNotEqual(audioWarning, subtitleWarning)
        state.subtitleSelectionUnavailable = false
        XCTAssertNil(state.notice)
    }

    func testTransientNoticeAndPersistentTrackFailureHaveSeparateLifetimes() {
        let state = DiscMenuPlaybackState()
        state.audioSelectionUnavailable = true
        let warning = state.notice
        state.notice = "Another operation is unavailable"
        state.audioSelectionUnavailable = false
        XCTAssertEqual(state.notice, "Another operation is unavailable")
        state.audioSelectionUnavailable = true
        state.notice = nil
        XCTAssertEqual(state.notice, warning, "Notice expiration must not hide an unresolved track failure.")
        state.reset()
        XCTAssertNil(state.notice)
        XCTAssertFalse(state.audioSelectionUnavailable)
        XCTAssertFalse(state.subtitleSelectionUnavailable)
    }
}
#endif
