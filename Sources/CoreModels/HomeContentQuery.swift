import Foundation

/// Shared by saved custom rows and temporary browse controls.
public struct HomeContentQuery: Codable, Hashable, Sendable {
    public static let sortFields: [SortField] = [.name, .dateAdded, .releaseDate, .runtime]
    public var sort: SortDescriptor?
    public var media: WatchlistMediaFilter
    public var filters: LibraryFilters

    public init(
        sort: SortDescriptor? = nil, media: WatchlistMediaFilter = .all,
        filters: LibraryFilters = .all
    ) {
        self.sort = sort
        self.media = media
        self.filters = filters
    }

    public var isDefault: Bool { sort == nil && media == .all && filters.isEmpty }
    public var activeFilterCount: Int { filters.activeCount + (media == .all ? 0 : 1) }
    public var sortTitle: LocalizedStringResource { sort?.field.displayName ?? "Source order" }

    public func filterSummary(in locale: Locale) -> String {
        var labels = [filters.summary(in: locale)].filter { !$0.isEmpty }
        if media != .all {
            var title = media.displayName
            title.locale = locale
            labels.insert(String(localized: title), at: 0) // l10n:content — resolves the selected media filter
        }
        return labels.joined(separator: " · ")
    }

    public func applying(to items: [MediaItem], watchlistDates: Bool = false) -> [MediaItem] {
        applying(to: items, watchlistDates: watchlistDates, checkCancellation: {})
    }

    public func applying(
        to items: [MediaItem], watchlistDates: Bool = false, checkCancellation: () throws -> Void
    ) rethrows -> [MediaItem] {
        try checkCancellation()
        guard !isDefault else { return items }
        var visited = 0
        let filtered = try media == .all && filters.isEmpty ? items : items.filter {
            visited += 1
            if visited.isMultiple(of: 256) { try checkCancellation() }
            return (media == .all || (media == .movies ? $0.kind == .movie : [.series, .season, .episode].contains($0.kind)))
                && (filters.isEmpty || LibraryQueryRecord($0, includeFormats: false).matches(filters))
        }
        guard let sort else { return filtered }
        if watchlistDates && sort.field == .dateAdded {
            return WatchlistBrowsePreferences(sort: sort).items(from: filtered)
        }
        return try MediaItemSortOrder.sorted(filtered, by: sort, checkCancellation: checkCancellation)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(sort?.field)
        hasher.combine(sort?.direction)
        hasher.combine(media)
        hasher.combine(filters)
    }
}
