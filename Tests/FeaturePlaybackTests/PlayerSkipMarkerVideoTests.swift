#if DEBUG && os(tvOS)
import CoreModels
import UIKit
import XCTest
@testable import FeaturePlayback

@MainActor
final class PlayerSkipMarkerVideoTests: XCTestCase {
    private var request: PlaybackRequest {
        .init(item: .init(id: "episode", title: "Fixture episode", kind: .episode),
              streamURL: URL(string: "https://fixture.invalid/video.mp4")!)
    }

    func testBackgroundUsesOneEngineAndReleasesItsSessionOnceOnExit() async throws {
        let engine = MarkerVideoEngine()
        let releases = MarkerVideoReleases()
        let request = request
        let model = PlayerSkipMarkerVideo(
            source: { .init(request: request, startPosition: 60, release: { await releases.record() }) },
            makeEngine: { engine }
        )
        model.start()
        model.start()
        try await waitUntil { model.state == .ready }
        XCTAssertEqual(engine.loads, 1)
        XCTAssertEqual(engine.currentTime, 60)
        XCTAssertEqual(model.title, request.item.title)
        model.togglePause()
        XCTAssertTrue(engine.isPaused)
        model.togglePause()
        XCTAssertFalse(engine.isPaused)
        model.stop()
        model.stop()
        try await waitUntil { await releases.count == 1 }
        XCTAssertEqual(engine.stops, 1)
        XCTAssertEqual(engine.drains, 1)
        XCTAssertNil(model.engine)
    }

    func testLateSourceAfterClosingIsReleasedWithoutConstructingAnEngine() async throws {
        let gate = MarkerVideoGate()
        let releases = MarkerVideoReleases()
        let request = request
        let requested = expectation(description: "source requested")
        let model = PlayerSkipMarkerVideo(
            source: {
                requested.fulfill()
                await gate.wait()
                return .init(request: request, startPosition: 60, release: { await releases.record() })
            },
            makeEngine: {
                XCTFail("Closing a preview must not construct a late player.")
                return MarkerVideoEngine()
            }
        )
        model.start()
        await fulfillment(of: [requested], timeout: 2)
        model.stop()
        await gate.open()
        try await waitUntil { await releases.count == 1 }
        XCTAssertNil(model.engine)
        XCTAssertEqual(model.state, .idle)
    }

    func testFailedEngineIsStoppedAndThePreparedSourceIsReleased() async throws {
        let engine = MarkerVideoEngine()
        engine.failure = .decoding
        let releases = MarkerVideoReleases()
        let request = request
        let model = PlayerSkipMarkerVideo(
            source: { .init(request: request, startPosition: 0, release: { await releases.record() }) },
            makeEngine: { engine }
        )
        model.start()
        try await waitUntil { model.state == .failed(.decoding) }
        try await waitUntil { await releases.count == 1 }
        XCTAssertEqual(engine.stops, 1)
        XCTAssertNil(model.engine)
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await predicate()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let satisfied = await predicate()
        XCTAssertTrue(satisfied)
    }
}

private actor MarkerVideoReleases {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor MarkerVideoGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { isOpen = true; continuation?.resume(); continuation = nil }
}

@MainActor
private final class MarkerVideoEngine: VideoEngine {
    let displayName = "fixture"
    var status: VideoEngineStatus = .idle
    var isPaused = false
    var hasPresentedVideoFrame = true
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 1_440
    var furthestObservedPosition: TimeInterval = 0
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var onProgress: (@MainActor () -> Void)?
    var onFailure: (@MainActor (AppError) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onTracksChanged: (@MainActor () -> Void)?
    var onProbedSourceFactsChanged: (@MainActor (EngineProbedSourceFacts) -> Void)?
    var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var loads = 0
    var stops = 0
    var drains = 0
    var failure: AppError?
    func load(request: PlaybackRequest, startPosition: TimeInterval) async {
        loads += 1
        currentTime = startPosition
        status = failure.map(VideoEngineStatus.failed) ?? .ready
    }
    func play() { isPaused = false }
    func pause() { isPaused = true }
    func seek(to seconds: TimeInterval) async { currentTime = seconds }
    func stop() { stops += 1; status = .idle }
    func drainTransport() async { drains += 1 }
    func selectAudioTrack(_ track: MediaTrack?) {}
    func selectSubtitleTrack(_ track: MediaTrack?) {}
    func makeVideoOutputView() -> UIView { UIView() }
}
#endif
