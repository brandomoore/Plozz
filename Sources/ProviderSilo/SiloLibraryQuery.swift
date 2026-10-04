import Foundation
import CoreModels
import CoreNetworking

extension SiloProvider: MediaLibraryQueryProviding {
    public func prepareLibraryQueryCapabilities() async throws {
        guard libraryRatings.needsRefresh else { return }
        struct Ratings: Decodable, Sendable {
            struct Source: Decodable, Sendable { let source: String }
            let allowed: Bool
            let state: String
            let sources: [Source]
        }
        do {
            let ratings: Ratings = try await client.request("/capabilities/ratings")
            libraryRatings.replace(ratings.allowed && ratings.state == "available" ? Set(ratings.sources.map(\.source)) : Set<String>())
        } catch AppError.notFound {
            PlozzLog.networking.info("Silo ratings capability is unavailable; retaining basic library sorts.")
            libraryRatings.replace([])
        }
    }
    public func libraryQueryInventorySortKey(_ field: SortField) -> SortField {
        [.plays, .lastPlayed, .progress].contains(field) ? field : .name
    }
    public func libraryQueryCapabilities(in containerID: String, kind: MediaItemKind) -> LibraryQueryCapabilities {
        LibraryQueryCapabilities(
            filters: LibraryFilter.allCases,
            nativeFilters: [.all, .hdr, .dolbyVision, .unwatched, .inProgress, .unmatched],
            nativeSortFields: Set(supportedSortFields(in: containerID, kind: kind)),
            supportsGenres: true, supportsYears: true, nativeFacets: true
        )
    }

    static func libraryFilterQuery(_ filters: LibraryFilters) throws -> [URLQueryItem] {
        struct Rule: Encodable { let field: String; let op = "is"; let value: Bool }
        struct Group: Encodable { let match = "all"; let rules: [Rule] }
        var query: [URLQueryItem] = []
        let rule: Rule?
        switch filters.filter {
        case .all: rule = nil
        case .hdr: rule = Rule(field: "hdr", value: true)
        case .dolbyVision: rule = Rule(field: "dolby_vision", value: true)
        case .unwatched: rule = Rule(field: "watched", value: false)
        case .inProgress: rule = Rule(field: "in_progress", value: true)
        case .unmatched: rule = nil; query.append(.init(name: "status", value: "unmatched"))
        case .hdr10Plus, .atmos, .duplicates: throw AppError.invalidResponse
        }
        if let rule {
            let data = try JSONEncoder().encode([Group(rules: [rule])])
            query.append(.init(name: "groups", value: String(decoding: data, as: UTF8.self)))
        }
        if let genre = filters.genre { query.append(.init(name: "genre", value: genre)) }
        if let year = filters.year {
            query += [.init(name: "year_min", value: String(year)), .init(name: "year_max", value: String(year))]
        }
        return query
    }

    public func libraryQueryFacets(in containerID: String, kind: MediaItemKind) async throws -> LibraryQueryFacets {
        struct Facets: Decodable { let genres: [String] }
        let response: Facets = try await client.request("/catalog/filters", query: [
            .init(name: "library_id", value: containerID), .init(name: "type", value: kind.rawValue),
            .init(name: "skip_technical", value: "true")
        ])
        // Two one-card extrema queries, never a catalog scan to populate a menu.
        let scope: [URLQueryItem] = [.init(name: "library_id", value: containerID),
                                    .init(name: "type", value: kind.rawValue), .init(name: "year_min", value: "1")]
        async let oldest = catalogPage(scope, page: .init(limit: 1, sort: .init(field: .year, direction: .ascending)), libraryID: containerID)
        async let newest = catalogPage(scope, page: .init(limit: 1, sort: .init(field: .year, direction: .descending)), libraryID: containerID)
        let (first, last) = try await (oldest, newest)
        let minimum = first.items.first?.productionYear
        let maximum = last.items.first?.productionYear
        let years: [Int]
        if let minimum, let maximum, minimum > 0, maximum >= minimum, maximum - minimum <= 300 {
            years = Array(minimum...maximum)
        } else { years = [] }
        return LibraryQueryFacets(genres: response.genres, years: years)
    }

    public func libraryQueryInventory(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        let nativeSort = supportedSortFields(in: containerID, kind: kind).contains(page.sort.field) ? page.sort : .default
        var result = try await items(
            in: containerID, kind: kind,
            page: .init(startIndex: page.startIndex, limit: page.limit, sort: nativeSort)
        )
        if page.filters.filter.needsFileMetadata && kind != .series {
            // Catalog overlays describe only the preferred file. Read all accessible
            // versions explicitly, at most two detail requests at a time.
            var hydrated: [MediaItem] = []
            for offset in stride(from: 0, to: result.items.count, by: 2) {
                try Task.checkCancellation()
                let batch = Array(result.items[offset..<min(offset + 2, result.items.count)])
                let items = try await withThrowingTaskGroup(of: (Int, MediaItem).self) { group in
                    for (index, summary) in batch.enumerated() {
                        group.addTask { [self] in
                            var detail = try await item(id: summary.id)
                            let hasAtmos = detail.librarySortValues?.hasAtmos
                            detail.librarySortValues = summary.librarySortValues
                            detail.librarySortValues?.hasAtmos = hasAtmos
                            detail.lastPlayedAt = summary.lastPlayedAt ?? detail.lastPlayedAt
                            detail.playedPercentage = summary.playedPercentage ?? detail.playedPercentage
                            detail.libraryID = containerID
                            return (index, detail)
                        }
                    }

                    var items: [(Int, MediaItem)] = []
                    for try await item in group { items.append(item) }
                    return items.sorted { $0.0 < $1.0 }.map(\.1)
                }
                hydrated += items
            }
            result = MediaPage(items: hydrated, startIndex: result.startIndex, totalCount: result.totalCount)
        }
        return result
    }

    public func libraryQueryEpisodeInventory(in containerID: String, page: PageRequest) async throws -> MediaPage {
        try await libraryQueryInventory(in: containerID, kind: .episode, page: page)
    }
}

final class SiloLibraryRatings: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: Set<String> = []
    private var loadedAt: Date?

    var needsRefresh: Bool { lock.withLock { loadedAt.map { Date().timeIntervalSince($0) >= 120 } ?? true } }
    func contains(_ source: String) -> Bool { lock.withLock { sources.contains(source) } }
    func replace(_ values: Set<String>) {
        lock.withLock {
            sources = values
            loadedAt = Date()
        }
    }
}
