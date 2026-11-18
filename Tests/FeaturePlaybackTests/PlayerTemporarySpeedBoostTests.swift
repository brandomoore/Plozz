#if canImport(AVFoundation)
import Foundation
import CoreModels
import XCTest
@testable import FeaturePlayback
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class PlayerTemporarySpeedBoostTests: XCTestCase {
    func testHoldRestoresSelectedSpeedWithoutPersistingForBothProviders() async {
        for kind in [ProviderKind.jellyfin, .plex] {
            for selected in [1.0, 1.5] {
                let (model, engine, preferences) = makeModel(speed: selected, kind: kind)
                XCTAssertNil(model.beginTemporarySpeedBoost(), "Bring-up is not active playback")
                await model.load()
                engine.commands = []

                XCTAssertEqual(model.beginTemporarySpeedBoost(), 2)
                XCTAssertEqual(model.temporarySpeedBoostRate, 2)
                XCTAssertEqual(model.nowPlayingSpeed, 2)
                XCTAssertEqual(model.controls.playbackSpeed, selected)
                XCTAssertEqual(preferences.loadPlaybackSpeed(), selected)
                XCTAssertTrue(preferences.writes.isEmpty)
                XCTAssertEqual(model.beginTemporarySpeedBoost(), 2)
                XCTAssertEqual(engine.commands, [.rate(2)], "Repeated begin must not replace ownership")

                model.endTemporarySpeedBoost()
                XCTAssertNil(model.temporarySpeedBoostRate)
                XCTAssertEqual(model.nowPlayingSpeed, selected)
                XCTAssertEqual(engine.commands, [.rate(2), .rate(selected)])
                model.endTemporarySpeedBoost()
                XCTAssertEqual(engine.commands, [.rate(2), .rate(selected)])
                XCTAssertEqual(preferences.loadPlaybackSpeed(), selected)
                XCTAssertTrue(preferences.writes.isEmpty)
                XCTAssertFalse(engine.isPaused)
                await model.stop()
            }
        }
    }

    func testPauseCancelsHoldAndCannotBeOverruledByEnginePlayingMirror() async {
        let (model, engine, preferences) = makeModel(speed: 1.5)
        await model.load()
        model.setPaused(true)
        engine.isPaused = false
        engine.commands = []
        XCTAssertNil(model.beginTemporarySpeedBoost(), "A phantom engine playing state is not user intent")
        XCTAssertTrue(engine.commands.isEmpty)

        model.setPaused(false)
        XCTAssertEqual(model.beginTemporarySpeedBoost(), 2)
        engine.commands = []
        model.setPaused(true)
        XCTAssertEqual(engine.commands, [.rate(1.5), .pause])
        XCTAssertTrue(engine.isPaused)
        XCTAssertTrue(model.controls.intendsPause)
        XCTAssertNil(model.temporarySpeedBoostRate)
        model.endTemporarySpeedBoost()
        XCTAssertEqual(engine.commands, [.rate(1.5), .pause])
        model.setPaused(false)
        XCTAssertEqual(engine.speed, 1.5)
        XCTAssertTrue(preferences.writes.isEmpty)
        await model.stop()
    }

    func testBufferingRefusesNewHoldAndReleaseDoesNotIssuePlayOrPause() async {
        let (model, engine, preferences) = makeModel(speed: 1.5)
        await model.load()
        engine.isBuffering = true
        engine.commands = []
        XCTAssertNil(model.beginTemporarySpeedBoost())
        XCTAssertTrue(engine.commands.isEmpty)
        engine.isBuffering = false
        XCTAssertEqual(model.beginTemporarySpeedBoost(), 2)

        engine.isBuffering = true
        engine.isPaused = true
        engine.commands = []
        model.endTemporarySpeedBoost()
        XCTAssertEqual(engine.commands, [.rate(1.5)])
        XCTAssertTrue(engine.isPaused)
        XCTAssertFalse(model.controls.intendsPause, "A transport underrun must not change playback intent")
        XCTAssertNil(model.temporarySpeedBoostRate)
        XCTAssertTrue(preferences.writes.isEmpty)
        await model.stop()
    }

    func testUnsupportedAndAtMaximumSpeedsAreNotBoosted() async {
        let (model, engine, preferences) = makeModel()
        await model.load()
        engine.commands = []
        engine.capabilities = []
        XCTAssertNil(model.beginTemporarySpeedBoost())
        engine.capabilities = [.playbackSpeed]
        for maximum in [1.0, 0.5, 0, -.infinity, .infinity, .nan] {
            engine.maximumPlaybackSpeed = maximum
            XCTAssertNil(model.beginTemporarySpeedBoost())
        }
        XCTAssertTrue(engine.commands.isEmpty)
        XCTAssertTrue(preferences.writes.isEmpty)
        await model.stop()
    }

    func testReleaseDuringEngineOwnedReloadRestoresResumeRateWithoutPlaying() async {
        let (model, engine, preferences) = makeModel(speed: 1.5)
        await model.load()
        XCTAssertEqual(model.beginTemporarySpeedBoost(), 2)
        engine.status = .loading
        engine.isPaused = true
        engine.commands = []
        model.endTemporarySpeedBoost()
        XCTAssertEqual(engine.commands, [.rate(1.5)])
        XCTAssertNil(model.temporarySpeedBoostRate)
        XCTAssertTrue(engine.isPaused)
        XCTAssertFalse(model.controls.intendsPause)
        XCTAssertTrue(preferences.writes.isEmpty)
        await model.stop()
    }

    func testBoostReportsSupportedRateBelowTwoAndNeverLowersFasterSelection() async {
        for maximum in [1.5, 2, 4] {
            let (model, engine, preferences) = makeModel()
            await model.load()
            engine.maximumPlaybackSpeed = maximum
            engine.commands = []
            let expected = min(2, maximum)
            XCTAssertEqual(model.beginTemporarySpeedBoost(), expected)
            XCTAssertEqual(model.temporarySpeedBoostRate, expected)
            model.endTemporarySpeedBoost()
            XCTAssertEqual(engine.commands, [.rate(expected), .rate(1)])
            XCTAssertTrue(preferences.writes.isEmpty)
            await model.stop()
        }
        for selected in [2.0, 3.0] {
            let (model, engine, preferences) = makeModel(speed: selected)
            await model.load()
            engine.commands = []
            XCTAssertNil(model.beginTemporarySpeedBoost())
            model.endTemporarySpeedBoost()
            XCTAssertTrue(engine.commands.isEmpty)
            XCTAssertEqual(engine.speed, selected)
            XCTAssertTrue(preferences.writes.isEmpty)
            await model.stop()
        }
    }

    func testExplicitSelectionSupersedesHoldAndLateReleaseIsInert() async {
        let (model, engine, preferences) = makeModel(speed: 1.5)
        await model.load()
        XCTAssertEqual(model.beginTemporarySpeedBoost(), 2)
        engine.commands = []
        model.setPlaybackSpeed(1.25)
        XCTAssertNil(model.temporarySpeedBoostRate)
        XCTAssertEqual(model.controls.playbackSpeed, 1.25)
        XCTAssertEqual(model.nowPlayingSpeed, 1.25)
        XCTAssertEqual(preferences.writes, [1.25])
        model.endTemporarySpeedBoost()
        XCTAssertEqual(engine.commands, [.rate(1.25)])
        XCTAssertEqual(model.beginTemporarySpeedBoost(), 2)
        model.endTemporarySpeedBoost()
        XCTAssertEqual(engine.speed, 1.25)
        XCTAssertEqual(preferences.writes, [1.25])
        await model.stop()
    }

    func testBackgroundCancelsHoldAndForegroundKeepsSelectedSpeedPaused() async {
        let (model, engine, preferences) = makeModel(speed: 1.5)
        await model.load()
        XCTAssertEqual(model.beginTemporarySpeedBoost(), 2)
        model.didEnterBackground()
        XCTAssertNil(model.temporarySpeedBoostRate)
        XCTAssertEqual(engine.speed, 1.5)
        XCTAssertTrue(engine.isPaused)
        XCTAssertNil(model.beginTemporarySpeedBoost())
        await model.resumeAfterBackground()
        XCTAssertTrue(engine.isPaused)
        XCTAssertTrue(model.controls.intendsPause)
        XCTAssertEqual(engine.speed, 1.5)
        model.endTemporarySpeedBoost()
        XCTAssertTrue(preferences.writes.isEmpty)
        await model.stop()
    }

    #if os(iOS)
    func testContinuingBackgroundAudioLosesOnlyTemporaryBoost() async {
        var settings = PlaybackSettings.default
        settings.backgroundAudio = true
        let (model, engine, preferences) = makeModel(speed: 1.5, settings: settings)
        await model.load()
        XCTAssertEqual(model.beginTemporarySpeedBoost(), 2)
        engine.commands = []
        model.didEnterBackground()
        XCTAssertEqual(engine.commands, [.rate(1.5)])
        XCTAssertFalse(engine.isPaused)
        XCTAssertFalse(model.controls.intendsPause)
        XCTAssertNil(model.temporarySpeedBoostRate)
        XCTAssertNil(model.beginTemporarySpeedBoost())
        XCTAssertTrue(preferences.writes.isEmpty)
        await model.stop()
    }
    #endif

    func testEngineHandoffCancelsBeforeSwapAndLateReleaseCannotChangeReplacement() async {
        let replacement = SpeedBoostEngine()
        replacement.maximumPlaybackSpeed = 1.25
        let (model, outgoing, preferences) = makeModel(speed: 1.5, replacement: replacement)
        await model.load()
        let outgoingToken = model.engineToken
        XCTAssertEqual(model.beginTemporarySpeedBoost(), 2)
        outgoing.commands = []
        await model.handoffPlayResolved(makeRequest(), engineKind: .plozzigen, startPosition: 12)
        XCTAssertNotEqual(model.engineToken, outgoingToken)
        XCTAssertEqual(outgoing.commands, [.rate(1.5), .stop])
        XCTAssertNil(model.temporarySpeedBoostRate)
        XCTAssertEqual(replacement.speed, 1.25)
        XCTAssertEqual(model.controls.playbackSpeed, 1.25)
        replacement.commands = []
        model.endTemporarySpeedBoost()
        XCTAssertTrue(replacement.commands.isEmpty)
        XCTAssertEqual(preferences.loadPlaybackSpeed(), 1.5)
        XCTAssertTrue(preferences.writes.isEmpty)
        await model.stop()
    }

    func testSameEngineReloadCancelsAndRefusesHoldInPreCommitWindow() async {
        let (model, engine, preferences) = makeModel(speed: 1.5)
        await model.load()
        let token = model.engineToken
        XCTAssertEqual(model.beginTemporarySpeedBoost(), 2)
        model.preEngineCommitYield = { [weak model] in
            guard let model else { return XCTFail("The active model must remain alive") }
            XCTAssertNil(model.temporarySpeedBoostRate)
            XCTAssertNil(model.beginTemporarySpeedBoost(), "The outgoing engine is still ready during this yield")
            await Task.yield()
        }
        await model.handoffPlayResolved(makeRequest(), engineKind: .native, startPosition: 24)
        XCTAssertEqual(model.engineToken, token)
        XCTAssertEqual(engine.speed, 1.5)
        engine.commands = []
        model.endTemporarySpeedBoost()
        XCTAssertTrue(engine.commands.isEmpty)
        XCTAssertEqual(model.beginTemporarySpeedBoost(), 2)
        model.endTemporarySpeedBoost()
        XCTAssertEqual(engine.speed, 1.5)
        XCTAssertTrue(preferences.writes.isEmpty)
        await model.stop()
    }

    func testVersionAndEpisodeHandoffsNeverExportTemporaryRate() async {
        let (model, engine, preferences) = makeModel(speed: 1.5)
        await model.load()
        XCTAssertEqual(model.beginTemporarySpeedBoost(), 2)
        let continuation = model.continuationForVersionChange()
        XCTAssertEqual(continuation.speed, 1.5)
        XCTAssertTrue(continuation.intendsPlayback)
        XCTAssertNil(model.temporarySpeedBoostRate)
        XCTAssertEqual(engine.speed, 1.5)
        XCTAssertEqual(model.beginTemporarySpeedBoost(), 2)
        model.playEpisode(.init(id: "next", title: "Next", kind: .episode))
        XCTAssertNil(model.temporarySpeedBoostRate)
        XCTAssertEqual(engine.speed, 1.5)
        XCTAssertNil(model.beginTemporarySpeedBoost())
        XCTAssertTrue(preferences.writes.isEmpty)
        await model.stop()
    }

    func testSeekingAndScrubbingRefuseHoldsAndCommittedSeekRestoresRate() async {
        let (model, engine, preferences) = makeModel(speed: 1.5)
        await model.load()
        engine.commands = []
        model.controls.isSeeking = true
        XCTAssertNil(model.beginTemporarySpeedBoost())
        model.controls.isSeeking = false
        model.controls.isScrubbing = true
        XCTAssertNil(model.beginTemporarySpeedBoost())
        model.controls.isScrubbing = false
        XCTAssertTrue(engine.commands.isEmpty)
        XCTAssertEqual(model.beginTemporarySpeedBoost(), 2)
        model.requestSeek(to: 40)
        XCTAssertNil(model.temporarySpeedBoostRate)
        XCTAssertEqual(engine.speed, 1.5)
        XCTAssertFalse(model.controls.intendsPause)
        XCTAssertTrue(preferences.writes.isEmpty)
        await model.stop()
    }

    func testStopRestoresBeforeTeardownAndLateReleaseNeverTouchesStoppedEngine() async {
        let (model, engine, preferences) = makeModel(speed: 1.5)
        await model.load()
        XCTAssertEqual(model.beginTemporarySpeedBoost(), 2)
        engine.commands = []
        await model.stop()
        XCTAssertEqual(engine.commands, [.rate(1.5), .stop])
        XCTAssertNil(model.temporarySpeedBoostRate)
        model.endTemporarySpeedBoost()
        XCTAssertNil(model.beginTemporarySpeedBoost())
        XCTAssertEqual(engine.commands, [.rate(1.5), .stop])
        XCTAssertTrue(preferences.writes.isEmpty)
    }

    func testEOFClearsHoldWithoutReactivatingEndedEngine() async {
        let (model, engine, preferences) = makeModel(speed: 1.5)
        await model.load()
        XCTAssertEqual(model.beginTemporarySpeedBoost(), 2)
        engine.commands = []
        engine.onEnded?()
        XCTAssertNil(model.temporarySpeedBoostRate)
        model.endTemporarySpeedBoost()
        XCTAssertNil(model.beginTemporarySpeedBoost())
        XCTAssertTrue(engine.commands.isEmpty)
        XCTAssertTrue(preferences.writes.isEmpty)
        await model.stop()
    }

    func testFailureClearsHoldWithoutSendingRateToFailedEngine() async {
        let (model, engine, preferences) = makeModel(speed: 1.5)
        await model.load()
        XCTAssertEqual(model.beginTemporarySpeedBoost(), 2)
        engine.status = .failed(.serverUnreachable)
        engine.commands = []
        model.handoffSetPhase(.failed(.serverUnreachable))
        XCTAssertNil(model.temporarySpeedBoostRate)
        model.endTemporarySpeedBoost()
        XCTAssertNil(model.beginTemporarySpeedBoost())
        XCTAssertEqual(engine.commands, [.stop], "Terminal failure stops playback without restoring a rate.")
        XCTAssertTrue(preferences.writes.isEmpty)
        await model.stop()
    }

    private func makeRequest() -> PlaybackRequest {
        PlaybackRequest(
            item: .init(id: "movie", title: "Movie", kind: .movie, runtime: 120),
            streamURL: URL(string: "https://fixture.test/movie.mp4")!
        )
    }

    private func makeModel(
        speed: Double = 1,
        kind: ProviderKind = .jellyfin,
        replacement: SpeedBoostEngine? = nil,
        settings: PlaybackSettings = .default
    ) -> (PlayerViewModel, SpeedBoostEngine, SpeedBoostPreferences) {
        let engine = SpeedBoostEngine()
        let preferences = SpeedBoostPreferences(speed: speed)
        let request = makeRequest()
        var factory = EngineFactory(makeNative: { _ in engine })
        if let replacement { factory.makePlozzigen = { replacement } }
        let model = PlayerViewModel(
            provider: SpeedBoostProvider(kind: kind, request: request), itemID: "movie",
            playbackSettings: settings, engineFactory: factory, preferencesStore: preferences,
            adoptedResolved: .init(itemID: "movie", request: request, engineKind: .native)
        )
        return (model, engine, preferences)
    }
}

private final class SpeedBoostPreferences: PlaybackPreferencesStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var speed: Double
    private var savedSpeeds: [Double] = []
    var writes: [Double] { lock.withLock { savedSpeeds } }

    init(speed: Double) { self.speed = speed }
    func loadPlaybackSpeed() -> Double { lock.withLock { speed } }
    func savePlaybackSpeed(_ speed: Double) {
        lock.withLock {
            self.speed = speed
            savedSpeeds.append(speed)
        }
    }
}

@MainActor
private final class SpeedBoostEngine: VideoEngine {
    enum Command: Equatable {
        case rate(Double), play, pause, stop
    }
    var commands: [Command] = []
    var capabilities: PlayerEngineCapabilities = [.playbackSpeed]
    var maximumPlaybackSpeed = 4.0
    var speed = 1.0
    var status: VideoEngineStatus = .idle
    var isPaused = false
    var isBuffering = false
    var preventsDisplaySleep: Bool { status == .ready && !isPaused && !isBuffering }
    var hasPresentedVideoFrame: Bool { status == .ready }
    var currentTime: TimeInterval = 10
    var duration: TimeInterval = 120
    var furthestObservedPosition: TimeInterval = 10
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var onProgress: (@MainActor () -> Void)?
    var onFailure: (@MainActor (AppError) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onTracksChanged: (@MainActor () -> Void)?
    var onProbedSourceFactsChanged: (@MainActor (EngineProbedSourceFacts) -> Void)?
    var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?

    func load(request: PlaybackRequest, startPosition: TimeInterval) async {
        status = .ready
        currentTime = startPosition
    }
    func play() { commands.append(.play); isPaused = false }
    func pause() { commands.append(.pause); isPaused = true }
    func stop() { commands.append(.stop); status = .idle; isPaused = true }
    func seek(to seconds: TimeInterval) async { currentTime = seconds }
    func setPlaybackSpeed(_ rate: Double) { commands.append(.rate(rate)); speed = rate }
    func selectAudioTrack(_ track: MediaTrack?) {}
    func selectSubtitleTrack(_ track: MediaTrack?) {}
    #if canImport(UIKit)
    func makeVideoOutputView() -> UIView { UIView() }
    #endif
}

private actor SpeedBoostProvider: MediaProvider {
    nonisolated let kind: ProviderKind
    nonisolated let session: UserSession
    private let request: PlaybackRequest

    init(kind: ProviderKind, request: PlaybackRequest) {
        self.kind = kind
        self.request = request
        session = UserSession(
            server: .init(id: "server", name: "Server", baseURL: URL(string: "https://fixture.test")!, provider: kind),
            userID: "user", userName: "User", deviceID: "device", accessToken: "fixture"
        )
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { request.item }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: page.startIndex, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { request }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
#endif
