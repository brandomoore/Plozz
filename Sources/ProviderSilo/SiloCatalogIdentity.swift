import CoreModels
import Foundation

/// Silo's frozen content-id scheme encodes a provider anchor. Catalog cards
/// omit the explicit provider-id fields that item details carry.
struct SiloCatalogIdentity {
    let providerIDs: [String: String]
    let seriesID: String?
    let seasonNumber: Int?
    let episodeNumber: Int?

    static func parse(_ id: String, kind: MediaItemKind) -> Self? {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0] == kind.rawValue else { return nil }
        let key: String
        switch parts[1] {
        case "tmdb": key = "Tmdb"
        case "tvdb": key = "Tvdb"
        case "imdb": key = "Imdb"
        default: return nil
        }
        let value = parts[2]
        if key == "Imdb" {
            guard value.hasPrefix("tt"), digits(String(value.dropFirst(2))) else { return nil }
        } else {
            guard digits(value) else { return nil }
        }
        switch kind {
        case .movie, .series:
            guard parts.count == 3 else { return nil }
            return Self(providerIDs: [key: value], seriesID: nil, seasonNumber: nil, episodeNumber: nil)
        case .season, .episode:
            guard parts.count == (kind == .season ? 4 : 5),
                  digits(parts[3]), let season = Int(parts[3]) else { return nil }
            let episode: Int?
            if kind == .episode {
                guard digits(parts[4]), let number = Int(parts[4]) else { return nil }
                episode = number
            } else { episode = nil }
            return Self(providerIDs: ["Series" + key: value],
                        seriesID: "series-\(parts[1])-\(value)",
                        seasonNumber: season, episodeNumber: episode)
        default: return nil
        }
    }

    private static func digits(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }
}
