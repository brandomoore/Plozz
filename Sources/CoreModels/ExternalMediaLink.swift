import Foundation

/// A user-supplied title link, never a playable stream or proof of ownership.
public struct ExternalMediaLink: Codable, Hashable, Sendable {
    public let url: URL
    public let service: Service

    public enum Service: String, Codable, Sendable {
        case appleTV, primeVideo, youTube, moviesAnywhere, fandango

        public var name: String { // l10n:content — official destination service names
            switch self {
            case .appleTV: "Apple TV"
            case .primeVideo: "Prime Video"
            case .youTube: "YouTube"
            case .moviesAnywhere: "Movies Anywhere"
            case .fandango: "Fandango at Home"
            }
        }
    }

    public static let maximumFileBytes = 8_192

    public init(contents: Data) throws {
        guard contents.count <= Self.maximumFileBytes,
              let text = String(data: contents, encoding: .utf8) else {
            throw AppError.unknown("The link file must contain a supported HTTPS title link.")
        }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        guard !value.contains(where: \.isWhitespace),
              value.rangeOfCharacter(from: .controlCharacters) == nil,
              let url = URL(string: value),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              let host = components.host?.lowercased(),
              let service = Self.service(host: host, path: components.path) else {
            throw AppError.unknown("The link file must contain a supported HTTPS title link.")
        }
        if service == .youTube {
            let videoID = host == "youtu.be" ? String(components.path.dropFirst())
                : components.queryItems?.first(where: { $0.name == "v" })?.value
            guard let videoID, videoID.count == 11,
                  videoID.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                      || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else {
                throw AppError.unknown("The link file must contain a supported HTTPS title link.")
            }
        }
        self.url = url
        self.service = service
    }

    private static func service(host: String, path: String) -> Service? {
        let parts = path.split(separator: "/")
        switch host {
        case "tv.apple.com":
            return parts.dropLast().contains("movie") || parts.dropLast().contains("show")
                || parts.dropLast().contains("episode") ? .appleTV : nil
        case "primevideo.com", "www.primevideo.com":
            return parts.dropLast().contains("detail") ? .primeVideo : nil
        case "amazon.com", "www.amazon.com", "amazon.co.uk", "www.amazon.co.uk",
             "amazon.de", "www.amazon.de", "amazon.co.jp", "www.amazon.co.jp":
            return (path.hasPrefix("/gp/video/detail/") && parts.count >= 4)
                || (path.hasPrefix("/gp/product/") && parts.count >= 3)
                || (path.hasPrefix("/dp/") && parts.count >= 2) ? .primeVideo : nil
        case "youtube.com", "www.youtube.com", "m.youtube.com":
            return path == "/watch" ? .youTube : nil
        case "youtu.be":
            return parts.count == 1 ? .youTube : nil
        case "moviesanywhere.com", "www.moviesanywhere.com":
            return path.hasPrefix("/movie/") && parts.count >= 2 ? .moviesAnywhere : nil
        case "athome.fandango.com", "www.vudu.com", "vudu.com":
            return path.hasPrefix("/content/browse/details/") && parts.count >= 4 ? .fandango : nil
        default:
            return nil
        }
    }

    private enum CodingKeys: String, CodingKey { case url }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let url = try values.decode(URL.self, forKey: .url)
        try self.init(contents: Data(url.absoluteString.utf8))
    }

    public var actionTitle: LocalizedStringResource {
        LocalizedStringResource("Open in \(service.name)", comment: "Open a user-imported title in the named external streaming service.")
    }
}

public extension MediaItem {
    var externalSourceVersion: MediaVersion? {
        if let selectedVersionID {
            return versions.first { ($0.id == selectedVersionID || $0.playbackMediaSourceID == selectedVersionID) && $0.isExternalSource }
        }
        guard !versions.isEmpty, versions.allSatisfy(\.isExternalSource) else { return nil }
        return versions.first(where: \.isDefault) ?? versions.first
    }

    var opensExternalSource: Bool {
        externalSourceVersion != nil
    }
}
