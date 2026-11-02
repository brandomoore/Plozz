import AetherEngine
import CoreModels
import FeaturePlayback
import XCTest
@testable import EnginePlozzigen

final class PlozzigenLiveOutputTests: XCTestCase {
    #if os(tvOS)
    @MainActor
    func testSDRPreviewFullscreenRoundTripsKeepThePlayingItemAndPauseState() async throws {
        try await verifySDRPresentationRoundTrips(isLive: false)
    }

    @MainActor
    func testLiveSDRPreviewFullscreenRoundTripsKeepThePlayingItemAndPauseState() async throws {
        try await verifySDRPresentationRoundTrips(isLive: true)
    }

    @MainActor
    private func verifySDRPresentationRoundTrips(isLive: Bool) async throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "no-chapters", withExtension: "mp4", subdirectory: "Fixtures"
        ))
        let engine = try PlozzigenVideoEngine()
        defer { engine.stop() }
        var policy = LiveChannelOutputPolicy(
            isAudible: true, sharesAudioSession: true, suppressesDisplayMatching: true
        )
        engine.configureLiveOutput(policy)
        if isLive {
            await engine.loadLive(url: url, httpHeaders: [:])
        } else {
            await engine.load(
                request: PlaybackRequest(item: .init(id: "channel", title: "Fixture", kind: .movie), streamURL: url),
                startPosition: 0
            )
        }
        let deadline = ContinuousClock.now + .seconds(20)
        while !engine.isPlaybackPositionReady, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(engine.isPlaybackPositionReady)
        engine.pause()
        let player = try XCTUnwrap(engine.nowPlayingPlayer)
        let item = try XCTUnwrap(player.currentItem)
        let position = engine.currentTime
        let selectedAudio = engine.currentAudioTrackID
        for suppressed in [false, true, false, true] {
            policy.suppressesDisplayMatching = suppressed
            engine.configureLiveOutput(policy)
            // Observe beyond the async policy task's admission, not just the synchronous setter.
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertTrue(engine.nowPlayingPlayer === player)
            XCTAssertTrue(player.currentItem === item, "Presentation must not replace the stream's AVPlayerItem.")
            XCTAssertEqual(engine.status, .ready)
            XCTAssertTrue(engine.isPaused)
            XCTAssertEqual(engine.currentTime, position, accuracy: 0.1)
            XCTAssertEqual(engine.currentAudioTrackID, selectedAudio)
        }
    }
    #endif

    func testEveryCushionPreservesRoutingStorageAndAudioPolicy() throws {
        for path in ["live.ts", "live.m3u8"] {
            let url = try XCTUnwrap(URL(string: "https://example.invalid/\(path)"))
            for buffer in LivePlaybackBuffer.allCases {
                let options = PlozzigenVideoEngine.liveLoadOptions(
                    httpHeaders: ["X-Fixture": "live"], url: url, buffer: buffer
                )
                XCTAssertEqual(options.liveEdgeCushionSeconds, buffer.seconds)
                XCTAssertTrue(options.isLive)
                XCTAssertEqual(options.nativeRemoteHLS, path.hasSuffix("m3u8"))
                XCTAssertEqual(options.objectAudioRendering, .off)
                XCTAssertNil(options.forwardBufferSegments)
                XCTAssertNil(options.sessionCacheByteBudget)
                XCTAssertNil(options.dvrWindowSeconds)
                XCTAssertEqual(options.softwarePacketCacheStorage, .automatic)
            }
        }
    }

    @MainActor
    func testCushionAndStartupAllowanceAreSampledTogetherForEachLoadAndResetOnStop() throws {
        var preference = LivePlaybackBuffer.automatic
        let engine = try PlozzigenVideoEngine(liveBufferPreference: { preference })
        defer { engine.stop() }
        XCTAssertEqual(engine.liveStartupBuffer, .automatic)
        XCTAssertNil(engine.liveLoadOptions(httpHeaders: [:]).liveEdgeCushionSeconds)
        preference = .fortyFiveSeconds
        let options = engine.liveLoadOptions(httpHeaders: [:])
        XCTAssertEqual(options.liveEdgeCushionSeconds, 45)
        XCTAssertEqual(engine.liveStartupBuffer, .fortyFiveSeconds)
        preference = .tenSeconds
        XCTAssertEqual(engine.liveStartupBuffer, .fortyFiveSeconds)
        XCTAssertEqual(options.liveEdgeCushionSeconds, 45)
        XCTAssertEqual(engine.liveLoadOptions(httpHeaders: [:]).liveEdgeCushionSeconds, 10)
        XCTAssertEqual(engine.liveStartupBuffer, .tenSeconds)
        engine.stop()
        XCTAssertEqual(engine.liveStartupBuffer, .automatic)
        XCTAssertNil(try PlozzigenVideoEngine().liveLoadOptions(httpHeaders: [:]).liveEdgeCushionSeconds)
    }

    func testRawTransportStreamsDoNotUseTheHLSOnlyNativeBypass() throws {
        for suffix in ["ts", "m2ts", "mts", "TS"] {
            let url = try XCTUnwrap(URL(string: "http://127.0.0.1/opaque.\(suffix)"))
            let options = PlozzigenVideoEngine.liveLoadOptions(httpHeaders: [:], url: url)
            XCTAssertTrue(options.isLive)
            XCTAssertEqual(options.objectAudioRendering, .off)
            XCTAssertFalse(options.nativeRemoteHLS, suffix)
            XCTAssertEqual(options.liveJoinProfile, .fastZap, suffix)
        }
        let playlist = try XCTUnwrap(URL(string: "http://127.0.0.1/opaque.m3u8"))
        XCTAssertTrue(PlozzigenVideoEngine.liveLoadOptions(httpHeaders: [:], url: playlist).nativeRemoteHLS)
        let opaque = try XCTUnwrap(URL(string: "http://127.0.0.1/extensionless"))
        XCTAssertFalse(PlozzigenVideoEngine.liveLoadOptions(httpHeaders: [:], url: opaque).nativeRemoteHLS)
        let detected = PlozzigenVideoEngine.liveLoadOptions(httpHeaders: [:], url: opaque, sourceFormat: .hls)
        XCTAssertTrue(detected.nativeRemoteHLS)
        XCTAssertEqual(detected.objectAudioRendering, .off)
        XCTAssertEqual(detected.liveJoinProfile, .standard)
    }

    func testOutputPoliciesLeavePanelModeInferenceToAether() {
        for var options in [
            LoadOptions(matchContentEnabled: true),
            PlozzigenVideoEngine.liveLoadOptions(httpHeaders: [:]),
        ] {
            for suppressesDisplayMatching in [true, false] {
                PlozzigenVideoEngine.applyLiveOutputPolicy(
                    .init(isAudible: true, sharesAudioSession: false,
                          suppressesDisplayMatching: suppressesDisplayMatching),
                    to: &options)
                XCTAssertFalse(options.panelIsInHDRMode)
                XCTAssertTrue(options.attemptsHDRMasterOnUnprovenPanel)
                #if os(tvOS)
                XCTAssertEqual(options.displayCriteriaOwner, suppressesDisplayMatching ? .host : .engine)
                #else
                XCTAssertEqual(options.displayCriteriaOwner, .engine)
                #endif
                XCTAssertEqual(options.suppressDisplayCriteria, suppressesDisplayMatching)
                XCTAssertEqual(options.matchContentEnabled, !suppressesDisplayMatching)
            }
        }
    }

    func testScheduledFilesAndNetworkStreamsShareDisplaySuppression() {
        var file = LoadOptions(matchContentEnabled: true)
        var stream = PlozzigenVideoEngine.liveLoadOptions(httpHeaders: [:])
        PlozzigenVideoEngine.applyLiveOutputPolicy(
            .init(isAudible: false, sharesAudioSession: true, suppressesDisplayMatching: true), to: &file
        )
        PlozzigenVideoEngine.applyLiveOutputPolicy(
            .init(isAudible: true, sharesAudioSession: true, suppressesDisplayMatching: true), to: &stream
        )
        XCTAssertTrue(file.suppressDisplayCriteria)
        XCTAssertTrue(stream.suppressDisplayCriteria)
        XCTAssertFalse(file.matchContentEnabled)
        XCTAssertFalse(stream.matchContentEnabled)
        XCTAssertTrue(stream.isLive)
        XCTAssertFalse(file.isLive)
    }

    func testSinglePlayerPolicyPreservesMatchingOnSubsequentLoad() {
        var options = LoadOptions(matchContentEnabled: false)
        options.suppressDisplayCriteria = true
        PlozzigenVideoEngine.applyLiveOutputPolicy(.init(), to: &options)
        XCTAssertTrue(options.matchContentEnabled)
        XCTAssertFalse(options.suppressDisplayCriteria)
    }
}
