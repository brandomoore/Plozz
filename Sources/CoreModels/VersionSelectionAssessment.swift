import Foundation

/// Metadata-only recommendation evidence, never a resolved delivery/output mode.
public struct VersionSelectionAssessment: Equatable, Sendable {
    public var hasSupportedInput: Bool
    public var qualityScore: Int
    public var effectiveHDRHint: SourceDynamicRange?
}

public extension MediaVersion {
    func selectionAssessment(
        for capabilities: MediaCapabilities,
        engine: PlaybackEngineKind = .plozzigen
    ) -> VersionSelectionAssessment {
        if engine == .native {
            return .init(
                hasSupportedInput: !isExternalSource && compatibility(with: capabilities) == .directPlay,
                qualityScore: qualityScore,
                effectiveHDRHint: SourceDynamicRange.providerHint(from: sourceMetadata ?? flattenedSourceMetadata)
            )
        }

        let video = sourceMetadata?.video
        let videoCodec = video?.codec ?? self.videoCodec
        let audioCodec = sourceMetadata?.audio?.codec ?? self.audioCodec
        // Audio bridging and software video decode are supported inputs, not
        // native passthrough. Missing facts remain for the engine to probe.
        let supported = !isExternalSource
            && videoCodec.map(PlozzigenMediaFormats.supports(videoCodec:)) == true
            && audioCodec.map(PlozzigenMediaFormats.supports(audioCodec:)) != false
        let range = selectionHDRHint(for: capabilities)
        let usableHDR: Bool
        switch range {
        case .dolbyVision: usableHDR = capabilities.supportsDolbyVision
        case .hdr10, .hdr10Plus: usableHDR = capabilities.supportsHDR10
        case .hlg: usableHDR = capabilities.supportsHLG
        case .sdr, nil: usableHDR = false
        }
        // Keep the existing weights; this phase corrects their inputs, not the
        // unresolved tradeoff between resolution, compression and source quality.
        let score = (video?.height ?? height ?? 0)
            + (usableHDR && capabilities.isHDRPlaybackEligible != false ? 4_000 : 0)
            + (bitrate ?? video?.bitrate ?? 0) / 1_000_000
            + (isDefault ? 1 : 0)
        return .init(hasSupportedInput: supported, qualityScore: score, effectiveHDRHint: range)
    }

    private func selectionHDRHint(for capabilities: MediaCapabilities) -> SourceDynamicRange? {
        let video = sourceMetadata?.video
        // Provider metadata cannot confirm MEL; score P7 by its HDR10 fallback.
        if video?.dolbyVisionProfile == 7 { return .hdr10 }
        func normalized(_ token: String?) -> String? {
            token?.uppercased().replacingOccurrences(of: "+", with: "PLUS")
                .filter { $0.isLetter || $0.isNumber }
                .replacingOccurrences(of: "DOLBYVISION", with: "DOVI")
        }
        let hasRichRange = video?.videoRangeType != nil || video?.videoRange != nil
            || video?.colorTransfer != nil || video?.dolbyVisionProfile != nil
        let rangeType = normalized(video?.videoRangeType ?? (hasRichRange ? nil : videoRange))
        let coarseRange = normalized(video?.videoRange)
        let range = SourceDynamicRange.classify(
            videoRangeType: rangeType ?? coarseRange,
            videoRange: coarseRange,
            colorTransfer: video?.colorTransfer,
            dolbyVisionProfile: video?.dolbyVisionProfile
        )
        guard range == .dolbyVision, !capabilities.supportsDolbyVision else { return range }
        // A profile number alone (notably P8) does not prove a compatible base.
        let compatibility = [rangeType, coarseRange].compactMap { $0 }.joined(separator: " ")
        if compatibility.contains("HDR10PLUS") { return .hdr10Plus }
        if compatibility.contains("HDR10") { return .hdr10 }
        if compatibility.contains("HLG") { return .hlg }
        if compatibility.contains("SDR") { return .sdr }
        return range
    }
}
