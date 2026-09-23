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

    func releaseStreamingEncoding(_ id: String, origin: String = #function) async {
        do {
            try await client.stopActiveEncoding(playSessionID: id, origin: origin)
            HandoffDiagnostics.emit("streaming RELEASE_ACK provider=\(kind.rawValue)")
        } catch {
            HandoffDiagnostics.emit("streaming RELEASE_FAILED provider=\(kind.rawValue)")
            PlozzLog.playback.error("Unable to release the previous streaming rendition.")
        }
    }
}

extension JellyfinCapabilityProfile {
    static let streamingHEVCBitDepth = 10
    static let streamingH264BitDepth = 8

    var canRequestHEVC: Bool {
        transcodingProfiles.contains { $0.videoCodec.split(separator: ",").contains("hevc") }
    }

    func applying(_ options: StreamingPlaybackOptions) -> Self {
        var result = self
        if let limit = options.quality.maximumBitrate {
            result.maxStreamingBitrate = limit
            result.maxStaticBitrate = limit
        }
        for index in result.transcodingProfiles.indices {
            result.transcodingProfiles[index].videoCodec = options.codec.codecs(supportsHEVC: canRequestHEVC)
                .joined(separator: ",")
            result.transcodingProfiles[index].audioCodec = "aac"
            result.transcodingProfiles[index].maxAudioChannels = "2"
        }
        for index in result.codecProfiles.indices {
            let depth: Int
            switch result.codecProfiles[index].codec {
            case "hevc": depth = Self.streamingHEVCBitDepth
            case "h264": depth = Self.streamingH264BitDepth
            default: continue
            }
            result.codecProfiles[index].conditions.append(.init(
                condition: "LessThanEqual", property: "VideoBitDepth",
                value: String(depth), isRequired: false
            ))
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
    func boundedTranscodingURL(_ options: StreamingPlaybackOptions, supportsHEVC: Bool) throws -> String {
        try options.quality.validate()
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
        if options.codec == .preferHEVC, supportsHEVC {
            guard offeredCodecs.contains("hevc") else {
                PlozzLog.playback.info("The server did not provide the requested HEVC rendition.")
                throw StreamingQualityError.codecUnavailable(.hevc)
            }
            set("VideoCodec", "hevc")
        } else if !supportsHEVC || options.codec == .preferH264 || !["h264", "hevc"].contains(videoCodec?.lowercased() ?? "") {
            set("VideoCodec", "h264")
        }
        let selectedCodec = query.first { $0.name.caseInsensitiveCompare("VideoCodec") == .orderedSame }?.value?.lowercased()
        if selectedCodec == "hevc" {
            let depth = String(JellyfinCapabilityProfile.streamingHEVCBitDepth)
            set("MaxVideoBitDepth", depth)
            set("hevc-videobitdepth", depth)
            if (MediaStreams?.first { $0.Type == "Video" }?.BitDepth ?? 0) > 8 {
                set("hevc-profile", "main10")
            }
        } else {
            let depth = String(JellyfinCapabilityProfile.streamingH264BitDepth)
            set("MaxVideoBitDepth", depth)
            set("h264-videobitdepth", depth)
        }
        set("AudioCodec", "aac")
        url.queryItems = query
        guard let value = url.string else { throw StreamingQualityError.unavailable }
        return value
    }
}
