import AetherEngine
import CoreModels
import XCTest
@testable import EnginePlozzigen

final class PipelineDiagnosticTests: XCTestCase {
    func testEveryAudioOutcomeMapsWithoutInferringFromDecoderOrVideoRoute() {
        let cases: [(AudioDelivery, EngineAudioDelivery?)] = [
            (.none, nil), (.noAudioInSource, .noAudioInSource), (.streamCopy, .streamCopy),
            (.bridged, .bridged), (.decoded, .decoded), (.droppedNoPipeline, .droppedNoPipeline),
            (.playerManaged, .playerManaged)
        ]
        XCTAssertEqual(cases.count, AudioDelivery.allCases.count)
        for (engine, expected) in cases {
            XCTAssertEqual(PlozzigenVideoEngine.playbackAudioDelivery(engine), expected)
        }
    }

    func testOverlayStatisticsKeepPlayedBitrateSeparateFromLocalDelivery() throws {
        let value = try XCTUnwrap(PlozzigenVideoEngine.playbackStatistics(
            snapshot(), route: .loopback, decoder: "AVPlayer"
        ))
        XCTAssertEqual(value.decoder, "AVPlayer")
        XCTAssertEqual(value.recentBitrate, 50_000_000)
        XCTAssertEqual(value.averageBitrate, 60_000_000)
        XCTAssertNil(value.audioBridgeBitrate)
        XCTAssertEqual(value.delivery, .local)
        XCTAssertEqual(value.deliveryBitrate, 500_000_000)
        XCTAssertEqual(value.deliveredBytes, 6_000_000)
        XCTAssertEqual(value.sourceBytes, 9_000_000)
        XCTAssertEqual(value.muxedBytes, 7_000_000)
        XCTAssertEqual(value.servedBytes, 6_000_000)
        XCTAssertEqual(value.serverRequests, 30)
        XCTAssertEqual(value.producerRestarts, 1)
        XCTAssertEqual(value.cachedBytes, 2_000_000)
        XCTAssertEqual(value.audioBridgeBytes, 0)
        XCTAssertEqual(value.residentMemoryBytes, 530 * 1_048_576)
    }

    func testBypassBandwidthDoesNotMasqueradeAsMeasuredPlayedBitrate() throws {
        let value = try XCTUnwrap(PlozzigenVideoEngine.playbackStatistics(
            snapshot(), route: .remoteBypass, decoder: "AVPlayer"
        ))
        XCTAssertNil(value.recentBitrate)
        XCTAssertNil(value.averageBitrate)
        XCTAssertNil(value.sourceBytes)
        XCTAssertNil(value.muxedBytes)
        XCTAssertNil(value.producerRestarts)
        XCTAssertNil(value.muxAVGapMilliseconds)
        XCTAssertEqual(value.delivery, .source)
        XCTAssertEqual(value.deliveredBytes, 6_000_000)
    }

    func testSoftwareAndUnavailableStatisticsDoNotInventLocalPipelineCounters() throws {
        let value = try XCTUnwrap(PlozzigenVideoEngine.playbackStatistics(
            snapshot(), route: .software, decoder: "VideoToolbox"
        ))
        XCTAssertEqual(value.delivery, .source)
        XCTAssertEqual(value.recentBitrate, 50_000_000)
        XCTAssertEqual(value.sourceBytes, 9_000_000)
        XCTAssertNil(value.serverRequests)
        XCTAssertNil(value.muxedBytes)
        XCTAssertNil(value.producerRestarts)
        XCTAssertNil(value.muxAVGapMilliseconds)
        let pending = PlozzigenVideoEngine.playbackStatistics(nil, route: .loopback, decoder: "AVPlayer")
        XCTAssertEqual(pending?.decoder, "AVPlayer")
        XCTAssertNil(pending?.sourceBytes)
        XCTAssertNil(pending?.deliveryBitrate)
        XCTAssertNil(PlozzigenVideoEngine.playbackStatistics(snapshot(), route: .none, decoder: nil))
    }

    func testBridgeRateSignedMuxGapAndFailedResidentMemoryRead() {
        let value = PlozzigenVideoEngine.playbackStatistics(
            snapshot(audioBitrate: 7.4, gap: -23.5, rss: 0), route: .loopback, decoder: "AVPlayer"
        )
        XCTAssertEqual(value?.audioBridgeBitrate, 7_400_000)
        XCTAssertEqual(value?.muxAVGapMilliseconds, -23.5)
        XCTAssertNil(value?.residentMemoryBytes, "The engine reports zero when its memory read fails")
    }

    func testJournalSeparatesSourceMuxDeliveryAndTheActualAudioTrack() {
        let line = PlozzigenVideoEngine.pipelineDiagnosticLine(
            telemetry: snapshot(), instance: "fixture", phase: "rebuffering", route: "loopback", position: 2190,
            engineBuffer: 0.2,
            audio: .init(id: 6, kind: .audio, displayTitle: "not written", language: nil, codec: "ac3", channels: 6),
            audioDelivery: "streamCopy", subtitleID: nil
        )
        XCTAssertTrue(line.contains("instance=fixture phase=rebuffering"))
        XCTAssertTrue(line.contains("playerSpan=0.100 engineBuffer=0.200"))
        XCTAssertTrue(line.contains("readerAheadBytes=1048576"))
        XCTAssertTrue(line.contains("sourceBytes=9000000 muxBytes=7000000 servedBytes=6000000"))
        XCTAssertTrue(line.contains("audioID=6 audioCodec=ac3 audioChannels=6 audioDelivery=streamCopy"))
        XCTAssertTrue(line.contains("engineSubtitleID=none"))
        XCTAssertFalse(line.contains("not written"))
        XCTAssertFalse(line.contains("networkMbps"), "A native consumer's loopback rate is not the origin's rate")
    }

    func testUnknownMetricsAndAudioRemainUnknownRatherThanZeroOrSourceDefaults() {
        let line = PlozzigenVideoEngine.pipelineDiagnosticLine(
            telemetry: snapshot(), instance: "fixture", phase: "paused", route: "loopback", position: .nan,
            engineBuffer: nil, audio: nil, audioDelivery: "none", subtitleID: nil
        )
        XCTAssertTrue(line.contains("sourcePosition=unknown"))
        XCTAssertTrue(line.contains("engineBuffer=unknown"))
        XCTAssertTrue(line.contains("dropped=unknown"))
        XCTAssertTrue(line.contains("audioID=unknown audioCodec=unknown audioChannels=unknown"))
    }

    private func snapshot(audioBitrate: Double? = nil, gap: Double? = nil, rss: Int = 530) -> LiveTelemetry {
        LiveTelemetry(
            instantBitrateMbps: 50, averageBitrateMbps: 60, audioBridgeBitrateMbps: audioBitrate,
            observedFps: nil, droppedFrameCount: nil, forwardBufferSeconds: 0.1,
            readerWindowAheadBytes: 1_048_576, cachedBytes: 2_000_000,
            networkThroughputMbps: 500, networkTransferredBytes: 6_000_000, avSyncGapMs: gap,
            producerRestartCount: 1, muxedBytesLifetime: 7_000_000, serverBytesSentLifetime: 6_000_000,
            serverRequestCount: 30, demuxerBytesFetched: 9_000_000, audioBridgeLiveBytes: 0, rssMb: rss
        )
    }
}
