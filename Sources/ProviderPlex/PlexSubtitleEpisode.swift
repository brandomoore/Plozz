import Foundation

/// Plex subtitle results expose release names rather than structured series/episode IDs.
struct PlexSubtitleEpisode {
    enum Match { case confirmed, conflict, unknown }

    let series: String
    private let season: Int
    private let episode: Int
    private let seriesWords: [String]

    init?(_ item: PlexMetadata) {
        guard item.type == "episode",
              let series = item.grandparentTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !series.isEmpty, let season = item.parentIndex, let episode = item.index else { return nil }
        self.series = series
        self.season = season
        self.episode = episode
        seriesWords = Self.words(series)
    }

    private static let ordinal = try! NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\p{N}])(?:s([0-9]{1,3})[ ._-]*e([0-9]{1,4})|([0-9]{1,2})x([0-9]{1,3}))(?![0-9])"#
    )

    func match(_ title: String?) -> Match {
        guard let title, let token = Self.ordinal.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let marker = Range(token.range, in: title) else { return .unknown }
        let group = token.range(at: 1).location == NSNotFound ? 3 : 1
        guard let s = Range(token.range(at: group), in: title),
              let e = Range(token.range(at: group + 1), in: title),
              Int(title[s]) == season, Int(title[e]) == episode else { return .conflict }
        var releaseWords = Self.words(String(title[..<marker.lowerBound]))
        guard !releaseWords.isEmpty, !seriesWords.isEmpty else { return .unknown }
        if releaseWords == seriesWords { return .confirmed }
        // Release names often add the premiere year to distinguish reboots.
        if let last = releaseWords.last, last.count == 4, Int(last) != nil {
            releaseWords.removeLast()
            if releaseWords == seriesWords { return .confirmed }
        }
        return .conflict
    }

    private static func words(_ title: String) -> [String] {
        title.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
