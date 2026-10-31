#if canImport(AVFoundation)
@preconcurrency import AVFoundation
@testable import CoreModels
import Foundation
import TraktService
import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import FeaturePlayback

@MainActor
final class StreamingPlaybackTests: XCTestCase {
    func testForceTranscodingHintRequiresAFailedConvertedStream() async {
        for enabled in [false, true] {
            for converted in [false, true] {
                let provider = QualityPlaybackProvider()
                if converted { await provider.setCompatibilityRendition() }
                else { await provider.setDeliversOriginal() }
                let engine = QualityEngine()
                let model = PlayerViewModel(
                    provider: provider, itemID: "movie",
                    streamingOptions: .init(quality: .original, forceTranscoding: enabled),
                    engineFactory: .init(makeNative: { _ in engine })
                )
                await model.load()
                XCTAssertEqual(model.phase, .ready)
                XCTAssertFalse(model.showsForcedTranscodingFailureHint)
                XCTAssertEqual(model.streamingIsTranscoding, converted)
                model.handoffSetPhase(.failed(.invalidResponse))
                XCTAssertEqual(model.showsForcedTranscodingFailureHint, enabled && converted)
                XCTAssertNotNil(model.playbackFailureReport?.message)
                XCTAssertEqual(model.streamingOptions?.forceTranscoding, enabled)
                model.retryPlayback()
                XCTAssertFalse(model.showsForcedTranscodingFailureHint)
                await wait { model.phase == .ready }
                XCTAssertFalse(model.showsForcedTranscodingFailureHint)
                await model.stop()
            }
        }
    }

    func testForceTranscodingHintDistinguishesConversionRefusalsFromOtherPreparationFailures() async {
        let cases: [(StreamingQualityError, Bool)] = [
            (.unavailable, true), (.unsupported, true), (.noCompatibleStream, true),
            (.codecUnavailable(.hevc), true), (.plexDecision(1000), true),
            (.serverRefusal("Conversion refused.", reason: .transcodingDisabled), true),
            (.serverRefusal("Conversion refused.", reason: .conversionToolUnavailable), true),
            (.serverRefusal("Conversion refused.", reason: .hdrTranscodeUnsupported), true),
            (.authenticationRequired, false), (.permissionDenied, false), (.sourceUnavailable, false),
            (.noStreams, false), (.malformedResponse, false), (.negotiationFailed, false),
            (.serverHTTP(401), false), (.serverHTTP(500), false),
            (.playback(.init(kind: .network)), false),
            (.serverRefusal("Source refused.", reason: .sourceMismatch), false)
        ]
        for (error, expected) in cases {
            let provider = QualityPlaybackProvider()
            await provider.setPreparationFailure(error)
            let model = PlayerViewModel(
                provider: provider, itemID: "movie",
                streamingOptions: .init(quality: .original, forceTranscoding: true),
                engineFactory: .init(makeNative: { _ in QualityEngine() })
            )
            await model.load()
            XCTAssertEqual(model.phase, .failed(.invalidResponse))
            XCTAssertEqual(model.streamingQualityError, error)
            XCTAssertEqual(model.showsForcedTranscodingFailureHint, expected, "\(error)")
            XCTAssertEqual(model.streamingOptions?.forceTranscoding, true)
            await model.stop()
        }
    }

    func testForceTranscodingHintFollowsTheCurrentVideoSelection() async {
        let provider = QualityPlaybackProvider()
        let engine = QualityEngine()
        let model = PlayerViewModel(
            provider: provider, itemID: "movie", streamingOptions: .init(quality: .original),
            engineFactory: .init(makeNative: { _ in engine })
        )
        await model.load()
        model.changeStreamingOptions(.init(quality: .original, forceTranscoding: true))
        await wait { model.phase == .ready && engine.positions.count == 2 }
        model.handoffSetPhase(.failed(.invalidResponse))
        XCTAssertTrue(model.showsForcedTranscodingFailureHint)
        model.changeStreamingOptions(.init(quality: .original))
        XCTAssertFalse(model.showsForcedTranscodingFailureHint)
        await wait { model.phase == .ready && engine.positions.count == 3 }
        model.handoffSetPhase(.failed(.invalidResponse))
        XCTAssertFalse(model.showsForcedTranscodingFailureHint)
        await model.stop()
    }

    func testForceTranscodingContinuationDoesNotTurnAnAutomaticFallbackIntoASetting() async {
        for selectedOptions: StreamingPlaybackOptions? in [nil, .init(quality: .original)] {
            let model = PlayerViewModel(
                provider: QualityPlaybackProvider(), itemID: "movie",
                continuation: .init(
                    position: 30, streamingOptions: .init(quality: .original, forceTranscoding: true),
                    intendsPlayback: true, speed: 1, tracks: .init()
                ),
                streamingOptions: selectedOptions,
                engineFactory: .init(makeNative: { _ in QualityEngine() })
            )
            await model.load()
            XCTAssertTrue(model.streamingIsTranscoding)
            model.handoffSetPhase(.failed(.invalidResponse))
            XCTAssertEqual(model.showsForcedTranscodingFailureHint, selectedOptions != nil)
            await model.stop()
        }
    }

    func testFailureSnapshotPinsTheOldItemAndAttemptAcrossImmediateRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let journal = PlaybackDiagnosticJournal(url: root.appendingPathComponent("playback.json"))
        let engine = QualityEngine()
        let model = PlayerViewModel(
            provider: QualityPlaybackProvider(), itemID: "movie",
            streamingOptions: .init(quality: .sd480, codec: .preferHEVC),
            engineFactory: .init(makeNative: { _ in engine }), diagnosticJournal: journal
        )
        await model.load()
        engine.nowPlayingPlayer = AVPlayer(playerItem: DiagnosticFailureItem(url: URL(fileURLWithPath: "/fixture")))
        engine.streamingFailure = .init(kind: .unknown, domain: .coreMedia, code: -12889)
        model.handoffSetPhase(.failed(.invalidResponse))
        XCTAssertNil(engine.nowPlayingPlayer, "The engine has already torn down its failing item.")
        engine.streamingFailure = nil
        model.retryPlayback()
        await wait { model.phase == .ready && engine.positions.count == 2 }
        await model.stop()

        var entries: [PlaybackDiagnosticJournal.Entry] = []
        for _ in 0..<100 {
            let report = await journal.report()
            let json = try XCTUnwrap(report.split(separator: "\n", maxSplits: 2).last)
            entries = try JSONDecoder().decode(PlaybackDiagnosticJournal.Journal.self, from: Data(json.utf8)).entries
            if entries.contains(where: { $0.event == .failureEvidence }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await journal.flush()
        defer { try? FileManager.default.removeItem(at: root) }
        let failure = try XCTUnwrap(entries.first { $0.event == .failed })
        let captured = try XCTUnwrap(entries.first { $0.event == .failureEvidence })
        XCTAssertEqual(failure.evidence?.nativeCapture, .pending)
        XCTAssertEqual(captured.evidence?.nativeCapture, .captured)
        XCTAssertEqual(captured.evidence?.nativeStatus, .failed)
        XCTAssertEqual(captured.evidence?.nativeErrors.map(\.code), [-12889, -1001])
        XCTAssertEqual(captured.failure?.kind, .unknown, "Evidence is not a speculative new classification.")
        XCTAssertEqual(captured.stage, .opening)
        XCTAssertEqual(captured.facts.quality, .sd480)
        XCTAssertEqual(captured.facts.codecPreference, .preferHEVC)
        XCTAssertEqual(captured.attempt, failure.attempt)
        XCTAssertNotEqual(captured.attempt, entries.last { $0.event == .loaded }?.attempt)
        let report = await journal.report()
        XCTAssertFalse(report.contains("private"))
        XCTAssertFalse(report.contains("secret"))
    }

    func testJournalKeepsAbandonedResolutionSeparateFromTheNewPlaybackAttempt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let journal = PlaybackDiagnosticJournal(url: root.appendingPathComponent("playback.json"))
        let gate = QualityDecisionGate()
        let provider = QualityPlaybackProvider(gate: gate)
        let engine = QualityEngine()
        let model = PlayerViewModel(
            provider: provider, itemID: "movie", streamingOptions: .init(quality: .hd720),
            engineFactory: .init(makeNative: { _ in engine }), diagnosticJournal: journal
        )
        let abandoned = Task { await model.load() }
        await gate.waitUntilEntered()
        await model.load()
        await model.stop()
        await gate.release()
        await abandoned.value
        await journal.flush()
        defer { try? FileManager.default.removeItem(at: root) }
        let report = await journal.report()
        let json = try XCTUnwrap(report.split(separator: "\n", maxSplits: 2).last)
        let entries = try JSONDecoder().decode(PlaybackDiagnosticJournal.Journal.self, from: Data(json.utf8)).entries
        let requests = entries.filter { $0.event == .requested }
        XCTAssertEqual(requests.count, 2)
        let abandonedRequest = try XCTUnwrap(requests.first)
        let activeRequest = try XCTUnwrap(requests.last)
        XCTAssertNotEqual(abandonedRequest.attempt, activeRequest.attempt)
        XCTAssertEqual(
            entries.first { $0.event == .releaseStarted && $0.stopReason == .superseded }?.attempt,
            abandonedRequest.attempt
        )
        XCTAssertEqual(
            entries.first { $0.event == .releaseStarted && $0.stopReason == .requested }?.attempt,
            activeRequest.attempt
        )
    }

    func testJournalPreservesFailureRetryOutputAndReleaseReasonsWithoutStaleCallbacks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let journal = PlaybackDiagnosticJournal(url: root.appendingPathComponent("playback.json"))
        let provider = QualityPlaybackProvider()
        let engine = QualityEngine()
        let model = PlayerViewModel(
            provider: provider, itemID: "movie", streamingOptions: .init(quality: .sd480, codec: .preferHEVC),
            engineFactory: .init(makeNative: { _ in engine }), diagnosticJournal: journal
        )
        await model.load()
        let oldPhase = engine.onDiagnosticPhaseChanged
        engine.streamingFailure = .init(kind: .unsupportedFormat, domain: .avFoundation, code: -11829)
        engine.onFailure?(.unknown("https://private.test?token=secret"))
        await wait { engine.positions.count == 2 && model.phase == .ready }
        oldPhase?(.stalled)
        engine.onDiagnosticPhaseChanged?(.playing)
        engine.onDiagnosticPhaseChanged?(.playing)
        engine.streamingOutputVideoCodec = .h264
        model.upNextDidPresentFirstFrame()
        model.upNextDidPresentFirstFrame()
        await model.stop()
        oldPhase?(.stalled)
        await journal.flush()
        defer { try? FileManager.default.removeItem(at: root) }
        let report = await journal.report()
        let json = try XCTUnwrap(report.split(separator: "\n", maxSplits: 2).last)
        let entries = try JSONDecoder().decode(PlaybackDiagnosticJournal.Journal.self, from: Data(json.utf8)).entries
        let failure = try XCTUnwrap(entries.first { $0.event == .failed })
        let loaded = entries.filter { $0.event == .loaded }
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(failure.failure?.nativeCode, -11829)
        XCTAssertEqual(failure.stage, .opening)
        XCTAssertEqual(failure.facts.quality, .sd480)
        XCTAssertEqual(failure.facts.codecPreference, .preferHEVC)
        XCTAssertEqual(failure.attempt, loaded.first?.attempt)
        XCTAssertNotEqual(failure.attempt, loaded.last?.attempt)
        XCTAssertTrue(entries.contains { $0.event == .codecRetry })
        XCTAssertEqual(entries.filter { $0.event == .phaseChanged }.map(\.phase), [.playing])
        XCTAssertEqual(entries.filter { $0.event == .firstFrame }.count, 1)
        XCTAssertEqual(entries.first { $0.event == .firstFrame }?.facts.outputCodec, .h264)
        XCTAssertEqual(entries.filter { $0.event == .releaseStarted }.map(\.stopReason), [.replacement, .requested])
        XCTAssertFalse(report.contains("private"))
        XCTAssertFalse(report.contains("secret"))
        XCTAssertFalse(report.contains("quality-"))
    }

    func testEmbeddedChaptersAppearAfterLoadWithoutServerMetadata() async {
        let (model, engine, _) = make()
        engine.loadChapters = [.init(start: 180, title: "From file"), .init(start: 0)]
        await model.load()
        XCTAssertEqual(model.controls.infoCard.chapters.map(\.start), [0, 180])
        model.setPaused(true)
        model.seekToChapter(engine.loadChapters[0])
        await wait { engine.currentTime == 180 && !model.controls.isSeeking }
        XCTAssertTrue(engine.isPaused)
        await model.stop()
    }

    func testLateEmbeddedChaptersPreserveServerMetadataAndArtwork() async {
        for serverHasChapters in [false, true] {
            let (model, engine, provider) = make()
            let server = MediaChapter(
                start: 0, title: "Server title", imageURL: URL(string: "https://fixture.invalid/chapter.jpg")
            )
            await provider.setChapters(serverHasChapters ? [server] : [])
            await model.load()
            let embedded = [MediaChapter(start: 0, title: "File title"), .init(start: 90)]
            engine.chapters = embedded
            engine.onChaptersChanged?()
            XCTAssertEqual(model.controls.infoCard.chapters, serverHasChapters ? [server] : embedded)
            await model.stop()
        }
    }

    func testUnusableServerChaptersAllowEmbeddedFallback() async {
        let (model, engine, provider) = make()
        await provider.setChapters([.init(start: -1), .init(start: 900)])
        engine.loadChapters = [.init(start: 0, title: "File title")]
        await model.load()
        XCTAssertEqual(model.controls.infoCard.chapters, engine.loadChapters)
        await model.stop()
    }

    func testOldChapterCallbacksCannotPublishAfterReloadOrStop() async {
        let (model, engine, _) = make()
        engine.loadChapters = [.init(start: 0), .init(start: 180)]
        await model.load()
        let outgoingCallback = engine.onChaptersChanged
        engine.loadChapters = []
        model.changeStreamingOptions(.init(quality: .sd480))
        await wait { engine.positions.count == 2 && model.phase == .ready }
        XCTAssertTrue(model.controls.infoCard.chapters.isEmpty)
        engine.chapters = [.init(start: 60, title: "Stale")]
        outgoingCallback?()
        XCTAssertTrue(model.controls.infoCard.chapters.isEmpty)
        let stoppedCallback = engine.onChaptersChanged
        await model.stop()
        stoppedCallback?()
        XCTAssertTrue(model.controls.infoCard.chapters.isEmpty)
        XCTAssertNil(engine.onChaptersChanged)
    }

    func testChaptersReachControlsSeekThroughTransportAndClearOnStop() async {
        for paused in [false, true] {
            let (model, engine, provider) = make()
            let chapter = MediaChapter(start: 180, title: "Middle")
            await provider.setChapters([.init(start: 0), chapter])
            await model.load()
            XCTAssertEqual(model.controls.infoCard.chapters.map(\.start), [0, 180])
            model.setPaused(paused)
            model.seekToChapter(chapter)
            await wait { engine.currentTime == 180 && !model.controls.isSeeking }
            XCTAssertEqual(model.controls.intendsPause, paused)
            XCTAssertEqual(engine.isPaused, paused)
            model.seekToChapter(.init(start: 240, title: "Not in this video"))
            XCTAssertEqual(engine.currentTime, 180)
            await model.stop()
            XCTAssertTrue(model.controls.infoCard.chapters.isEmpty)
        }
    }

    func testQualityReloadReplacesChapterMetadataRatherThanKeepingOutgoingChapters() async {
        let (model, engine, provider) = make()
        await provider.setChapters([.init(start: 0), .init(start: 180)])
        await model.load()
        await provider.setChapters([])
        model.changeStreamingOptions(.init(quality: .sd480))
        await wait { engine.positions.count == 2 && model.phase == .ready }
        XCTAssertTrue(model.controls.infoCard.chapters.isEmpty)
        await model.stop()
    }

    func testCancelledStopCallerStillReportsAndConcurrentStopJoinsTeardown() async {
        let (model, engine, provider) = make()
        await model.load()
        engine.currentTime = 590
        let gate = QualityDecisionGate()
        engine.drainGate = gate
        let stop = Task { await model.stop() }
        await gate.waitUntilEntered()
        stop.cancel()
        var joined = false
        var secondEntered = false
        let secondStop = Task { secondEntered = true; await model.stop(); joined = true }
        await wait { secondEntered }
        XCTAssertFalse(joined, "A second stop must await the same outstanding teardown.")
        await gate.release()
        await stop.value
        await secondStop.value
        let reports = await provider.playbackReports
        XCTAssertEqual(reports.filter { $0.event == .stop }.count, 1)
        XCTAssertEqual(reports.last?.progress.positionSeconds, 590)
        XCTAssertEqual(reports.last?.progress.durationSeconds, 600)
        let released = await provider.released
        XCTAssertEqual(released, ["quality-1"])
    }

    func testDismissalDuringOutgoingRenditionReportPreservesOneFinalStop() async {
        let (model, engine, provider) = make()
        await model.load()
        engine.currentTime = 590
        engine.duration = 620
        let gate = QualityDecisionGate()
        await provider.setStopReportGate(gate)
        model.changeStreamingOptions(.init(quality: .sd480))
        await gate.waitUntilEntered()
        var stopEntered = false
        let stop = Task { stopEntered = true; await model.stop() }
        await wait { stopEntered }
        await gate.release()
        await stop.value
        let reports = await provider.playbackReports
        XCTAssertEqual(reports.map(\.event), [.start, .stop])
        XCTAssertEqual(reports.last?.progress.playSessionID, "report-1")
        XCTAssertEqual(reports.last?.progress.positionSeconds, 590)
        XCTAssertEqual(reports.last?.progress.durationSeconds, 620)
        XCTAssertEqual(engine.positions.count, 1, "Dismissal must not start the replacement.")
    }

    func testProfileSDHPreferenceReachesServerNegotiation() async throws {
        let provider = QualityPlaybackProvider()
        let engine = QualityEngine()
        let model = PlayerViewModel(
            provider: provider, itemID: "movie",
            behavior: .init(preferredSubtitleLanguage: "en", hearingImpairedPreference: .onlySDH),
            streamingOptions: .init(quality: .hd720),
            engineFactory: .init(makeNative: { _ in engine })
        )
        await model.load()
        let calls = await provider.calls
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.options.hearingImpairedPreference, .onlySDH)
        XCTAssertNil(call.options.selectedSubtitle(in: [
            .init(id: 1, kind: .subtitle, displayTitle: "English", language: "en")
        ]))
        await model.stop()
    }

    func testPausedSessionMaintenanceDoesNotWaitForScrobbling() async throws {
        let provider = QualityPlaybackProvider()
        let gate = QualityDecisionGate()
        let engine = QualityEngine()
        let model = PlayerViewModel(
            provider: provider, itemID: "movie", streamingOptions: .init(quality: .hd720),
            scrobbler: GatedQualityScrobbler(gate: gate),
            engineFactory: .init(makeNative: { _ in engine })
        )
        model.streamingSessionMaintenance = .init(interval: .milliseconds(5))
        let load = Task { await model.load() }
        await gate.waitUntilEntered()
        model.setPaused(true)
        let deadline = ContinuousClock.now + .seconds(2)
        while await provider.maintained.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let maintained = await provider.maintained
        XCTAssertFalse(maintained.isEmpty)
        XCTAssertTrue(engine.isPaused)
        XCTAssertEqual(engine.currentTime, 0)
        await gate.release()
        await load.value
        await model.stop()
    }

    func testFailureDuringStartReportCannotRestartMaintenance() async throws {
        let provider = QualityPlaybackProvider()
        let gate = QualityDecisionGate()
        await provider.setStartReportGate(gate)
        let (model, _, _) = make(provider: provider)
        model.streamingSessionMaintenance = .init(interval: .milliseconds(5))
        let load = Task { await model.load() }
        await gate.waitUntilEntered()
        model.handoffSetPhase(.failed(.invalidResponse))
        await gate.release()
        await load.value
        let deadline = ContinuousClock.now + .seconds(2)
        while await provider.released.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let before = await provider.maintained.count
        try await Task.sleep(for: .milliseconds(30))
        let after = await provider.maintained.count
        let released = await provider.released
        XCTAssertEqual(before, after)
        XCTAssertEqual(released, ["quality-1"])
        if case .failed = model.phase {} else { XCTFail("Late reporting must not revive failed playback.") }
        await model.stop()
    }

    func testTerminalFailureAndStopBothDrainAnInFlightPingBeforeRelease() async throws {
        let provider = QualityPlaybackProvider()
        let gate = QualityDecisionGate()
        await provider.setMaintenanceGate(gate)
        let (model, _, _) = make(provider: provider)
        model.streamingSessionMaintenance = .init(interval: .milliseconds(5))
        await model.load()
        await gate.waitUntilEntered()
        model.handoffSetPhase(.failed(.invalidResponse))
        let stop = Task { await model.stop() }
        try await Task.sleep(for: .milliseconds(20))
        let premature = await provider.released
        XCTAssertTrue(premature.isEmpty)
        await gate.release()
        await stop.value
        try await Task.sleep(for: .milliseconds(20))
        let released = await provider.released
        let maintained = await provider.maintained
        XCTAssertEqual(released, ["quality-1"])
        XCTAssertEqual(maintained, ["quality-1"])
    }

    func testStreamingMaintenanceDoesNotNeedPositionUpdatesAndDrainsOnCancel() async throws {
        let provider = QualityPlaybackProvider()
        let gate = QualityDecisionGate()
        await provider.setMaintenanceGate(gate)
        let maintenance = StreamingSessionMaintenance(interval: .milliseconds(5))
        maintenance.start(request: maintenanceRequest("first"), provider: provider)
        await gate.waitUntilEntered()
        let ending = maintenance.cancel()
        var drained = false
        let drain = Task { await ending?.value; drained = true }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(drained, "The server session cannot be released while its ping is still in flight.")
        await gate.release()
        await drain.value
        try await Task.sleep(for: .milliseconds(20))
        let maintained = await provider.maintained
        let reports = await provider.playbackReports
        XCTAssertEqual(maintained, ["first"])
        XCTAssertTrue(reports.isEmpty, "Maintenance must not generate watch-progress/scrobble events.")
    }

    func testStreamingMaintenanceReplacementWaitsForTheOldPing() async throws {
        let provider = QualityPlaybackProvider()
        let gate = QualityDecisionGate()
        await provider.setMaintenanceGate(gate)
        let maintenance = StreamingSessionMaintenance(interval: .milliseconds(5))
        maintenance.start(request: maintenanceRequest("first"), provider: provider)
        await gate.waitUntilEntered()
        maintenance.start(request: maintenanceRequest("second"), provider: provider)
        try await Task.sleep(for: .milliseconds(20))
        let beforeDrain = await provider.maintained
        XCTAssertEqual(beforeDrain, ["first"])
        await gate.release()
        let deadline = ContinuousClock.now + .seconds(2)
        while await provider.maintained.count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        await maintenance.cancel()?.value
        let maintained = await provider.maintained
        XCTAssertGreaterThanOrEqual(maintained.count, 2)
        XCTAssertEqual(maintained.first, "first")
        XCTAssertTrue(maintained.dropFirst().allSatisfy { $0 == "second" })
    }

    func testStreamingMaintenanceSkipsOriginalFilesAndUnownedSessions() async throws {
        let provider = QualityPlaybackProvider()
        let maintenance = StreamingSessionMaintenance(interval: .milliseconds(5))
        for original in [true, false] {
            var request = maintenanceRequest("unused")
            if original { request.isTranscoding = false }
            else { request.streamingSessionID = nil }
            maintenance.start(request: request, provider: provider)
            try await Task.sleep(for: .milliseconds(20))
            await maintenance.cancel()?.value
        }
        let maintained = await provider.maintained
        XCTAssertTrue(maintained.isEmpty)
    }

    private func maintenanceRequest(_ sessionID: String) -> PlaybackRequest {
        var request = PlaybackRequest(
            item: .init(id: "movie", title: "Movie", kind: .movie),
            streamURL: URL(string: "https://fixture.test/master.m3u8")!,
            isTranscoding: true
        )
        request.streamingSessionID = sessionID
        return request
    }

    func testGeneratedStillsUseOriginalQualityButNeverReducedQuality() async throws {
        let source = PlaybackSource.publicURL(try SecretFreeURLSource(
            url: URL(string: "https://fixture.test/original.mp4")!
        ))
        for quality in [StreamingQuality.original, .hd720] {
            let provider = QualityPlaybackProvider()
            await provider.setScrubStillSource(source)
            let engine = QualityEngine()
            var sources: [PlaybackSource] = []
            let model = PlayerViewModel(
                provider: provider, itemID: "movie", mediaSourceID: "version",
                streamingOptions: .init(quality: quality, forceTranscoding: true),
                engineFactory: .init(
                    makeNative: { _ in engine },
                    makeScrubStillExtractor: { source, _ in
                        sources.append(source)
                        return QualityScrubStillExtractor()
                    }
                )
            )
            await model.load()
            XCTAssertTrue(model.isTranscoding)
            XCTAssertEqual(model.makeScrubPreviewCoordinator() != nil, quality == .original)
            XCTAssertEqual(sources, quality == .original ? [source] : [])
            await model.stop()
        }
    }

    func testBurnedSubtitleOffAndTrackSwitchRebuildLegacyAndBoundedRenditions() async {
        for options: StreamingPlaybackOptions? in [nil, .init(quality: .hd720)] {
            for selection in [PlayerTrackOption.offID, 7] {
                let provider = QualityPlaybackProvider()
                await provider.setBurnedSubtitle()
                let (model, engine, _) = make(options: options, provider: provider)
                await model.load()
                XCTAssertNil(engine.selectedSubtitleID, "Burn-in must not select a native legible copy")
                XCTAssertTrue(model.liveSubtitles.primary.isEmpty)
                XCTAssertFalse(model.controls.subtitleDelayAdjustable)
                XCTAssertEqual(model.continuationForVersionChange().tracks.primary?.id, 6)
                model.selectSubtitleOption(id: 6)
                XCTAssertEqual(engine.positions.count, 1, "Reselecting burn-in must not restart")
                engine.currentTime = 123
                model.setPaused(true)
                model.setPlaybackSpeed(1.5)
                model.selectSubtitleOption(id: selection)
                await wait { engine.positions.count == 2 && model.phase == .ready }
                XCTAssertEqual(engine.positions.last, 123)
                XCTAssertTrue(engine.isPaused)
                XCTAssertEqual(model.controls.playbackSpeed, 1.5)
                XCTAssertEqual(engine.selectedSubtitleID, selection == 7 ? 7 : nil)
                let calls = await provider.calls
                XCTAssertEqual(calls.last?.options.subtitlesOff, selection == PlayerTrackOption.offID)
                XCTAssertEqual(calls.last?.options.subtitleTrack?.id, selection == 7 ? 7 : nil)
                XCTAssertEqual(calls.last?.options.audioTrack?.id, 3)
                XCTAssertEqual(calls.last?.source, "version")
                XCTAssertEqual(calls.last?.options.quality, options?.quality ?? .original)
                if options == nil { XCTAssertEqual(calls.last?.options.forceTranscoding, true) }
                model.handoffSetPhase(.failed(.invalidResponse))
                XCTAssertFalse(model.showsForcedTranscodingFailureHint,
                               "Keeping a legacy fallback transcoding is not enabling the user's setting.")
                await model.stop()
            }
        }
    }

    func testStoppingAfterBackgroundClockResetReportsThePreservedPosition() async {
        let (model, engine, provider) = make(options: .init(quality: .original))
        await model.load()
        engine.currentTime = 123
        model.suspendForBackground()
        engine.currentTime = 0.07
        await model.stop()
        let reports = await provider.playbackReports
        XCTAssertEqual(reports.last { $0.event == .stop }?.progress.positionSeconds, 123)
    }

    func testBackgroundReturnPreservesPositionAcrossClockResetAndLateSourceProbe() async {
        let (model, engine, _) = make(options: .init(quality: .original))
        await model.load()
        engine.currentTime = 123
        engine.onPause = { [weak engine] in
            engine?.currentTime = 0
            engine?.onPause = nil
        }
        model.suspendForBackground()
        XCTAssertEqual(engine.currentTime, 0)
        let diagnosticsBeforeProbe = model.diagnosticsToken
        engine.onProbedSourceFactsChanged?(.init(range: .hdr10))
        XCTAssertNotEqual(model.diagnosticsToken, diagnosticsBeforeProbe)
        XCTAssertEqual(model.continuationForVersionChange().position, 123)
        model.didEnterBackground()
        await model.resumeAfterBackground()
        XCTAssertEqual(engine.currentTime, 123)
        XCTAssertTrue(engine.isPaused)
        XCTAssertTrue(model.controls.intendsPause)
        XCTAssertEqual(model.phase, .ready)
        await model.stop()
    }

    func testCueArrivalUsesThePresentationClockBeforeTheNextDisplayTick() async {
        let (model, engine, _) = make(options: .init(quality: .original))
        await model.load()
        model.selectSubtitleOption(id: 6)
        model.liveSubtitles.tick(0)
        engine.currentTime = 75
        engine.onSubtitleCues?([
            .init(id: 1, start: 74, end: 76, body: .text(.init("Current picture"))),
            .init(id: 2, start: 0, end: 2, body: .text(.init("Previous clock")))
        ])
        XCTAssertEqual(model.liveSubtitles.primary.compactMap(\.text), ["Current picture"])
        await model.stop()
    }

    func testCustomSelectionRetainsTracksPositionPauseSpeedAndVersionContinuation() async throws {
        let quality = try StreamingQuality.custom(maximumHeight: 1080, bitrateKbps: 2_000)
        let (model, engine, provider) = make()
        await model.load()
        engine.currentTime = 123
        model.selectAudioOption(id: 4)
        model.selectSubtitleOption(id: 6)
        model.setPaused(true)
        model.setPlaybackSpeed(1.5)
        model.changeStreamingOptions(.init(quality: quality))
        await wait { engine.positions.count == 2 && model.phase == .ready }
        XCTAssertEqual(engine.positions.last, 123)
        XCTAssertTrue(engine.isPaused)
        XCTAssertEqual(model.controls.playbackSpeed, 1.5)
        XCTAssertEqual(engine.currentAudioTrackID, 4)
        XCTAssertEqual(engine.selectedSubtitleID, 6)
        XCTAssertEqual(model.streamingOptions?.quality, quality)
        let calls = await provider.calls
        XCTAssertEqual(calls.map(\.source), ["version", "version"])
        XCTAssertEqual(calls.map { $0.options.quality }, [.hd720, quality],
                       "Changing just resolution at the same total bitrate is still a new quality")
        model.changeStreamingOptions(.init(quality: try .custom(maximumHeight: 1080, bitrateKbps: 2_000)))
        let unchangedCalls = await provider.calls
        XCTAssertEqual(unchangedCalls.count, 2, "Recreating the same custom value must not restart playback")

        engine.currentTime = 92
        let continuation = model.continuationForVersionChange()
        await model.stop()
        let incomingEngine = QualityEngine()
        let incomingProvider = QualityPlaybackProvider()
        let incoming = PlayerViewModel(
            provider: incomingProvider, itemID: "movie", mediaSourceID: "other-version",
            continuation: continuation,
            streamingOptions: .init(quality: .original),
            engineFactory: .init(makeNative: { _ in incomingEngine })
        )
        await incoming.load()
        XCTAssertEqual(incomingEngine.positions, [92])
        XCTAssertTrue(incomingEngine.isPaused)
        XCTAssertEqual(incoming.controls.playbackSpeed, 1.5)
        XCTAssertEqual(incoming.streamingOptions?.quality, quality)
        XCTAssertEqual(incomingEngine.currentAudioTrackID, 4)
        XCTAssertEqual(incomingEngine.selectedSubtitleID, 6)
        let incomingCalls = await incomingProvider.calls
        XCTAssertEqual(incomingCalls.first?.source, "other-version")
        await incoming.stop()
    }

    func testCustomCodecRetryRetainsExactLimitsAndDoesNotChangeAnotherPlayer() async throws {
        let quality = try StreamingQuality.custom(maximumHeight: 1080, bitrateKbps: 2_000)
        let otherQuality = try StreamingQuality.custom(maximumHeight: 480, bitrateKbps: 750)
        let (model, engine, provider) = make(options: .init(quality: quality, codec: .preferHEVC))
        let (other, otherEngine, otherProvider) = make(options: .init(quality: otherQuality))
        await model.load()
        await other.load()
        engine.currentTime = 76
        model.setPaused(true)
        engine.onFailure?(.invalidResponse)
        await wait { engine.positions.count == 2 && model.phase == .ready }
        let calls = await provider.calls
        XCTAssertEqual(calls.map { $0.options.quality }, [quality, quality])
        XCTAssertEqual(calls.map { $0.options.codec }, [.preferHEVC, .preferH264])
        XCTAssertEqual(calls.map(\.forceTranscode), [false, true])
        XCTAssertEqual(calls.map(\.source), ["version", "version"])
        XCTAssertEqual(engine.positions.last, 76)
        XCTAssertTrue(engine.isPaused)
        XCTAssertEqual(model.streamingOptions?.codec, .preferHEVC)
        XCTAssertEqual(other.streamingOptions?.quality, otherQuality)
        XCTAssertEqual(otherEngine.loadedQualities, [otherQuality])
        let otherCalls = await otherProvider.calls
        XCTAssertEqual(otherCalls.count, 1)
        await model.stop()
        await other.stop()
    }

    func testInvalidCustomLimitShowsItsErrorWithoutCallingProviderOrTryingMaximum() async {
        let (model, engine, provider) = make(options: .init(quality: .invalid(.malformedCustom)))
        await model.load()
        if case .failed = model.phase {} else { XCTFail("Invalid custom quality must fail closed") }
        XCTAssertEqual(model.streamingQualityError, .invalidQuality(.malformedCustom))
        let calls = await provider.calls
        let ordinaryCalls = await provider.ordinaryCalls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(ordinaryCalls, 0)
        XCTAssertTrue(engine.loadedQualities.isEmpty)
        await model.stop()
    }

    func testFailedOriginalQualityRemuxIsEncodedOnRetryWithoutSavingAForcePreference() async {
        let provider = QualityPlaybackProvider()
        await provider.setCompatibilityRendition()
        await provider.setNegotiatedCodec(.hevc)
        let (model, engine, _) = make(
            options: .init(quality: .original), provider: provider, capabilities: .init(supportsHEVC: true)
        )
        await model.load()
        engine.onFailure?(.invalidResponse)
        await wait { engine.positions.count == 2 && model.phase == .ready }
        let calls = await provider.calls
        XCTAssertEqual(calls.map(\.forceTranscode), [false, true])
        XCTAssertEqual(calls.map { $0.options.quality }, [.original, .original])
        XCTAssertEqual(calls.map { $0.options.codec }, [.automatic, .preferH264])
        XCTAssertEqual(model.streamingOptions?.forceTranscoding, false)
        XCTAssertEqual(model.streamingOptions?.codec, .automatic)
        await model.stop()
    }

    func testCurrentStreamBadgesResetAndRejectPriorRenditionCallbacks() async {
        let (model, engine, _) = make()
        await model.load()
        XCTAssertTrue(model.controls.infoCard.isTranscoding)
        XCTAssertTrue(model.controls.infoCard.badges.isEmpty)
        let token = model.diagnosticsToken
        let details = PlaybackStreamDetails(metadata: .init(
            video: .init(codec: "h264", width: 426, height: 230, videoRangeType: "SDR"),
            audio: .init(codec: "aac", channels: 2)
        ))
        model.updateCurrentStreamDetails(details, token: token, playerID: model.playerInstanceID)
        XCTAssertEqual(model.controls.infoCard.badges, details.technicalBadges)
        XCTAssertEqual(model.currentStreamDetails, details)
        model.changeStreamingOptions(.init(quality: .low))
        XCTAssertTrue(model.currentStreamDetails.technicalBadges.isEmpty)
        XCTAssertTrue(model.controls.infoCard.badges.isEmpty)
        await wait { model.phase == .ready && engine.positions.count == 2 }
        model.updateCurrentStreamDetails(details, token: token, playerID: model.playerInstanceID)
        XCTAssertTrue(model.currentStreamDetails.technicalBadges.isEmpty)
        await model.stop()
        model.updateCurrentStreamDetails(details, token: model.diagnosticsToken, playerID: model.playerInstanceID)
        XCTAssertTrue(model.currentStreamDetails.technicalBadges.isEmpty)
    }

    func testAutomaticH264FailureRequestsHEVCWithoutChangingBudgetOrVersion() async throws {
        let provider = QualityPlaybackProvider()
        await provider.setNegotiatedCodec(.h264)
        let (model, engine, _) = make(provider: provider, capabilities: .init(supportsHEVC: true))
        await model.load()
        XCTAssertEqual(model.streamingNegotiatedVideoCodec, .h264)
        engine.currentTime = 95
        model.setPaused(true)
        engine.streamingFailure = .init(kind: .hdrConversionUnconfirmed, domain: .coreMedia, code: -12927, provider: .emby)
        engine.onFailure?(.invalidResponse)
        await wait { model.phase == .ready && engine.positions.count == 2 }
        let calls = await provider.calls
        XCTAssertEqual(calls.map { $0.options.codec }, [.automatic, .preferHEVC])
        XCTAssertEqual(calls.map { $0.options.quality }, [.hd720, .hd720])
        XCTAssertEqual(calls.map(\.source), ["version", "version"])
        XCTAssertEqual(engine.positions.last, 95)
        XCTAssertTrue(engine.isPaused)
        XCTAssertTrue(model.streamingUsedHEVCFallback)
        XCTAssertFalse(model.streamingUsedH264Fallback)
        var retryMessage = try XCTUnwrap(model.streamingCodecRetryMessage)
        retryMessage.locale = Locale(identifier: "en_US")
        XCTAssertEqual(String(localized: retryMessage), "Retried requesting HEVC at the same quality limit.")
        XCTAssertEqual(model.streamingNegotiatedVideoCodec, .h264,
                       "A requested HEVC retry is not proof that the server supplied HEVC")
        XCTAssertEqual(model.streamingOptions?.codec, .automatic)
        engine.onFailure?(.invalidResponse)
        await wait { if case .failed = model.phase { return true }; return false }
        let afterFailure = await provider.calls
        XCTAssertEqual(afterFailure.count, 2)
        await model.stop()
    }

    func testRefusedAutomaticHEVCRetryDoesNotFallBackToH264AThirdTime() async {
        let provider = QualityPlaybackProvider()
        await provider.setNegotiatedCodec(.h264)
        await provider.setSourceRange("HDR10")
        await provider.setHEVCFailure(StreamingQualityError.codecUnavailable(.hevc))
        let (model, engine, _) = make(provider: provider, capabilities: .init(supportsHEVC: true))
        await model.load()
        engine.onFailure?(.invalidResponse)
        await wait { if case .failed = model.phase { return true }; return false }
        let calls = await provider.calls
        XCTAssertEqual(calls.map { $0.options.codec }, [.automatic, .preferHEVC])
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(model.streamingQualityError, .codecUnavailable(.hevc))
        XCTAssertTrue(model.streamingHasHDRConversionError, "Keep explicit SDR/original recovery available after HEVC is refused")
        await model.stop()
    }

    func testFailedStreamIsReleasedBeforeDismissAndOnlyOnce() async {
        let (model, engine, provider) = make(options: .init(quality: .hd720, codec: .preferH264))
        await model.load()
        engine.onFailure?(.invalidResponse)
        await wait { if case .failed = model.phase { return true }; return false }
        let deadline = ContinuousClock.now + .seconds(3)
        while await provider.released.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        let beforeDismiss = await provider.released
        XCTAssertEqual(beforeDismiss, ["quality-1"])
        await model.stop()
        let afterDismiss = await provider.released
        XCTAssertEqual(afterDismiss, ["quality-1"])
    }

    func testRefusedHEVCNegotiationRetriesH264OnceWithoutChangingThePreferenceOrBudget() async {
        for refusal in [
            StreamingQualityError.noCompatibleStream, .unavailable, .plexDecision(4005),
            .serverHTTP(400), .serverHTTP(415), .serverHTTP(422)
        ] {
            let provider = QualityPlaybackProvider()
            await provider.setHEVCFailure(refusal)
            let (model, engine, _) = make(options: .init(quality: .sd480, codec: .preferHEVC), provider: provider)
            await model.load()
            XCTAssertEqual(model.phase, .ready)
            let calls = await provider.calls
            XCTAssertEqual(calls.map { $0.options.codec }, [.preferHEVC, .preferH264])
            XCTAssertEqual(calls.map { $0.options.quality }, [.sd480, .sd480])
            XCTAssertEqual(calls.map(\.source), ["version", "version"])
            XCTAssertEqual(model.streamingOptions?.codec, .preferHEVC)
            XCTAssertTrue(model.streamingUsedH264Fallback)
            engine.onFailure?(.invalidResponse)
            await wait { if case .failed = model.phase { return true }; return false }
            let finalCalls = await provider.calls
            XCTAssertEqual(finalCalls.count, 2)
            await model.stop()
        }
    }

    func testHEVCPreferenceDoesNotTreatAuthenticationNetworkOrServerErrorsAsCodecRefusals() async {
        let errors: [any Error & Sendable] = [
            AppError.unauthorized, AppError.serverUnreachable,
            StreamingQualityError.permissionDenied, StreamingQualityError.serverHTTP(403),
            StreamingQualityError.serverHTTP(429), StreamingQualityError.serverHTTP(503),
            StreamingQualityError.malformedResponse, StreamingQualityError.sourceUnavailable
        ]
        for error in errors {
            let provider = QualityPlaybackProvider()
            await provider.setHEVCFailure(error)
            let (model, engine, _) = make(options: .init(quality: .hd720, codec: .preferHEVC), provider: provider)
            await model.load()
            if case .failed = model.phase {} else { XCTFail("Expected the original error") }
            let calls = await provider.calls
            XCTAssertEqual(calls.count, 1)
            XCTAssertTrue(engine.loadedQualities.isEmpty)
            XCTAssertEqual(model.streamingOptions?.codec, .preferHEVC)
            await model.stop()
        }
    }

    func testStreamCodecIsObservedInsteadOfInferredFromThePreference() async {
        let (model, engine, _) = make(options: .init(quality: .hd720, codec: .preferHEVC))
        await model.load()
        XCTAssertNil(model.streamingOutputVideoCodec)
        engine.streamingOutputVideoCodec = .h264
        XCTAssertEqual(model.streamingOutputVideoCodec, .h264)
        XCTAssertEqual(model.streamingOptions?.codec, .preferHEVC)
        engine.streamingOutputVideoCodec = .hevc
        XCTAssertEqual(model.streamingOutputVideoCodec, .hevc)
        await model.stop()
    }

    func testNewUserSelectionGetsAFreshHEVCAttemptAfterAnEarlierFallback() async {
        let provider = QualityPlaybackProvider()
        await provider.setHEVCFailure(StreamingQualityError.noCompatibleStream)
        let (model, engine, _) = make(options: .init(quality: .sd480, codec: .preferHEVC), provider: provider)
        await model.load()
        engine.currentTime = 75
        model.changeStreamingOptions(.init(quality: .hd720, codec: .preferHEVC))
        await wait { model.phase == .ready && engine.positions.count == 2 }
        let calls = await provider.calls
        XCTAssertEqual(calls.map { $0.options.codec }, [.preferHEVC, .preferH264, .preferHEVC, .preferH264])
        XCTAssertEqual(calls.map { $0.options.quality }, [.sd480, .sd480, .hd720, .hd720])
        XCTAssertEqual(engine.positions.last, 75)
        XCTAssertEqual(model.streamingOptions?.codec, .preferHEVC)
        await model.stop()
    }

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

    func testOrdinaryServerHLSStartupGetsOneCodecRetryWithoutChangingContinuation() async {
        let (model, engine, provider) = make(options: nil)
        await model.load()
        XCTAssertNil(model.streamingOptions, "Ordinary playback must not opt into quality negotiation up front.")
        model.selectAudioOption(id: 4)
        engine.currentTime = 123
        model.setPaused(true)
        model.setPlaybackSpeed(1.5)
        guard model.handoffHandleStartupTimeout() else {
            XCTFail("Server-selected HLS needs the same bounded recovery as explicitly selected quality.")
            await model.stop()
            return
        }
        await wait { engine.positions.count == 2 && model.phase == .ready }
        let calls = await provider.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.item, "movie")
        XCTAssertEqual(calls.first?.source, "version")
        XCTAssertEqual(calls.first?.options.quality, .original)
        XCTAssertEqual(calls.first?.options.codec, .preferH264)
        XCTAssertEqual(calls.first?.options.audioTrack?.id, 4)
        XCTAssertEqual(calls.first?.forceTranscode, true)
        XCTAssertEqual(engine.positions.last, 123)
        XCTAssertTrue(engine.isPaused)
        XCTAssertEqual(model.controls.playbackSpeed, 1.5)
        XCTAssertFalse(model.handoffHandleStartupTimeout(), "Do not loop through server renditions.")
        XCTAssertEqual(model.streamingQualityError, .startupTimedOut)
        let ordinaryCalls = await provider.ordinaryCalls
        XCTAssertEqual(ordinaryCalls, 1, "Never retry the original file to bypass a server decision.")
        await model.stop()
    }

    func testOrdinaryServerHLSRefusalDoesNotBecomeCodecRecovery() async {
        for failure in [
            StreamingPlaybackFailure(kind: .network, domain: .url, code: -1009),
            .init(kind: .accessDenied, httpStatus: 403),
            .init(kind: .server, httpStatus: 503)
        ] {
            let (model, engine, provider) = make(options: nil)
            await model.load()
            engine.streamingFailure = failure
            XCTAssertFalse(model.handoffHandleStartupTimeout())
            XCTAssertEqual(model.streamingQualityError, .playback(failure))
            XCTAssertNil(model.streamingOptions)
            let calls = await provider.calls
            XCTAssertTrue(calls.isEmpty)
            await model.stop()
        }
    }

    func testOrdinaryServerHLSDecoderFailureUsesTheSameBoundedRecovery() async {
        let (model, engine, provider) = make(options: nil)
        await model.load()
        engine.streamingFailure = .init(kind: .unsupportedFormat, domain: .avFoundation, code: -11829)
        engine.onFailure?(.invalidResponse)
        await wait { engine.positions.count == 2 && model.phase == .ready }
        let calls = await provider.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.options.codec, .preferH264)
        XCTAssertEqual(calls.first?.forceTranscode, true)
        await model.stop()
    }

    func testOrdinaryServerHLSRecoveryPinsTheServerSelectedVersion() async throws {
        func source(_ version: String) throws -> PlaybackSource {
            .authenticatedHTTP(try .init(
                provider: .plex, accountID: "account", credentialRevision: CredentialRevision(),
                itemID: "movie", mediaSourceID: version, deliveryMode: .serverTranscode,
                purpose: .mediaStream,
                resource: try .init(pathBase: .configuredBaseURL, path: "master.m3u8")
            ))
        }
        let provider = QualityPlaybackProvider()
        await provider.setOrdinaryPlaybackSource(try source("version-a"))
        let engine = QualityEngine()
        let model = PlayerViewModel(
            provider: provider, itemID: "movie",
            engineFactory: .init(makeNative: { _ in engine })
        )
        await model.load()
        XCTAssertEqual(model.currentMediaSourceID, "version-a")
        await provider.setOrdinaryPlaybackSource(try source("version-b"))
        XCTAssertTrue(model.handoffHandleStartupTimeout())
        await wait { engine.positions.count == 2 && model.phase == .ready }
        let calls = await provider.calls
        XCTAssertEqual(calls.map(\.source), ["version-a"], "Do not ask the provider to choose its default again.")
        XCTAssertEqual(model.currentMediaSourceID, "version-a")
        await model.stop()
    }

    func testStopCancelsOrdinaryServerHLSRecoveryBeforeNegotiation() async {
        let (model, engine, provider) = make(options: nil)
        await model.load()
        let gate = QualityDecisionGate()
        engine.drainGate = gate
        guard model.handoffHandleStartupTimeout() else {
            XCTFail("Expected bounded server-rendition recovery.")
            engine.drainGate = nil
            await model.stop()
            return
        }
        await gate.waitUntilEntered()
        let stopping = Task { await model.stop() }
        await Task.yield()
        await gate.release()
        await stopping.value
        let calls = await provider.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(engine.positions.count, 1)
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
        let (model, engine, provider) = make(capabilities: .init(supportsHEVC: false))
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
        XCTAssertEqual(PlayerViewModel.streamingFailure(.unauthorized), .authenticationRequired)
        XCTAssertEqual(PlayerViewModel.streamingFailure(.serverUnreachable), .playback(.init(kind: .network)))
        XCTAssertEqual(PlayerViewModel.streamingFailure(.notFound, streamWasSupplied: false), .sourceUnavailable)
        XCTAssertEqual(PlayerViewModel.streamingFailure(.notFound), .playback(.init(kind: .unavailable)))
        XCTAssertEqual(PlayerViewModel.streamingFailure(.decoding, streamWasSupplied: false), .malformedResponse)
        XCTAssertEqual(PlayerViewModel.streamingFailure(.decoding), .playback(.init(kind: .unsupportedFormat)))
        XCTAssertEqual(PlayerViewModel.streamingFailure(.invalidResponse), .playback(.init(kind: .unknown)))
        XCTAssertEqual(PlayerViewModel.streamingFailure(.invalidResponse, streamWasSupplied: false), .negotiationFailed)
    }

    func testCompatibilityFallbackStopsTheOutgoingReportingSessionBeforeReplacement() async {
        let (model, engine, provider) = make(options: .init(quality: .original))
        await model.load()
        XCTAssertFalse(model.isTranscoding)
        engine.currentTime = 123
        model.setPaused(true)
        model.setPlaybackSpeed(1.5)
        engine.onFailure?(.invalidResponse)
        await wait { engine.positions.count == 2 && model.phase == .ready }
        let reportDeadline = ContinuousClock.now + .seconds(3)
        while !(await provider.playbackReports).contains(where: {
            $0.event == .start && $0.progress.playSessionID == "report-2"
        }), ContinuousClock.now < reportDeadline {
            await Task.yield()
        }
        let reports = await provider.playbackReports
        let stopped = reports.firstIndex {
            $0.event == .stop && $0.progress.playSessionID == "report-1"
        }
        let started = reports.firstIndex {
            $0.event == .start && $0.progress.playSessionID == "report-2"
        }
        XCTAssertNotNil(stopped)
        XCTAssertNotNil(started)
        if let stopped, let started {
            XCTAssertLessThan(stopped, started)
            XCTAssertEqual(reports[stopped].progress.positionSeconds, 123)
        }
        XCTAssertTrue(model.isTranscoding)
        XCTAssertEqual(engine.positions.last, 123)
        XCTAssertTrue(engine.isPaused)
        XCTAssertEqual(model.controls.playbackSpeed, 1.5)
        let calls = await provider.calls
        XCTAssertEqual(calls.map(\.forceTranscode), [false, true])
        await model.stop()
        let finalReports = await provider.playbackReports
        XCTAssertEqual(finalReports.filter { $0.event == .stop }.map(\.progress.playSessionID),
                       ["report-1", "report-2"])
    }

    func testDismissedCompatibilityFallbackCannotRestartOrStopTheOldSessionTwice() async {
        let (model, engine, provider) = make(options: .init(quality: .original))
        await model.load()
        engine.currentTime = 123
        let gate = QualityDecisionGate()
        await provider.installGate(gate)
        engine.onFailure?(.invalidResponse)
        await gate.waitUntilEntered()
        let stop = Task { await model.stop() }
        await Task.yield()
        await gate.release()
        await stop.value
        let reports = await provider.playbackReports
        XCTAssertEqual(reports.filter { $0.event == .start }.map(\.progress.playSessionID), ["report-1"])
        XCTAssertEqual(reports.filter { $0.event == .stop }.map(\.progress.playSessionID), ["report-1"])
        XCTAssertEqual(engine.positions.count, 1)
        let released = await provider.released
        XCTAssertTrue(released.contains("quality-2"))
    }

    private func make(
        options: StreamingPlaybackOptions? = .init(quality: .hd720),
        provider: QualityPlaybackProvider = QualityPlaybackProvider(),
        capabilities: MediaCapabilities = .detected()
    ) -> (PlayerViewModel, QualityEngine, QualityPlaybackProvider) {
        let engine = QualityEngine()
        let model = PlayerViewModel(
            provider: provider, itemID: "movie", mediaSourceID: "version",
            playbackSettings: .init(resumeRewindInterval: .five, audioLanguagePreference: .device),
            streamingOptions: options,
            engineFactory: .init(makeNative: { _ in engine }),
            capabilities: capabilities
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
        XCTAssertEqual(model.streamingOptions?.codec, .preferHEVC)
        engine.onFailure?(.invalidResponse)
        await wait { if case .failed = model.phase { return true }; return false }
        let finalCalls = await provider.calls
        XCTAssertEqual(finalCalls.count, 2, "No original or repeated codec fallback")
        await model.stop()
    }

    func testPlexNativeResourceFailureAfterEngineSwapCanPrepareOneServerRendition() async {
        let provider = QualityPlaybackProvider()
        let native = QualityEngine()
        let plozzigen = QualityEngine()
        let model = PlayerViewModel(
            provider: provider, itemID: "movie", mediaSourceID: "version",
            streamingOptions: .init(quality: .original),
            engineFactory: .init(makeNative: { _ in native }, makePlozzigen: { plozzigen })
        )
        await model.load()
        XCTAssertEqual(plozzigen.positions.count, 1)
        plozzigen.streamingFailure = .init(kind: .unsupportedFormat)
        plozzigen.onFailure?(.invalidResponse)
        await wait { model.phase == .ready && native.positions.count == 1 }

        native.currentTime = 125
        native.streamingFailure = NativePlaybackFailure.classify(NSError(
            domain: NSURLErrorDomain, code: URLError.resourceUnavailable.rawValue,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -16849)]
        ))
        native.onFailure?(.invalidResponse)
        await wait { model.phase == .ready && plozzigen.positions.count == 2 }
        let recovered = await provider.calls
        XCTAssertEqual(recovered.map(\.forceTranscode), [false, true])
        XCTAssertEqual(recovered.map(\.source), ["version", "version"])
        XCTAssertEqual(recovered.map(\.item), ["movie", "movie"])
        XCTAssertEqual(recovered.map(\.options.quality), [.original, .original])
        XCTAssertEqual(plozzigen.positions.last, 125)
        XCTAssertEqual(native.positions.count, 1, "Recovery must not swap back to the failed native attempt.")

        plozzigen.streamingFailure = NativePlaybackFailure.classify(
            URLError(.resourceUnavailable) as NSError, httpStatus: 404
        )
        plozzigen.onFailure?(.invalidResponse)
        await wait { if case .failed = model.phase { return true }; return false }
        let final = await provider.calls
        XCTAssertEqual(final.count, 2, "A confirmed missing rendition must not trigger another recovery.")
        await model.stop()
    }

    func testMissingConvertedResourceDoesNotPretendChangingCodecWillFixIt() async {
        let (model, engine, provider) = make(options: .init(quality: .low, codec: .preferHEVC))
        await model.load()
        engine.streamingFailure = .init(kind: .unavailable, domain: .url, code: -1100)
        engine.onFailure?(.invalidResponse)
        await wait { if case .failed = model.phase { return true }; return false }
        let final = await provider.calls
        XCTAssertEqual(final.count, 1)
        XCTAssertEqual(model.streamingQualityError, .playback(.init(kind: .unavailable, domain: .url, code: -1100)))
        await model.stop()
    }

    func testOrdinaryPlaybackRetainsEndedSessionEvidenceAndRetryResolvesAgain() async {
        let (model, engine, provider) = make(options: nil)
        await model.load()
        engine.currentTime = 125
        let failure = StreamingPlaybackFailure(kind: .unavailable, httpStatus: 410, provider: .silo)
        engine.streamingFailure = failure
        engine.onFailure?(.unknown("https://private.test?token=secret"))
        await wait { if case .failed = model.phase { return true }; return false }
        XCTAssertEqual(model.streamingQualityError, .playback(failure))
        XCTAssertEqual(model.streamingQualityError?.diagnosticCode, "HTTP 410")
        XCTAssertEqual(engine.status, .idle)
        XCTAssertTrue(model.playbackFailureReport?.supportText.contains("http_status=410") == true)
        XCTAssertTrue(model.playbackFailureReport?.supportText.contains("stage=opening") == true)
        let before = await provider.ordinaryCalls
        XCTAssertEqual(before, 1)
        XCTAssertFalse(String(localized: model.streamingQualityError!.userMessage).contains("secret"))

        engine.streamingFailure = nil
        model.retryPlayback()
        await wait { model.phase == .ready && engine.positions.count == 2 }
        let after = await provider.ordinaryCalls
        XCTAssertEqual(after, 2, "Retry must negotiate a fresh session, not reopen the ended URL.")
        XCTAssertEqual(engine.positions.last, 125)
        XCTAssertNil(model.streamingQualityError)
        XCTAssertNil(model.playbackFailureReport, "A retry must not show the previous attempt’s evidence.")
        await model.stop()
    }

    func testOrdinaryPlaybackAuthenticationDoesNotAttemptConversion() async {
        let (model, engine, provider) = make(options: nil)
        await model.load()
        engine.onFailure?(.unauthorized)
        await wait { if case .failed = model.phase { return true }; return false }
        XCTAssertEqual(model.streamingQualityError, .authenticationRequired)
        let ordinaryCalls = await provider.ordinaryCalls
        XCTAssertEqual(ordinaryCalls, 1)
        await model.stop()
    }

    func testOrdinaryStartupTimeoutRetainsItsCauseAfterCodecRecovery() async {
        let (model, engine, _) = make(options: nil)
        await model.load()
        XCTAssertTrue(model.handoffHandleStartupTimeout())
        await wait { engine.positions.count == 2 && model.phase == .ready }
        XCTAssertFalse(model.handoffHandleStartupTimeout())
        model.handoffSetPhase(.failed(.invalidResponse))
        XCTAssertEqual(model.streamingQualityError, .startupTimedOut)
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

    func testManagedAudioChangesRenegotiateInsteadOfSelectingRenditionLocalIndices() async throws {
        for manual in [true, false] {
            let (model, engine, provider) = make(options: .init(quality: .hd720))
            await model.load()
            engine.currentTime = 80
            model.setPaused(true)
            let track = try XCTUnwrap(engine.audioTracks.first { $0.id == 4 })
            if manual {
                model.selectAudioOption(id: track.id)
            } else {
                model.trackSelectAudioTrack(track)
            }
            await wait { engine.positions.count == 2 && model.phase == .ready }
            let calls = await provider.calls
            XCTAssertEqual(calls.last?.options.audioTrack?.id, 4)
            XCTAssertEqual(engine.positions.last, 80)
            XCTAssertEqual(engine.currentAudioTrackID, 4)
            XCTAssertTrue(engine.isPaused)
            XCTAssertTrue(engine.localAudioSelections.isEmpty)
            await model.stop()
        }
    }

    func testManagedAudioRestorationDoesNotRenegotiateWhenEngineHasNoActiveID() async {
        let (model, engine, provider) = make(options: .init(quality: .hd720))
        engine.suppressActiveAudioID = true
        await model.load()
        model.selectAudioOption(id: 4)
        await wait { engine.positions.count == 2 && model.phase == .ready }
        let calls = await provider.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.last?.options.audioTrack?.id, 4)
        XCTAssertTrue(engine.localAudioSelections.isEmpty)
        XCTAssertNil(engine.currentAudioTrackID)
        await model.stop()
    }

    func testImportedAudioWaitsForBringUpAndPreservesResumeBeforeClockReadiness() async {
        let provider = QualityPlaybackProvider()
        let engine = QualityEngine()
        let model = PlayerViewModel(
            provider: provider, itemID: "movie", streamingOptions: .init(quality: .hd720),
            startPosition: 125, engineFactory: .init(makeNative: { _ in engine })
        )
        let controller = SubtitleTrackController(host: model)
        engine.didLoad = { [weak engine, weak controller] in
            engine?.currentTime = 0
            controller?.queueImportedAudio(language: "jpn")
        }
        await model.load()
        XCTAssertEqual(engine.positions, [120], "Import must preserve the configured five-second resume rewind.")
        controller.applyImportedAudioIfPossible()
        await wait { engine.positions.count == 2 && model.phase == .ready }
        let calls = await provider.calls
        XCTAssertEqual(calls.last?.options.audioTrack?.id, 4)
        XCTAssertEqual(engine.positions, [120, 120])
        XCTAssertTrue(engine.localAudioSelections.isEmpty)
        await model.stop()
    }

    func testPlexEmbeddedSubtitleSelectionPreparesRenditionWithoutLosingContinuation() async {
        let provider = QualityPlaybackProvider()
        await provider.setPlexSubtitleRenditions()
        let (model, engine, _) = make(provider: provider)
        await model.load()
        engine.currentTime = 123
        model.setPaused(true)
        model.setPlaybackSpeed(1.5)
        model.selectSubtitleOption(id: 6)
        await wait { engine.positions.count == 2 && model.phase == .ready }
        XCTAssertEqual(engine.positions.last, 123)
        XCTAssertTrue(engine.isPaused)
        XCTAssertEqual(model.controls.playbackSpeed, 1.5)
        XCTAssertEqual(engine.selectedSubtitleID, 6)
        var calls = await provider.calls
        XCTAssertEqual(calls.last?.options.subtitleTrack?.id, 6)
        XCTAssertEqual(calls.last?.options.quality, .hd720)
        XCTAssertEqual(calls.last?.source, "version")

        model.selectSubtitleOption(id: PlayerTrackOption.offID)
        XCTAssertNil(engine.selectedSubtitleID)
        model.selectSubtitleOption(id: 6)
        XCTAssertEqual(engine.selectedSubtitleID, 6)
        calls = await provider.calls
        XCTAssertEqual(calls.count, 2, "Off and the prepared rendition switch locally")

        engine.currentTime = 150
        model.selectSubtitleOption(id: 7)
        await wait { engine.positions.count == 3 && model.phase == .ready }
        XCTAssertEqual(engine.positions.last, 150)
        XCTAssertTrue(engine.isPaused)
        XCTAssertEqual(model.controls.playbackSpeed, 1.5)
        XCTAssertEqual(engine.selectedSubtitleID, 7)
        calls = await provider.calls
        XCTAssertEqual(calls.last?.options.subtitleTrack?.id, 7)
        XCTAssertEqual(calls.map { $0.options.quality }, [.hd720, .hd720, .hd720])
        XCTAssertEqual(calls.map(\.source), ["version", "version", "version"])
        let released = await provider.released
        XCTAssertEqual(released, ["quality-1", "quality-2"])
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
        request.negotiatedStreamingVideoCodec = .hevc
        request.burnedInSubtitleTrackID = 6
        request.serverDecision = .init(
            sourceBitrate: 82_000_000, clientMaxBitrate: 2_000_000,
            supportsDirectPlay: false, supportsDirectStream: false, supportsTranscoding: true,
            subtitleBurnIn: true, transcodeReasons: ["ContainerBitrateExceedsLimit"]
        )
        let local = PlayerViewModel.applyingOfflineRewrite(
            to: request, localURL: URL(fileURLWithPath: "/fixture/movie.mp4")
        )
        XCTAssertNil(local.streamingOptions)
        XCTAssertNil(local.streamingSessionID)
        XCTAssertNil(local.negotiatedStreamingVideoCodec)
        XCTAssertNil(local.burnedInSubtitleTrackID)
        XCTAssertNil(local.serverDecision)
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

private struct GatedQualityScrobbler: TraktScrobbling {
    let gate: QualityDecisionGate
    func scrobble(item: MediaItem, progress: Double, event: PlaybackEvent) async {
        if case .start = event { await gate.suspend() }
    }
}

private actor QualityPlaybackProvider: StreamingQualityProviding, StreamingSessionMaintaining {
    struct Call: Sendable {
        let item: String
        let source: String?
        let options: StreamingPlaybackOptions
        let forceTranscode: Bool
    }
    struct Report: Sendable { let progress: PlaybackProgress; let event: PlaybackEvent }
    nonisolated let kind: ProviderKind = .plex
    nonisolated let session = UserSession(
        server: .init(id: "server", name: "Server", baseURL: URL(string: "https://fixture.test")!, provider: .plex),
        userID: "user", userName: "User", deviceID: "device", accessToken: "fixture"
    )
    private(set) var calls: [Call] = []
    private(set) var ordinaryCalls = 0
    private(set) var released: [String] = []
    private(set) var playbackReports: [Report] = []
    private(set) var maintained: [String] = []
    private var maintenanceGate: QualityDecisionGate?
    private var startReportGate: QualityDecisionGate?
    private var stopReportGate: QualityDecisionGate?
    private var refusesQuality = false
    private var preparationFailure: StreamingQualityError?
    private var deliversOriginal = false
    private var hevcFailure: (any Error & Sendable)?
    private var negotiatedCodec: DirectPlayVideoCodec?
    private var sourceRange: String?
    private var plexSubtitleRenditions = false
    private var burnedSubtitle = false
    private var compatibilityRendition = false
    private var ordinaryPlaybackSource: PlaybackSource?
    private var scrubStillSource: PlaybackSource?
    private var chapters: [MediaChapter] = []
    private var gate: QualityDecisionGate?
    init(gate: QualityDecisionGate? = nil) { self.gate = gate }
    func installGate(_ gate: QualityDecisionGate) { self.gate = gate }
    func setMaintenanceGate(_ gate: QualityDecisionGate) { maintenanceGate = gate }
    func setStartReportGate(_ gate: QualityDecisionGate) { startReportGate = gate }
    func setStopReportGate(_ gate: QualityDecisionGate) { stopReportGate = gate }
    func maintainStreamingSession(_ request: PlaybackRequest) async throws {
        guard let id = request.streamingSessionID else { throw StreamingQualityError.unavailable }
        maintained.append(id)
        if let gate = maintenanceGate {
            maintenanceGate = nil
            await gate.suspend()
        }
    }
    func setRefusesQuality() { refusesQuality = true }
    func setPreparationFailure(_ error: StreamingQualityError) { preparationFailure = error }
    func setDeliversOriginal() { deliversOriginal = true }
    func setHEVCFailure(_ error: any Error & Sendable) { hevcFailure = error }
    func setNegotiatedCodec(_ codec: DirectPlayVideoCodec) { negotiatedCodec = codec }
    func setSourceRange(_ range: String) { sourceRange = range }
    func setPlexSubtitleRenditions() { plexSubtitleRenditions = true }
    func setBurnedSubtitle() { burnedSubtitle = true }
    func setCompatibilityRendition() { compatibilityRendition = true }
    func setOrdinaryPlaybackSource(_ source: PlaybackSource) { ordinaryPlaybackSource = source }
    func setScrubStillSource(_ source: PlaybackSource) { scrubStillSource = source }
    func setChapters(_ chapters: [MediaChapter]) { self.chapters = chapters }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        ordinaryCalls += 1
        var request = baseRequest()
        if let ordinaryPlaybackSource {
            request.playbackSource = ordinaryPlaybackSource
            request.streamURL = nil
        }
        return request
    }
    func playbackInfo(for itemID: String, mediaSourceID: String?, forceTranscode: Bool, streaming: StreamingPlaybackOptions) async throws -> PlaybackRequest {
        calls.append(.init(item: itemID, source: mediaSourceID, options: streaming, forceTranscode: forceTranscode))
        let sequence = calls.count
        if let gate { self.gate = nil; await gate.suspend() }
        if let preparationFailure { throw preparationFailure }
        if refusesQuality { throw StreamingQualityError.unavailable }
        if streaming.codec == .preferHEVC, let hevcFailure { throw hevcFailure }
        var request = baseRequest()
        request.isTranscoding = !deliversOriginal
            && (streaming.requiresConversionPolicy || compatibilityRendition || forceTranscode)
        request.deliveryMode = request.isTranscoding ? .transcode : .directPlay
        request.streamingOptions = streaming
        request.playSessionID = "report-\(sequence)"
        request.streamingSessionID = "quality-\(sequence)"
        request.negotiatedStreamingVideoCodec = negotiatedCodec
        if burnedSubtitle, calls.count > 1 || ordinaryCalls > 0 {
            request.burnedInSubtitleTrackID = nil
        }
        return request
    }
    func releaseStreamingSession(_ request: PlaybackRequest) {
        if let id = request.streamingSessionID { released.append(id) }
    }
    private func baseRequest() -> PlaybackRequest {
        var request = PlaybackRequest(item: MediaItem(id: "movie", title: "Movie", kind: .movie, runtime: 600),
                        streamURL: URL(string: "https://fixture.test/master.m3u8")!,
                        audioTracks: [
                            .init(id: 3, kind: .audio, displayTitle: "English", language: "eng", isDefault: true),
                            .init(id: 4, kind: .audio, displayTitle: "Japanese", language: "jpn")
                        ],
                        subtitleTracks: plexSubtitleRenditions || burnedSubtitle ? [
                            .init(id: 6, kind: .subtitle, displayTitle: "English", language: "eng"),
                            .init(id: 7, kind: .subtitle, displayTitle: "French", language: "fra")
                        ] : [.init(id: 6, kind: .subtitle, displayTitle: "English", language: "eng")],
                        isTranscoding: true,
                        sourceMetadata: sourceRange.map { .init(video: .init(videoRangeType: $0)) },
                        sourceProvider: plexSubtitleRenditions ? .plex : nil)
        if burnedSubtitle { request.burnedInSubtitleTrackID = 6 }
        request.scrubStillSource = scrubStillSource
        request.chapters = chapters
        return request
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
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {
        if case .start = event, let gate = startReportGate {
            startReportGate = nil
            await gate.suspend()
        }
        if case .stop = event, let gate = stopReportGate {
            stopReportGate = nil
            await gate.suspend()
        }
        try Task.checkCancellation()
        playbackReports.append(.init(progress: progress, event: event))
    }
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

@MainActor
private final class QualityScrubStillExtractor: ScrubStillExtracting {
    func thumbnail(atSeconds seconds: TimeInterval, maxWidth: Int) async -> CGImage? { nil }
}

@MainActor
private final class QualityEngine: VideoEngine {
    var nowPlayingPlayer: AVPlayer?
    var didLoad: (() -> Void)?
    var suppressActiveAudioID = false
    var loadGate: QualityDecisionGate?
    var drainGate: QualityDecisionGate?
    var streamingFailure: StreamingPlaybackFailure?
    var streamingOutputDynamicRange: SourceDynamicRange?
    var streamingOutputVideoCodec: DirectPlayVideoCodec?
    let displayName = "Quality fixture"
    var status: VideoEngineStatus = .idle
    var isPaused = false
    var preventsDisplaySleep = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 600
    var furthestObservedPosition: TimeInterval = 0
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var chapters: [MediaChapter] = []
    var loadChapters: [MediaChapter] = []
    var currentAudioTrackID: Int?
    var localAudioSelections: [Int?] = []
    var selectedSubtitleID: Int?
    var onPause: (@MainActor () -> Void)?
    var isPlaybackPositionReady: Bool { status == .ready }
    var positions: [TimeInterval] = []
    var loadedQualities: [StreamingQuality] = []
    var onProgress: (@MainActor () -> Void)?
    var onFailure: (@MainActor (AppError) -> Void)?
    var onDiagnosticPhaseChanged: (@MainActor (PlaybackDiagnosticJournal.Phase) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onTracksChanged: (@MainActor () -> Void)?
    var onChaptersChanged: (@MainActor () -> Void)?
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
        chapters = loadChapters
        currentAudioTrackID = suppressActiveAudioID ? nil : (request.streamingOptions?.audioTrack?.id ?? 3)
        selectedSubtitleID = nil
        didLoad?()
        status = .ready
    }
    func play() { isPaused = false }
    func pause() { isPaused = true; onPause?() }
    func seek(to seconds: TimeInterval) async { currentTime = seconds }
    func stop() {
        status = .idle
        currentTime = 0
        isPaused = true
        nowPlayingPlayer?.replaceCurrentItem(with: nil)
        nowPlayingPlayer = nil
    }
    func drainTransport() async {
        if let gate = drainGate { drainGate = nil; await gate.suspend() }
    }
    func selectAudioTrack(_ track: MediaTrack?) {
        localAudioSelections.append(track?.id)
        currentAudioTrackID = track?.id
    }
    func selectSubtitleTrack(_ track: MediaTrack?) { selectedSubtitleID = track?.id }
    #if canImport(UIKit)
    func makeVideoOutputView() -> UIView { UIView() }
    #endif
}

private final class DiagnosticFailureItem: AVPlayerItem, @unchecked Sendable {
    override var status: AVPlayerItem.Status { .failed }
    override var error: (any Error)? {
        NSError(domain: "CoreMediaErrorDomain", code: -12889, userInfo: [
            NSLocalizedDescriptionKey: "private https://fixture.test?token=secret",
            NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: -1001)
        ])
    }
}
#endif
