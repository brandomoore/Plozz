#if canImport(AVFoundation)
import Foundation
import AVFoundation
import CoreMedia
import CoreModels

/// The HDR/Dolby-Vision display class of a resolved source range. Drives the
/// tvOS display-mode switch so the
/// Apple TV negotiates the correct HDMI signalling (true Dolby Vision, HDR10,
/// HLG, or plain SDR) with the panel before `AVPlayer` starts rendering.
///
/// This is the *native* (AVPlayer) path's contribution to true Dolby Vision:
/// only Apple's own pipeline can light up the DoVi handshake, and a custom
/// `AVPlayerLayer`-based player (as opposed to `AVPlayerViewController`) has to
/// drive `AVDisplayManager.preferredDisplayCriteria` itself — tvOS won't switch
/// the display for us automatically.
enum HDRDisplayMode: Equatable {
    case sdr
    case hdr10
    case hlg
    case dolbyVision

    /// Classifies a source from its declared range tokens. Mirrors Jellyfin's
    /// `VideoRangeType` vocabulary (`DOVI`, `DOVIWithHDR10`, `DOVIWithSDR`,
    /// `DOVIWithHLG`, `HDR10`, `HLG`) with `colorTransfer`/`videoRange` as a
    /// fallback. Any Dolby Vision profile maps to `.dolbyVision` so the panel is
    /// driven into DoVi mode; the RPU base layer is handled downstream.
    init(_ metadata: MediaSourceMetadata?) {
        self.init(SourceDynamicRange.providerHint(from: metadata) ?? .sdr)
    }

    init(_ range: SourceDynamicRange) {
        switch range {
        case .sdr: self = .sdr
        case .hlg: self = .hlg
        // Both use PQ/BT.2020 display criteria. HDR10+ additionally requires
        // the video's per-frame metadata, not a different static display mode.
        case .hdr10, .hdr10Plus: self = .hdr10
        case .dolbyVision: self = .dolbyVision
        }
    }

    var isHDR: Bool { self != .sdr }
}

#if os(tvOS)
/// Bootstrap criteria for the native player while the asset's actual preferred
/// criteria load. HLS may need an initial HDR request before loading its tracks.
/// Returns nil for SDR; never substitutes for the asset-derived criteria.
///
/// The criteria is constructed from a synthetic `CMVideoFormatDescription` whose
/// codec FourCC selects Dolby Vision (`dvh1`) vs HDR/SDR HEVC (`hvc1`) and whose
/// colour extensions advertise BT.2020 primaries/matrix with the PQ or HLG
/// transfer function. These source hints cannot preserve the full stream format
/// description, so NativeDisplayCriteriaController replaces them with AVFoundation's
/// preferred criteria instead of treating generic PQ as the final HDR10+ request.
func makeDisplayCriteria(mode: HDRDisplayMode, metadata: MediaSourceMetadata?) -> AVDisplayCriteria? {
    guard mode != .sdr else { return nil }

    let width = Int32(metadata?.video?.width ?? 3840)
    let height = Int32(metadata?.video?.height ?? 2160)
    // 0.0 tells tvOS to leave the current refresh rate untouched (dynamic-range
    // switch only) when the source frame rate is unknown.
    let refreshRate = Float(metadata?.video?.frameRate ?? 0)

    // 'dvh1' Dolby Vision HEVC; otherwise standard HEVC.
    let dolbyVisionCodecType: CMVideoCodecType = 0x64766831 // 'dvh1'
    let codecType: CMVideoCodecType = (mode == .dolbyVision)
        ? dolbyVisionCodecType
        : kCMVideoCodecType_HEVC

    let transferFunction: CFString = (mode == .hlg)
        ? kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        : kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ

    let extensions: [CFString: Any] = [
        kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
        kCMFormatDescriptionExtension_TransferFunction: transferFunction,
        kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
    ]

    var formatDescription: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        codecType: codecType,
        width: width,
        height: height,
        extensions: extensions as CFDictionary,
        formatDescriptionOut: &formatDescription
    )
    guard status == noErr, let formatDescription else { return nil }

    return AVDisplayCriteria(refreshRate: refreshRate, formatDescription: formatDescription)
}
#endif
#endif
