import AetherEngine
import CoreModels
import XCTest
@testable import EnginePlozzigen

final class PipelineDiagnosticTests: XCTestCase {
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

    private func snapshot() -> LiveTelemetry {
        LiveTelemetry(
            instantBitrateMbps: 50, averageBitrateMbps: 60, audioBridgeBitrateMbps: nil,
            observedFps: nil, droppedFrameCount: nil, forwardBufferSeconds: 0.1,
            readerWindowAheadBytes: 1_048_576, cachedBytes: 2_000_000,
            networkThroughputMbps: 500, networkTransferredBytes: 6_000_000, avSyncGapMs: nil,
            producerRestartCount: 1, muxedBytesLifetime: 7_000_000, serverBytesSentLifetime: 6_000_000,
            serverRequestCount: 30, demuxerBytesFetched: 9_000_000, audioBridgeLiveBytes: 0, rssMb: 530
        )
    }
}
