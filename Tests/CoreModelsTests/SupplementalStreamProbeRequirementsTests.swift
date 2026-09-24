import Foundation
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

    func testNetworkRequirementsKeepHDRIndependentAndDelegateVideoCodecSupport() {
        for codec in ["hevc", "av1", "vp9", "h264"] {
            let metadata = MediaSourceMetadata(
                video: .init(codec: codec, width: 3840, height: 2160, videoRangeType: "HDR10"),
                audio: .init(codec: "eac3", profile: "Dolby Atmos", channels: 6))
            XCTAssertEqual(
                SupplementalStreamProbeRequirements.missingNetworkFileFacts(in: metadata), .hdr10Plus)
        }
        XCTAssertEqual(
            SupplementalStreamProbeRequirements.missingNetworkFileFacts(in: nil),
            [.streamDetails, .atmos, .hdr10Plus])
    }

    func testNetworkRequirementsDoNotRescanKnownRangesOrUnrelatedAudioCodecs() {
        for range in ["DOVI", "HDR10Plus", "SDR", "HLG"] {
            for codec in ["aac", "truehd", "dts"] {
                let metadata = MediaSourceMetadata(
                    video: .init(codec: "hevc", width: 1920, height: 1080, videoRangeType: range),
                    audio: .init(codec: codec, channels: 6))
                XCTAssertTrue(SupplementalStreamProbeRequirements.missingNetworkFileFacts(in: metadata).isEmpty)
            }
        }
        XCTAssertEqual(
            SupplementalStreamProbeRequirements.missingNetworkFileFacts(in: .init(
                video: .init(codec: "av1", videoRangeType: "SDR"),
                audio: .init(codec: "aac", channels: 2))),
            .streamDetails)
    }

    func testNetworkAudioRequirementsForMissingAndEAC3CodecsOnly() {
        for codec in [nil, "", "eac3", " EAC3 "] as [String?] {
            let metadata = MediaSourceMetadata(
                video: .init(codec: "av1", width: 1920, height: 1080, videoRangeType: "HLG"),
                audio: .init(codec: codec, channels: 6))
            let requirements = SupplementalStreamProbeRequirements.missingNetworkFileFacts(in: metadata)
            XCTAssertTrue(requirements.contains(.atmos))
            XCTAssertFalse(requirements.contains(.hdr10Plus))
        }
    }

    func testIndependentProbeFactsMergeWithoutLosingPositiveOrDefaultTrackEvidence() {
        let original = ProbedStreamFacts(
            videoWidth: 3840, videoHeight: 2160, videoRangeType: "DOVI", videoCodec: "hevc",
            audioTrackID: 3, audioCodec: "eac3", audioChannels: 6, audioIsAtmos: true,
            durationSeconds: 120)
        let merged = original.merging(.init(videoRangeType: "HDR10Plus", audioIsAtmos: false))
        XCTAssertEqual(merged, original)
        XCTAssertEqual(original.merging(.init(
            audioTrackID: 7, audioCodec: "aac", audioChannels: 2)), original)
        XCTAssertEqual(
            ProbedStreamFacts(videoRangeType: "HDR10Plus").merging(.init(videoRangeType: "HDR10")).videoRangeType,
            "HDR10Plus")
        XCTAssertEqual(
            ProbedStreamFacts(videoRangeType: "HDR10").merging(.init(videoRangeType: "HDR10Plus")).videoRangeType,
            "HDR10Plus")
    }

    func testApplyingHeaderAndScanFactsDoesNotDemoteKnownRangesInItemOrVersion() {
        for range in ["DOVI", "HDR10Plus", "SDR", "HLG"] {
            let metadata = MediaSourceMetadata(
                sourceRevision: "same-file",
                video: .init(codec: "hevc", videoRangeType: range),
                audio: .init(codec: "eac3", profile: "Dolby Atmos", channels: 6))
            let item = MediaItem(
                id: "movie", title: "Movie", kind: .movie, mediaInfo: metadata,
                versions: [
                    .init(id: "selected", videoRange: range, audioProfile: "Dolby Atmos", sourceMetadata: metadata),
                    .init(id: "alternate", videoRange: "SDR")
                ],
                selectedVersionID: "selected")
            let enriched = item.applyingSupplementalStreamFacts(.init(
                videoWidth: 3840, videoHeight: 2160, videoRangeType: "HDR10",
                audioIsAtmos: false, durationSeconds: 100))
            XCTAssertEqual(enriched.mediaInfo?.video?.videoRangeType, range)
            XCTAssertEqual(enriched.mediaInfo?.audio?.profile, "Dolby Atmos")
            XCTAssertEqual(enriched.mediaInfo?.sourceRevision, "same-file")
            XCTAssertEqual(enriched.versions.first?.videoRange, range)
            XCTAssertEqual(enriched.versions.first?.sourceMetadata?.video?.videoRangeType, range)
            XCTAssertEqual(enriched.versions.first?.audioProfile, "Dolby Atmos")
            XCTAssertEqual(enriched.versions.last, item.versions.last)
            XCTAssertEqual(enriched.runtime, 100)
        }
    }

    func testHDR10PlusOutputCannotDemoteExplicitDolbyVisionProfile() {
        let metadata = MediaSourceMetadata(video: .init(codec: "hevc", dolbyVisionProfile: 8))
        let enriched = ProbedStreamFacts(videoRangeType: "HDR10Plus").applying(to: metadata)
        XCTAssertEqual(enriched, metadata)
    }

    func testAdditionalHDR10PlusEvidenceSurvivesIndependentMergesWithoutDemotingDolbyVision() {
        let dolbyVision = ProbedStreamFacts(videoRangeType: "DOVI")
        let hdr = ProbedStreamFacts(videoRangeType: "HDR10Plus", carriesHDR10PlusMetadata: true)
        let combined = dolbyVision.merging(hdr)
        XCTAssertEqual(combined.videoRangeType, "DOVI")
        XCTAssertEqual(combined.carriesHDR10PlusMetadata, true)
        XCTAssertEqual(combined.merging(.init()).carriesHDR10PlusMetadata, true)
        var negative = ProbedStreamFacts()
        negative.carriesHDR10PlusMetadata = false
        XCTAssertEqual(combined.merging(negative).carriesHDR10PlusMetadata, true)
        XCTAssertNil(dolbyVision.merging(negative).carriesHDR10PlusMetadata)
        XCTAssertNil(ProbedStreamFacts(carriesHDR10PlusMetadata: false).carriesHDR10PlusMetadata)
    }

    func testLegacyProbeFactsDecodeWithoutAdditionalHDR10PlusEvidence() throws {
        let legacy = Data(#"{"videoRangeType":"DOVI","audioIsAtmos":true}"#.utf8)
        let decoded = try JSONDecoder().decode(ProbedStreamFacts.self, from: legacy)
        XCTAssertEqual(decoded.videoRangeType, "DOVI")
        XCTAssertTrue(decoded.audioIsAtmos)
        XCTAssertNil(decoded.carriesHDR10PlusMetadata)
    }

    func testAdditionalHDR10PlusEvidenceCodableRoundTripPreservesBothFormats() throws {
        let facts = ProbedStreamFacts(
            videoRangeType: "DOVI", carriesHDR10PlusMetadata: true)
        let decoded = try JSONDecoder().decode(
            ProbedStreamFacts.self, from: JSONEncoder().encode(facts))
        XCTAssertEqual(decoded, facts)
    }

    // MARK: Probe results on a version's badges (#58)

    /// An Emby/Jellyfin version usually has no stream metadata of its own, only
    /// flattened fields. Upgrading its HDR10 to HDR10+ used to create metadata
    /// holding just the range, which `technicalBadges` then preferred, so the
    /// 4K and Dolby Digital+ badges disappeared as the HDR10+ one appeared.
    func testHDR10PlusUpgradeKeepsResolutionAndAudioBadges() {
        var item = MediaItem(id: "movie", title: "Movie", kind: .movie)
        item.versions = [MediaVersion(
            id: "v", width: 3840, height: 2160, isDefault: true,
            videoCodec: "hevc", videoRange: "HDR10",
            audioCodec: "eac3", audioChannels: 6)]
        XCTAssertNil(item.versions[0].sourceMetadata)
        let before = item.versions[0].technicalBadges.map(\.label)

        let upgraded = item.applyingSupplementalStreamFacts(.init(videoRangeType: "HDR10Plus"))
        let after = upgraded.versions[0].technicalBadges.map(\.label)

        XCTAssertTrue(before.contains("4K") && before.contains("HDR10"), "\(before)")
        XCTAssertEqual(after, before.map { $0 == "HDR10" ? "HDR10+" : $0 })
    }

    /// A version that already carries its file's metadata keeps it, with the
    /// probed range merged in, exactly as before.
    func testProbeMergesIntoExistingVersionMetadata() {
        var item = MediaItem(id: "movie", title: "Movie", kind: .movie)
        let metadata = MediaSourceMetadata(
            container: "mkv",
            video: .init(codec: "hevc", width: 3840, height: 2160, videoRangeType: "HDR10"),
            audio: .init(codec: "truehd", profile: "Dolby Atmos", channels: 8))
        item.versions = [MediaVersion(id: "v", isDefault: true, videoRange: "HDR10", sourceMetadata: metadata)]

        let upgraded = item.applyingSupplementalStreamFacts(.init(videoRangeType: "HDR10Plus"))
        let merged = upgraded.versions[0].sourceMetadata

        XCTAssertEqual(merged?.container, "mkv")
        XCTAssertEqual(merged?.video?.videoRangeType, "HDR10Plus")
        XCTAssertEqual(merged?.audio?.profile, "Dolby Atmos")
        XCTAssertEqual(merged?.audio?.channels, 8)
    }
}

