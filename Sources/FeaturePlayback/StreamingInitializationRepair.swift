import CoreNetworking
import Foundation

struct StreamingInitializationRepair: Sendable {
    let playlistURL: URL
    let initializationURL: URL
    let playlist: Data
    let initialization: Data

    static func prepare(
        mediaURL: URL, using client: (any HTTPClient)? = nil
    ) async throws -> Self? {
        guard StreamingMediaPlaylist.origin(mediaURL) != nil,
              mediaURL.pathExtension.lowercased() == "m3u8" else { return nil }
        try Task.checkCancellation()
        let client = client ?? StreamingMediaPlaylist.client
        let (data, response) = try await client.send(
            Endpoint(path: "", redirectPolicy: .sameOrigin), baseURL: mediaURL
        )
        try Task.checkCancellation()
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8),
              let finalURL = response.url,
              StreamingMediaPlaylist.origin(finalURL) == StreamingMediaPlaylist.origin(mediaURL),
              let candidate = candidate(in: text, mediaURL: finalURL) else { return nil }
        let (initialization, initResponse) = try await client.send(
            Endpoint(path: "", redirectPolicy: .sameOrigin), baseURL: candidate.initialization
        )
        try Task.checkCancellation()
        guard let initURL = initResponse.url,
              StreamingMediaPlaylist.origin(initURL) == StreamingMediaPlaylist.origin(finalURL),
              let repaired = try FragmentedMP4Initialization.removingEmptySampleDependencies(from: initialization) else {
            return nil
        }
        let playlistURL = URL(string: "plozz-stream://\(UUID().uuidString)/media.m3u8")!
        let initializationURL = playlistURL.deletingLastPathComponent().appendingPathComponent("init.mp4")
        var lines = candidate.lines
        lines[candidate.mapIndex] = "#EXT-X-MAP:URI=\"\(initializationURL.absoluteString)\""
        return Self(
            playlistURL: playlistURL, initializationURL: initializationURL,
            playlist: Data((lines.joined(separator: "\n") + "\n").utf8), initialization: repaired
        )
    }

    private struct Candidate {
        var lines: [String]
        let mapIndex: Int
        let initialization: URL
    }

    private static func candidate(in text: String, mediaURL: URL) -> Candidate? {
        guard StreamingMediaPlaylist.origin(mediaURL) != nil else { return nil }
        var lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "#EXTM3U", lines.contains("#EXT-X-PLAYLIST-TYPE:VOD"),
              lines.contains("#EXT-X-ENDLIST") else { return nil }
        var mapIndex: Int?
        var initialization: URL?
        var segmentCount = 0
        var durationCount = 0
        var expectsSegment = false
        var ended = false
        for index in lines.indices {
            let line = lines[index]
            guard !ended || line.isEmpty else { return nil }
            if line.hasPrefix("#EXT-X-MAP:") {
                guard mapIndex == nil, segmentCount == 0, !expectsSegment,
                      let fields = StreamingMediaPlaylist.attributes(String(line.dropFirst("#EXT-X-MAP:".count))),
                      fields.count == 1, let reference = fields["URI"],
                      let url = StreamingMediaPlaylist.sameOriginURL(reference, relativeTo: mediaURL) else { return nil }
                mapIndex = index
                initialization = url
            } else if line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-SESSION-KEY:")
                        || line.hasPrefix("#EXT-X-DEFINE:") || line.hasPrefix("#EXT-X-STREAM-INF:")
                        || line.hasPrefix("#EXT-X-MEDIA:") || line.hasPrefix("#EXT-X-BYTERANGE:")
                        || line.contains("URI=") {
                return nil
            } else if line.hasPrefix("#EXTINF:") {
                guard mapIndex != nil, !expectsSegment,
                      let duration = Double(line.dropFirst("#EXTINF:".count).split(separator: ",").first ?? ""),
                      duration.isFinite, duration > 0 else { return nil }
                durationCount += 1
                expectsSegment = true
            } else if line == "#EXT-X-ENDLIST" {
                guard !expectsSegment else { return nil }
                ended = true
            } else if !line.isEmpty, !line.hasPrefix("#") {
                guard expectsSegment,
                      let url = StreamingMediaPlaylist.sameOriginURL(line, relativeTo: mediaURL) else { return nil }
                lines[index] = url.absoluteString
                segmentCount += 1
                expectsSegment = false
            }
        }
        guard let mapIndex, let initialization, segmentCount > 0, segmentCount == durationCount else { return nil }
        return Candidate(lines: lines, mapIndex: mapIndex, initialization: initialization)
    }
}
