#if DEBUG && canImport(UIKit)
import AVFoundation
@testable import CoreModels
import CoreNetworking
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import FeaturePlayback

private final class LiveChannelObservationChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCount = 0

    var count: Int { lock.withLock { recordedCount } }

    func record() { lock.withLock { recordedCount += 1 } }
}

@MainActor
final class LiveChannelPlayerModelTests: XCTestCase {
    func testPreviewPublishesSourceRangeAndChangesOutputWithoutRetuning() async {
        let engine = LiveEngineSpy()
        let model = LiveChannelPlayerModel(
            engine: engine, streamURL: URL(string: "https://example.invalid/live.m3u8")!,
            allowsDisplayMatching: false
        )
        defer { model.stop() }
        await model.start()
        XCTAssertNil(model.sourceDynamicRange)
        engine.probedSourceFacts = .init(range: .dolbyVision)
        model.refreshFromEngine()
        XCTAssertEqual(model.sourceDynamicRange, .dolbyVision)
        XCTAssertFalse(model.allowsDisplayMatching)
        model.setDisplayMatchingAllowed(true)
        XCTAssertTrue(model.allowsDisplayMatching)
        XCTAssertFalse(engine.outputPolicy.suppressesDisplayMatching)
        engine.probedSourceFacts = nil
        model.refreshFromEngine()
        XCTAssertEqual(model.sourceDynamicRange, .dolbyVision, "Retain exit facts during an output rebuild")
        model.setDisplayMatchingAllowed(false)
        XCTAssertTrue(engine.outputPolicy.suppressesDisplayMatching)
        XCTAssertEqual(engine.liveLoads, 1)
        XCTAssertEqual(engine.stopCount, 0)
    }

    func testLocalJournalCapturesLiveFailuresWithoutServerSessionReporting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let journal = PlaybackDiagnosticJournal(url: root.appendingPathComponent("playback.json"))
        let engine = LiveEngineSpy()
        let model = LiveChannelPlayerModel(
            engine: engine, input: .stream(url: URL(string: "https://private.test/live.m3u8")!,
                                          httpHeaders: ["Authorization": "private-token"]),
            playbackJournal: journal
        )
        await model.start()
        model.refreshFromEngine()
        let attempt = try XCTUnwrap(PlaybackFailureDiagnostics().begin(
            layer: .liveEngine, content: .live, captureForPresentation: true
        ))
        attempt.fail(stage: .load, reason: .authentication, engineFailure: .sourceRefused, httpStatus: 403)
        engine.livePlaybackFailureDiagnostic = attempt.diagnostic
        engine.liveTelemetry = .init(droppedFrameCount: 9, bufferedSecondsAhead: 0)
        engine.onFailure?(.unauthorized)
        XCTAssertNil(engine.liveTelemetry, "Engine teardown clears live telemetry.")
        engine.onFailure?(.unauthorized)
        model.stop()
        await journal.flush()
        defer { try? FileManager.default.removeItem(at: root) }
        let report = await journal.report()
        let json = try XCTUnwrap(report.split(separator: "\n", maxSplits: 2).last)
        let entries = try JSONDecoder().decode(PlaybackDiagnosticJournal.Journal.self, from: Data(json.utf8)).entries
        XCTAssertEqual(entries.filter { $0.event == .failed }.count, 1)
        XCTAssertEqual(entries.first { $0.event == .failed }?.liveFailure?.httpStatus, 403)
        XCTAssertEqual(entries.first { $0.event == .failed }?.pipeline?.droppedFrames, 9)
        XCTAssertTrue(entries.contains { $0.event == .firstFrame })
        XCTAssertTrue(entries.allSatisfy { $0.facts.content == .live && $0.facts.provider == nil })
        XCTAssertFalse(report.contains("private"))
        XCTAssertFalse(report.contains("Authorization"))
    }

    func testEndedStreamPreservesTelemetryBeforeEngineTeardown() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = PlaybackDiagnosticJournal(url: root.appendingPathComponent("playback.json"))
        let engine = LiveEngineSpy()
        let model = LiveChannelPlayerModel(
            engine: engine, input: .stream(url: URL(string: "https://example.invalid/live.m3u8")!, httpHeaders: [:]),
            playbackJournal: journal
        )
        await model.start()
        engine.liveTelemetry = .init(droppedFrameCount: 12, bufferedSecondsAhead: 0.5)
        engine.onEnded?()
        XCTAssertNil(engine.liveTelemetry)
        model.stop()
        await journal.flush()
        let report = await journal.report()
        let json = try XCTUnwrap(report.split(separator: "\n", maxSplits: 2).last)
        let value = try JSONDecoder().decode(PlaybackDiagnosticJournal.Journal.self, from: Data(json.utf8))
        let failure = try XCTUnwrap(value.failureSnapshots?.first?.entries.first { $0.event == .failed })
        XCTAssertEqual(failure.pipeline?.droppedFrames, 12)
        XCTAssertEqual(failure.pipeline?.bufferedSeconds, 0.5)
    }

    func testLateVideoDimensionsPublishWithoutRetuningOrRepeatedNotifications() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        XCTAssertNil(model.videoAspectRatio)
        let changes = LiveChannelObservationChanges()
        withObservationTracking {
            _ = model.videoAspectRatio
        } onChange: {
            changes.record()
        }
        engine.videoAspectRatio = 16 / 9
        model.refreshFromEngine()
        XCTAssertEqual(model.videoAspectRatio, 16 / 9)
        XCTAssertEqual(changes.count, 1)
        withObservationTracking {
            _ = model.videoAspectRatio
        } onChange: {
            changes.record()
        }
        model.refreshFromEngine()
        XCTAssertEqual(changes.count, 1)
        engine.videoAspectRatio = 4 / 3
        model.refreshFromEngine()
        XCTAssertEqual(model.videoAspectRatio, 4 / 3)
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(engine.liveLoads, 1)
        XCTAssertEqual(engine.stopCount, 0)
    }

    func testLiveSubtitlesFollowThePresentedFrameInsteadOfTheSeekTarget() async {
        let engine = LiveEngineSpy()
        engine.presentedSubtitleTime = 50
        engine.liveSnapshot.position = 100
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        model.subtitles.beginLiveFeed()
        model.subtitles.updateLiveCues([
            .init(id: 1, start: 49, end: 52, body: .text(.init("Held picture"))),
            .init(id: 2, start: 99, end: 102, body: .text(.init("Seek target")))
        ])
        model.refreshFromEngine()
        XCTAssertEqual(model.subtitles.primary.compactMap(\.text), ["Held picture"])
        XCTAssertEqual(engine.currentTime, 100)
        engine.presentedSubtitleTime = 100
        model.refreshFromEngine()
        XCTAssertEqual(model.subtitles.primary.compactMap(\.text), ["Seek target"])
        let wrapper = LibraryLiveChannelEngine(engine: engine)
        XCTAssertEqual(wrapper.subtitlePresentationTime, 100)
    }

    func testVODDisplayLinkAlsoUsesThePresentedSubtitleClock() async throws {
        let engine = LiveEngineSpy()
        engine.presentedSubtitleTime = 50
        engine.liveSnapshot.position = 100
        let subtitles = LiveSubtitleModel()
        subtitles.beginLiveFeed()
        subtitles.updateLiveCues([
            .init(id: 1, start: 49, end: 52, body: .text(.init("Held picture"))),
            .init(id: 2, start: 99, end: 102, body: .text(.init("Seek target")))
        ])
        let controller = PlayerInputViewController(
            engine: engine, model: PlayerControlsModel(), actions: PlayerActions()
        )
        controller.loadViewIfNeeded()
        controller.attachSubtitleOverlay(subtitles)
        controller.viewDidAppear(false)
        defer { controller.viewDidDisappear(false) }
        let deadline = ContinuousClock.now + .seconds(2)
        while subtitles.primary.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(subtitles.primary.compactMap(\.text), ["Held picture"])
        XCTAssertEqual(engine.currentTime, 100)
    }

    func testPausingAtTheEdgeKeepsTimeShiftIntentWhileTheDelayGrows() async {
        let engine = LiveEngineSpy()
        engine.liveSnapshot.behindLiveSeconds = 1
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        model.togglePlayPause()
        model.refreshFromEngine()
        XCTAssertFalse(model.canGoLive)
        engine.liveSnapshot.behindLiveSeconds = 5
        model.refreshFromEngine()
        XCTAssertTrue(model.canGoLive, "An initial near-edge refresh must not forget the deliberate pause.")
    }

    func testLiveStyleRefreshesOverlayAndNativeRendererWithoutRetuning() async throws {
        let name = "LiveCaptionStyle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SubtitleStyleModel(store: SubtitleStyleStore(defaults: defaults, namespace: "viewer"))
        settings.style.followsSystemStyle = false
        settings.style.textColor = .yellow
        settings.usesSeparateLiveTVStyle = true
        settings.resolvedLiveTVStyle.fontScale = 0.4
        let preferences = LiveChannelTrackPreferences(namespace: "viewer", defaults: defaults)
        let engine = LiveEngineSpy()
        let model = LiveChannelPlayerModel(
            engine: engine, streamURL: URL(string: "https://example.invalid/channel.m3u8")!,
            trackPreferences: preferences
        )
        defer { model.stop() }
        await model.start()
        model.refreshFromEngine()
        XCTAssertEqual(model.subtitles.style.fontScale, 0.4)
        XCTAssertEqual(engine.subtitleStyles.last, settings.resolvedLiveTVStyle)

        settings.resolvedLiveTVStyle.followsSystemStyle = true
        model.refreshFromEngine()
        XCTAssertTrue(model.subtitles.style.followsSystemStyle)
        XCTAssertEqual(engine.subtitleStyles.last, settings.resolvedLiveTVStyle)
        XCTAssertFalse(settings.style.followsSystemStyle)
        let count = engine.subtitleStyles.count
        model.refreshFromEngine()
        XCTAssertEqual(engine.subtitleStyles.count, count)

        let other = SubtitleStyleModel(store: SubtitleStyleStore(defaults: defaults, namespace: "other"))
        other.style.textColor = .pink
        model.refreshFromEngine()
        XCTAssertEqual(engine.subtitleStyles.count, count)

        settings.usesSeparateLiveTVStyle = false
        model.refreshFromEngine()
        XCTAssertEqual(model.subtitles.style, settings.style)
        XCTAssertEqual(engine.subtitleStyles.last, settings.style)
        XCTAssertEqual(engine.liveLoads, 1)
        engine.onProgrammeChanged?()
        model.refreshFromEngine()
        XCTAssertEqual(engine.subtitleStyles.last, settings.style)
        XCTAssertEqual(engine.subtitleStyles.count, count + 2)
    }

    func testLiveFailureCopyDoesNotAskPublicChannelViewersToSignInAgain() {
        let messages: [(AppError, String)] = [
            (.notFound, "could not find this stream"),
            (.unauthorized, "did not authorize access"),
            (.serverUnreachable, "streaming server"),
            (.invalidResponse, "playlist or video data"),
            (.decoding, "could not decode"),
            (.rateLimited(retryAfter: nil), "limiting requests"),
            (.unknown("https://example.invalid/?token=fixture-secret"), "could not start playback")
        ]
        for (error, expected) in messages {
            let message = String(localized: LiveChannelPlaybackFailure.engineMessage(error))
            XCTAssertTrue(message.contains(expected), message)
            XCTAssertFalse(message.contains("fixture-secret"))
            XCTAssertFalse(message.contains("sign in again"))
            XCTAssertFalse(message.contains("Something went wrong"))
        }
    }

    private func makeModel(
        engine: LiveEngineSpy,
        clock: LiveTestClock = LiveTestClock()
    ) -> LiveChannelPlayerModel {
        LiveChannelPlayerModel(
            engine: engine,
            streamURL: URL(string: "https://example.invalid/channel.m3u8")!,
            uptime: { clock.now }
        )
    }

    func testLoadsLiveInsteadOfConstructingVODRequest() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        XCTAssertEqual(engine.liveLoads, 1)
        XCTAssertEqual(engine.vodLoads, 0)
        XCTAssertNotNil(engine.onLiveSourceReset)
        XCTAssertEqual(model.phase, .playing)
        XCTAssertFalse(model.showsActivityIndicator)
    }

    func testPlaybackFacetInvalidatesPhaseWithoutInvalidatingTrackMenu() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        let phaseChanges = LiveChannelObservationChanges()
        let trackChanges = LiveChannelObservationChanges()
        withObservationTracking {
            _ = model.phase
        } onChange: {
            phaseChanges.record()
        }
        withObservationTracking {
            _ = model.audioTracks
        } onChange: {
            trackChanges.record()
        }

        model.togglePlayPause()

        XCTAssertEqual(model.phase, .paused)
        XCTAssertEqual(phaseChanges.count, 1)
        XCTAssertEqual(trackChanges.count, 0)
    }

    func testTrackFacetInvalidatesListsSelectionsAndProgrammeResetWithoutUnrelatedPhaseChanges() async {
        let engine = LiveEngineSpy()
        engine.audioTracks = [.init(id: 1, kind: .audio, displayTitle: "English", language: "eng")]
        engine.currentAudioTrackID = 1
        let model = LiveChannelPlayerModel(
            engine: engine, input: .libraryChannel(id: UUID(), authorizationID: "observation-fixture")
        )
        defer { model.stop() }
        await model.start()
        let originalSubtitles = model.subtitles
        let phaseChanges = LiveChannelObservationChanges()
        let trackChanges = LiveChannelObservationChanges()
        let selectionChanges = LiveChannelObservationChanges()
        withObservationTracking {
            _ = model.phase
        } onChange: {
            phaseChanges.record()
        }
        withObservationTracking {
            _ = model.audioTracks
        } onChange: {
            trackChanges.record()
        }
        withObservationTracking {
            _ = model.selectedAudioID
        } onChange: {
            selectionChanges.record()
        }
        let french = MediaTrack(id: 2, kind: .audio, displayTitle: "French", language: "fra")
        engine.audioTracks.append(french)
        engine.onTracksChanged?()
        model.selectAudio(french)

        XCTAssertEqual(trackChanges.count, 1)
        XCTAssertEqual(selectionChanges.count, 1)
        XCTAssertEqual(model.selectedAudioID, 2)
        XCTAssertEqual(phaseChanges.count, 0)
        let resetChanges = LiveChannelObservationChanges()
        withObservationTracking {
            _ = model.audioTracks
            _ = model.selectedAudioID
        } onChange: {
            resetChanges.record()
        }
        engine.onProgrammeChanged?()
        XCTAssertEqual(resetChanges.count, 1)
        XCTAssertTrue(model.audioTracks.isEmpty)
        XCTAssertNil(model.selectedAudioID)
        XCTAssertTrue(model.subtitles === originalSubtitles)
    }

    func testLiveSessionStartsAtFirstFrameAndReportsStateAndHeartbeat() async {
        let engine = LiveEngineSpy()
        let clock = LiveTestClock()
        engine.liveSnapshot.firstFrameReady = false
        let model = makeModel(engine: engine, clock: clock)
        defer { model.stop() }
        var updates: [LiveTVPlaybackUpdate] = []
        model.setSessionReporting(.init(id: UUID(), update: { updates.append($0) }, failed: { _ in }))
        await model.start()
        XCTAssertTrue(updates.isEmpty)
        engine.liveSnapshot.firstFrameReady = true
        model.refreshFromEngine()
        XCTAssertEqual(updates.map(\.state), [.started])
        clock.now = 14
        model.refreshFromEngine()
        XCTAssertEqual(updates.count, 1)
        clock.now = 15
        model.refreshFromEngine()
        XCTAssertEqual(updates.map(\.state), [.started, .playing])
        model.togglePlayPause()
        model.refreshFromEngine()
        XCTAssertEqual(updates.last?.state, .paused)
        XCTAssertEqual(updates.last?.positionSeconds, 100)
        XCTAssertEqual(engine.vodLoads, 0)
    }

    func testNewLiveSessionReloadsEvenWhenItsResolvedURLIsUnchanged() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        var original: [LiveTVPlaybackUpdate.State] = []
        var replacement: [LiveTVPlaybackUpdate.State] = []
        model.setSessionReporting(.init(id: UUID(), update: { original.append($0.state) }, failed: { _ in }))
        await model.start()
        await model.changeSource(
            channelID: "",
            streamURL: URL(string: "https://example.invalid/channel.m3u8")!,
            reporting: .init(id: UUID(), update: { replacement.append($0.state) }, failed: { _ in })
        )
        XCTAssertEqual(engine.liveLoads, 2)
        XCTAssertEqual(original, [.started])
        XCTAssertEqual(replacement, [.started])
    }

    func testSameLiveSessionDoesNotRestartOrRepeatStartedReport() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        var updates: [LiveTVPlaybackUpdate.State] = []
        let reporting = LiveChannelSessionReporting(id: UUID(), update: { updates.append($0.state) }, failed: { _ in })
        model.setSessionReporting(reporting)
        await model.start()
        await model.changeSource(
            channelID: "",
            streamURL: URL(string: "https://example.invalid/channel.m3u8")!,
            reporting: reporting
        )
        model.refreshFromEngine()
        XCTAssertEqual(engine.liveLoads, 1)
        XCTAssertEqual(updates, [.started])
    }

    func testLiveSessionFailureIsReportedOnceAndStopDoesNotReportFailure() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        var failures = 0
        model.setSessionReporting(.init(id: UUID(), update: { _ in }, failed: { _ in failures += 1 }))
        await model.start()
        engine.onFailure?(.serverUnreachable)
        engine.onFailure?(.serverUnreachable)
        model.refreshFromEngine()
        XCTAssertEqual(failures, 1)
        model.stop()
        XCTAssertEqual(failures, 1)

        let stopped = makeModel(engine: LiveEngineSpy())
        stopped.setSessionReporting(.init(id: UUID(), update: { _ in }, failed: { _ in failures += 1 }))
        await stopped.start()
        stopped.stop()
        XCTAssertEqual(failures, 1)
    }

    func testSessionFailureCapturesEvidenceBeforeEngineStop() async throws {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        var reported: LiveChannelFailureReport?
        model.setSessionReporting(.init(id: UUID(), update: { _ in }, failed: { reported = $0 }))
        await model.start()
        let attempt = try XCTUnwrap(PlaybackFailureDiagnostics().begin(
            layer: .liveEngine, content: .live, captureForPresentation: true
        ))
        attempt.fail(stage: .load, reason: .authentication, engineFailure: .sourceRefused, httpStatus: 403)
        engine.livePlaybackFailureDiagnostic = attempt.diagnostic
        engine.onFailure?(.unauthorized)
        XCTAssertNil(engine.livePlaybackFailureDiagnostic)
        XCTAssertEqual(reported?.failure, .engine(.unauthorized))
        XCTAssertEqual(reported?.diagnostic?.httpStatus, 403)
        XCTAssertTrue(String(localized: try XCTUnwrap(reported?.message)).contains("HTTP 403"))
    }

    func testPlayingIntentWithoutFirstFrameKeepsStartupCover() async {
        let engine = LiveEngineSpy()
        engine.liveSnapshot.firstFrameReady = false
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        XCTAssertEqual(model.phase, .loading)
        XCTAssertFalse(model.hasPresentedFrame)
        engine.liveSnapshot.firstFrameReady = true
        model.refreshFromEngine()
        XCTAssertEqual(model.phase, .playing)
        XCTAssertFalse(model.showsActivityIndicator)
    }

    func testWrappedFailureAndEndCaptureEvidenceBeforeStoppingTheDecoder() async throws {
        for ended in [false, true] {
            let decoder = LiveEngineSpy()
            let wrapper = LibraryLiveChannelEngine(engine: decoder)
            let model = LiveChannelPlayerModel(
                engine: wrapper, streamURL: URL(string: "https://example.invalid/live.m3u8")!
            )
            defer { model.stop() }
            var reports: [LiveChannelFailureReport] = []
            model.setSessionReporting(.init(id: UUID(), update: { _ in }, failed: { reports.append($0) }))
            await model.start()
            let attempt = try XCTUnwrap(PlaybackFailureDiagnostics().begin(
                layer: .liveEngine, content: .live, captureForPresentation: true
            ))
            attempt.fail(stage: .load, reason: .authentication, engineFailure: .sourceRefused, httpStatus: 403)
            decoder.livePlaybackFailureDiagnostic = attempt.diagnostic
            let finish = ended ? decoder.onEnded : { decoder.onFailure?(.unauthorized) }
            finish?()
            finish?()
            XCTAssertNil(decoder.livePlaybackFailureDiagnostic)
            XCTAssertEqual(reports.count, 1)
            XCTAssertEqual(reports.first?.failure, ended ? .ended : .engine(.unauthorized))
            XCTAssertEqual(reports.first?.diagnostic?.httpStatus, 403)
            await wrapper.drainTransport()
        }
    }

    func testPlaylistHeadersSurviveLiveLoadRetryAndSourceReset() async {
        let engine = LiveEngineSpy()
        let headers = ["User-Agent": "IPTV test", "Referer": "https://example.invalid/"]
        let model = LiveChannelPlayerModel(
            engine: engine, streamURL: URL(string: "https://example.invalid/live.m3u8")!,
            httpHeaders: headers
        )
        defer { model.stop() }
        await model.start()
        engine.onFailure?(.serverUnreachable)
        await model.retry()
        engine.onLiveSourceReset?()
        await model.requestRetune()?.value
        XCTAssertEqual(engine.loadedHeaders, Array(repeating: headers, count: engine.liveLoads))
        XCTAssertEqual(engine.liveLoads, 3)
    }

    func testChannelChangeReusesEngineWithNewURLAndHeaders() async {
        let engine = LiveEngineSpy()
        let firstURL = URL(string: "https://example.invalid/one.m3u8")!
        let secondURL = URL(string: "https://example.invalid/two.m3u8")!
        let firstHeaders = ["User-Agent": "First"]
        let secondHeaders = ["User-Agent": "Second", "Referer": "https://example.invalid/"]
        let model = LiveChannelPlayerModel(
            engine: engine,
            channelID: "one",
            streamURL: firstURL,
            httpHeaders: firstHeaders
        )
        defer { model.stop() }

        await model.start()
        await model.changeSource(
            channelID: "two",
            streamURL: secondURL,
            httpHeaders: secondHeaders
        )

        XCTAssertEqual(engine.loadedURLs, [firstURL, secondURL])
        XCTAssertEqual(engine.loadedHeaders, [firstHeaders, secondHeaders])
        XCTAssertEqual(engine.liveLoads, 2)
        XCTAssertEqual(model.phase, .playing)
    }

    func testChannelChangeResetsPerChannelStateAndCoversPreviousFrame() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        engine.onFailure?(.serverUnreachable)
        await model.retry()
        XCTAssertEqual(model.manualRetryCount, 1)
        XCTAssertTrue(model.hasPresentedFrame)

        engine.suspendsLoads = true
        let change = Task {
            await model.changeSource(
                channelID: "replacement",
                streamURL: URL(string: "https://example.invalid/replacement.m3u8")!,
                httpHeaders: ["Authorization": "fixture"]
            )
        }
        await waitForLiveLoads(3, engine: engine)

        XCTAssertEqual(model.manualRetryCount, 0)
        XCTAssertEqual(model.phase, .loading)
        XCTAssertFalse(model.hasPresentedFrame)
        XCTAssertNil(model.seekableWindow)
        engine.resumeLoad(3)
        await change.value
        XCTAssertEqual(model.phase, .playing)
    }

    func testStaleChannelFailureCannotReplaceNewestPlaybackState() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        let staleFailure = engine.capturedFailureHandlers[0]

        await model.changeSource(
            channelID: "newest",
            streamURL: URL(string: "https://example.invalid/newest.m3u8")!,
            httpHeaders: [:]
        )
        staleFailure(.unauthorized)

        XCTAssertEqual(model.phase, .playing)
        XCTAssertTrue(model.hasPresentedFrame)
        XCTAssertEqual(engine.stopCount, 0)
    }

    func testStaleLoadCompletionCannotPresentOldChannelFrame() async {
        let engine = LiveEngineSpy()
        engine.suspendsLoads = true
        let model = makeModel(engine: engine)
        defer { model.stop() }

        let firstLoad = Task { await model.start() }
        await waitForLiveLoads(1, engine: engine)
        let replacementLoad = Task {
            await model.changeSource(
                channelID: "replacement",
                streamURL: URL(string: "https://example.invalid/replacement.m3u8")!,
                httpHeaders: [:]
            )
        }
        await waitForLiveLoads(2, engine: engine)

        engine.resumeLoad(1)
        await firstLoad.value
        XCTAssertEqual(model.phase, .loading)
        XCTAssertFalse(model.hasPresentedFrame)

        engine.resumeLoad(2)
        await replacementLoad.value
        XCTAssertEqual(model.phase, .playing)
        XCTAssertTrue(model.hasPresentedFrame)
    }

    func testUnchangedSourceDoesNotReload() async {
        let engine = LiveEngineSpy()
        let url = URL(string: "https://example.invalid/channel.m3u8")!
        let headers = ["User-Agent": "IPTV test"]
        let model = LiveChannelPlayerModel(
            engine: engine,
            channelID: "same",
            streamURL: url,
            httpHeaders: headers
        )
        defer { model.stop() }
        await model.start()

        await model.changeSource(
            channelID: "same",
            streamURL: url,
            httpHeaders: headers
        )

        XCTAssertEqual(engine.liveLoads, 1)
    }

    func testSameChannelIDReloadsWhenURLOrHeadersChange() async {
        let engine = LiveEngineSpy()
        let firstURL = URL(string: "https://example.invalid/original.m3u8")!
        let replacementURL = URL(string: "https://example.invalid/replacement.m3u8")!
        let firstHeaders = ["User-Agent": "Original"]
        let replacementHeaders = ["User-Agent": "Replacement"]
        let model = LiveChannelPlayerModel(
            engine: engine,
            channelID: "stable-id",
            streamURL: firstURL,
            httpHeaders: firstHeaders
        )
        defer { model.stop() }
        await model.start()

        await model.changeSource(
            channelID: "stable-id",
            streamURL: replacementURL,
            httpHeaders: firstHeaders
        )
        await model.changeSource(
            channelID: "stable-id",
            streamURL: replacementURL,
            httpHeaders: replacementHeaders
        )

        XCTAssertEqual(
            engine.loadedURLs,
            [firstURL, replacementURL, replacementURL]
        )
        XCTAssertEqual(
            engine.loadedHeaders,
            [firstHeaders, firstHeaders, replacementHeaders]
        )
    }

    func testChannelChangeResetsAutomaticRetuneBudget() async {
        let clock = LiveTestClock()
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine, clock: clock)
        defer { model.stop() }
        await model.start()
        for tick in 0..<3 {
            clock.now = Double(tick) * 20
            engine.onLiveSourceReset?()
            await model.requestRetune()?.value
        }
        engine.onLiveSourceReset?()
        XCTAssertEqual(model.phase, .failed(.recoveryExhausted))

        await model.changeSource(
            channelID: "new-budget",
            streamURL: URL(string: "https://example.invalid/new-budget.m3u8")!,
            httpHeaders: [:]
        )
        engine.onLiveSourceReset?()
        await model.requestRetune()?.value

        XCTAssertEqual(engine.liveLoads, 6)
        XCTAssertEqual(model.phase, .playing)
    }

    func testChannelChangePreservesUserPauseIntent() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        model.togglePlayPause()

        await model.changeSource(
            channelID: "paused-replacement",
            streamURL: URL(string: "https://example.invalid/paused.m3u8")!,
            httpHeaders: [:]
        )

        XCTAssertEqual(model.phase, .paused)
        XCTAssertTrue(engine.isPaused)
        model.togglePlayPause()
        XCTAssertEqual(model.phase, .playing)
        XCTAssertEqual(engine.playCount, 1)
    }

    func testPausedReplacementCanResumeBeforeItsFirstFrameAndLiveWindow() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        model.togglePlayPause()
        engine.liveSnapshot.firstFrameReady = false
        engine.liveSnapshot.seekableRange = nil
        engine.liveSnapshot.behindLiveSeconds = 10

        await model.changeSource(
            channelID: "paused-no-frame",
            streamURL: URL(string: "https://example.invalid/paused-no-frame.m3u8")!
        )

        XCTAssertEqual(model.phase, .paused)
        XCTAssertFalse(model.hasPresentedFrame)
        XCTAssertTrue(model.canPause)
        XCTAssertFalse(model.canGoLive)
        model.togglePlayPause()
        XCTAssertFalse(engine.isPaused)
        XCTAssertEqual(engine.playCount, 1)
    }

    func testFirstFrameTimingIsOncePerAttemptAndIncludesPauseBeforeFirstFrame() async {
        let wasEnabled = HandoffDiagnostics.isEnabled
        HandoffDiagnostics.setEnabled(true)
        defer { HandoffDiagnostics.setEnabled(wasEnabled) }
        let clock = LiveTestClock()
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine, clock: clock)
        defer { model.stop() }
        await model.start()
        model.togglePlayPause()
        engine.liveSnapshot.firstFrameReady = false
        clock.now = 100
        await model.changeSource(
            channelID: "timed-replacement",
            streamURL: URL(string: "https://example.invalid/timed.m3u8")!
        )
        clock.now = 110
        model.togglePlayPause()
        clock.now = 112
        engine.liveSnapshot.firstFrameReady = true
        model.refreshFromEngine()

        let lines = PlozzLog.recentEntries(limit: 50).map(\.message)
        let timing = lines.last { $0.contains("event=tuneToFirstFrame") }
        XCTAssertTrue(timing?.contains("elapsedMs=12000") == true)
        let occurrences = lines.filter { $0 == timing }.count
        model.refreshFromEngine()
        XCTAssertEqual(
            PlozzLog.recentEntries(limit: 50).map(\.message).filter { $0 == timing }.count,
            occurrences
        )
    }

    func testEnginePhaseOwnsStatusEvenWhileClockAdvances() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        let cases: [(LiveChannelEnginePhase, LiveChannelPlaybackPhase)] = [
            (.rebuffering, .buffering),
            (.stalled(reconnecting: true), .reconnecting),
            (.stalled(reconnecting: false), .buffering),
            (.seeking, .seeking),
            (.paused, .paused),
            (.playing, .playing),
        ]
        for (enginePhase, expectedPhase) in cases {
            engine.liveSnapshot.phase = enginePhase
            engine.liveSnapshot.position += 1
            model.refreshFromEngine()
            XCTAssertEqual(model.phase, expectedPhase)
        }
    }

    func testPauseIntentWinsOverLatePlayingPublication() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        model.togglePlayPause()
        engine.liveSnapshot.phase = .playing
        model.refreshFromEngine()
        XCTAssertEqual(model.phase, .paused)
        XCTAssertFalse(model.showsActivityIndicator)
        model.togglePlayPause()
        XCTAssertEqual(engine.playCount, 1)
        XCTAssertEqual(model.phase, .playing)
    }

    func testRouteReplacementWaitsForItsOwnFirstFrame() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        engine.liveSnapshot.route = .localHLS
        engine.liveSnapshot.firstFrameReady = false
        model.refreshFromEngine()
        XCTAssertEqual(model.phase, .buffering)
        engine.liveSnapshot.firstFrameReady = true
        model.refreshFromEngine()
        XCTAssertEqual(model.phase, .playing)
    }

    func testNoAdvertisedWindowDoesNotInventTimeshift() async {
        let engine = LiveEngineSpy()
        engine.liveSnapshot.seekableRange = nil
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        XCTAssertFalse(model.canPause)
        XCTAssertFalse(model.canGoLive)
        model.togglePlayPause()
        await model.goLive()
        XCTAssertEqual(engine.pauseCount, 0)
        XCTAssertEqual(engine.goLiveCount, 0)
    }

    func testGoLiveUsesEngineAPIInsteadOfGuessingSeekTarget() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        model.togglePlayPause()
        model.refreshFromEngine()
        XCTAssertTrue(model.canGoLive)
        await model.goLive()
        XCTAssertEqual(engine.goLiveCount, 1)
        XCTAssertEqual(engine.genericSeekCount, 0)
        XCTAssertTrue(model.isAtLiveEdge)
    }

    func testWindowSeekStacksPressesAndCommitsOnce() async throws {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        engine.liveSnapshot.seekableRange = 0...600
        engine.liveSnapshot.position = 598
        engine.liveSnapshot.behindLiveSeconds = 2
        model.refreshFromEngine()
        XCTAssertTrue(model.canSeekWindow)
        XCTAssertEqual(model.seekWindowSeconds, 600)

        model.seek(by: -10)
        model.seek(by: -10)
        model.seek(by: -10)
        // The timeline follows the presses before the engine is asked.
        XCTAssertEqual(model.behindLiveSeconds, 32, accuracy: 0.001)
        XCTAssertFalse(model.isAtLiveEdge)
        XCTAssertEqual(engine.genericSeekCount, 0)

        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(engine.genericSeekCount, 1)
        XCTAssertEqual(try XCTUnwrap(engine.lastSeekTarget), 568, accuracy: 0.001)
        XCTAssertEqual(engine.goLiveCount, 0)
    }

    func testScrubPreviewFromAnEndedAttemptIsDiscarded() async throws {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        engine.liveSnapshot.seekableRange = 0...600
        model.refreshFromEngine()
        var pending: CheckedContinuation<CGImage?, Never>?
        engine.onScrubThumbnail = {
            await withCheckedContinuation { pending = $0 }
        }
        let requested = Task { await model.scrubThumbnail(behindLive: 20, maxWidth: 640) }
        let deadline = ContinuousClock.now + .seconds(2)
        while pending == nil, ContinuousClock.now < deadline { await Task.yield() }
        guard let pending else {
            requested.cancel()
            XCTFail("The preview request did not reach the engine")
            return
        }
        let frame = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }.cgImage)
        model.stop()
        pending.resume(returning: frame)
        let image = await requested.value
        XCTAssertNil(image, "An outgoing source's image must never reach the next presentation")
    }

    func testTouchRewindStartsFromActualLiveHoldbackAndKeepsPendingTarget() async throws {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        engine.liveSnapshot.seekableRange = 0...600
        engine.liveSnapshot.position = 590
        engine.liveSnapshot.behindLiveSeconds = 10
        model.refreshFromEngine()
        XCTAssertEqual(model.behindLiveSeconds, 0, "The live badge hides normal stream delay.")
        XCTAssertEqual(model.seekPosition, 590)

        let gestures = PlayerTouchGestureState()
        defer { gestures.cancel() }
        let window = try XCTUnwrap(model.seekableWindow)
        let floor = LiveChannelPlayerModel.windowSeekTarget(window.lowerBound, window: window)
        for expected in [585.0, 580.0] {
            let target = try XCTUnwrap(gestures.seek(
                by: -5, from: model.seekPosition, within: floor...window.upperBound
            ))
            XCTAssertEqual(target, expected)
            model.seek(behindLive: window.upperBound - target)
            XCTAssertEqual(model.seekPosition, expected)
        }
        XCTAssertEqual(gestures.skip?.seconds, -10)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(engine.genericSeekCount, 1)
        XCTAssertEqual(try XCTUnwrap(engine.lastSeekTarget), 580)
        XCTAssertEqual(engine.goLiveCount, 0)
    }

    func testWindowSeekPastTheEdgeGoesLive() async throws {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        engine.liveSnapshot.seekableRange = 0...600
        engine.liveSnapshot.position = 500
        engine.liveSnapshot.behindLiveSeconds = 100
        model.refreshFromEngine()

        model.seek(by: 200)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(engine.goLiveCount, 1)
        XCTAssertEqual(engine.genericSeekCount, 0)
    }

    func testReplacementChannelDoesNotWaitForOrLoseItsSeekToThePreviousChannel() async throws {
        let engine = LiveEngineSpy()
        engine.liveSnapshot.seekableRange = 0...600
        engine.liveSnapshot.position = 500
        engine.liveSnapshot.behindLiveSeconds = 100
        engine.suspendsSeeks = true
        let model = makeModel(engine: engine)
        defer { engine.resumeAllSeeks(); model.stop() }
        await model.start()
        model.seek(by: -10)
        try await waitForSeekCount(1, engine: engine)
        await model.changeSource(channelID: "replacement", streamURL: try XCTUnwrap(URL(string: "https://fixture.invalid/b.m3u8")))
        model.seek(by: -20)
        try await waitForSeekCount(2, engine: engine)
        XCTAssertEqual(engine.lastSeekTarget, 480)
        engine.resumeSeek(1)
        await Task.yield()
        model.seek(by: -10)
        try await Task.sleep(for: LiveChannelPlayerModel.seekCommitDelay + .milliseconds(100))
        XCTAssertEqual(engine.genericSeekCount, 2, "The retired seek cannot clear the new worker's ownership.")
        engine.resumeSeek(2)
        try await waitForSeekCount(3, engine: engine)
        XCTAssertEqual(engine.lastSeekTarget, 470)
    }

    func testGoLiveAndRewindUseOneWorkerAndKeepTheLatestIntent() async throws {
        for liveFirst in [false, true] {
            let engine = LiveEngineSpy()
            engine.liveSnapshot.seekableRange = 0...600
            engine.liveSnapshot.position = 500
            engine.liveSnapshot.behindLiveSeconds = 100
            engine.suspendsSeeks = true
            let model = makeModel(engine: engine)
            defer { engine.resumeAllSeeks(); model.stop() }
            await model.start()
            let first = Task {
                if liveFirst { await model.goLive() }
                else { model.seek(by: -10) }
            }
            try await waitForSeekCount(1, engine: engine)
            if liveFirst { model.seek(by: -20) }
            else { await model.goLive() }
            try await Task.sleep(for: LiveChannelPlayerModel.seekCommitDelay + .milliseconds(100))
            XCTAssertEqual(engine.genericSeekCount + engine.goLiveCount, 1)
            engine.resumeSeek(1)
            try await waitForSeekCount(2, engine: engine)
            XCTAssertEqual(engine.maximumConcurrentSeeks, 1)
            XCTAssertEqual(engine.genericSeekCount, 1)
            XCTAssertEqual(engine.goLiveCount, 1)
            engine.resumeSeek(2)
            await first.value
        }
    }

    func testTemporaryInactivityKeepsOwnershipOfAnOutstandingSeek() async throws {
        let engine = LiveEngineSpy()
        engine.liveSnapshot.seekableRange = 0...600
        engine.liveSnapshot.position = 500
        engine.liveSnapshot.behindLiveSeconds = 100
        engine.suspendsSeeks = true
        let model = makeModel(engine: engine)
        defer { engine.resumeAllSeeks(); model.stop() }
        await model.start()
        model.seek(by: -10)
        try await waitForSeekCount(1, engine: engine)
        model.handleScenePhase(.inactive)
        model.handleScenePhase(.active)
        model.seek(by: -20)
        try await Task.sleep(for: LiveChannelPlayerModel.seekCommitDelay + .milliseconds(100))
        XCTAssertEqual(engine.genericSeekCount, 1)
        engine.resumeSeek(1)
        try await waitForSeekCount(2, engine: engine)
        XCTAssertEqual(engine.maximumConcurrentSeeks, 1)
    }

    private func waitForSeekCount(_ count: Int, engine: LiveEngineSpy) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while engine.genericSeekCount + engine.goLiveCount < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(engine.genericSeekCount + engine.goLiveCount, count)
    }

    func testPlaylistHoldbackIsNotASeekWindow() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        model.refreshFromEngine()
        XCTAssertFalse(model.canSeekWindow)
        XCTAssertNil(model.seekWindowSeconds)
        model.seek(by: -10)
        XCTAssertTrue(model.isAtLiveEdge)
    }

    func testWindowSeekStaysClearOfTheOldestSegment() throws {
        let window = try XCTUnwrap(LiveSeekableWindow(ranges: [(start: 1_000, duration: 600)]))
        XCTAssertEqual(LiveChannelPlayerModel.windowSeekTarget(0, window: window), 1_006)
        XCTAssertEqual(LiveChannelPlayerModel.windowSeekTarget(1_300, window: window), 1_300)
        XCTAssertEqual(LiveChannelPlayerModel.windowSeekTarget(9_999, window: window), 1_600)
    }

    func testPauseDuringGoLiveDoesNotResumeAtCompletion() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        model.togglePlayPause()
        model.refreshFromEngine()
        XCTAssertTrue(model.canGoLive)
        engine.onGoLive = { model.togglePlayPause() }
        await model.goLive()
        XCTAssertEqual(engine.goLiveCount, 1)
        model.refreshFromEngine()
        XCTAssertEqual(engine.playCount, 0)
        XCTAssertEqual(model.phase, .paused)
    }

    func testStopDuringGoLiveIgnoresLateCompletion() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        await model.start()
        model.togglePlayPause()
        model.refreshFromEngine()
        XCTAssertTrue(model.canGoLive)
        engine.onGoLive = { model.stop() }
        await model.goLive()
        XCTAssertEqual(engine.goLiveCount, 1)
        XCTAssertEqual(engine.playCount, 0)
        XCTAssertNil(engine.onLiveSourceReset)
    }

    func testStopDuringLoadDoesNotResurrectPlayback() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        engine.onLoad = { model.stop() }
        await model.start()
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertEqual(engine.playCount, 0)
        XCTAssertFalse(model.hasPresentedFrame)
        XCTAssertNil(engine.onFailure)
    }

    func testFailureDuringLoadSurvivesLateLoadCompletion() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        engine.onLoad = { engine.onFailure?(.notFound) }
        await model.start()
        XCTAssertEqual(model.phase, .failed(.engine(.notFound)))
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertTrue(model.canRetry)
    }

    func testStartupTimeoutStopsUnreadyEngine() async {
        let clock = LiveTestClock()
        let engine = LiveEngineSpy()
        engine.liveSnapshot.firstFrameReady = false
        let model = makeModel(engine: engine, clock: clock)
        defer { model.stop() }
        await model.start()
        clock.now = 29
        model.refreshFromEngine()
        XCTAssertEqual(model.phase, .loading)
        clock.now = 30
        model.refreshFromEngine()
        XCTAssertEqual(model.phase, .failed(.startupTimedOut))
        XCTAssertEqual(engine.stopCount, 1)
    }

    func testStallAllowsEngineRecoveryButIsStillBounded() async {
        let clock = LiveTestClock()
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine, clock: clock)
        defer { model.stop() }
        await model.start()
        engine.liveSnapshot.phase = .stalled(reconnecting: true)
        model.refreshFromEngine()
        clock.now = 59
        model.refreshFromEngine()
        XCTAssertEqual(model.phase, .reconnecting)
        clock.now = 60
        model.refreshFromEngine()
        XCTAssertEqual(model.phase, .failed(.bufferingTimedOut))
    }

    func testStartupTimeoutAllowsTheSelectedCushionButStillExpires() async {
        for buffer in LivePlaybackBuffer.allCases {
            let clock = LiveTestClock()
            let engine = LiveEngineSpy()
            engine.liveStartupBuffer = buffer
            engine.liveSnapshot.firstFrameReady = false
            let model = makeModel(engine: engine, clock: clock)
            defer { model.stop() }
            await model.start()
            let deadline = 30 + (buffer.seconds ?? 0)
            clock.now = deadline - 0.01
            model.refreshFromEngine()
            XCTAssertEqual(model.phase, .loading, buffer.rawValue)
            clock.now = deadline
            model.refreshFromEngine()
            XCTAssertEqual(model.phase, .failed(.startupTimedOut), buffer.rawValue)
            XCTAssertEqual(engine.stopCount, 1)
        }
    }

    func testIntentionalCushionUsesTheEngineSafeEdgeWithoutChangingAutomatic() async {
        let engine = LiveEngineSpy()
        engine.liveStartupBuffer = .fortyFiveSeconds
        engine.liveSnapshot.seekableRange = 0...100
        engine.liveSnapshot.position = 55
        engine.liveSnapshot.behindLiveSeconds = 45
        engine.liveSnapshot.isAtLiveEdge = true
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        XCTAssertTrue(model.isAtLiveEdge)
        XCTAssertFalse(model.canGoLive)
        engine.liveSnapshot.isAtLiveEdge = false
        engine.liveSnapshot.behindLiveSeconds = 60
        model.refreshFromEngine()
        XCTAssertFalse(model.isAtLiveEdge)
        XCTAssertTrue(model.canGoLive)
        engine.liveStartupBuffer = .automatic
        engine.liveSnapshot.isAtLiveEdge = true
        model.refreshFromEngine()
        XCTAssertFalse(model.isAtLiveEdge, "Automatic retains the existing time-shift policy.")
    }

    func testExplicitCushionDoesNotPublishANonFiniteDistance() async {
        let engine = LiveEngineSpy()
        engine.liveStartupBuffer = .thirtySeconds
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        engine.liveSnapshot.behindLiveSeconds = nil
        engine.liveSnapshot.isAtLiveEdge = false
        for position in [-Double.infinity, Double.nan] {
            engine.liveSnapshot.position = position
            model.refreshFromEngine()
            XCTAssertEqual(model.behindLiveSeconds, 0)
        }
    }

    func testTerminalEngineErrorIsNotMistakenForBuffering() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        engine.status = .failed(.unauthorized)
        engine.liveSnapshot.phase = .failed
        model.refreshFromEngine()
        XCTAssertEqual(model.phase, .failed(.engine(.unauthorized)))
        XCTAssertFalse(model.showsActivityIndicator)
    }

    func testFailurePollingWaitsForBoundedDiagnosticCaptureBeforeStoppingTheEngine() async throws {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        var report: LiveChannelFailureReport?
        model.setSessionReporting(.init(id: UUID(), update: { _ in }, failed: { report = $0 }))
        await model.start()
        engine.liveSnapshot.phase = .failed
        engine.isCapturingLiveFailureDiagnostic = true
        model.refreshFromEngine()
        XCTAssertNil(report)
        let attempt = try XCTUnwrap(PlaybackFailureDiagnostics().begin(
            layer: .liveEngine, content: .live, captureForPresentation: true
        ))
        attempt.fail(
            stage: .playback, domain: .avfoundation, code: -11850,
            evidence: .init(nativeCapture: .captured,
                            nativeErrors: [.init(domain: "CoreMediaErrorDomain", code: -12939)])
        )
        engine.livePlaybackFailureDiagnostic = attempt.diagnostic
        engine.isCapturingLiveFailureDiagnostic = false
        engine.status = .failed(.invalidResponse)
        model.refreshFromEngine()
        XCTAssertEqual(report?.diagnostic?.evidence?.nativeErrors.first?.code, -12939)
        XCTAssertEqual(model.failureReport, report, "The visible interruption retains the same report as the guide.")
        XCTAssertNil(engine.livePlaybackFailureDiagnostic, "Capture must precede teardown.")
        engine.status = .ready
        engine.liveSnapshot.phase = .loading
        await model.retry()
        XCTAssertNil(model.failureReport, "The next attempt starts with fresh diagnostic evidence.")
    }

    func testManualRetriesAreBounded() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        for _ in 0..<3 {
            engine.onFailure?(.serverUnreachable)
            await model.retry()
        }
        XCTAssertEqual(engine.liveLoads, 3)
        XCTAssertEqual(model.manualRetryCount, 2)
        XCTAssertFalse(model.canRetry)
    }

    func testSourceResetRetunesOnlyThreeTimesPerChannelSession() async {
        let clock = LiveTestClock()
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine, clock: clock)
        defer { model.stop() }
        await model.start()
        for tick in 0..<3 {
            clock.now = Double(tick) * 20
            engine.onLiveSourceReset?()
            await model.requestRetune()?.value
            XCTAssertEqual(model.phase, .playing)
        }
        XCTAssertEqual(engine.liveLoads, 4)
        engine.onLiveSourceReset?()
        XCTAssertEqual(model.phase, .failed(.recoveryExhausted))
        XCTAssertEqual(engine.liveLoads, 4)
        await model.retry()
        XCTAssertEqual(engine.liveLoads, 5)
        engine.onLiveSourceReset?()
        XCTAssertEqual(model.phase, .failed(.recoveryExhausted))
        XCTAssertEqual(engine.liveLoads, 5)
    }

    func testSourceResetRaisedDuringLoadIsNotLost() async {
        let engine = LiveEngineSpy()
        engine.onLoad = {
            if engine.liveLoads == 1 { engine.onLiveSourceReset?() }
        }
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        await model.requestRetune()?.value
        XCTAssertEqual(engine.liveLoads, 2)
        XCTAssertEqual(model.phase, .playing)
    }

    func testSustainedAdvancingPlaybackRestoresAutomaticRetunes() async {
        let clock = LiveTestClock()
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine, clock: clock)
        defer { model.stop() }
        await model.start()
        for tick in 0..<3 {
            clock.now = Double(tick) * 20
            engine.onLiveSourceReset?()
            await model.requestRetune()?.value
        }
        model.refreshFromEngine()
        for _ in 0..<300 {
            clock.now += 1
            engine.liveSnapshot.position += 1
            model.refreshFromEngine()
        }
        engine.onLiveSourceReset?()
        await model.requestRetune()?.value
        XCTAssertTrue(engine.loadedURLs.allSatisfy { $0 == engine.loadedURLs.first })
        XCTAssertEqual(engine.liveLoads, 5)
        XCTAssertEqual(model.phase, .playing)
        XCTAssertEqual(model.manualRetryCount, 0)
    }

    func testPauseBackgroundBufferingAndSeekingDiscardHealthyRecoveryCredit() async {
        for interruption in ["pause", "background", "buffering", "seek"] {
            let clock = LiveTestClock()
            let engine = LiveEngineSpy()
            let model = makeModel(engine: engine, clock: clock)
            defer { model.stop() }
            await model.start()
            for tick in 0..<3 {
                clock.now = Double(tick) * 20
                engine.onLiveSourceReset?()
                await model.requestRetune()?.value
            }
            model.refreshFromEngine()
            for _ in 0..<299 {
                clock.now += 1
                engine.liveSnapshot.position += 1
                model.refreshFromEngine()
            }
            switch interruption {
            case "pause":
                model.togglePlayPause()
                model.togglePlayPause()
            case "background":
                model.handleScenePhase(.background)
                model.handleScenePhase(.active)
                await waitForLiveLoads(5, engine: engine)
            case "buffering":
                engine.liveSnapshot.phase = .rebuffering
                model.refreshFromEngine()
                engine.liveSnapshot.phase = .playing
            default:
                engine.liveSnapshot.behindLiveSeconds = 40
                model.refreshFromEngine()
                XCTAssertTrue(model.canGoLive)
                await model.goLive()
                XCTAssertEqual(engine.goLiveCount, 1)
            }
            for _ in 0..<2 {
                clock.now += 1
                engine.liveSnapshot.position += 1
                model.refreshFromEngine()
            }
            engine.onLiveSourceReset?()
            XCTAssertNil(model.requestRetune(), interruption)
            XCTAssertEqual(model.phase, .failed(.recoveryExhausted), interruption)
            XCTAssertEqual(engine.liveLoads, interruption == "background" ? 5 : 4, interruption)
        }
    }

    func testSourceResetWhilePausedWaitsForUserResume() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        model.togglePlayPause()
        engine.onLiveSourceReset?()
        XCTAssertNil(model.requestRetune())
        XCTAssertEqual(engine.liveLoads, 1)
        model.togglePlayPause()
        await model.requestRetune()?.value
        XCTAssertEqual(engine.liveLoads, 2)
        XCTAssertEqual(model.phase, .playing)
    }

    func testSourceResetWhileBackgroundedWaitsForForeground() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        model.handleScenePhase(.background)
        engine.onLiveSourceReset?()
        XCTAssertNil(model.requestRetune())
        XCTAssertEqual(engine.liveLoads, 1)
        model.handleScenePhase(.active)
        await waitForLiveLoads(2, engine: engine)
    }

    func testRepeatedResetSignalsCoalesceBeforeRetuneStarts() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        for _ in 0..<100 { engine.onLiveSourceReset?() }
        await model.requestRetune()?.value
        XCTAssertEqual(engine.liveLoads, 2)
        XCTAssertEqual(model.phase, .playing)
    }

    func testStopCancelsScheduledRecovery() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        await model.start()
        engine.onLiveSourceReset?()
        let task = model.requestRetune()
        model.stop()
        await task?.value
        XCTAssertEqual(engine.liveLoads, 1)
        XCTAssertNil(engine.onLiveSourceReset)
    }

    func testBackgroundStopsEngineAndPausedReturnDoesNotAutoplay() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        model.togglePlayPause()
        model.handleScenePhase(.inactive)
        model.handleScenePhase(.background)
        XCTAssertEqual(engine.stopCount, 1)
        model.handleScenePhase(.active)
        XCTAssertEqual(engine.liveLoads, 1)
        XCTAssertEqual(engine.playCount, 0)
        let loaded = expectation(description: "Reload only after explicit resume")
        engine.onLoad = { loaded.fulfill() }
        model.togglePlayPause()
        await fulfillment(of: [loaded], timeout: 2)
        XCTAssertEqual(engine.liveLoads, 2)
    }

    func testInactiveReturnDoesNotReloadHealthyStream() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        model.handleScenePhase(.inactive)
        #if os(tvOS)
        XCTAssertEqual(engine.pauseCount, 0)
        XCTAssertFalse(engine.isPaused)
        XCTAssertEqual(model.phase, .playing)
        #else
        XCTAssertTrue(engine.isPaused)
        #endif
        model.handleScenePhase(.active)
        XCTAssertEqual(engine.liveLoads, 1)
        XCTAssertEqual(engine.stopCount, 0)
        XCTAssertEqual(model.phase, .playing)
        #if os(tvOS)
        XCTAssertEqual(engine.playCount, 0, "Closing an overlay must not synthesize a resume")
        #endif
    }

    func testInactiveReturnKeepsUserPausedStreamPaused() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        model.togglePlayPause()

        model.handleScenePhase(.inactive)
        model.handleScenePhase(.active)

        XCTAssertTrue(engine.isPaused)
        XCTAssertEqual(model.phase, .paused)
        XCTAssertEqual(engine.playCount, 0)
        XCTAssertEqual(engine.liveLoads, 1)
    }

    #if os(tvOS)
    func testSourceResetUnderSystemOverlayCanStillRecover() async {
        let engine = LiveEngineSpy()
        let model = makeModel(engine: engine)
        defer { model.stop() }
        await model.start()
        model.handleScenePhase(.inactive)
        engine.onLiveSourceReset?()

        let recovery = model.requestRetune()
        XCTAssertNotNil(recovery)
        await recovery?.value

        XCTAssertEqual(engine.liveLoads, 2)
        XCTAssertEqual(model.phase, .playing)
        model.handleScenePhase(.active)
        XCTAssertEqual(engine.liveLoads, 2)
    }
    #endif

    private func waitForLiveLoads(
        _ expected: Int,
        engine: LiveEngineSpy
    ) async {
        for _ in 0..<100 {
            if engine.liveLoads >= expected { break }
            await Task.yield()
        }
        XCTAssertEqual(engine.liveLoads, expected)
    }
}

final class LiveChannelPlaybackFocusPolicyTests: XCTestCase {
    func testPlaybackPrefersTheTimelineWhateverElseIsAvailable() {
        for canPlayPause in [true, false] {
            let availability = LiveChannelPlaybackFocusPolicy.Availability(
                isPresented: true,
                canPlayPause: canPlayPause,
                canGoLive: false,
                canToggleFavorite: true
            )

            XCTAssertEqual(availability.preferredControl, .timeline)
            XCTAssertTrue(availability.contains(availability.preferredControl))
        }
    }

    func testNewPlayPauseAvailabilityDoesNotInvalidateExistingTransportFocus() {
        let availability = LiveChannelPlaybackFocusPolicy.Availability(
            isPresented: true,
            canPlayPause: true,
            canGoLive: false,
            canToggleFavorite: true
        )

        XCTAssertTrue(availability.contains(.next))
        XCTAssertTrue(availability.contains(.previous))
        XCTAssertTrue(availability.contains(.audio))
        XCTAssertTrue(availability.contains(.subtitles))
    }

    func testPlaybackEligibilityExcludesMissingAndEscapeControls() {
        let availability = LiveChannelPlaybackFocusPolicy.Availability(
            isPresented: true,
            canPlayPause: false,
            canGoLive: true,
            canToggleFavorite: true
        )

        XCTAssertTrue(availability.contains(.previous))
        XCTAssertTrue(availability.contains(.goLive))
        XCTAssertTrue(availability.contains(.next))
        XCTAssertTrue(availability.contains(.favorite))
        XCTAssertTrue(availability.contains(.audio))
        XCTAssertTrue(availability.contains(.subtitles))
        XCTAssertFalse(availability.contains(.playPause))
        XCTAssertFalse(availability.contains(.surface))
        XCTAssertFalse(availability.contains(.close))
        XCTAssertFalse(availability.contains(.retry))
        XCTAssertFalse(availability.contains(nil))
        XCTAssertFalse(
            LiveChannelPlaybackFocusPolicy.Availability.hidden.contains(.next)
        )
        XCTAssertFalse(
            LiveChannelPlaybackFocusPolicy.Availability.hidden.contains(.timeline)
        )
    }

    func testUnavailableFavoriteActionLeavesExistingTransportFocusValid() {
        let availability = LiveChannelPlaybackFocusPolicy.Availability(
            isPresented: true,
            canPlayPause: true,
            canGoLive: true,
            canToggleFavorite: false
        )

        XCTAssertTrue(availability.contains(.previous))
        XCTAssertTrue(availability.contains(.playPause))
        XCTAssertTrue(availability.contains(.goLive))
        XCTAssertTrue(availability.contains(.next))
        XCTAssertFalse(availability.contains(.favorite))
    }

    func testInterruptionPrefersRetryThenFallsBackToClose() {
        XCTAssertEqual(
            LiveChannelPlaybackFocusPolicy.interruptionControl(canRetry: true),
            .retry
        )
        XCTAssertEqual(
            LiveChannelPlaybackFocusPolicy.interruptionControl(canRetry: false),
            .close
        )
    }
}

final class LiveChannelFavoriteControlStateTests: XCTestCase {
    func testFavoriteControlCopyMatchesPersistedState() {
        let add = LiveChannelFavoriteControlState(isFavorite: false, canToggle: true)
        XCTAssertEqual(String(localized: add.title), "Add to Favorites")
        XCTAssertEqual(add.systemImage, "star")
        XCTAssertTrue(add.canToggle)

        let remove = LiveChannelFavoriteControlState(isFavorite: true, canToggle: true)
        XCTAssertEqual(String(localized: remove.title), "Remove from Favorites")
        XCTAssertEqual(remove.systemImage, "star.fill")
        XCTAssertTrue(remove.canToggle)
    }

    func testFavoriteControlCanStayTruthfulWhilePersistenceIsUnavailable() {
        let state = LiveChannelFavoriteControlState(isFavorite: false, canToggle: false)

        XCTAssertEqual(String(localized: state.title), "Add to Favorites")
        XCTAssertEqual(state.systemImage, "star")
        XCTAssertFalse(state.canToggle)
    }
}

final class LiveChannelPlaybackStartPolicyTests: XCTestCase {
    func testExpandedAlreadyPlayingPreviewBecomesEligible() {
        XCTAssertNil(
            eligibleSource(
                "station-a",
                isExpanded: false,
                phase: .playing,
                hasPresentedFrame: true
            )
        )
        XCTAssertEqual(
            eligibleSource(
                "station-a",
                isExpanded: true,
                phase: .playing,
                hasPresentedFrame: true
            ),
            "station-a"
        )
    }

    func testDelayedStartupWaitsForPlayingFrame() {
        XCTAssertNil(
            eligibleSource(
                "station-a",
                isExpanded: true,
                phase: .loading,
                hasPresentedFrame: false
            )
        )
        XCTAssertNil(
            eligibleSource(
                "station-a",
                isExpanded: true,
                phase: .playing,
                hasPresentedFrame: false
            )
        )
        XCTAssertEqual(
            eligibleSource(
                "station-a",
                isExpanded: true,
                phase: .playing,
                hasPresentedFrame: true
            ),
            "station-a"
        )
    }

    func testPreviewStalePausedAndInterruptedSourcesAreIneligible() {
        XCTAssertNil(
            eligibleSource(
                "station-a",
                sourceMatches: false,
                isExpanded: true,
                phase: .playing,
                hasPresentedFrame: true
            )
        )
        XCTAssertNil(
            eligibleSource(
                "station-a",
                isExpanded: true,
                phase: .paused,
                hasPresentedFrame: true
            )
        )
        XCTAssertNil(
            eligibleSource(
                "station-a",
                isExpanded: true,
                phase: .failed(.startupTimedOut),
                hasPresentedFrame: true
            )
        )
    }

    func testSuccessfulFullscreenSourcesNotifyOncePerViewing() {
        var policy = LiveChannelPlaybackStartPolicy<String>()

        XCTAssertTrue(policy.consume("station-a"))
        XCTAssertFalse(policy.consume("station-a"))
        policy.resetViewing()
        XCTAssertTrue(policy.consume("station-b"))
        XCTAssertFalse(policy.consume("station-b"))
        policy.resetViewing()
        XCTAssertTrue(policy.consume("station-a"))
    }

    func testFailedTuneDoesNotConsumeNotification() {
        var policy = LiveChannelPlaybackStartPolicy<String>()

        XCTAssertFalse(policy.consume(nil))
        XCTAssertTrue(policy.consume("station-b"))
    }

    private func eligibleSource(
        _ source: String,
        sourceMatches: Bool = true,
        isExpanded: Bool,
        phase: LiveChannelPlaybackPhase,
        hasPresentedFrame: Bool
    ) -> String? {
        LiveChannelPlaybackStartPolicy<String>.eligibleSource(
            source,
            sourceMatches: sourceMatches,
            isExpanded: isExpanded,
            phase: phase,
            hasPresentedFrame: hasPresentedFrame
        )
    }
}

private final class LiveTestClock {
    var now: TimeInterval = 0
}

#if os(tvOS)
@MainActor
final class LiveChannelFullscreenPresentationTests: XCTestCase {
    func testNativeFullscreenCoversNavigationAndReturnsTheSameOutputWithoutRetuning() async throws {
        let probe = LiveFullscreenProbe()
        let window = try await makeWindow(probe)
        defer { window.isHidden = true; window.rootViewController = nil; probe.engine.stop() }
        await waitUntil { probe.engine.liveLoads == 1 && probe.engine.outputView.window != nil }
        let root = try XCTUnwrap(window.rootViewController)
        let surface = probe.engine.outputView
        XCTAssertTrue(surface.isDescendant(of: root.view))

        for _ in 0..<2 {
            probe.expanded = true
            await waitUntil { root.presentedViewController?.view.window != nil }
            let fullscreen = try XCTUnwrap(root.presentedViewController)
            await waitUntil { surface.isDescendant(of: fullscreen.view) }
            XCTAssertTrue(surface.isDescendant(of: fullscreen.view))
            await waitUntil { focusIsInside(fullscreen.view, window: window) }
            XCTAssertTrue(focusIsInside(fullscreen.view, window: window),
                          "Focused item: \(String(describing: UIFocusSystem.focusSystem(for: window)?.focusedItem)); key window: \(window.isKeyWindow)")
            XCTAssertEqual(fullscreen.view.frame, window.bounds)
            XCTAssertTrue([UIModalPresentationStyle.fullScreen, .overFullScreen].contains(fullscreen.modalPresentationStyle))
            XCTAssertEqual(probe.creations, 1)
            XCTAssertEqual(probe.engine.liveLoads, 1)
            XCTAssertEqual(probe.engine.stopCount, 0)

            // Exercise a real presentation dismissal, not just an expanded flag.
            fullscreen.dismiss(animated: false)
            await waitUntil { !probe.expanded && surface.isDescendant(of: root.view) }
            XCTAssertFalse(probe.expanded)
            XCTAssertTrue(surface.isDescendant(of: root.view))
            XCTAssertEqual(probe.engine.liveLoads, 1)
            XCTAssertEqual(probe.engine.stopCount, 0)
        }
        XCTAssertEqual(probe.returns, 2)
        probe.active = false
        await waitUntil { probe.engine.stopCount == 1 }
        XCTAssertEqual(probe.engine.stopCount, 1)
    }

    func testExpandingDuringStartupDoesNotCancelThePendingLiveLoad() async throws {
        let probe = LiveFullscreenProbe()
        probe.engine.suspendsLoads = true
        let window = try await makeWindow(probe)
        defer { window.isHidden = true; window.rootViewController = nil; probe.engine.stop() }
        await waitUntil { probe.engine.liveLoads == 1 }
        probe.expanded = true
        await waitUntil { window.rootViewController?.presentedViewController?.view.window != nil }
        probe.engine.resumeLoad(1)
        await waitUntil { !probe.engine.cancelledLoads.isEmpty }
        XCTAssertEqual(probe.engine.cancelledLoads, [false])
        XCTAssertEqual(probe.creations, 1)
        XCTAssertEqual(probe.engine.liveLoads, 1)
        XCTAssertEqual(probe.engine.stopCount, 0)

        probe.active = false
        await waitUntil {
            probe.engine.stopCount == 1 && window.rootViewController?.presentedViewController == nil
        }
        XCTAssertEqual(probe.engine.stopCount, 1)
        XCTAssertNil(window.rootViewController?.presentedViewController)
        XCTAssertEqual(probe.returns, 0)
    }

    func testTopBarFullscreenRetunesInPlaceAndHonorsAnExternalGuideReturn() async throws {
        let probe = LiveFullscreenProbe(usesSidebar: false)
        let window = try await makeWindow(probe)
        defer { window.isHidden = true; window.rootViewController = nil; probe.engine.stop() }
        await waitUntil { probe.engine.liveLoads == 1 }
        probe.expanded = true
        let root = try XCTUnwrap(window.rootViewController)
        await waitUntil { root.presentedViewController?.view.window != nil }
        let fullscreen = try XCTUnwrap(root.presentedViewController)
        probe.favorite = true
        probe.channelID = "replacement"
        await waitUntil { probe.engine.liveLoads == 2 }
        XCTAssertEqual(probe.engine.loadedURLs.last?.lastPathComponent, "replacement.m3u8")
        XCTAssertTrue(root.presentedViewController === fullscreen)
        XCTAssertTrue(probe.engine.outputView.isDescendant(of: fullscreen.view))
        XCTAssertEqual(probe.creations, 1)
        XCTAssertEqual(probe.engine.stopCount, 0)

        probe.expanded = false
        await waitUntil { root.presentedViewController == nil && probe.engine.outputView.isDescendant(of: root.view) }
        XCTAssertNil(root.presentedViewController)
        XCTAssertTrue(probe.engine.outputView.isDescendant(of: root.view))
        XCTAssertEqual(probe.returns, 0)
        XCTAssertEqual(probe.engine.liveLoads, 2)
        XCTAssertEqual(probe.engine.stopCount, 0)
        probe.active = false
        await waitUntil { probe.engine.stopCount == 1 }
    }

    private func makeWindow(_ probe: LiveFullscreenProbe) async throws -> UIWindow {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            throw XCTSkip("Native fullscreen regressions require an app-hosted test with a window scene.")
        }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(
            rootView: LiveFullscreenHarness(probe: probe).environment(\.scenePhase, .active)
        )
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        probe.active = true
        return window
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func focusIsInside(_ view: UIView, window: UIWindow) -> Bool {
        var environment: (any UIFocusEnvironment)? = UIFocusSystem.focusSystem(for: window)?.focusedItem
        while let current = environment {
            if let focusedView = current as? UIView {
                return focusedView.isDescendant(of: view)
            }
            environment = current.parentFocusEnvironment
        }
        return false
    }
}

@MainActor
@Observable
private final class LiveFullscreenProbe {
    let engine = LiveEngineSpy()
    let usesSidebar: Bool
    var expanded = false
    var active = false
    var channelID = "channel"
    var favorite = false
    var creations = 0
    var returns = 0

    init(usesSidebar: Bool = true) {
        self.usesSidebar = usesSidebar
    }
}

private struct LiveFullscreenHarness: View {
    let probe: LiveFullscreenProbe

    var body: some View {
        if #available(tvOS 27.0, *), probe.usesSidebar {
            tabs.tabViewStyle(.sidebarAdaptable)
        } else {
            tabs.tabViewStyle(.tabBarOnly)
        }
    }

    private var tabs: some View {
        TabView {
            Tab("Live TV", systemImage: "tv") {
                NavigationStack {
                    LiveChannelPlayerView(
                        channelID: probe.channelID,
                        title: "Live channel",
                        streamURL: URL(string: "https://example.invalid/\(probe.channelID).m3u8")!,
                        logoURL: nil,
                        makeEngine: { probe.creations += 1; return probe.engine },
                        onPreviousChannel: {}, onNextChannel: {},
                        isFavorite: probe.favorite, canToggleFavorite: true,
                        onToggleFavorite: { probe.favorite.toggle() },
                        isExpanded: probe.expanded,
                        usesNativeFullscreen: true,
                        isActive: probe.active,
                        onReturnToGuide: { probe.returns += 1; probe.expanded = false }
                    )
                }
                .toolbar(probe.expanded ? .hidden : .visible, for: .tabBar)
                .toolbar(.hidden, for: .navigationBar)
            }
            Tab("Home", systemImage: "house") { Text("Home") }
        }
    }
}
#endif

@MainActor
final class LiveEngineSpy: LiveChannelEngine {
    var probedSourceFacts: EngineProbedSourceFacts?
    var videoAspectRatio: Double?
    var liveStartupBuffer: LivePlaybackBuffer = .automatic
    var livePlaybackFailureDiagnostic: PlaybackFailureDiagnostic?
    var liveTelemetry: EngineLiveTelemetry?
    var isCapturingLiveFailureDiagnostic = false
    let outputView = UIView()
    var liveSnapshot = LiveChannelEngineSnapshot(
        phase: .playing, firstFrameReady: true, position: 100,
        bufferedPosition: 110, seekableRange: 90...110,
        behindLiveSeconds: 10, route: .nativeHLS
    )
    var status: VideoEngineStatus = .ready
    var isPaused = false
    var currentTime: TimeInterval { liveSnapshot.position }
    var presentedSubtitleTime: TimeInterval?
    var subtitlePresentationTime: TimeInterval { presentedSubtitleTime ?? currentTime }
    var duration: TimeInterval { 0 }
    var furthestObservedPosition: TimeInterval { 0 }
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var currentAudioTrackID: Int?
    var selectedSubtitleID: Int?
    var continuesPlaybackInBackground = false
    var externalPlaybackRouteName: String?
    var onPresentationLayerChanged: (() -> Void)?
    var nativeSubtitlesActive = false
    var subtitleStyles: [SubtitleStyle] = []
    func updateSubtitleStyle(_ style: SubtitleStyle) { subtitleStyles.append(style) }
    func pictureInPicturePlayerLayer() -> AVPlayerLayer? { nil }
    func setPictureInPictureActive(_ active: Bool) { continuesPlaybackInBackground = active }
    func setNativeSubtitlesActive(_ active: Bool) { nativeSubtitlesActive = active }
    var onProgress: (@MainActor () -> Void)?
    var onFailure: (@MainActor (AppError) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onTracksChanged: (@MainActor () -> Void)?
    var onProbedSourceFactsChanged: (@MainActor (EngineProbedSourceFacts) -> Void)?
    var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onLiveSourceReset: (@MainActor () -> Void)?
    var onProgrammeChanged: (@MainActor () -> Void)?
    var recoverableProgrammeIssue: LibraryChannelError?
    var onLoad: (@MainActor () async -> Void)?
    var onGoLive: (@MainActor () -> Void)?
    var onScrubThumbnail: (@MainActor () async -> CGImage?)?
    var loadedInputs: [LiveChannelInput] = []
    var inputLoadError: Error?
    var watching = false
    var liveLoads = 0
    var cancelledLoads: [Bool] = []
    var loadedURLs: [URL] = []
    var loadedHeaders: [[String: String]] = []
    var capturedFailureHandlers: [(@MainActor (AppError) -> Void)] = []
    var suspendsLoads = false
    private var loadContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    var vodLoads = 0
    var playCount = 0
    var pauseCount = 0
    var stopCount = 0
    var goLiveCount = 0
    var genericSeekCount = 0
    var suspendsSeeks = false
    private var seekContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var concurrentSeeks = 0
    var maximumConcurrentSeeks = 0
    var outputPolicy = LiveChannelOutputPolicy()
    var onOutputPolicy: (@MainActor (LiveChannelOutputPolicy) -> Void)?
    var supportsConcurrentPlayback: Bool { true }

    func configureLiveOutput(_ policy: LiveChannelOutputPolicy) {
        outputPolicy = policy
        onOutputPolicy?(policy)
    }

    func setWatching(_ isWatching: Bool) { watching = isWatching }

    func loadChannel(_ input: LiveChannelInput) async throws {
        loadedInputs.append(input)
        if let inputLoadError { throw inputLoadError }
        if case .stream(let url, let headers) = input {
            await loadLive(url: url, httpHeaders: headers)
        }
    }

    func loadLive(url: URL, httpHeaders: [String: String]) async {
        liveLoads += 1
        let loadNumber = liveLoads
        loadedURLs.append(url)
        loadedHeaders.append(httpHeaders)
        if let onFailure {
            capturedFailureHandlers.append(onFailure)
        }
        status = .ready
        isPaused = false
        if suspendsLoads {
            await withCheckedContinuation { continuation in
                loadContinuations[loadNumber] = continuation
            }
        }
        await onLoad?()
        cancelledLoads.append(Task.isCancelled)
    }
    func resumeLoad(_ loadNumber: Int) {
        loadContinuations.removeValue(forKey: loadNumber)?.resume()
    }
    func liveScrubThumbnail(secondsIntoWindow seconds: TimeInterval, maxWidth: Int) async -> CGImage? {
        await onScrubThumbnail?()
    }
    func load(request: PlaybackRequest, startPosition: TimeInterval) async { vodLoads += 1 }
    func play() { playCount += 1; isPaused = false }
    func pause() { pauseCount += 1; isPaused = true }
    func stop() {
        stopCount += 1
        livePlaybackFailureDiagnostic = nil
        liveTelemetry = nil
        status = .idle
        onLoad = nil
        onGoLive = nil
    }
    var lastSeekTarget: TimeInterval?
    func seek(to seconds: TimeInterval) async {
        genericSeekCount += 1
        lastSeekTarget = seconds
        await waitForSeek()
    }
    func seekToLiveEdge() async {
        goLiveCount += 1
        onGoLive?()
        await waitForSeek()
        liveSnapshot.behindLiveSeconds = 0
    }
    private func waitForSeek() async {
        concurrentSeeks += 1
        maximumConcurrentSeeks = max(maximumConcurrentSeeks, concurrentSeeks)
        defer { concurrentSeeks -= 1 }
        if suspendsSeeks {
            let id = genericSeekCount + goLiveCount
            await withCheckedContinuation { seekContinuations[id] = $0 }
        }
    }
    func resumeSeek(_ id: Int) { seekContinuations.removeValue(forKey: id)?.resume() }
    func resumeAllSeeks() {
        suspendsSeeks = false
        let continuations = Array(seekContinuations.values)
        seekContinuations.removeAll()
        for continuation in continuations { continuation.resume() }
    }
    func selectAudioTrack(_ track: MediaTrack?) { currentAudioTrackID = track?.id }
    func selectSubtitleTrack(_ track: MediaTrack?) { selectedSubtitleID = track?.id }
    func makeVideoOutputView() -> UIView { outputView }
}
#endif
