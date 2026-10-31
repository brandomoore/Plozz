#if os(tvOS) || os(iOS)
import AVFoundation
import CoreModels
import FeaturePlayback
import XCTest
@testable import EnginePlozzigen

@MainActor
final class PlaybackAudioSessionTests: XCTestCase {
    func testPlozzigenClearsTrailerAndThemeMixingOnEveryLoad() async throws {
        let session = AVAudioSession.sharedInstance()
        let original = (session.category, session.mode, session.routeSharingPolicy, session.categoryOptions)
        defer { restore(original) }
        let engine = try PlozzigenVideoEngine()
        defer { engine.stop() }

        for mode: AVAudioSession.Mode in [.moviePlayback, .default, .moviePlayback] {
            try session.setCategory(.playback, mode: mode, options: [.mixWithOthers])
            let policy = session.routeSharingPolicy
            await engine.load(request: requestWithoutSource, startPosition: 0)
            assertNonMixingVideo(session)
            XCTAssertEqual(session.routeSharingPolicy, policy)
            assertMissingSourceFailure(engine)
        }
    }

    func testNativeClearsPreviewMixingWhenTheSameEngineLoadsAgain() async throws {
        let session = AVAudioSession.sharedInstance()
        let original = (session.category, session.mode, session.routeSharingPolicy, session.categoryOptions)
        defer { restore(original) }
        let engine = NativeVideoEngine()
        defer { engine.stop() }

        for mode: AVAudioSession.Mode in [.moviePlayback, .default] {
            try session.setCategory(.playback, mode: mode, options: [.mixWithOthers])
            await engine.load(request: requestWithoutSource, startPosition: 0)
            assertNonMixingVideo(session)
            assertMissingSourceFailure(engine)
        }
    }

    func testSharedAndMutedChannelLoadsDoNotOverwriteTheOwnersAudioPolicy() async throws {
        let session = AVAudioSession.sharedInstance()
        let original = (session.category, session.mode, session.routeSharingPolicy, session.categoryOptions)
        defer { restore(original) }
        let engine = try PlozzigenVideoEngine()
        defer { engine.stop() }

        for policy in [
            LiveChannelOutputPolicy(isAudible: false),
            .init(isAudible: true, sharesAudioSession: true),
            .init(isAudible: false, sharesAudioSession: true)
        ] {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            engine.configureLiveOutput(policy)
            await engine.load(request: requestWithoutSource, startPosition: 0)
            XCTAssertEqual(session.mode, .default)
            XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers))
            assertMissingSourceFailure(engine)
        }
    }

    private var requestWithoutSource: PlaybackRequest {
        // Exercise the real load entry points without starting decoding or network I/O.
        var request = PlaybackRequest(
            item: MediaItem(id: "audio-session", title: "Audio session", kind: .movie),
            streamURL: URL(fileURLWithPath: "/unused.mp4")
        )
        request.streamURL = nil
        return request
    }

    private func assertNonMixingVideo(
        _ session: AVAudioSession, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(session.category, .playback, file: file, line: line)
        XCTAssertEqual(session.mode, .moviePlayback, file: file, line: line)
        XCTAssertEqual(session.categoryOptions, [], file: file, line: line)
    }

    private func assertMissingSourceFailure(
        _ engine: any VideoEngine, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .failed = engine.status else {
            XCTFail("The source-free fixture must stop before media loading.", file: file, line: line)
            return
        }
    }

    private func restore(
        _ original: (AVAudioSession.Category, AVAudioSession.Mode,
                     AVAudioSession.RouteSharingPolicy, AVAudioSession.CategoryOptions)
    ) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false)
            try session.setCategory(original.0, mode: original.1, policy: original.2, options: original.3)
        } catch {
            XCTFail("Could not restore the test process's audio session: \(error)")
        }
    }
}
#endif
