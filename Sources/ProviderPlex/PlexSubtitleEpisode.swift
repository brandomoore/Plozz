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
        let release = String(title[..<marker.lowerBound])
        let releaseWords = Self.words(release)
        guard !releaseWords.isEmpty, !seriesWords.isEmpty else { return .unknown }
        if Self.matchesSeries(releaseWords, seriesWords) { return .confirmed }
        // Releases may either split at an apostrophe or omit it entirely.
        return Self.matchesSeries(Self.words(release, elidingApostrophes: true),
                                  Self.words(series, elidingApostrophes: true)) ? .confirmed : .conflict
    }

    private static func matchesSeries(_ release: [String], _ series: [String]) -> Bool {
        guard !series.isEmpty else { return false }
        if release == series { return true }
        // Release names often add the premiere year to distinguish reboots.
        guard let year = release.last, year.count == 4, Int(year) != nil else { return false }
        return release.dropLast().elementsEqual(series)
    }

    private static func words(_ title: String, elidingApostrophes: Bool = false) -> [String] {
        var folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                                   locale: Locale(identifier: "en_US_POSIX"))
        if elidingApostrophes { folded.removeAll { $0 == "'" || $0 == "\u{2019}" || $0 == "\u{02BC}" } }
        return folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
