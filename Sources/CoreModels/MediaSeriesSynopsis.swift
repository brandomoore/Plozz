import Foundation

/// Keeps show-level prose attached to its server identity without replacing episode text.
public struct MediaSeriesSynopsis: Codable, Hashable, Sendable {
    public let seriesID: String
    public let sourceAccountID: String?
    public let overview: String?
    public let tagline: String?

    public init?(series: MediaItem) {
        guard series.kind == .series, !series.id.isEmpty else { return nil }
        seriesID = series.id
        sourceAccountID = series.sourceAccountID
        overview = series.overview
        tagline = series.tagline
    }

    public func matches(_ item: MediaItem) -> Bool {
        (item.kind == .episode || item.kind == .season)
            && item.seriesID == seriesID
            && item.sourceAccountID == sourceAccountID
    }
}
