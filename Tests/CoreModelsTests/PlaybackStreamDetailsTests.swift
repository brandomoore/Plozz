import CoreModels
import XCTest

final class PlaybackStreamDetailsTests: XCTestCase {
    func testEmptyFactsDoNotAdvertiseRequestedQualityOrOriginalFormats() {
        let details = PlaybackStreamDetails()
        XCTAssertTrue(details.technicalBadges.isEmpty)
        XCTAssertEqual(details.diagnostics.resolutionText, PlaybackDiagnostics.placeholder)
        XCTAssertEqual(details.diagnostics.hdr, .unknown)
        XCTAssertNil(details.declaredBitrate)
    }

    func testMeasuredCinemaResolutionAndStereoReplaceOriginalStyleBadges() {
        let details = PlaybackStreamDetails(metadata: .init(
            video: .init(codec: "h264", width: 426, height: 230, videoRangeType: "SDR"),
            audio: .init(codec: "aac", channels: 2, sampleRate: 48_000)
        ), declaredBitrate: 500_000)
        XCTAssertEqual(details.technicalBadges.map(\.label), ["426×230", "H.264", "SDR", "AAC Stereo"])
        XCTAssertFalse(details.technicalBadges.contains { ["4K", "Dolby Atmos", "Dolby Digital", "HDR10+"].contains($0.label) })
        XCTAssertEqual(details.diagnostics.resolution, .init(width: 426, height: 230))
        XCTAssertEqual(details.diagnostics.indicatedBitrate, 500_000)
        XCTAssertNil(details.diagnostics.observedBitrate, "Advertised bitrate is not download throughput")
    }
}
