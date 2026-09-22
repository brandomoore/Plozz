import CoreModels
import CoreNetworking
import Foundation

enum StreamingMediaPlaylist {
    private static let maximumBytes = 64 * 1024
    private static let client: any HTTPClient = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSessionHTTPClient(session: URLSession(configuration: configuration))
    }()

    static func resolve(_ url: URL, using client: (any HTTPClient)? = nil) async throws -> URL? {
        guard origin(url) != nil, url.pathExtension.lowercased() == "m3u8" else { return nil }
        let (data, response) = try await (client ?? self.client).send(
            Endpoint(path: "", redirectPolicy: .sameOrigin), baseURL: url
        )
        try Task.checkCancellation()
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8),
              let responseURL = response.url, origin(responseURL) == origin(url) else { return nil }
        return singleMediaURL(in: text, masterURL: responseURL)
    }

    /// Bypass only a single, self-contained server rendition. Do not choose an
    /// adaptive variant, discard external tracks, or invent a new transcode URL.
    static func singleMediaURL(in text: String, masterURL: URL) -> URL? {
        guard text.utf8.count <= maximumBytes, let acceptedOrigin = origin(masterURL) else { return nil }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.first == "#EXTM3U" else { return nil }
        var variant: String?
        var expectsURI = false
        var variantCount = 0
        var referencedGroups = Set<String>()
        var inBandGroups = Set<String>()
        for line in lines.dropFirst() {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                variantCount += 1
                guard variantCount == 1,
                      let fields = attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count))),
                      let bandwidth = fields["BANDWIDTH"].flatMap(Int.init), bandwidth > 0 else { return nil }
                for key in ["AUDIO", "VIDEO", "SUBTITLES"] {
                    if let group = fields[key] { referencedGroups.insert("\(key):\(group)") }
                }
                expectsURI = true
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                guard let fields = attributes(String(line.dropFirst("#EXT-X-MEDIA:".count))),
                      fields["URI"] == nil, let type = fields["TYPE"], let group = fields["GROUP-ID"] else { return nil }
                inBandGroups.insert("\(type):\(group)")
            } else if line.hasPrefix("#EXT-X-DEFINE:") || line.hasPrefix("#EXT-X-SESSION-KEY:")
                        || line.hasPrefix("#EXTINF:") || line.hasPrefix("#EXT-X-TARGETDURATION:") {
                return nil
            } else if !line.hasPrefix("#") {
                guard expectsURI, !line.contains("{$"), !line.contains("\\") else { return nil }
                variant = line
                expectsURI = false
            }
        }
        guard !expectsURI, referencedGroups.isSubset(of: inBandGroups),
              let variant, let url = URL(string: variant, relativeTo: masterURL)?.absoluteURL,
              url.pathExtension.lowercased() == "m3u8", url != masterURL,
              origin(url) == acceptedOrigin else { return nil }
        return url
    }

    private static func origin(_ url: URL) -> NetworkOrigin? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              let scheme = parts.scheme, let host = parts.host else { return nil }
        return try? NetworkOrigin(scheme: scheme, host: host, port: parts.port)
    }

    private static func attributes(_ text: String) -> [String: String]? {
        var quoted = false
        var field = ""
        var fields: [String] = []
        for character in text {
            if character == "\"" { quoted.toggle() }
            if character == ",", !quoted {
                fields.append(field)
                field = ""
            } else {
                field.append(character)
            }
        }
        guard !quoted else { return nil }
        fields.append(field)
        var result: [String: String] = [:]
        for field in fields {
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            var value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty, result[key] == nil else { return nil }
            if value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            guard !value.contains("\"") else { return nil }
            result[key] = value
        }
        return result
    }
}
