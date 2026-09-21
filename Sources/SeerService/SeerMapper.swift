import Foundation
import CoreModels

/// Pure DTO → `MediaItem` mapping for Seerr results, plus TMDB image URL
/// construction. Kept free of networking and `@MainActor` so it's exhaustively
/// unit-testable off-device.
enum SeerMapper {
    /// TMDB image CDN base. Poster/backdrop paths from Seerr are relative
    /// (`/abc.jpg`) and resolve as `{base}{size}{path}`.
    static let tmdbImageBase = "https://image.tmdb.org/t/p/"

    /// Size buckets chosen for tvOS: a grid-friendly poster, a rail-friendly
    /// backdrop, and a full-bleed hero backdrop.
    static let posterSize = "w500"
    static let backdropSize = "w780"
    static let heroBackdropSize = "w1280"

    /// Builds a full TMDB image URL from a relative path, or `nil` when the path
    /// is absent/blank.
    static func imageURL(path: String?, size: String) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        // Paths are already absolute-from-root ("/abc.jpg"); guard against a
        // stray leading-slash mismatch either way.
        let normalized = path.hasPrefix("/") ? path : "/\(path)"
        return URL(string: "\(tmdbImageBase)\(size)\(normalized)")
    }

    /// The stable `MediaItem.id` for a Seerr title. TMDB movie and TV identifiers
    /// occupy separate namespaces, so kind must be included to keep discovery
    /// slides and their artwork/request state uniquely addressable.
    static func itemID(tmdbID: Int, kind: MediaItemKind) -> String {
        "seer:\(kind.rawValue):\(tmdbID)"
    }

    /// Extracts a production year from a TMDB date string (`YYYY-MM-DD`).
    static func year(from date: String?) -> Int? {
        guard let date, date.count >= 4 else { return nil }
        return Int(date.prefix(4))
    }

    /// Maps one discover/search result to a `MediaItem`, or `nil` when it isn't a
    /// playable/browsable title (people, or a title with no usable name).
    static func mediaItem(from result: SeerDiscoverResult) -> MediaItem? {
        let kind: MediaItemKind
        switch result.mediaType.lowercased() {
        case "tv": kind = .series
        case "movie": kind = .movie
        default: return nil // "person" and anything unexpected
        }

        // Movies carry `title`, TV carries `name`; fall back across both so a
        // mis-tagged result still maps.
        guard let title = (result.title ?? result.name)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else { return nil }

        // An untracked discovery title (no `mediaInfo`) isn't in the library and
        // hasn't been requested — for a **featured** item that means "requestable"
        // (`.unknown`), NOT `nil`. `nil` is reserved for ordinary library items and
        // would make the hero show a dead "Play" for something you don't have. A
        // present-but-unrecognized status also falls back to `.unknown`.
        let status = result.mediaInfo?.status.flatMap(MediaAvailabilityStatus.init(rawValue:)) ?? .unknown

        return MediaItem(
            id: itemID(tmdbID: result.id, kind: kind),
            title: title,
            originalTitle: result.originalTitle ?? result.originalName,
            kind: kind,
            overview: result.overview,
            productionYear: year(from: result.releaseDate ?? result.firstAirDate),
            releaseDate: MediaItem.calendarDayReleaseDate(
                from: result.releaseDate ?? result.firstAirDate
            ),
            posterURL: imageURL(path: result.posterPath, size: posterSize),
            backdropURL: imageURL(path: result.backdropPath, size: backdropSize),
            heroBackdropURL: imageURL(path: result.backdropPath, size: heroBackdropSize),
            providerIDs: ["Tmdb": String(result.id)],
            availability: status,
            locallyValidatedPlayableSource: false,
            downloadProgress: downloadProgress(from: result.mediaInfo?.downloadStatus)
        )
    }

    /// Aggregate fetched fraction across a title's active download queue items:
    /// `Σ(size - sizeLeft) / Σ size`. Returns `nil` when nothing is downloading,
    /// no usable sizes are reported (queued but size unknown), OR the fetched
    /// fraction wouldn't yet display as at least 1% — a just-grabbed item reports
    /// `sizeLeft ≈ size` (≈0%), which should read as "Requested" rather than a
    /// stuck "Downloading 0%". Never returns `1` (a fully-fetched title reports as
    /// available, not downloading), so a non-nil result is always a live `1...99%`.
    static func downloadProgress(from items: [SeerDownloadingItem]?) -> Double? {
        guard let items, !items.isEmpty else { return nil }
        var totalSize = 0.0
        var totalLeft = 0.0
        for item in items {
            guard let size = item.size, size > 0 else { continue }
            let left = max(0, min(size, item.sizeLeft ?? size))
            totalSize += size
            totalLeft += left
        }
        guard totalSize > 0 else { return nil }
        let fraction = (totalSize - totalLeft) / totalSize
        // Below ~0.5% rounds to "0%" — treat that as not-yet-downloading.
        guard fraction >= 0.005 else { return nil }
        return min(0.999, fraction)
    }

    /// Maps a page of results to `MediaItem`s, dropping people/unmappable
    /// entries, and caps to `limit` (0 or negative = no cap).
    static func mediaItems(from page: SeerDiscoverPage, limit: Int = 0) -> [MediaItem] {
        let mapped = page.results.compactMap(mediaItem(from:))
        guard limit > 0 else { return mapped }
        return Array(mapped.prefix(limit))
    }

    /// Combines TMDB's complete numbered-season list with Seerr's tracked-season
    /// statuses. A numbered season absent from `mediaInfo.seasons` is untracked and
    /// therefore requestable (`unknown`). Specials (season 0) stay out of Plozz's
    /// simple request picker.
    static func requestAvailability(from details: SeerMediaDetails) -> MediaRequestAvailability {
        var titles: [Int: String] = [:]
        for season in details.seasons where season.seasonNumber > 0 {
            let title = season.name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? "Season \(season.seasonNumber)"
            if titles[season.seasonNumber] == nil
                || titles[season.seasonNumber] == "Season \(season.seasonNumber)" {
                titles[season.seasonNumber] = title
            }
        }

        var tracked: [Int: MediaAvailabilityStatus] = [:]
        for season in details.mediaInfo?.seasons ?? [] where season.seasonNumber > 0 {
            let status = season.status.flatMap(MediaAvailabilityStatus.init(rawValue:)) ?? .unknown
            tracked[season.seasonNumber] = preferredAvailability(
                tracked[season.seasonNumber] ?? .unknown,
                status
            )
        }

        var requestStatuses: [Int: MediaSeasonRequestStatus] = [:]
        // MediaRequestStatus: pending=1, approved=2, declined=3, failed=4,
        // completed=5. Workflow remains separate from availability because a
        // partially imported season may still have an active request.
        for request in details.mediaInfo?.requests ?? [] where request.is4k != true {
            guard let requestStatus = request.status,
                  let parentWorkflow = requestWorkflow(from: requestStatus)
            else { continue }
            for season in request.seasons {
                guard season.seasonNumber > 0 else { continue }
                if titles[season.seasonNumber] == nil {
                    titles[season.seasonNumber] = "Season \(season.seasonNumber)"
                }
                let seasonWorkflow = season.status.flatMap(requestWorkflow(from:))
                let workflow: MediaSeasonRequestStatus
                if seasonWorkflow == .completed {
                    workflow = .completed
                } else {
                    switch parentWorkflow {
                    case .failed, .declined, .completed:
                        workflow = parentWorkflow
                    case .pending, .processing:
                        workflow = seasonWorkflow ?? parentWorkflow
                    }
                }
                requestStatuses[season.seasonNumber] = preferredRequestWorkflow(
                    requestStatuses[season.seasonNumber],
                    workflow
                )
            }
        }

        for season in details.seasons where season.seasonNumber > 0 {
            if tracked[season.seasonNumber] == nil {
                tracked[season.seasonNumber] = .unknown
            }
        }

        let seasons = Set(titles.keys)
            .union(tracked.keys)
            .sorted()
            .map { number in
                let coverage = tracked[number] ?? .unknown
                let workflow = coverage == .available ? nil : requestStatuses[number]
                let status: MediaAvailabilityStatus
                if coverage.isRequestable {
                    switch workflow {
                    case .pending, .failed: status = .pending
                    case .processing: status = .processing
                    case .declined, .completed, nil: status = coverage
                    }
                } else {
                    status = coverage
                }
                return MediaSeasonRequestState(
                    number: number,
                    title: titles[number] ?? "Season \(number)",
                    status: status,
                    requestFailed: workflow == .failed,
                    requestStatus: workflow
                )
            }
        return MediaRequestAvailability(
            status: details.mediaInfo?.status.flatMap(MediaAvailabilityStatus.init(rawValue:)) ?? .unknown,
            downloadProgress: downloadProgress(from: details.mediaInfo?.downloadStatus),
            seasons: seasons
        )
    }

    private static func preferredAvailability(
        _ lhs: MediaAvailabilityStatus,
        _ rhs: MediaAvailabilityStatus
    ) -> MediaAvailabilityStatus {
        func rank(_ status: MediaAvailabilityStatus) -> Int {
            switch status {
            case .available: 60
            case .partiallyAvailable: 50
            case .processing: 40
            case .pending: 30
            case .deleted: 20
            case .unknown: 10
            }
        }
        return rank(lhs) >= rank(rhs) ? lhs : rhs
    }

    private static func requestWorkflow(from rawValue: Int) -> MediaSeasonRequestStatus? {
        switch rawValue {
        case 1: .pending
        case 2: .processing
        case 3: .declined
        case 4: .failed
        case 5: .completed
        default: nil
        }
    }

    private static func preferredRequestWorkflow(
        _ lhs: MediaSeasonRequestStatus?,
        _ rhs: MediaSeasonRequestStatus
    ) -> MediaSeasonRequestStatus {
        func rank(_ status: MediaSeasonRequestStatus?) -> Int {
            switch status {
            case .processing: 60
            case .pending: 50
            case .failed: 40
            case .declined: 30
            case .completed: 20
            case nil: 10
            }
        }
        guard let lhs else { return rhs }
        return rank(lhs) >= rank(rhs) ? lhs : rhs
    }

    // MARK: - Request derivation

    /// The Seerr `mediaType` string for a `MediaItem`, or `nil` when the item
    /// isn't a movie/series (only those are requestable).
    static func requestMediaType(for item: MediaItem) -> String? {
        switch item.kind {
        case .movie: return "movie"
        case .series: return "tv"
        default: return nil
        }
    }

    /// The TMDB id to request for an item: prefers the `Tmdb` provider id, then
    /// parses either a current `seer:<kind>:<id>` or legacy `seer:<id>` synthetic
    /// id. `nil` when neither yields an integer.
    static func tmdbID(for item: MediaItem) -> Int? {
        if let raw = item.providerID(.tmdb), let value = Int(raw) {
            return value
        }
        if item.id.hasPrefix("seer:"),
           let raw = item.id.split(separator: ":").last,
           let value = Int(raw)
        {
            return value
        }
        return nil
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
