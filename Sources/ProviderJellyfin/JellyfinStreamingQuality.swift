import CoreModels
import CoreNetworking
import Foundation

extension JellyfinProvider: StreamingQualityProviding {
    public func playbackInfo(
        for itemID: String, mediaSourceID: String?, forceTranscode: Bool,
        streaming: StreamingPlaybackOptions
    ) async throws -> PlaybackRequest {
        try await resolvePlayback(
            for: itemID, mediaSourceID: mediaSourceID,
            forceTranscode: forceTranscode, streaming: streaming
        )
    }

    public func releaseStreamingSession(_ request: PlaybackRequest) async {
        guard let id = request.streamingSessionID else { return }
        await releaseStreamingEncoding(id)
    }

    func releaseStreamingEncoding(_ id: String) async {
        do { try await client.stopActiveEncoding(playSessionID: id) }
        catch { PlozzLog.playback.error("Unable to release the previous streaming rendition.") }
    }
}

extension JellyfinCapabilityProfile {
    func applying(_ options: StreamingPlaybackOptions) -> Self {
        var result = self
        if let limit = options.quality.maximumBitrate {
            result.maxStreamingBitrate = limit
            result.maxStaticBitrate = limit
        }
        let supportsHEVC = transcodingProfiles.contains {
            $0.videoCodec.split(separator: ",").contains("hevc")
        }
        for index in result.transcodingProfiles.indices {
            result.transcodingProfiles[index].videoCodec = options.codec.codecs(supportsHEVC: supportsHEVC)
                .joined(separator: ",")
            result.transcodingProfiles[index].audioCodec = "aac"
            result.transcodingProfiles[index].maxAudioChannels = "2"
        }
        if let height = options.quality.maximumHeight, let width = options.quality.maximumWidth {
            result.codecProfiles.append(.init(type: "Video", codec: "", conditions: [
                .init(condition: "LessThanEqual", property: "Width", value: String(width), isRequired: true),
                .init(condition: "LessThanEqual", property: "Height", value: String(height), isRequired: true)
            ]))
        }
        return result
    }
}

extension PlaybackInfoResponse {
    var streamingError: StreamingQualityError? {
        switch ErrorCode {
        case nil: nil
        case "NotAllowed": .permissionDenied
        case "NoCompatibleStream": .noCompatibleStream
        default: .negotiationFailed
        }
    }
}

extension MediaSourceInfo {
    func fits(_ quality: StreamingQuality) -> Bool {
        let video = MediaStreams?.first { $0.Type == "Video" }
        return quality.permitsOriginal(bitrate: Bitrate, width: video?.Width, height: video?.Height)
    }

    /// Apply bounds to the server-issued rendition, never to an original-file URL.
    func boundedTranscodingURL(_ options: StreamingPlaybackOptions) throws -> String {
        guard let TranscodingUrl, var url = URLComponents(string: TranscodingUrl) else {
            throw StreamingQualityError.unavailable
        }
        var query = url.queryItems ?? []
        func set(_ name: String, _ value: String) {
            query.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            query.append(.init(name: name, value: value))
        }
        if let total = options.quality.maximumBitrate, let bitrate = options.quality.videoBitrate,
           let height = options.quality.maximumHeight, let width = options.quality.maximumWidth {
            set("VideoBitrate", String(bitrate))
            set("AudioBitrate", String(options.quality.audioBitrate))
            set("MaxStreamingBitrate", String(total))
            set("MaxHeight", String(height))
            set("MaxWidth", String(width))
            set("MaxAudioChannels", "2")
        }
        set("AllowVideoStreamCopy", "false")
        set("AllowAudioStreamCopy", "false")
        if let audio = options.audioTrack { set("AudioStreamIndex", String(audio.id)) }
        if !options.subtitlesOff, let subtitle = options.subtitleTrack, subtitle.isBitmapSubtitle {
            set("SubtitleStreamIndex", String(subtitle.id))
            if query.contains(where: { $0.name.caseInsensitiveCompare("SubtitleStreamIndexes") == .orderedSame }) {
                set("SubtitleStreamIndexes", String(subtitle.id))
            }
            set("SubtitleMethod", "Encode")
        } else {
            // Emby can still burn its default track when the index is -1 but
            // the delivery method is omitted. Explicitly keep subtitles out of HLS.
            set("SubtitleStreamIndex", "-1")
            if query.contains(where: { $0.name.caseInsensitiveCompare("SubtitleStreamIndexes") == .orderedSame }) {
                set("SubtitleStreamIndexes", "-1")
            }
            set("SubtitleMethod", "External")
            query.removeAll { $0.name.caseInsensitiveCompare("ManifestSubtitles") == .orderedSame }
        }
        let videoCodec = query.first { $0.name.caseInsensitiveCompare("VideoCodec") == .orderedSame }?.value
        let offeredCodecs = (videoCodec ?? "").lowercased().split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if options.codec == .preferHEVC, offeredCodecs.contains("hevc") {
            set("VideoCodec", "hevc")
        } else if options.codec == .preferH264 || !["h264", "hevc"].contains(videoCodec?.lowercased() ?? "") {
            set("VideoCodec", "h264")
        }
        set("AudioCodec", "aac")
        url.queryItems = query
        guard let value = url.string else { throw StreamingQualityError.unavailable }
        return value
    }
}
