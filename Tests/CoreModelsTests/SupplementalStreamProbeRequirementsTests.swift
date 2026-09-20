import XCTest
@testable import CoreModels

final class SupplementalStreamProbeRequirementsTests: XCTestCase {
    func testHDR10PlusDetectionIsIndependentOfAudioCodecAndAtmosLabel() {
        for audio in [
            MediaSourceMetadata.AudioStream(codec: "aac"),
            .init(codec: "truehd", profile: "Dolby Atmos"),
            .init(codec: "eac3", profile: "Dolby Atmos")
        ] {
            let metadata = MediaSourceMetadata(
                video: .init(codec: "hevc", videoRangeType: "HDR10"),
                audio: audio)
            XCTAssertEqual(SupplementalStreamProbeRequirements.missingEmbyFacts(in: metadata), .hdr10Plus)
        }
    }

    func testMissingAudioAndHDRConfirmationsAreCombined() {
        let metadata = MediaSourceMetadata(
            video: .init(codec: "hevc", videoRangeType: "HDR10"),
            audio: .init(codec: "eac3"))
        XCTAssertEqual(
            SupplementalStreamProbeRequirements.missingEmbyFacts(in: metadata), [.atmos, .hdr10Plus])
    }

    func testKnownHDR10PlusDolbyVisionAndSDRAreNotRepeatedHDRCandidates() {
        for range in ["HDR10Plus", "DOVI", "DOVIWithHDR10", "SDR", "HLG"] {
            let metadata = MediaSourceMetadata(
                video: .init(codec: "hevc", videoRangeType: range),
                audio: .init(codec: "aac"))
            XCTAssertTrue(SupplementalStreamProbeRequirements.missingEmbyFacts(in: metadata).isEmpty)
        }
    }

    func testMissingHEVCRangeCanBeInspectedButUnrelatedCodecsCannot() {
        XCTAssertEqual(SupplementalStreamProbeRequirements.missingEmbyFacts(in: .init(
            video: .init(codec: "hevc"))), .hdr10Plus)
        for codec in ["h264", "mpeg2", "vp9", "av1"] {
            XCTAssertTrue(SupplementalStreamProbeRequirements.missingEmbyFacts(in: .init(
                video: .init(codec: codec, videoRangeType: "HDR10"))).isEmpty)
        }
    }

    func testPositiveHDR10PlusConfirmationDoesNotReplaceDolbyVision() {
        let metadata = MediaSourceMetadata(video: .init(
            codec: "hevc", videoRangeType: "DOVIWithHDR10", dolbyVisionProfile: 8))
        XCTAssertEqual(metadata.confirmingHDR10Plus(), metadata)
        let item = MediaItem(id: "dv", title: "DV", kind: .movie, mediaInfo: metadata)
        XCTAssertEqual(item.confirmingHDR10Plus(), item)
    }
}
