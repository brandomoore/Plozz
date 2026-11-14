import Foundation

public enum UpcomingInterest: String, CaseIterable, Codable, Hashable, Sendable {
    case watching, watchlist, requested

    public var title: LocalizedStringResource {
        switch self {
        case .watching: "Watching"
        case .watchlist: "Watchlist"
        case .requested: "Requested"
        }
    }
}

public enum UpcomingReleaseKind: String, CaseIterable, Codable, Hashable, Sendable {
    case episode, digital, theatrical, physical, premiere, television

    public var title: LocalizedStringResource {
        switch self {
        case .episode: "Episode"
        case .digital: "Digital"
        case .theatrical: "In theaters"
        case .physical: "Physical"
        case .premiere: "Premiere"
        case .television: "On TV"
        }
    }

    public init(_ kind: TitleReleaseEvent.Kind) {
        switch kind {
        case .digital: self = .digital
        case .theatrical, .theatricalLimited: self = .theatrical
        case .physical: self = .physical
        case .premiere: self = .premiere
        case .television: self = .television
        }
    }
}

/// An announced release, not a promise that the media is in a server library.
/// `item` is always the real title used by the existing detail navigation.
public struct UpcomingRelease: Identifiable, Equatable, Sendable {
    public let id: String
    public let titleKey: String
    public var item: MediaItem
    public let date: Date
    public let datePrecision: AirDatePrecision
    public let kind: UpcomingReleaseKind
    public var interests: Set<UpcomingInterest>
    public let episodes: [UpcomingEpisode]
    public let regionCode: String?

    public init(
        id: String, titleKey: String, item: MediaItem, date: Date,
        datePrecision: AirDatePrecision, kind: UpcomingReleaseKind,
        interests: Set<UpcomingInterest>, episodes: [UpcomingEpisode] = [],
        regionCode: String? = nil
    ) {
        self.id = id
        self.titleKey = titleKey
        self.item = item
        self.date = date
        self.datePrecision = datePrecision
        self.kind = kind
        self.interests = interests
        self.episodes = episodes
        self.regionCode = regionCode
    }

    public var subtitle: LocalizedStringResource {
        guard kind == .episode else { return kind.title }
        if let season = episodes.first?.seasonNumber {
            if episodes.count > 1 { return "Season \(season) · \(episodes.count) episodes" }
            if let number = episodes.first?.episodeNumber {
                return "Season \(season) · Episode \(number)"
            }
            return "Season \(season)"
        }
        if episodes.count > 1 { return "\(episodes.count) episodes" }
        if let number = episodes.first?.absoluteEpisodeNumber { return "Episode \(number)" }
        return "New episode"
    }

    public static func titleKey(for item: MediaItem) -> String {
        for case .external(let source, let value) in MediaItemIdentity.identities(for: item) {
            return "\(item.kind.rawValue)|\(source)|\(value)"
        }
        return "\(item.kind.rawValue)|\(item.stablePresentationID)"
    }
}

public struct UpcomingFilters: Equatable, Codable, Sendable {
    public enum MediaType: String, CaseIterable, Codable, Sendable {
        case all, shows, movies

        public var title: LocalizedStringResource {
            switch self {
            case .all: "All"
            case .shows: "Shows"
            case .movies: "Movies"
            }
        }
    }

    public var mediaType: MediaType = .all
    public var interests = Set(UpcomingInterest.allCases)
    public var releaseKinds = Set(UpcomingReleaseKind.allCases)
    public var premieresOnly = false
    public var hideWatchedMovies = false

    public init() {}

    public func includes(_ release: UpcomingRelease) -> Bool {
        guard !interests.isDisjoint(with: release.interests),
            releaseKinds.contains(release.kind)
        else { return false }
        if mediaType == .shows && release.kind != .episode { return false }
        if mediaType == .movies && release.kind == .episode { return false }
        if hideWatchedMovies && release.item.kind == .movie && release.item.isPlayed { return false }
        if premieresOnly && release.kind == .episode {
            return release.episodes.contains { $0.episodeNumber == 1 || $0.absoluteEpisodeNumber == 1 }
        }
        return true
    }
}

public enum UpcomingReleaseBuilder {
    public static func episodes(
        _ episodes: [UpcomingEpisode], for item: MediaItem,
        calendar: Calendar = .current
    ) -> [UpcomingRelease] {
        let titleKey = UpcomingRelease.titleKey(for: item)
        var seen = Set<String>()
        let unique = episodes.sorted { $0.refreshedAt > $1.refreshedAt }.filter {
            let numbered = $0.episodeNumber != nil || $0.absoluteEpisodeNumber != nil
            let key = [
                $0.seasonNumber.map(String.init) ?? "",
                $0.episodeNumber.map(String.init) ?? "",
                $0.absoluteEpisodeNumber.map(String.init) ?? "",
                numbered ? "" : String($0.airDate.timeIntervalSince1970),
            ].joined(separator: "|")
            return seen.insert(key).inserted
        }
        let groups = Dictionary(grouping: unique) {
            "\(calendar.startOfDay(for: $0.airDate).timeIntervalSince1970)|\($0.seasonNumber.map(String.init) ?? "absolute")"
        }
        return groups.map { key, values in
            let ordered = values.sorted {
                if $0.airDate != $1.airDate { return $0.airDate < $1.airDate }
                return ($0.episodeNumber ?? $0.absoluteEpisodeNumber ?? 0)
                    < ($1.episodeNumber ?? $1.absoluteEpisodeNumber ?? 0)
            }
            let first = ordered[0]
            return UpcomingRelease(
                id: "\(titleKey)|episodes|\(key)", titleKey: titleKey, item: item,
                date: first.airDate,
                datePrecision: ordered.count == 1 ? first.datePrecision : .dateOnly,
                kind: .episode, interests: [.watching], episodes: ordered
            )
        }.sorted { $0.date < $1.date }
    }

    public static func movies(
        _ events: [TitleReleaseEvent], for item: MediaItem,
        interests: Set<UpcomingInterest>, regionCode: String,
        calendar: Calendar = .current
    ) -> [UpcomingRelease] {
        let titleKey = UpcomingRelease.titleKey(for: item)
        var seen = Set<String>()
        return events.sorted { $0.date < $1.date }.compactMap { event in
            guard event.regionCode.caseInsensitiveCompare(regionCode) == .orderedSame else { return nil }
            let kind = UpcomingReleaseKind(event.kind)
            let key =
                "\(titleKey)|\(kind.rawValue)|\(regionCode.uppercased())|\(calendar.startOfDay(for: event.date).timeIntervalSince1970)"
            guard seen.insert(key).inserted else { return nil }
            return UpcomingRelease(
                id: key, titleKey: titleKey, item: item, date: event.date,
                datePrecision: .dateOnly, kind: kind, interests: interests,
                regionCode: regionCode.uppercased()
            )
        }
    }

    public static func home(
        _ releases: [UpcomingRelease], hiddenTitles: Set<String> = [],
        now: Date = Date(), calendar: Calendar = .current, limit: Int = 20
    ) -> [UpcomingRelease] {
        let today = calendar.startOfDay(for: now)
        var seen = Set<String>()
        return Array(
            releases.sorted { $0.date < $1.date }.filter {
                $0.date >= today && !hiddenTitles.contains($0.titleKey)
                    && seen.insert($0.titleKey).inserted
            }.prefix(max(0, limit)))
    }
}
