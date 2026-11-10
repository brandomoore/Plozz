import CoreModels
import Foundation

/// Emby's audio endpoint honors the selected container index. Jellyfin's does not.
public enum EmbyOfflineDownloadURLBuilder {
    public static func makeURL(
        from playbackURL: URL, itemID: String, mediaSourceID: String,
        audioStreamIndex: Int, audioOnly: Bool, sessionID: String,
        maximumVideoBitrateBps: Int, maximumHeight: Int
    ) throws -> URL {
        guard !itemID.isEmpty, !itemID.contains("/"), !mediaSourceID.isEmpty,
              !sessionID.isEmpty, audioStreamIndex >= 0,
              maximumHeight > 0, maximumVideoBitrateBps > 0,
              var components = URLComponents(url: playbackURL, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let route = components.path.range(of: "/Videos/\(itemID)/", options: [.caseInsensitive, .backwards]),
              components.path.lowercased().hasSuffix(".m3u8") else {
            throw AppError.invalidResponse
        }
        components.path = String(components.path[..<route.lowerBound])
            + "/\(audioOnly ? "Audio" : "Videos")/\(itemID)/stream.\(audioOnly ? "aac" : "mp4")"
        var items = components.queryItems ?? []
        let replaced = [
            "static", "mediasourceid", "audiostreamindex", "audiocodec", "audiobitrate",
            "maxaudiochannels", "playsessionid", "enableautostreamcopy", "allowaudiostreamcopy",
            "allowvideostreamcopy", "videocodec", "videobitrate", "maxheight", "starttimeticks",
            "subtitlemethod", "subtitlestreamindex", "segmentcontainer", "minsegments",
            "breakonnonkeyframes", "transcodingcontainer", "transcodingprotocol"
        ]
        items.removeAll { replaced.contains($0.name.lowercased()) }
        items += [
            .init(name: "Static", value: "false"),
            .init(name: "MediaSourceId", value: mediaSourceID),
            .init(name: "AudioStreamIndex", value: String(audioStreamIndex)),
            .init(name: "AudioCodec", value: "aac"),
            .init(name: "AudioBitRate", value: "192000"),
            .init(name: "MaxAudioChannels", value: "2"),
            .init(name: "PlaySessionId", value: sessionID),
            .init(name: "EnableAutoStreamCopy", value: "false"),
            .init(name: "AllowAudioStreamCopy", value: "false"),
            .init(name: "StartTimeTicks", value: "0")
        ]
        if !audioOnly {
            items += [
                .init(name: "VideoCodec", value: "h264"),
                .init(name: "VideoBitrate", value: String(maximumVideoBitrateBps)),
                .init(name: "MaxHeight", value: String(maximumHeight)),
                .init(name: "AllowVideoStreamCopy", value: "false"),
                .init(name: "SubtitleMethod", value: "External")
            ]
        }
        components.queryItems = items
        guard let url = components.url else { throw AppError.invalidResponse }
        return url
    }
}

extension JellyfinProvider {
    public func finishOfflineAudioEncoding(sessionID: String) async throws {
        guard kind == .emby, !sessionID.isEmpty else { throw AppError.invalidResponse }
        try await client.stopActiveEncoding(playSessionID: sessionID)
    }
}
