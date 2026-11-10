import XCTest
@testable import CoreModels

final class VersionSelectionAssessmentTests: XCTestCase {
    private let baseline = MediaVersion(
        id: "baseline", height: 1080, videoCodec: "h264", videoRange: "SDR", audioCodec: "aac"
    )

    func testBridgedAudioDoesNotRejectHigherQualityInput() {
        for codec in ["dts", "dts-hd ma", "truehd", "flac", "opus"] {
            let higher = MediaVersion(
                id: codec, height: 2160, videoCodec: "hevc", videoRange: "HDR10", audioCodec: codec
            )
            XCTAssertTrue(higher.selectionAssessment(for: .default).hasSupportedInput, codec)
            XCTAssertEqual([baseline, higher].recommendedSelection(for: .default)?.id, codec)
        }
    }

    func testSoftwareVideoIsSupportedWithoutPretendingItIsNative() {
        for codec in ["av1", "vp9", "mpeg2video", "vc1"] {
            let higher = MediaVersion(id: codec, height: 2160, videoCodec: codec, audioCodec: "aac")
            XCTAssertTrue(higher.selectionAssessment(for: .default).hasSupportedInput, codec)
            XCTAssertNotEqual(higher.compatibility(with: .default), .directPlay, codec)
            XCTAssertEqual([baseline, higher].recommendedSelection(for: .default)?.id, codec)
        }
    }

    func testRichMetadataWinsOverStaleFlattenedFacts() {
        let version = MediaVersion(
            id: "rich", height: 480, videoCodec: "unsupported", videoRange: "SDR", audioCodec: "unsupported",
            sourceMetadata: .init(
                video: .init(codec: "hevc", height: 2160, bitrate: 40_000_000, videoRangeType: "HDR10"),
                audio: .init(codec: "dts")
            )
        )
        let assessment = version.selectionAssessment(for: .default)
        XCTAssertTrue(assessment.hasSupportedInput)
        XCTAssertEqual(assessment.qualityScore, 6_200)
        XCTAssertEqual(assessment.effectiveHDRHint, .hdr10)
        XCTAssertEqual([baseline, version].recommendedSelection(for: .default)?.id, "rich")
    }

    func testProfile7UsesHDR10InsteadOfDolbyVisionCapabilities() {
        let p7 = MediaVersion(id: "p7", sourceMetadata: .init(
            video: .init(codec: "hevc", height: 2160, videoRangeType: "DOVI", dolbyVisionProfile: 7)
        ))
        let hdr10Only = MediaCapabilities(supportsHDR10: true, supportsDolbyVision: false)
        let dvOnly = MediaCapabilities(supportsHDR10: false, supportsDolbyVision: true)
        XCTAssertEqual(p7.selectionAssessment(for: hdr10Only).effectiveHDRHint, .hdr10)
        XCTAssertEqual(p7.selectionAssessment(for: hdr10Only).qualityScore, 6_160)
        XCTAssertEqual(p7.selectionAssessment(for: dvOnly).qualityScore, 2_160)
        XCTAssertEqual(p7.hdrLabel, "Dolby Vision", "Source labels must remain source facts.")
    }

    func testRichRangeAndTransferOverrideConflictingFlatRange() {
        for video in [
            MediaSourceMetadata.VideoStream(codec: "hevc", height: 2160, videoRange: "SDR"),
            .init(codec: "hevc", height: 2160, colorTransfer: "bt709")
        ] {
            let version = MediaVersion(
                id: "sdr", videoRange: "DOVIWithHDR10", sourceMetadata: .init(video: video)
            )
            let assessment = version.selectionAssessment(for: .default)
            XCTAssertEqual(assessment.effectiveHDRHint, .sdr)
            XCTAssertEqual(assessment.qualityScore, 2_160)
        }
        let explicitBase = MediaVersion(id: "dv", sourceMetadata: .init(
            video: .init(codec: "hevc", height: 2160, videoRange: "HDR10", videoRangeType: "DOVI", dolbyVisionProfile: 8)
        ))
        XCTAssertEqual(explicitBase.selectionAssessment(for: .default).effectiveHDRHint, .hdr10)
        let noBase = MediaVersion(
            id: "dv", videoRange: "DOVIWithHDR10",
            sourceMetadata: .init(video: .init(codec: "hevc", height: 2160, dolbyVisionProfile: 5))
        )
        XCTAssertEqual(noBase.selectionAssessment(for: .default).qualityScore, 2_160)
    }

    func testDolbyVisionBaseRequiresExplicitCompatibilityExceptProfile7Policy() {
        let caps = MediaCapabilities(supportsDolbyVision: false)
        for (token, expected) in [
            ("DOVIWithHDR10Plus", SourceDynamicRange.hdr10Plus),
            ("DOVIWithHDR10", .hdr10), ("DOVIWithHLG", .hlg), ("DOVIWithSDR", .sdr)
        ] {
            let version = MediaVersion(id: token, height: 2160, videoCodec: "hevc", videoRange: token)
            XCTAssertEqual(version.selectionAssessment(for: caps).effectiveHDRHint, expected)
            XCTAssertEqual(version.selectionAssessment(for: caps).qualityScore, expected.isHDR ? 6_160 : 2_160)
        }
        for profile in [5, 8] {
            let version = MediaVersion(id: "dv", sourceMetadata: .init(
                video: .init(codec: "hevc", height: 2160, colorTransfer: "smpte2084", dolbyVisionProfile: profile)
            ))
            XCTAssertEqual(version.selectionAssessment(for: caps).effectiveHDRHint, .dolbyVision)
            XCTAssertEqual(version.selectionAssessment(for: caps).qualityScore, 2_160)
        }
    }

    func testHDREligibilityDoesNotInventDisplaySupportOrRejectDecodableInput() {
        let caps = MediaCapabilities(supportsDolbyVision: true, isHDRPlaybackEligible: false)
        let hdr = MediaVersion(id: "hdr", height: 1080, videoCodec: "hevc", videoRange: "DOVI")
        let sdr = MediaVersion(id: "sdr", height: 2160, videoCodec: "hevc", videoRange: "SDR")
        XCTAssertTrue(hdr.selectionAssessment(for: caps).hasSupportedInput)
        XCTAssertEqual(hdr.selectionAssessment(for: caps).qualityScore, 1_080)
        XCTAssertEqual([hdr, sdr].recommendedSelection(for: caps)?.id, "sdr")
        XCTAssertGreaterThan(hdr.qualityScore, sdr.qualityScore, "Source ordering remains unchanged.")
    }

    func testHDRFormatsHaveNoInventedQualityHierarchy() {
        let caps = MediaCapabilities(supportsDolbyVision: true, isHDRPlaybackEligible: true)
        for range in ["DOVI", "HDR10", "HDR10Plus", "HLG"] {
            let version = MediaVersion(
                id: range, height: 2160, bitrate: 40_000_000, videoCodec: "hevc", videoRange: range
            )
            XCTAssertEqual(version.selectionAssessment(for: caps).qualityScore, 6_200, range)
        }
    }

    func testUnknownAndUnsupportedFactsRetainServerFallback() {
        let unknown = MediaVersion(id: "unknown", height: 4320, isDefault: true)
        let unsupported = MediaVersion(id: "unsupported", height: 4320, videoCodec: "not-a-codec")
        let badAudio = MediaVersion(id: "audio", height: 4320, videoCodec: "hevc", audioCodec: "not-a-codec")
        for version in [unknown, unsupported, badAudio] {
            XCTAssertFalse(version.selectionAssessment(for: .default).hasSupportedInput)
            XCTAssertEqual([version, baseline].recommendedSelection(for: .default)?.id, baseline.id)
        }
        XCTAssertEqual([unsupported, unknown].recommendedSelection(for: .default)?.id, unknown.id)
    }

    func testRecommendationTiesDoNotDependOnArrivalOrFileSize() {
        var first = baseline
        first.id = "a"
        first.sizeBytes = 1_000
        var second = baseline
        second.id = "b"
        second.sizeBytes = 10_000
        XCTAssertEqual([first, second].sortedForPicker().first?.id, "b")
        XCTAssertEqual([first, second].recommendedSelection(for: .default)?.id, "a")
        XCTAssertEqual([second, first].recommendedSelection(for: .default)?.id, "a")
    }

    func testCrossSourceSelectionUsesTheSameEngineAssessment() {
        let dts = MediaVersion(id: "dts", height: 2160, videoCodec: "hevc", videoRange: "HDR10", audioCodec: "dts")
        let sources = [
            MediaSourceRef(accountID: "one", itemID: "movie", versions: [baseline]),
            MediaSourceRef(accountID: "two", itemID: "movie", versions: [dts])
        ]
        XCTAssertEqual(CrossSourceSelector.bestSelection(from: sources, capabilities: .default)?.version?.id, "dts")
        XCTAssertEqual(
            CrossSourceSelector.bestSelection(from: sources, capabilities: .default, engine: .native)?.version?.id,
            baseline.id
        )
        let sdrDisplay = MediaCapabilities(isHDRPlaybackEligible: false)
        let hdr = MediaVersion(id: "hdr", height: 1080, videoCodec: "hevc", videoRange: "HDR10")
        let sdr = MediaVersion(id: "sdr", height: 2160, videoCodec: "hevc", videoRange: "SDR")
        let alternatives = [
            MediaSourceRef(accountID: "one", itemID: "movie", versions: [hdr]),
            MediaSourceRef(accountID: "two", itemID: "movie", versions: [sdr])
        ]
        XCTAssertEqual(CrossSourceSelector.bestSelection(from: alternatives, capabilities: sdrDisplay)?.version?.id, "sdr")
    }
}
