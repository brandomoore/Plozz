#if DEBUG && canImport(UIKit)
import XCTest
@testable import FeaturePlayback

@MainActor
final class LiveChannelOutputGroupTests: XCTestCase {
    func testPreviewKeepsAudioWithoutTakingDisplayOwnership() {
        let group = LiveChannelOutputGroup()
        let preview = LiveEngineSpy()
        let id = UUID()
        group.register(preview, id: id, audible: true, allowsDisplayMatching: false)
        XCTAssertTrue(preview.outputPolicy.isAudible)
        XCTAssertTrue(preview.outputPolicy.suppressesDisplayMatching)
        group.unregister(id)
    }

    func testWatchingEnablesMatchingAndReturningToGuideDisablesIt() {
        let group = LiveChannelOutputGroup()
        let preview = LiveEngineSpy()
        let second = LiveEngineSpy()
        let id = UUID()
        let secondID = UUID()
        group.register(preview, id: id, audible: true, allowsDisplayMatching: false)
        group.register(second, id: secondID, audible: false, allowsDisplayMatching: false)
        group.setDisplayMatchingAllowed(true, id: id)
        XCTAssertFalse(preview.outputPolicy.suppressesDisplayMatching)
        XCTAssertTrue(second.outputPolicy.suppressesDisplayMatching)
        group.setDisplayMatchingAllowed(false, id: id)
        XCTAssertTrue(preview.outputPolicy.suppressesDisplayMatching)
        XCTAssertTrue(second.outputPolicy.suppressesDisplayMatching)
        XCTAssertTrue(preview.outputPolicy.isAudible)
        group.unregister(secondID)
        group.unregister(id)
    }

    func testDisplayOwnershipNeverFallsBackToAnUncommittedPreview() {
        let group = LiveChannelOutputGroup()
        let watching = LiveEngineSpy()
        let preview = LiveEngineSpy()
        let watchingID = UUID()
        let previewID = UUID()
        group.register(watching, id: watchingID, audible: true)
        group.register(preview, id: previewID, audible: false, allowsDisplayMatching: false)
        group.unregister(watchingID)
        XCTAssertTrue(preview.outputPolicy.suppressesDisplayMatching)
        group.unregister(previewID)
    }

    func testStandalonePreviewPolicyIsAppliedBeforeLoadingAndIgnoresWatchHistoryIntent() async {
        let engine = LiveEngineSpy()
        let model = LiveChannelPlayerModel(
            engine: engine, streamURL: URL(string: "https://example.invalid/channel.m3u8")!,
            allowsDisplayMatching: false
        )
        XCTAssertTrue(engine.outputPolicy.suppressesDisplayMatching)
        await model.start()
        model.setWatching(true)
        XCTAssertTrue(engine.outputPolicy.suppressesDisplayMatching)
        model.setDisplayMatchingAllowed(true)
        XCTAssertFalse(engine.outputPolicy.suppressesDisplayMatching)
        model.setDisplayMatchingAllowed(false)
        XCTAssertTrue(engine.outputPolicy.suppressesDisplayMatching)
        XCTAssertEqual(engine.liveLoads, 1)
        model.stop()
    }

    func testAddingSilentPanePreservesAudioAndSingleDisplayOwner() {
        let group = LiveChannelOutputGroup()
        let first = LiveEngineSpy()
        let second = LiveEngineSpy()
        let firstID = UUID()
        let secondID = UUID()
        group.register(first, id: firstID, audible: true)
        group.register(second, id: secondID, audible: false)
        XCTAssertTrue(first.outputPolicy.isAudible)
        XCTAssertFalse(second.outputPolicy.isAudible)
        XCTAssertFalse(first.outputPolicy.suppressesDisplayMatching)
        XCTAssertTrue(second.outputPolicy.suppressesDisplayMatching)
        XCTAssertTrue(first.outputPolicy.sharesAudioSession)
        XCTAssertTrue(second.outputPolicy.sharesAudioSession)
        group.unregister(secondID)
        group.unregister(firstID)
    }

    func testAudioHandoffNeverMakesBothEnginesAudible() {
        let group = LiveChannelOutputGroup()
        let first = LiveEngineSpy()
        let second = LiveEngineSpy()
        let firstID = UUID()
        let secondID = UUID()
        group.register(first, id: firstID, audible: true)
        group.register(second, id: secondID, audible: false)
        var overlappingAudio = false
        first.onOutputPolicy = { _ in
            overlappingAudio = overlappingAudio || (first.outputPolicy.isAudible && second.outputPolicy.isAudible)
        }
        second.onOutputPolicy = { _ in
            overlappingAudio = overlappingAudio || (first.outputPolicy.isAudible && second.outputPolicy.isAudible)
        }
        group.setAudible(true, id: secondID)
        XCTAssertFalse(overlappingAudio)
        XCTAssertFalse(first.outputPolicy.isAudible)
        XCTAssertTrue(second.outputPolicy.isAudible)
        // A delayed old-view update must not mute the newly selected pane.
        group.setAudible(false, id: firstID)
        XCTAssertTrue(second.outputPolicy.isAudible)
        first.onOutputPolicy = nil
        second.onOutputPolicy = nil
        group.unregister(firstID)
        group.unregister(secondID)
    }

    func testOnlyLastDepartingEngineMayResetSharedAudioAndDisplay() {
        let group = LiveChannelOutputGroup()
        let first = LiveEngineSpy()
        let second = LiveEngineSpy()
        let firstID = UUID()
        let secondID = UUID()
        group.register(first, id: firstID, audible: true)
        group.register(second, id: secondID, audible: false)
        group.unregister(firstID)
        XCTAssertTrue(first.outputPolicy.sharesAudioSession)
        XCTAssertTrue(first.outputPolicy.suppressesDisplayMatching)
        group.unregister(secondID)
        XCTAssertFalse(second.outputPolicy.sharesAudioSession)
        XCTAssertFalse(second.outputPolicy.suppressesDisplayMatching)
    }

    func testLateDepartingRendererCannotMuteOrUnregisterItsReplacement() {
        let group = LiveChannelOutputGroup()
        let old = LiveEngineSpy()
        let replacement = LiveEngineSpy()
        let id = UUID()
        group.register(old, id: id, audible: true)
        group.register(replacement, id: id, audible: true)
        XCTAssertFalse(old.outputPolicy.isAudible)
        group.setAudible(false, id: id, engine: old)
        group.unregister(id, engine: old)
        XCTAssertTrue(replacement.outputPolicy.isAudible)
        group.unregister(id, engine: replacement)
        XCTAssertFalse(replacement.outputPolicy.sharesAudioSession)
    }

    func testStoppingOnePlayerDoesNotStopOrReloadItsSibling() async {
        let group = LiveChannelOutputGroup()
        let first = LiveEngineSpy()
        let second = LiveEngineSpy()
        let firstModel = LiveChannelPlayerModel(
            engine: first, streamURL: URL(string: "https://example.invalid/1.m3u8")!,
            outputGroup: group, isAudible: true
        )
        let secondModel = LiveChannelPlayerModel(
            engine: second, streamURL: URL(string: "https://example.invalid/2.m3u8")!,
            outputGroup: group, isAudible: false
        )
        await firstModel.start()
        await secondModel.start()
        secondModel.stop()
        XCTAssertEqual(second.stopCount, 1)
        XCTAssertEqual(first.stopCount, 0)
        XCTAssertEqual(first.liveLoads, 1)
        XCTAssertTrue(first.outputPolicy.isAudible)
        firstModel.stop()
    }
}
#endif
