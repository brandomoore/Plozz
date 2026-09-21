#if canImport(AVFoundation)
import CoreModels
import Foundation
import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import FeaturePlayback

@MainActor
final class StreamingPlaybackTests: XCTestCase {
    func testSDRConversionNoticeNeedsRealOutputEvidenceAndLeavesPlaybackAlone() async {
        let provider = QualityPlaybackProvider()
        await provider.setSourceRange("HDR10")
        let (model, engine, _) = make(provider: provider)
        await model.load()
        XCTAssertFalse(model.streamingUsesSDRConversion)
        engine.streamingOutputDynamicRange = .hdr10
        XCTAssertFalse(model.streamingUsesSDRConversion)
        engine.streamingOutputDynamicRange = .sdr
        XCTAssertTrue(model.streamingUsesSDRConversion)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.streamingOptions?.quality, .hd720)
        let calls = await provider.calls
        XCTAssertEqual(calls.count, 1, "A valid tone-mapped stream must not be re-resolved or rejected")
        await model.stop()
    }

    func testVersionContinuationKeepsCurrentPositionQualityTracksPauseAndSpeed() async {
        let (outgoing, engine, _) = make(options: .init(quality: .hd720))
        await outgoing.load()
        outgoing.selectAudioOption(id: 4)
        outgoing.selectSubtitleOption(id: 6)
        engine.currentTime = 120
        outgoing.changeStreamingOptions(.init(quality: .sd480))
        await wait { engine.positions.count == 2 && outgoing.phase == .ready }
        engine.currentTime = 92
        outgoing.setPaused(true)
        outgoing.setPlaybackSpeed(1.5)
        let continuation = outgoing.continuationForVersionChange()
        XCTAssertEqual(continuation.position, 92, "Do not reuse the older quality-change position")
        await outgoing.stop()

        let incomingEngine = QualityEngine()
        let provider = QualityPlaybackProvider()
        let incoming = PlayerViewModel(
            provider: provider, itemID: "movie", mediaSourceID: "other-version",
            continuation: continuation,
            playbackSettings: .init(resumeRewindInterval: .five, audioLanguagePreference: .device),
            streamingOptions: .init(quality: .original),
            engineFactory: .init(makeNative: { _ in incomingEngine })
        )
        await incoming.load()
        XCTAssertEqual(incomingEngine.positions, [92])
        XCTAssertTrue(incomingEngine.isPaused)
        XCTAssertEqual(incoming.controls.playbackSpeed, 1.5)
        XCTAssertEqual(incoming.streamingOptions?.quality, .sd480)
        XCTAssertEqual(incomingEngine.currentAudioTrackID, 4)
        XCTAssertEqual(incomingEngine.selectedSubtitleID, 6)
        let calls = await provider.calls
        XCTAssertEqual(calls.first?.source, "other-version")
        await incoming.stop()
    }

    func testLateEngineLoadCannotReplaceTerminalStartupFailureWithReady() async {
        let (model, engine, _) = make(options: .init(quality: .low, codec: .preferH264))
        let gate = QualityDecisionGate()
        engine.loadGate = gate
        let loading = Task { await model.load() }
        await gate.waitUntilEntered()
        XCTAssertFalse(model.handoffHandleStartupTimeout())
        model.handoffSetPhase(.failed(.invalidResponse))
        await gate.release()
        await loading.value
        XCTAssertEqual(model.phase, .failed(.invalidResponse))
        XCTAssertEqual(model.streamingQualityError, .startupTimedOut)
        await model.stop()
    }

    func testQueuedFailureCannotOverwriteANewerRendition() async {
        let (model, engine, provider) = make()
        await model.load()
        engine.onFailure?(.invalidResponse)
        model.changeStreamingOptions(.init(quality: .sd480))
        await wait { engine.positions.count == 2 && model.phase == .ready }
        let calls = await provider.calls
        XCTAssertEqual(calls.map { $0.options.quality }, [.hd720, .sd480])
        XCTAssertEqual(calls.last?.options.codec, .automatic)
        XCTAssertNil(model.streamingQualityError)
        await model.stop()
    }

    func testStartupTimeoutIsNotReportedAsAServerCodecRejection() async {
        let (model, _, _) = make(options: .init(quality: .hd720, codec: .preferH264))
        await model.load()
        XCTAssertFalse(model.handoffHandleStartupTimeout())
        model.handoffSetPhase(.failed(.invalidResponse))
        XCTAssertEqual(model.streamingQualityError, .startupTimedOut)
        XCTAssertEqual(model.streamingQualityError?.diagnosticCode, "PlaybackStartupTimeout")
        await model.stop()
    }

    func testTimeoutFallbackStaysBoundedAndReportsItsActualStage() async {
        let (model, engine, provider) = make()
        await model.load()
        XCTAssertTrue(model.handoffHandleStartupTimeout())
        XCTAssertTrue(model.streamingUsedH264Fallback)
        await wait { engine.positions.count == 2 && model.phase == .ready }
        XCTAssertFalse(model.handoffHandleStartupTimeout())
        let calls = await provider.calls
        XCTAssertEqual(calls.map { $0.options.quality }, [.hd720, .hd720])
        XCTAssertEqual(calls.map { $0.options.codec }, [.automatic, .preferH264])
        XCTAssertEqual(model.streamingQualityError, .startupTimedOut)
        await model.stop()
    }

    func testNetworkStreamFailureSkipsCodecRetryAndKeepsItsEvidence() async {
        let (model, engine, provider) = make()
        await model.load()
        let failure = StreamingPlaybackFailure(kind: .network, domain: .url, code: -1009)
        engine.streamingFailure = failure
        engine.onFailure?(.invalidResponse)
        await wait { if case .failed = model.phase { return true }; return false }
        XCTAssertEqual(model.streamingQualityError, .playback(failure))
        XCTAssertEqual(engine.status, .idle, "No failed stream should keep playing behind its error")
        let calls = await provider.calls
        XCTAssertEqual(calls.count, 1)
        await model.stop()
    }

    func testTerminalFailureRetainsResumeAfterStoppingTheDecoder() async {
        let (model, engine, _) = make(options: .init(quality: .hd720, codec: .preferH264))
        await model.load()
        engine.currentTime = 142
        engine.streamingFailure = .init(kind: .network, domain: .url, code: -1009)
        engine.onFailure?(.invalidResponse)
        await wait { if case .failed = model.phase { return true }; return false }
        XCTAssertEqual(engine.status, .idle)
        XCTAssertEqual(engine.currentTime, 0)
        XCTAssertEqual(model.continuationForVersionChange().position, 142)
        model.changeStreamingOptions(.init(quality: .hd720, codec: .preferH264))
        await wait { model.phase == .ready && engine.positions.count == 2 }
        XCTAssertEqual(engine.positions.last, 142)
        await model.stop()
    }

    func testConfirmedHDRConversionFailureDoesNotRepeatAnIdenticalH264Attempt() async {
        let (model, engine, provider) = make()
        await model.load()
        let failure = StreamingPlaybackFailure(kind: .hdrConversion, domain: .coreMedia, code: -12927, provider: .emby)
        engine.streamingFailure = failure
        engine.onFailure?(.invalidResponse)
        await wait { if case .failed = model.phase { return true }; return false }
        XCTAssertEqual(model.streamingQualityError, .playback(failure))
        let calls = await provider.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(model.streamingOptions?.quality, .hd720)
        XCTAssertEqual(engine.status, .idle)
        await model.stop()
    }

    func testAuthenticationErrorsRemainAuthenticationErrors() {
        XCTAssertNil(PlayerViewModel.streamingFailure(.unauthorized))
        XCTAssertNil(PlayerViewModel.streamingFailure(.serverUnreachable))
        XCTAssertEqual(PlayerViewModel.streamingFailure(.invalidResponse), .playback(.init(kind: .unknown)))
        XCTAssertEqual(PlayerViewModel.streamingFailure(.invalidResponse, streamWasSupplied: false), .negotiationFailed)
    }
    private func make(
        options: StreamingPlaybackOptions? = .init(quality: .hd720),
        provider: QualityPlaybackProvider = QualityPlaybackProvider()
    ) -> (PlayerViewModel, QualityEngine, QualityPlaybackProvider) {
        let engine = QualityEngine()
        let model = PlayerViewModel(
            provider: provider, itemID: "movie", mediaSourceID: "version",
            playbackSettings: .init(resumeRewindInterval: .five, audioLanguagePreference: .device),
            streamingOptions: options,
            engineFactory: .init(makeNative: { _ in engine })
        )
        return (model, engine, provider)
    }

    private func wait(_ condition: @escaping () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition(), "Streaming transition did not finish")
    }

    func testChangingQualityRetainsVersionPositionPauseAndSpeedAndReleasesOldSession() async {
        let (model, engine, provider) = make()
        await model.load()
        engine.currentTime = 123
        engine.duration = 600
        engine.onProgress?()
        model.setPaused(true)
        model.setPlaybackSpeed(1.5)
        model.changeStreamingOptions(.init(quality: .sd480, codec: .preferH264))
        await wait { engine.positions.count == 2 && model.phase == .ready }
        XCTAssertEqual(engine.positions.last, 123, "Quality switching must not apply resume rewind")
        XCTAssertTrue(engine.isPaused)
        XCTAssertEqual(model.controls.playbackSpeed, 1.5)
        XCTAssertEqual(model.streamingOptions?.quality, .sd480)
        let calls = await provider.calls
        XCTAssertEqual(calls.map(\.source), ["version", "version"])
        XCTAssertEqual(calls.map(\.item), ["movie", "movie"])
        let released = await provider.released
        XCTAssertEqual(released, ["quality-1"])
        await model.stop()
    }

    func testHEVCFailureRetriesH264OnceWithoutRaisingTheBudget() async {
        let (model, engine, provider) = make(options: .init(quality: .sd480, codec: .preferHEVC))
        await model.load()
        engine.onFailure?(.invalidResponse)
        await wait { engine.positions.count == 2 && model.phase == .ready }
        let calls = await provider.calls
        XCTAssertEqual(calls.map { $0.options.quality }, [.sd480, .sd480])
        XCTAssertEqual(calls.map { $0.options.codec }, [.preferHEVC, .preferH264])
        engine.onFailure?(.invalidResponse)
        await wait { if case .failed = model.phase { return true }; return false }
        let finalCalls = await provider.calls
        XCTAssertEqual(finalCalls.count, 2, "No original or repeated codec fallback")
        await model.stop()
    }

    func testMissingConvertedResourceRetriesAFreshH264SessionOnce() async {
        let (model, engine, provider) = make(options: .init(quality: .low, codec: .preferHEVC))
        await model.load()
        engine.streamingFailure = .init(kind: .unavailable, domain: .url, code: -1100)
        engine.onFailure?(.invalidResponse)
        await wait { engine.positions.count == 2 && model.phase == .ready }
        let calls = await provider.calls
        XCTAssertEqual(calls.map { $0.options.quality }, [.low, .low])
        XCTAssertEqual(calls.last?.options.codec, .preferH264)
        engine.onFailure?(.invalidResponse)
        await wait { if case .failed = model.phase { return true }; return false }
        let final = await provider.calls
        XCTAssertEqual(final.count, 2)
        await model.stop()
    }

    func testStreamingPolicyIsOptInAndLeavesTVStyleCallersUnchanged() async {
        let (model, _, provider) = make(options: nil)
        await model.load()
        XCTAssertNil(model.streamingOptions)
        XCTAssertFalse(model.streamingQualityAvailable)
        let ordinaryCalls = await provider.ordinaryCalls
        let calls = await provider.calls
        XCTAssertEqual(ordinaryCalls, 1)
        XCTAssertTrue(calls.isEmpty)
        await model.stop()
    }

    func testRenditionSwitchRetainsManualAudioAndSubtitleSelections() async {
        let (model, engine, provider) = make(options: .init(quality: .original))
        await model.load()
        model.selectAudioOption(id: 4)
        model.selectSubtitleOption(id: 6)
        engine.currentTime = 80
        model.changeStreamingOptions(.init(quality: .hd720))
        await wait { engine.positions.count == 2 && model.phase == .ready }
        let calls = await provider.calls
        XCTAssertEqual(calls.last?.options.audioTrack?.language, "jpn")
        XCTAssertEqual(calls.last?.options.subtitleTrack?.language, "eng")
        XCTAssertEqual(engine.currentAudioTrackID, 4)
        XCTAssertEqual(engine.selectedSubtitleID, 6)
        model.selectSubtitleOption(id: PlayerTrackOption.offID)
        model.changeStreamingOptions(.init(quality: .sd480))
        await wait { engine.positions.count == 3 && model.phase == .ready }
        XCTAssertNil(engine.selectedSubtitleID)
        let afterOff = await provider.calls
        XCTAssertEqual(afterOff.last?.options.subtitlesOff, true)
        await model.stop()
    }

    func testRefusedQualitySurfacesSpecificErrorWithoutOriginalRetry() async {
        let provider = QualityPlaybackProvider()
        await provider.setRefusesQuality()
        let (model, engine, _) = make(provider: provider)
        await model.load()
        XCTAssertNotNil(model.streamingQualityError)
        XCTAssertEqual(engine.positions.count, 0)
        XCTAssertTrue(model.streamingQualityAvailable, "The quality menu must remain available to recover")
        let ordinaryCalls = await provider.ordinaryCalls
        XCTAssertEqual(ordinaryCalls, 0)
        await model.stop()
    }

    func testCancelledOldDecisionCannotLoadAfterANetworkQualityChange() async {
        let gate = QualityDecisionGate()
        let provider = QualityPlaybackProvider(gate: gate)
        let (model, engine, _) = make(options: .init(quality: .original), provider: provider)
        let initial = Task { await model.load() }
        await gate.waitUntilEntered()
        model.changeStreamingOptions(.init(quality: .hd720))
        await gate.release()
        await initial.value
        await wait { model.phase == .ready }
        XCTAssertEqual(engine.loadedQualities, [.hd720])
        let released = await provider.released
        XCTAssertTrue(released.contains("quality-1"))
        await model.stop()
    }

    func testStopDuringPendingChangeCannotResurrectPlayback() async {
        let gate = QualityDecisionGate()
        let provider = QualityPlaybackProvider(gate: gate)
        let (model, engine, _) = make(provider: provider)
        let load = Task { await model.load() }
        await gate.waitUntilEntered()
        await model.stop()
        await gate.release()
        await load.value
        XCTAssertTrue(engine.positions.isEmpty)
        let released = await provider.released
        XCTAssertEqual(released, ["quality-1"])
    }

    func testRapidQualityChangesDiscardTheSupersededRendition() async {
        let (model, engine, provider) = make()
        await model.load()
        engine.currentTime = 75
        model.setPaused(true)
        let gate = QualityDecisionGate()
        await provider.installGate(gate)
        model.changeStreamingOptions(.init(quality: .sd480))
        await gate.waitUntilEntered()
        model.changeStreamingOptions(.init(quality: .hd1080))
        await gate.release()
        await wait { model.phase == .ready && engine.positions.count == 2 }
        XCTAssertEqual(engine.loadedQualities, [.hd720, .hd1080])
        XCTAssertEqual(engine.positions.last, 75)
        XCTAssertTrue(engine.isPaused)
        let released = await provider.released
        XCTAssertTrue(released.contains("quality-2"))
        await model.stop()
    }

    func testOfflineRewriteAndAdoptionCannotRetainAnOldStreamingPolicy() {
        var request = PlaybackRequest(
            item: MediaItem(id: "movie", title: "Movie", kind: .movie),
            streamURL: URL(string: "https://fixture.test/master.m3u8")!, isTranscoding: true
        )
        request.streamingOptions = .init(quality: .hd720)
        request.streamingSessionID = "session"
        let local = PlayerViewModel.applyingOfflineRewrite(
            to: request, localURL: URL(fileURLWithPath: "/fixture/movie.mp4")
        )
        XCTAssertNil(local.streamingOptions)
        XCTAssertNil(local.streamingSessionID)
        XCTAssertFalse(local.isTranscoding)
        XCTAssertFalse(PlayerViewModel.streamingSelectionMatches(.init(quality: .hd720), .init(quality: .original)))
        XCTAssertFalse(PlayerViewModel.streamingSelectionMatches(.init(quality: .hd720), nil))
        XCTAssertTrue(PlayerViewModel.streamingSelectionMatches(nil, nil))
    }
}

private actor QualityDecisionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false
    func suspend() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !entered, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(entered)
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor QualityPlaybackProvider: StreamingQualityProviding {
    struct Call: Sendable { let item: String; let source: String?; let options: StreamingPlaybackOptions }
    nonisolated let kind: ProviderKind = .plex
    nonisolated let session = UserSession(
        server: .init(id: "server", name: "Server", baseURL: URL(string: "https://fixture.test")!, provider: .plex),
        userID: "user", userName: "User", deviceID: "device", accessToken: "fixture"
    )
    private(set) var calls: [Call] = []
    private(set) var ordinaryCalls = 0
    private(set) var released: [String] = []
    private var refusesQuality = false
    private var sourceRange: String?
    private var gate: QualityDecisionGate?
    init(gate: QualityDecisionGate? = nil) { self.gate = gate }
    func installGate(_ gate: QualityDecisionGate) { self.gate = gate }
    func setRefusesQuality() { refusesQuality = true }
    func setSourceRange(_ range: String) { sourceRange = range }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        ordinaryCalls += 1
        return baseRequest()
    }
    func playbackInfo(for itemID: String, mediaSourceID: String?, forceTranscode: Bool, streaming: StreamingPlaybackOptions) async throws -> PlaybackRequest {
        calls.append(.init(item: itemID, source: mediaSourceID, options: streaming))
        let sequence = calls.count
        if let gate { self.gate = nil; await gate.suspend() }
        if refusesQuality { throw StreamingQualityError.unavailable }
        var request = baseRequest()
        request.isTranscoding = streaming.requiresConversionPolicy
        request.deliveryMode = request.isTranscoding ? .transcode : .directPlay
        request.streamingOptions = streaming
        request.streamingSessionID = "quality-\(sequence)"
        return request
    }
    func releaseStreamingSession(_ request: PlaybackRequest) {
        if let id = request.streamingSessionID { released.append(id) }
    }
    private func baseRequest() -> PlaybackRequest {
        PlaybackRequest(item: MediaItem(id: "movie", title: "Movie", kind: .movie, runtime: 600),
                        streamURL: URL(string: "https://fixture.test/master.m3u8")!,
                        audioTracks: [
                            .init(id: 3, kind: .audio, displayTitle: "English", language: "eng", isDefault: true),
                            .init(id: 4, kind: .audio, displayTitle: "Japanese", language: "jpn")
                        ],
                        subtitleTracks: [.init(id: 6, kind: .subtitle, displayTitle: "English", language: "eng")],
                        isTranscoding: true,
                        sourceMetadata: sourceRange.map { .init(video: .init(videoRangeType: $0)) })
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { baseRequest().item }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        .init(items: [], startIndex: 0, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

@MainActor
private final class QualityEngine: VideoEngine {
    var loadGate: QualityDecisionGate?
    var streamingFailure: StreamingPlaybackFailure?
    var streamingOutputDynamicRange: SourceDynamicRange?
    let displayName = "Quality fixture"
    var status: VideoEngineStatus = .idle
    var isPaused = false
    var preventsDisplaySleep = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 600
    var furthestObservedPosition: TimeInterval = 0
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var currentAudioTrackID: Int?
    var selectedSubtitleID: Int?
    var positions: [TimeInterval] = []
    var loadedQualities: [StreamingQuality] = []
    var onProgress: (@MainActor () -> Void)?
    var onFailure: (@MainActor (AppError) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onTracksChanged: (@MainActor () -> Void)?
    var onProbedSourceFactsChanged: (@MainActor (EngineProbedSourceFacts) -> Void)?
    var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var capabilities: PlayerEngineCapabilities { [.playbackSpeed] }
    var maximumPlaybackSpeed: Double { 4 }
    func load(request: PlaybackRequest, startPosition: TimeInterval) async {
        if let loadGate { self.loadGate = nil; await loadGate.suspend() }
        positions.append(startPosition)
        if let quality = request.streamingOptions?.quality { loadedQualities.append(quality) }
        currentTime = startPosition
        audioTracks = request.audioTracks
        subtitleTracks = request.subtitleTracks
        currentAudioTrackID = request.streamingOptions?.audioTrack?.id ?? 3
        selectedSubtitleID = nil
        status = .ready
    }
    func play() { isPaused = false }
    func pause() { isPaused = true }
    func seek(to seconds: TimeInterval) async { currentTime = seconds }
    func stop() { status = .idle; currentTime = 0; isPaused = true }
    func selectAudioTrack(_ track: MediaTrack?) { currentAudioTrackID = track?.id }
    func selectSubtitleTrack(_ track: MediaTrack?) { selectedSubtitleID = track?.id }
    #if canImport(UIKit)
    func makeVideoOutputView() -> UIView { UIView() }
    #endif
}
#endif
