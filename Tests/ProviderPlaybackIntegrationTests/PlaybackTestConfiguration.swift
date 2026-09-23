import Foundation

struct PlaybackTestConfiguration: Decodable {
    struct Server: Decodable {
        let baseURL: URL
        let serverID: String
        let userID: String
        let tokenFile: String
        let itemID: String
        let mediaSourceID: String?
        let codecs: [String]
    }
    let servers: [String: Server]
    let startupTimeoutSeconds: Double
    let playbackSeconds: Double
    let seekSeconds: Double
    let resumeSeconds: Double

    static let supportedProviders = ["jellyfin", "plex", "emby", "silo"]

    func validate() throws {
        guard startupTimeoutSeconds.isFinite, (10...90).contains(startupTimeoutSeconds),
              playbackSeconds.isFinite, (5...60).contains(playbackSeconds),
              seekSeconds.isFinite, seekSeconds >= 5,
              resumeSeconds.isFinite, resumeSeconds >= 5,
              !servers.isEmpty else { throw PlaybackTestFailure.invalidConfiguration }
        for (name, server) in servers {
            guard Self.supportedProviders.contains(name),
                  let parts = URLComponents(url: server.baseURL, resolvingAgainstBaseURL: false),
                  ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
                  parts.host != nil, parts.user == nil, parts.password == nil,
                  parts.query == nil, parts.fragment == nil,
                  !server.serverID.isEmpty, !server.userID.isEmpty, !server.itemID.isEmpty,
                  server.tokenFile.hasPrefix("/"), !server.codecs.isEmpty,
                  (name == "silo" ? server.codecs == ["server"] : Set(server.codecs).isSubset(of: ["h264", "hevc"])),
                  Set(server.codecs).count == server.codecs.count else {
                throw PlaybackTestFailure.invalidConfiguration
            }
        }
    }
}

enum PlaybackTestFailure: String, Error {
    case invalidConfiguration, missingToken, missingPlayer, missingVideo, missingAudio
    case unexpectedDelivery, wrongDimensions, wrongCodec, startupTimeout, sustainedPlaybackFailed
    case pauseFailed, seekFailed, cleanupFailed, mediaFetchFailed, invalidPlaylist, audioDecodeFailed
    case clientHEVCUnavailable
    case audibleTestPlayer
}

enum PlaybackTestPlaylist {
    struct Segment {
        let initialization: URL?
        let media: URL
    }

    static func segment(_ text: String, baseURL: URL, position: Double = 0) throws -> Segment {
        guard text.utf8.count <= 2_000_000 else { throw PlaybackTestFailure.invalidPlaylist }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "#EXTM3U",
              !lines.contains(where: {
                  $0.hasPrefix("#EXT-X-STREAM-INF:") || $0.hasPrefix("#EXT-X-KEY:")
                      || $0.hasPrefix("#EXT-X-BYTERANGE:") || $0.hasPrefix("#EXT-X-DEFINE:")
              }) else { throw PlaybackTestFailure.invalidPlaylist }
        func resolved(_ value: String) throws -> URL {
            guard !value.contains("\\"),
                  let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
                  sameOrigin(url, baseURL) else { throw PlaybackTestFailure.invalidPlaylist }
            return url
        }
        var initialization: URL?
        var start = 0.0
        var duration: Double?
        var last: Segment?
        for line in lines {
            if line.hasPrefix("#EXT-X-MAP:") {
                guard let marker = line.range(of: "URI=\""),
                      let end = line[marker.upperBound...].firstIndex(of: "\""),
                      !line.contains("BYTERANGE") else { throw PlaybackTestFailure.invalidPlaylist }
                initialization = try resolved(String(line[marker.upperBound..<end]))
            } else if line.hasPrefix("#EXTINF:") {
                duration = Double(line.dropFirst("#EXTINF:".count).split(separator: ",", maxSplits: 1).first ?? "")
            } else if !line.isEmpty, !line.hasPrefix("#") {
                let segment = Segment(initialization: initialization, media: try resolved(line))
                if position == 0 { return segment }
                guard let seconds = duration, seconds.isFinite, seconds > 0 else {
                    throw PlaybackTestFailure.invalidPlaylist
                }
                if start <= position, position < start + seconds { return segment }
                start += seconds
                last = segment
                duration = nil
            }
        }
        if let last { return last }
        throw PlaybackTestFailure.invalidPlaylist
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let a = URLComponents(url: lhs, resolvingAgainstBaseURL: false),
              let b = URLComponents(url: rhs, resolvingAgainstBaseURL: false),
              a.user == nil, a.password == nil, a.fragment == nil,
              b.user == nil, b.password == nil, b.fragment == nil else { return false }
        return a.scheme?.lowercased() == b.scheme?.lowercased()
            && a.host?.lowercased() == b.host?.lowercased()
            && (a.port ?? (a.scheme?.lowercased() == "https" ? 443 : 80))
                == (b.port ?? (b.scheme?.lowercased() == "https" ? 443 : 80))
    }
}
