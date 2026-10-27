#if canImport(AVFoundation)
import XCTest
import AVFoundation
import CoreModels
import os
@testable import FeaturePlayback

@MainActor
final class PlaybackDiagnosticsSamplerTests: XCTestCase {
    func testCacheTelemetryClearsWhenMissingUnsupportedStoppedOrRestarted() {
        let sampler = PlaybackDiagnosticsSampler()
        defer { sampler.stop() }
        let cache = EngineSessionCache(residentBytes: 0, effectiveBudgetBytes: 96 << 20,
                                       storage: .memory, targetSeconds: 300, byteLimitReached: true)
        var telemetry: EngineLiveTelemetry? = .init(sessionCache: cache)
        var route = LiveChannelEngineRoute.localHLS
        sampler.start(
            player: nil, mode: .plozzigen, engineTelemetry: { telemetry },
            liveRoute: { route }, includesSystemMetrics: false
        )
        sampler.sampleTick()
        XCTAssertEqual(sampler.latest?.sessionCache, cache)
        telemetry = nil
        sampler.sampleTick()
        XCTAssertNil(sampler.latest?.sessionCache)
        telemetry = .init(sessionCache: cache)
        route = .nativeHLS
        sampler.sampleTick()
        XCTAssertNil(sampler.latest?.sessionCache)
        route = .localHLS
        sampler.sampleTick()
        XCTAssertEqual(sampler.latest?.sessionCache, cache)
        telemetry = .init()
        sampler.sampleTick()
        XCTAssertNil(sampler.latest?.sessionCache)
        telemetry = .init(sessionCache: cache)
        sampler.sampleTick()
        sampler.stop()
        XCTAssertNil(sampler.latest?.sessionCache)
        sampler.start(player: nil, mode: .plozzigen, includesSystemMetrics: false)
        sampler.sampleTick()
        XCTAssertNil(sampler.latest?.sessionCache)
    }

    func testActualAudioPipelineTracksConversionFallbackTrackChangesAndUnknownWithoutAProbe() {
        let sampler = PlaybackDiagnosticsSampler()
        defer { sampler.stop() }
        var telemetry: EngineLiveTelemetry?
        sampler.start(
            player: nil, mode: .plozzigen,
            metadata: .init(audio: .init(codec: "truehd", profile: "Dolby Atmos", channels: 8)),
            engineTelemetry: { telemetry }, includesSystemMetrics: false
        )
        XCTAssertNil(sampler.latest?.audioPipelineDescription)
        XCTAssertNil(sampler.latest?.audioEncodingDescription)
        XCTAssertNil(sampler.latest?.audioOutputDescription)
        let cases: [(String?, LocalizedStringResource?)] = [
            ("TRUEHD Atmos → APAC 7.1.4", "Lossy encoding"),
            ("TRUEHD → FLAC bridge", "Lossless encoding"),
            ("DTS → EAC3 bridge", "Lossy encoding"),
            ("DTS → FLAC bridge", "Lossless encoding"),
            ("Stream-copy (EAC3+JOC Atmos)", "No re-encoding"),
            ("libavcodec AAC → CoreAudio", "Decoded to PCM"),
            ("Unreported pipeline", nil), (nil, nil)
        ]
        for (pipeline, encoding) in cases {
            telemetry = .init(audioPipelineDescription: pipeline)
            sampler.sampleTick()
            XCTAssertEqual(sampler.latest?.audioPipelineDescription, pipeline)
            XCTAssertEqual(sampler.latest?.audioEncodingDescription, encoding)
            XCTAssertNil(sampler.latest?.audioOutputDescription)
        }
        telemetry = .init(audioPipelineDescription: "TRUEHD Atmos → APAC 7.1.4")
        sampler.sampleTick()
        telemetry = nil
        sampler.sampleTick()
        XCTAssertNil(sampler.latest?.audioPipelineDescription, "Missing telemetry must not retain a previous pipeline")
        XCTAssertNil(sampler.latest?.audioEncodingDescription)
    }

    func testAudioPipelineDoesNotLeakAcrossStopRestartOrNativeRouteHandoff() {
        let sampler = PlaybackDiagnosticsSampler()
        defer { sampler.stop() }
        var route = LiveChannelEngineRoute.localHLS
        sampler.start(
            player: nil, mode: .plozzigen,
            engineTelemetry: { .init(audioPipelineDescription: "TRUEHD Atmos → APAC 7.1.4") },
            liveRoute: { route }, includesSystemMetrics: false
        )
        sampler.sampleTick()
        XCTAssertNotNil(sampler.latest?.audioPipelineDescription)
        route = .nativeHLS
        sampler.sampleTick()
        XCTAssertNil(sampler.latest?.audioPipelineDescription)
        XCTAssertNil(sampler.latest?.audioEncodingDescription)
        route = .localHLS
        sampler.sampleTick()
        XCTAssertNotNil(sampler.latest?.audioPipelineDescription)
        sampler.stop()
        XCTAssertNil(sampler.latest?.audioPipelineDescription)
        XCTAssertNil(sampler.latest?.audioEncodingDescription)
        sampler.start(player: nil, mode: .plozzigen, includesSystemMetrics: false)
        sampler.sampleTick()
        XCTAssertNil(sampler.latest?.audioPipelineDescription)
        XCTAssertNil(sampler.latest?.audioEncodingDescription)
    }

    func testNativeAndServerTranscodesDoNotAcquireAnEngineConversionClaim() {
        for mode: PlaybackDiagnostics.PlaybackMode in [.directPlay, .remux, .transcode] {
            let sampler = PlaybackDiagnosticsSampler()
            defer { sampler.stop() }
            sampler.start(
                player: nil, mode: mode,
                engineTelemetry: { .init(audioPipelineDescription: "TRUEHD Atmos → APAC 7.1.4") },
                probedFacts: { .init(audioDecoder: "TRUEHD Atmos → APAC 7.1.4") },
                includesSystemMetrics: false
            )
            sampler.sampleTick()
            XCTAssertNil(sampler.latest?.audioPipelineDescription)
        }
    }

    func testLiveActiveTracksReplaceInitialFactsAndClearOnItemReplacement() async throws {
        let item = AVPlayerItem(asset: AVMutableComposition())
        let output = MediaSourceMetadata(
            video: .init(codec: "h264", frameRate: 50, videoRangeType: "SDR"),
            audio: .init(codec: "ac3", channels: 6)
        )
        let sampler = PlaybackDiagnosticsSampler(liveTracksReader: { current in
            current === item ? output : .init()
        }, logReader: { _ in .init() })
        defer { sampler.stop() }
        let player = AVPlayer(playerItem: item)
        sampler.start(
            player: player, mode: .plozzigen,
            metadata: .init(video: .init(codec: "hevc", frameRate: 25, videoRangeType: "HDR10"),
                            audio: .init(codec: "aac", channels: 2)),
            liveStream: { .init(route: "Native HLS") }, includesSystemMetrics: false
        )
        try await wait { sampler.sampleTick(); return sampler.latest?.audioChannels == 6 }
        XCTAssertEqual(sampler.latest?.audioCodec, "Dolby Digital")
        XCTAssertEqual(sampler.latest?.frameRate, 50)
        XCTAssertEqual(sampler.latest?.hdr, .sdr)
        player.replaceCurrentItem(with: AVPlayerItem(asset: AVMutableComposition()))
        sampler.sampleTick()
        XCTAssertNil(sampler.latest?.audioCodec)
        XCTAssertNil(sampler.latest?.audioChannels)
        XCTAssertEqual(sampler.latest?.hdr, .unknown)
    }

    func testBlockedLogReadIsOffMainCoalescedAndCannotPublishIntoReplacement() async throws {
        let entered = expectation(description: "Background log reader entered")
        let release = DispatchSemaphore(value: 0)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let old = AVPlayerItem(asset: AVMutableComposition())
        let sampler = PlaybackDiagnosticsSampler(logReader: { item in
            XCTAssertFalse(Thread.isMainThread)
            reads.withLock { $0 += 1 }
            if item === old {
                entered.fulfill()
                release.wait()
                return .init(stalls: 99, liveEvents: [
                    .init(playbackType: "OLD", startupTime: 1, mediaRequests: 1, bytesTransferred: 1, downloadOverdue: 0)
                ])
            }
            return .init(stalls: 2)
        })
        defer { release.signal(); sampler.stop() }
        let player = AVPlayer(playerItem: old)
        sampler.start(player: player, mode: .plozzigen, liveStream: { .init() }, includesSystemMetrics: false)
        await fulfillment(of: [entered], timeout: 2)
        for _ in 0..<10 { sampler.sampleTick() }
        player.replaceCurrentItem(with: AVPlayerItem(asset: AVMutableComposition()))
        sampler.sampleTick()
        XCTAssertEqual(reads.withLock { $0 }, 1)
        XCTAssertNil(sampler.latest?.stallCount)
        XCTAssertNil(sampler.latest?.liveStream?.playlistType)
        release.signal()
        try await wait { sampler.sampleTick(); return sampler.latest?.stallCount == 2 }
        XCTAssertNil(sampler.latest?.liveStream?.playlistType)
    }

    func testStopReleasesLiveTelemetryCallback() {
        let sampler = PlaybackDiagnosticsSampler()
        var calls = 0
        sampler.start(player: nil, mode: .plozzigen, liveStream: { calls += 1; return .init() }, includesSystemMetrics: false)
        sampler.sampleTick()
        XCTAssertEqual(calls, 1)
        sampler.stop()
        sampler.sampleTick()
        XCTAssertEqual(calls, 1)
    }

    func testLiveDolbyVisionProfileRequiresAnActualMeasurement() {
        let profiles: [Int?] = [nil, 8]
        for profile in profiles {
            var diagnostics = PlaybackDiagnostics()
            let metadata = MediaSourceMetadata(video: .init(
                codec: "dvh1", videoRangeType: "DOVI", dolbyVisionProfile: profile
            ))
            PlaybackDiagnosticsSampler.applyLiveTracks(from: metadata, into: &diagnostics)
            XCTAssertEqual(diagnostics.hdr, .dolbyVision)
            XCTAssertEqual(diagnostics.dolbyVisionProfile, profile)
        }
    }

    func testLateLiveRouteAndNativeFallbackNeverReportLoopbackAsNetworkThroughput() async throws {
        for startingRoute in [LiveChannelEngineRoute.none, .nativeHLS] {
            var route = startingRoute
            var supplied: AVPlayer?
            let sampler = PlaybackDiagnosticsSampler(logReader: { _ in
                .init(indicatedBitrate: 10_000_000, observedBitrate: 100_000_000, stalls: 2)
            })
            defer { sampler.stop() }
            sampler.start(
                player: nil, playerProvider: { supplied }, mode: route.diagnosticsMode,
                liveRoute: { route }, liveStream: { .init() }, includesSystemMetrics: false
            )
            supplied = AVPlayer(playerItem: AVPlayerItem(asset: AVMutableComposition()))
            try await wait { sampler.sampleTick(); return sampler.latest?.stallCount == 2 }
            XCTAssertEqual(sampler.latest?.observedBitrate, startingRoute == .nativeHLS ? 100_000_000 : nil)
            route = .localHLS
            supplied?.replaceCurrentItem(with: AVPlayerItem(asset: AVMutableComposition()))
            try await wait { sampler.sampleTick(); return sampler.latest?.stallCount == 2 }
            XCTAssertEqual(sampler.latest?.mode, .plozzigen)
            XCTAssertNil(sampler.latest?.observedBitrate)
            XCTAssertNil(sampler.latest?.indicatedBitrate)
        }
    }

    func testLateInternalPlayerAndReplacementAreSampledWithoutRestartingTheHUD() {
        let sampler = PlaybackDiagnosticsSampler()
        defer { sampler.stop() }
        var supplied: AVPlayer?
        sampler.start(player: nil, playerProvider: { supplied }, mode: .plozzigen,
                      metadata: .init(video: .init(codec: "hevc", bitrate: 57_400_000)),
                      includesSystemMetrics: false)
        sampler.sampleTick()
        XCTAssertNil(sampler.latest?.positionSeconds)
        supplied = AVPlayer(playerItem: AVPlayerItem(asset: AVMutableComposition()))
        sampler.sampleTick()
        XCTAssertNotNil(sampler.latest?.positionSeconds)
        XCTAssertNotNil(sampler.latest?.playbackState)
        XCTAssertEqual(sampler.latest?.videoBitrate, 57_400_000)
        supplied = AVPlayer()
        sampler.sampleTick()
        XCTAssertNil(sampler.latest?.positionSeconds)
        XCTAssertNil(sampler.latest?.playbackState)
        supplied?.replaceCurrentItem(with: AVPlayerItem(asset: AVMutableComposition()))
        sampler.sampleTick()
        XCTAssertNotNil(sampler.latest?.playbackState)
        supplied = nil
        sampler.sampleTick()
        XCTAssertNil(sampler.latest?.positionSeconds)
        XCTAssertNil(sampler.latest?.bufferedSecondsAhead)
        XCTAssertNil(sampler.latest?.droppedVideoFrames)
    }

    func testEngineCacheIsDistinctFromThePlayerBufferAndNotNetworkThroughput() {
        let sampler = PlaybackDiagnosticsSampler()
        defer { sampler.stop() }
        var supplied: AVPlayer?
        sampler.start(
            player: nil, playerProvider: { supplied }, mode: .plozzigen,
            engineTelemetry: { .init(observedBitrate: 500_000_000, bufferedSecondsAhead: 42) },
            includesSystemMetrics: false
        )
        sampler.sampleTick()
        XCTAssertEqual(sampler.latest?.bufferedSecondsAhead, 42)
        XCTAssertNil(sampler.latest?.observedBitrate, "Encoded-stream telemetry is not a server network-rate measurement")
        supplied = AVPlayer(playerItem: AVPlayerItem(asset: AVMutableComposition()))
        sampler.sampleTick()
        XCTAssertEqual(sampler.latest?.engineBufferedSecondsAhead, 42)
        XCTAssertNil(sampler.latest?.observedBitrate)
        XCTAssertNil(sampler.latest?.droppedVideoFrames, "No access-log measurement is not zero dropped frames")
    }

    func testAutomaticSampleUsesEngineSourceRange() async {
        let sampler = PlaybackDiagnosticsSampler()
        defer { sampler.stop() }
        let sampled = expectation(description: "Initial source probe")
        sampler.start(
            player: nil,
            mode: .plozzigen,
            metadata: .init(video: .init(videoRangeType: "HDR10")),
            capabilities: .default,
            probedFacts: {
                sampled.fulfill()
                return .init(range: .hdr10Plus)
            }
        )

        await fulfillment(of: [sampled], timeout: 1)

        XCTAssertEqual(sampler.latest?.hdr, .hdr10Plus)
        XCTAssertEqual(sampler.latest?.videoRangeType, "HDR10+")
    }

    func testProbedHDR10PlusCorrectsProviderHDR10OnOriginalSourcePaths() {
        for mode: PlaybackDiagnostics.PlaybackMode in [.directPlay, .remux, .plozzigen] {
            let sampler = PlaybackDiagnosticsSampler()
            defer { sampler.stop() }
            sampler.start(
                player: nil,
                mode: mode,
                metadata: .init(video: .init(videoRangeType: "HDR10", colorTransfer: "smpte2084")),
                capabilities: .default,
                probedFacts: { .init(range: .hdr10Plus) }
            )

            sampler.sampleTick()

            XCTAssertEqual(sampler.latest?.hdr, .hdr10Plus, "\(mode)")
            XCTAssertEqual(sampler.latest?.videoRangeType, "HDR10+", "\(mode)")
            XCTAssertEqual(sampler.latest?.colorTransfer, "smpte2084", "\(mode)")
        }
    }

    func testProbedHDRCorrectsIncorrectSDRProviderHint() {
        let sampler = PlaybackDiagnosticsSampler()
        defer { sampler.stop() }
        sampler.start(
            player: nil,
            mode: .plozzigen,
            metadata: .init(video: .init(videoRangeType: "SDR", colorTransfer: "bt709")),
            capabilities: .default,
            probedFacts: { .init(range: .hdr10Plus) }
        )

        sampler.sampleTick()

        XCTAssertEqual(sampler.latest?.hdr, .hdr10Plus)
        XCTAssertEqual(sampler.latest?.videoRangeType, "HDR10+")
        XCTAssertNil(sampler.latest?.colorTransfer)
    }

    func testMissingOrUnknownProbeKeepsProviderRange() {
        for facts: EngineProbedSourceFacts? in [nil, .init()] {
            let sampler = PlaybackDiagnosticsSampler()
            defer { sampler.stop() }
            sampler.start(
                player: nil,
                mode: .plozzigen,
                metadata: .init(video: .init(videoRangeType: "HDR10Plus")),
                capabilities: .default,
                probedFacts: { facts }
            )

            sampler.sampleTick()

            XCTAssertEqual(sampler.latest?.hdr, .hdr10Plus)
            XCTAssertEqual(sampler.latest?.videoRangeType, "HDR10Plus")
        }
    }

    func testMissingProviderAndUnknownProbeDoNotInventSDR() {
        let sampler = PlaybackDiagnosticsSampler()
        defer { sampler.stop() }
        sampler.start(
            player: nil, mode: .plozzigen, capabilities: .default,
            probedFacts: { .init() }
        )

        sampler.sampleTick()

        XCTAssertEqual(sampler.latest?.hdr, .unknown)
        XCTAssertNil(sampler.latest?.videoRangeType)
    }

    func testSourceProbeFillsMissingProviderFacts() {
        let sampler = PlaybackDiagnosticsSampler()
        defer { sampler.stop() }
        sampler.start(
            player: nil, mode: .plozzigen, capabilities: .default,
            probedFacts: {
                .init(
                    range: .hdr10Plus, videoWidth: 3840, videoHeight: 2160,
                    audioCodec: "aac", audioChannels: 2
                )
            }
        )

        sampler.sampleTick()

        XCTAssertEqual(sampler.latest?.hdr, .hdr10Plus)
        XCTAssertEqual(sampler.latest?.videoRangeType, "HDR10+")
        XCTAssertEqual(sampler.latest?.resolution, .init(width: 3840, height: 2160))
        XCTAssertEqual(sampler.latest?.audioCodec, "AAC")
        XCTAssertEqual(sampler.latest?.audioChannels, 2)
    }

    func testLateProbeUpdatesRangeAndMissingProbeReturnsToProviderFallback() {
        let sampler = PlaybackDiagnosticsSampler()
        defer { sampler.stop() }
        var facts: EngineProbedSourceFacts?
        sampler.start(
            player: nil,
            mode: .plozzigen,
            metadata: .init(video: .init(videoRangeType: "HDR10")),
            capabilities: .default,
            probedFacts: { facts }
        )
        sampler.sampleTick()
        XCTAssertEqual(sampler.latest?.hdr, .hdr10)

        facts = .init(range: .hdr10Plus)
        sampler.sampleTick()
        XCTAssertEqual(sampler.latest?.hdr, .hdr10Plus)
        XCTAssertEqual(sampler.latest?.videoRangeType, "HDR10+")

        facts = .init()
        sampler.sampleTick()
        XCTAssertEqual(sampler.latest?.hdr, .hdr10)
        XCTAssertEqual(sampler.latest?.videoRangeType, "HDR10")
    }

    func testMatchingDolbyVisionProbePreservesProfileSevenAndBaseLayerToken() {
        let sampler = PlaybackDiagnosticsSampler()
        defer { sampler.stop() }
        sampler.start(
            player: nil,
            mode: .plozzigen,
            metadata: .init(video: .init(
                videoRangeType: "DOVIWithHDR10",
                colorTransfer: "smpte2084",
                dolbyVisionProfile: 7
            )),
            capabilities: .default,
            probedFacts: { .init(range: .dolbyVision) }
        )

        sampler.sampleTick()

        XCTAssertEqual(sampler.latest?.hdr, .dolbyVision)
        XCTAssertEqual(sampler.latest?.videoRangeType, "DOVIWithHDR10")
        XCTAssertEqual(sampler.latest?.dolbyVisionProfile, 7)
        XCTAssertEqual(sampler.latest?.colorTransfer, "smpte2084")
    }

    func testProbedSDRClearsConflictingDolbyVisionDetails() {
        let sampler = PlaybackDiagnosticsSampler()
        defer { sampler.stop() }
        sampler.start(
            player: nil,
            mode: .directPlay,
            metadata: .init(video: .init(
                videoRangeType: "DOVIWithHDR10",
                colorTransfer: "smpte2084",
                dolbyVisionProfile: 7
            )),
            capabilities: .default,
            probedFacts: { .init(range: .sdr) }
        )

        sampler.sampleTick()

        XCTAssertEqual(sampler.latest?.hdr, .sdr)
        XCTAssertEqual(sampler.latest?.videoRangeType, "SDR")
        XCTAssertNil(sampler.latest?.dolbyVisionProfile)
        XCTAssertNil(sampler.latest?.colorTransfer)
    }

    func testTranscodedInputProbeDoesNotReplaceOriginalSourceRange() {
        let sampler = PlaybackDiagnosticsSampler()
        defer { sampler.stop() }
        sampler.start(
            player: nil,
            mode: .transcode,
            metadata: .init(video: .init(videoRangeType: "HDR10Plus", colorTransfer: "smpte2084")),
            capabilities: .default,
            probedFacts: { .init(range: .sdr) }
        )

        sampler.sampleTick()

        XCTAssertEqual(sampler.latest?.mode, .transcode)
        XCTAssertEqual(sampler.latest?.hdr, .unknown)
        XCTAssertNil(sampler.latest?.videoRangeType)
        XCTAssertNil(sampler.latest?.colorTransfer)
        XCTAssertEqual(sampler.latest?.originalSource?.video?.videoRangeType, "HDR10Plus")
        XCTAssertEqual(sampler.latest?.originalSource?.video?.colorTransfer, "smpte2084")
    }

    func testTranscodedInputProbeCannotEstablishUnknownOriginalSourceRange() {
        let sampler = PlaybackDiagnosticsSampler()
        defer { sampler.stop() }
        sampler.start(
            player: nil, mode: .transcode, capabilities: .default,
            probedFacts: { .init(range: .sdr) }
        )

        sampler.sampleTick()

        XCTAssertEqual(sampler.latest?.hdr, .unknown)
        XCTAssertNil(sampler.latest?.videoRangeType)
    }

    func testRestartAndStopDiscardPreviousProbeCallback() {
        let sampler = PlaybackDiagnosticsSampler()
        defer { sampler.stop() }
        var previousProbeReads = 0
        sampler.start(
            player: nil, mode: .plozzigen, capabilities: .default,
            probedFacts: {
                previousProbeReads += 1
                return .init(range: .hdr10Plus)
            }
        )
        sampler.sampleTick()
        XCTAssertEqual(sampler.latest?.hdr, .hdr10Plus)
        XCTAssertEqual(previousProbeReads, 1)

        var currentProbeReads = 0
        sampler.start(
            player: nil,
            mode: .plozzigen,
            metadata: .init(video: .init(videoRangeType: "SDR")),
            capabilities: .default,
            probedFacts: {
                currentProbeReads += 1
                return .init(range: .hlg)
            }
        )
        sampler.sampleTick()
        XCTAssertEqual(sampler.latest?.hdr, .hlg)
        XCTAssertEqual(sampler.latest?.videoRangeType, "HLG")
        XCTAssertEqual(previousProbeReads, 1)
        XCTAssertEqual(currentProbeReads, 1)

        sampler.stop()
        sampler.sampleTick()
        XCTAssertEqual(previousProbeReads, 1)
        XCTAssertEqual(currentProbeReads, 1)
    }

    func testTranscodeNeverUsesOriginalResolutionAudioOrBitrateAsCurrentStream() async throws {
        let source = MediaSourceMetadata(
            container: "mkv", video: .init(codec: "hevc", width: 3840, height: 2076,
                                          bitrate: 25_000_000, videoRangeType: "HDR10Plus"),
            audio: .init(codec: "ac3", channels: 6, bitrate: 384_000)
        )
        var returned = MediaSourceMetadata()
        let sampler = PlaybackDiagnosticsSampler(streamDetailsReader: { _ in returned })
        defer { sampler.stop() }
        let player = AVPlayer(playerItem: AVPlayerItem(asset: AVMutableComposition()))
        var details = PlaybackStreamDetails()
        sampler.start(player: player, mode: .transcode, metadata: source,
                      probedFacts: { .init(range: .hdr10Plus, videoWidth: 3840, videoHeight: 2076) },
                      onStreamDetails: { details = $0 })
        sampler.sampleTick()
        XCTAssertNil(sampler.latest?.resolution)
        XCTAssertNil(sampler.latest?.audioCodec)
        XCTAssertNil(sampler.latest?.indicatedBitrate)
        XCTAssertEqual(sampler.latest?.hdr, .unknown)
        XCTAssertTrue(details.technicalBadges.isEmpty)

        returned = .init(video: .init(codec: "h264", width: 426, height: 230, bitrate: 372_000, videoRangeType: "SDR"),
                         audio: .init(codec: "aac", channels: 2, sampleRate: 48_000, bitrate: 128_000))
        try await wait { sampler.sampleTick(); return sampler.latest?.resolution?.width == 426 }
        XCTAssertEqual(sampler.latest?.resolution, .init(width: 426, height: 230))
        XCTAssertEqual(sampler.latest?.videoCodec, "H.264")
        XCTAssertEqual(sampler.latest?.audioCodec, "AAC")
        XCTAssertEqual(sampler.latest?.audioChannels, 2)
        XCTAssertEqual(sampler.latest?.hdr, .sdr)
        XCTAssertNil(sampler.latest?.indicatedBitrate, "The requested limit is not an advertised or observed stream bitrate")
        XCTAssertEqual(sampler.latest?.originalSource, source)
        XCTAssertEqual(details.technicalBadges.map(\.label), ["426×230", "H.264", "SDR", "AAC Stereo"])
        sampler.setSystemMetricsEnabled(false)
        sampler.sampleTick()
        XCTAssertEqual(details.metadata, returned, "Closing diagnostics must not blank Info or Quality")
        sampler.setSystemMetricsEnabled(true)
        sampler.sampleTick()
        XCTAssertEqual(details.metadata, returned)
        player.replaceCurrentItem(with: nil)
        sampler.sampleTick()
        XCTAssertNil(sampler.latest?.resolution)
        XCTAssertTrue(details.technicalBadges.isEmpty)
    }

    func testH264SDRRequestCannotRelabelTheServersActualHDROutput() async throws {
        for rangeParameter in ["h264-videorange", "h264-rangetype"] {
            let output = MediaSourceMetadata(video: .init(codec: "h264", videoRangeType: "HDR10"))
            let sampler = PlaybackDiagnosticsSampler(streamDetailsReader: { _ in output })
            defer { sampler.stop() }
            let player = AVPlayer(playerItem: AVPlayerItem(asset: AVMutableComposition()))
            var details = PlaybackStreamDetails()
            sampler.start(
                player: player, mode: .transcode,
                metadata: .init(video: .init(codec: "hevc", videoRangeType: "DOVI")),
                streamURL: URL(string: "https://media.example.test/master.m3u8?VideoCodec=h264&\(rangeParameter)=SDR"),
                onStreamDetails: { details = $0 }
            )
            try await wait { sampler.sampleTick(); return sampler.latest?.hdr == .hdr10 }
            XCTAssertEqual(sampler.latest?.videoCodec, "H.264")
            XCTAssertEqual(sampler.latest?.hdr, .hdr10)
            XCTAssertEqual(details.metadata, output)
            XCTAssertEqual(details.technicalBadges.map(\.label), ["H.264", "HDR10"])
        }
    }

    func testReplacedPlayerItemAndLatePriorReadsCannotRestoreOldFormat() async throws {
        let entered = expectation(description: "old read suspended")
        var release: CheckedContinuation<Void, Never>?
        let oldItem = AVPlayerItem(asset: AVMutableComposition())
        let newItem = AVPlayerItem(asset: AVMutableComposition())
        let sampler = PlaybackDiagnosticsSampler(streamDetailsReader: { item in
            if item === oldItem {
                await withCheckedContinuation { release = $0; entered.fulfill() }
                return .init(video: .init(codec: "hevc", width: 3840, height: 2160, videoRangeType: "HDR10"))
            }
            return .init(video: .init(codec: "h264", width: 426, height: 230))
        })
        defer { sampler.stop(); release?.resume() }
        let player = AVPlayer(playerItem: oldItem)
        sampler.start(player: player, mode: .transcode)
        await fulfillment(of: [entered], timeout: 2)
        player.replaceCurrentItem(with: newItem)
        sampler.sampleTick()
        XCTAssertNil(sampler.latest?.resolution)
        release?.resume()
        release = nil
        try await wait { sampler.sampleTick(); return sampler.latest?.resolution?.width == 426 }
        XCTAssertEqual(sampler.latest?.hdr, .unknown)
        XCTAssertEqual(sampler.latest?.videoCodec, "H.264")
    }

    func testRestartCancelsLateFormatPublicationIntoAnotherRequest() async throws {
        let entered = expectation(description: "read suspended")
        var release: CheckedContinuation<Void, Never>?
        let sampler = PlaybackDiagnosticsSampler(streamDetailsReader: { _ in
            await withCheckedContinuation { release = $0; entered.fulfill() }
            return .init(video: .init(codec: "hevc", width: 3840, height: 2160))
        })
        defer { sampler.stop(); release?.resume() }
        let player = AVPlayer(playerItem: AVPlayerItem(asset: AVMutableComposition()))
        sampler.start(player: player, mode: .transcode)
        await fulfillment(of: [entered], timeout: 2)
        sampler.start(player: nil, mode: .directPlay,
                      metadata: .init(video: .init(codec: "h264", width: 1280, height: 720)))
        release?.resume()
        release = nil
        try await Task.sleep(for: .milliseconds(50))
        sampler.sampleTick()
        XCTAssertEqual(sampler.latest?.resolution, .init(width: 1280, height: 720))
        XCTAssertEqual(sampler.latest?.mode, .directPlay)
    }

    private func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<100 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Current stream facts were not published")
    }
}
#endif
