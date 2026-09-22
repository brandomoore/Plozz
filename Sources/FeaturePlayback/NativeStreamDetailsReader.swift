#if canImport(AVFoundation)
import AVFoundation
import CoreModels
import CoreNetworking
import Foundation

enum NativeStreamDetailsReader {
    static func read(_ item: AVPlayerItem) async -> MediaSourceMetadata {
        var metadata = MediaSourceMetadata()
        guard item.status == .readyToPlay else { return metadata }
        do {
            let enabled = item.tracks.filter(\.isEnabled).compactMap(\.assetTrack)
            // HLS can publish ready before AVPlayerItem's tracks are available.
            let tracks = enabled.isEmpty ? try await item.asset.load(.tracks) : enabled
            try Task.checkCancellation()
            let videoTracks = tracks.filter { $0.mediaType == .video }
            let audioTracks = tracks.filter { $0.mediaType == .audio }
            if videoTracks.count == 1, let video = videoTracks.first,
               let description = try await video.load(.formatDescriptions).first {
                metadata.video = videoStream(description)
                let fps = try await video.load(.nominalFrameRate)
                if fps.isFinite, fps > 0 { metadata.video?.frameRate = Double(fps) }
                let bitrate = try await video.load(.estimatedDataRate)
                metadata.video?.bitrate = positiveInteger(Double(bitrate))
            }
            try Task.checkCancellation()
            if audioTracks.count == 1, let audio = audioTracks.first,
               let description = try await audio.load(.formatDescriptions).first {
                metadata.audio = audioStream(description)
                let bitrate = try await audio.load(.estimatedDataRate)
                metadata.audio?.bitrate = positiveInteger(Double(bitrate))
            }
        } catch is CancellationError {
            return .init()
        } catch {
            PlozzLog.playback.debug("Current stream format is not yet available; retaining only observed rendition facts.")
        }
        return metadata
    }

    static func videoStream(_ description: CMFormatDescription) -> MediaSourceMetadata.VideoStream {
        let tag = fourCC(CMFormatDescriptionGetMediaSubType(description))
        let format = NativePlaybackFailure.VideoFormat(description)
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        let range: String?
        if ["dvh1", "dvhe", "dav1", "dvav"].contains(tag) {
            range = "DOVI"
        } else {
            switch format.dynamicRange {
            case .sdr: range = "SDR"
            case .hdr10: range = "HDR10"
            case .hlg: range = "HLG"
            default: range = nil
            }
        }
        return .init(
            codec: format.videoCodec?.rawValue ?? tag, codecTag: tag,
            width: dimensions.width > 0 ? Int(dimensions.width) : nil,
            height: dimensions.height > 0 ? Int(dimensions.height) : nil,
            videoRangeType: range,
            colorTransfer: range == nil ? nil : format.transfer
        )
    }

    static func audioStream(_ description: CMFormatDescription) -> MediaSourceMetadata.AudioStream {
        let tag = fourCC(CMFormatDescriptionGetMediaSubType(description))
        let codec: String
        switch tag {
        case "ac-3": codec = "ac3"
        case "ec-3": codec = "eac3"
        case "aac ", "aach", "aacp", "aacl": codec = "aac"
        default: codec = tag.trimmingCharacters(in: .whitespaces)
        }
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        return .init(
            codec: codec,
            channels: asbd.flatMap { $0.mChannelsPerFrame > 0 ? Int($0.mChannelsPerFrame) : nil },
            sampleRate: asbd.flatMap { positiveInteger($0.mSampleRate) }
        )
    }

    private static func positiveInteger(_ value: Double) -> Int? {
        guard value.isFinite, value > 0, value < Double(Int.max) else { return nil }
        return Int(value.rounded())
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((value >> $0) & 0xff) }, encoding: .ascii) ?? ""
    }
}
#endif
