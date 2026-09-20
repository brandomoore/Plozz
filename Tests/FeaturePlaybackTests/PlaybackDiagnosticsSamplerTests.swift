#if canImport(AVFoundation)
import XCTest
import CoreModels
@testable import FeaturePlayback

@MainActor
final class PlaybackDiagnosticsSamplerTests: XCTestCase {
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
        XCTAssertEqual(sampler.latest?.hdr, .hdr10Plus)
        XCTAssertEqual(sampler.latest?.videoRangeType, "HDR10Plus")
        XCTAssertEqual(sampler.latest?.colorTransfer, "smpte2084")
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
}
#endif
