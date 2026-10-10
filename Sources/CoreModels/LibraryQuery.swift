import Foundation

public enum LibraryFilter: String, CaseIterable, Codable, Sendable {
    case all
    case hdr
    case dolbyVision
    case hdr10Plus
    case atmos
    case unwatched
    case inProgress
    case unmatched
    case duplicates

    public enum DisplayName: Sendable {
        case localized(LocalizedStringResource)
        case format(String)
    }

    public var displayName: DisplayName {
        switch self {
        case .all: return .localized("All")
        case .hdr: return .format("HDR")
        case .dolbyVision: return .format("Dolby Vision")
        case .hdr10Plus: return .format("HDR10+")
        case .atmos: return .format("Atmos")
        case .unwatched: return .localized("Unwatched")
        case .inProgress: return .localized("In Progress")
        case .unmatched: return .localized("Unmatched")
        case .duplicates: return .localized("Duplicates")
        }
    }

    public var needsFileMetadata: Bool {
        [.hdr, .dolbyVision, .hdr10Plus, .atmos, .duplicates].contains(self)
    }
}

/// Independent genre/year facets intersect the selected quick filter.
public struct LibraryFilters: Codable, Hashable, Sendable {
    public var filter: LibraryFilter
    /// Server genre label, not a provider-local tag ID.
    public var genre: String?
    public var year: Int?

    public init(filter: LibraryFilter = .all, genre: String? = nil, year: Int? = nil) {
        self.filter = filter
        self.genre = genre
        self.year = year
    }

    public static let all = Self()
    public var isEmpty: Bool { self == .all }
    public var activeCount: Int {
        (filter == .all ? 0 : 1) + (genre == nil ? 0 : 1) + (year == nil ? 0 : 1)
    }

    public func summary(in locale: Locale) -> String {
        var values: [String] = []
        if filter != .all {
            switch filter.displayName {
            case .localized(var name):
                name.locale = locale
                values.append(String(localized: name)) // l10n:content — resolves the existing quick-filter label for presentation
            case .format(let name):
                values.append(name)
            }
        }
        if let genre { values.append(genre) }
        if let year { values.append(String(year)) }
        return values.joined(separator: " · ")
    }
}

public struct LibraryQueryFacets: Equatable, Sendable {
    public var genres: [String]
    public var years: [Int]

    public init(genres: [String] = [], years: [Int] = []) {
        self.genres = Array(Set(genres.filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        self.years = Array(Set(years)).sorted(by: >)
    }
}

public struct LibraryQueryCapabilities: Equatable, Sendable {
    public var filters: [LibraryFilter]
    public var nativeFilters: Set<LibraryFilter>
    public var nativeSortFields: Set<SortField>
    public var supportsGenres: Bool
    public var supportsYears: Bool
    public var nativeFacets: Bool

    public init(
        filters: [LibraryFilter] = [.all],
        nativeFilters: Set<LibraryFilter> = [.all],
        nativeSortFields: Set<SortField> = Set(SortField.legacyFields),
        supportsGenres: Bool = false,
        supportsYears: Bool = false,
        nativeFacets: Bool = false
    ) {
        self.filters = filters
        self.nativeFilters = nativeFilters
        self.nativeSortFields = nativeSortFields
        self.supportsGenres = supportsGenres
        self.supportsYears = supportsYears
        self.nativeFacets = nativeFacets
    }

    public func needsIndex(for page: PageRequest) -> Bool {
        !nativeFilters.contains(page.filters.filter)
            || !nativeSortFields.contains(page.sort.field)
            || (!nativeFacets && (page.filters.genre != nil || page.filters.year != nil))
    }
}

/// Original server sort inputs, separate from externally enriched display ratings.
public struct LibrarySortValues: Codable, Hashable, Sendable {
    public var sortName: String?
    public var dateAdded: Date?
    /// Ratings use a common 0...100 scale.
    public var audienceRating: Double?
    public var criticRating: Double?
    public var userRating: Double?
    public var playCount: Int?
    public var watched: Bool?
    public var matched: Bool?
    public var episodeWatchRollup: Bool?
    public var hasAtmos: Bool?

    public init(
        sortName: String? = nil, dateAdded: Date? = nil,
        audienceRating: Double? = nil, criticRating: Double? = nil,
        userRating: Double? = nil, playCount: Int? = nil,
        watched: Bool? = nil, matched: Bool? = nil, episodeWatchRollup: Bool? = nil,
        hasAtmos: Bool? = nil
    ) {
        self.sortName = sortName
        self.dateAdded = dateAdded
        self.audienceRating = audienceRating
        self.criticRating = criticRating
        self.userRating = userRating
        self.playCount = playCount
        self.watched = watched
        self.matched = matched
        self.episodeWatchRollup = episodeWatchRollup
        self.hasAtmos = hasAtmos
    }
}

/// Native queries remain paged. Only explicitly requested unsupported options
/// use the lightweight inventory; ordinary browsing never starts an inventory.
public protocol MediaLibraryQueryProviding: MediaProvider, MediaSortFieldProviding {
    func prepareLibraryQueryCapabilities() async throws
    func libraryQueryCapabilities(in containerID: String, kind: MediaItemKind)
        -> LibraryQueryCapabilities
    func libraryQueryFacets(in containerID: String, kind: MediaItemKind) async throws
        -> LibraryQueryFacets
    func libraryQueryInventory(in containerID: String, kind: MediaItemKind, page: PageRequest)
        async throws -> MediaPage
    func libraryQueryEpisodeInventory(in containerID: String, page: PageRequest) async throws
        -> MediaPage
    func finishLibraryQueryInventory() async
    func libraryQueryItem(_ reference: LibraryQueryReference) async throws -> MediaItem
    func libraryQueryMergeInventory(_ records: [LibraryQueryRecord]) -> [LibraryQueryRecord]
    func libraryQueryInventorySortKey(_ field: SortField) -> SortField
    func libraryQueryLetterIndex(in containerID: String, kind: MediaItemKind, page: PageRequest)
        async throws -> [LibraryLetterIndexEntry]
    func libraryQueryLetterPosition(
        in containerID: String, kind: MediaItemKind, letter: String, page: PageRequest
    ) async throws -> Int?
}

extension MediaLibraryQueryProviding {
    public func prepareLibraryQueryCapabilities() async throws {}
    public func libraryQueryMergeInventory(_ records: [LibraryQueryRecord]) -> [LibraryQueryRecord]
    {
        records
    }
    public func libraryQueryInventorySortKey(_ field: SortField) -> SortField { .name }
    public func finishLibraryQueryInventory() async {}

    public func libraryQueryItem(_ reference: LibraryQueryReference) async throws -> MediaItem {
        try await item(id: reference.id)
    }
    public func libraryQueryInventory(
        in containerID: String, kind: MediaItemKind, page: PageRequest
    )
        async throws -> MediaPage
    {
        try await items(in: containerID, kind: kind, page: page)
    }
}

public struct LibraryQueryReference: Sendable {
    public var id: String
    public var accountID: String?
    public var sources: [MediaSourceRef]

    public init(id: String, accountID: String? = nil, sources: [MediaSourceRef] = []) {
        self.id = id
        self.accountID = accountID
        self.sources = sources
    }
}

/// An inventory retains IDs and query facts, never posters, full descriptions,
/// cast lists, subtitle tracks, or authenticated resource URLs.
public struct LibraryQueryRecord: Sendable {
    public var reference: LibraryQueryReference
    public var title: String
    public var originalTitle: String?
    public var sortName: String
    public var kind: MediaItemKind
    public var year: Int?
    public var releaseDate: Date?
    public var contentRating: String?
    public var genres: [String]
    public var runtime: Double?
    public var isPlayed: Bool
    public var inProgress: Bool
    public var progress: Double
    public var lastPlayed: Date?
    public var seriesID: String?
    public var providerIDs: [String: String]
    public var rejectedSourceIDs: Set<String>
    public var seasonNumber: Int?
    public var episodeNumber: Int?
    public var completed: Bool
    public var values: LibrarySortValues?
    public var matched: Bool
    public var duplicates: Bool
    private var formats: UInt8

    public init(_ item: MediaItem, includeFormats: Bool = true) {
        reference = LibraryQueryReference(
            id: item.id, accountID: item.sourceAccountID,
            sources: item.sources.map { source in
                var copy = source
                copy.versions = []
                return copy
            }
        )
        title = item.title
        originalTitle = item.originalTitle
        sortName = MediaItemSortOrder.sortName(item)
        kind = item.kind
        year = item.productionYear
        releaseDate = item.releaseDate
        if releaseDate == nil, let year = item.productionYear, (1...9999).contains(year) {
            releaseDate = Calendar(identifier: .gregorian).date(
                from: DateComponents(year: year, month: 1, day: 1))
        }
        contentRating = item.officialRating
        genres = item.genres
        runtime = item.runtime
        isPlayed = item.isPlayed
        completed = item.librarySortValues?.watched ?? item.isPlayed
        let resumed = item.runtime.flatMap { duration in
            duration > 0 ? item.resumePosition.map { $0 / duration } : nil
        }
        progress = min(1, max(0, item.playedPercentage ?? resumed ?? (item.isPlayed ? 1 : 0)))
        inProgress = !item.isPlayed && ((item.resumePosition ?? 0) > 0 || progress > 0)
        lastPlayed = item.lastPlayedAt
        seriesID = item.seriesID
        providerIDs = item.providerIDs
        rejectedSourceIDs = item.rejectedSourceIDs
        seasonNumber = item.seasonNumber
        episodeNumber = item.episodeNumber
        values = item.librarySortValues
        if values == nil { values = LibrarySortValues() }
        if values?.audienceRating == nil {
            values?.audienceRating = item.ratings.first {
                $0.cohort == .community || $0.cohort == .audience
            }.map { $0.normalized * 100 }
        }
        if values?.criticRating == nil {
            values?.criticRating = item.ratings.first { $0.cohort == .critics }.map {
                $0.normalized * 100
            }
        }
        matched = item.librarySortValues?.matched ?? item.providerIDs.contains { !$0.value.isEmpty }
        duplicates = Set(item.versions.map(\.id)).count > 1
            || Set(item.sources.map(\.id)).count > 1 || item.allSourceAccountIDs.count > 1
        formats = item.librarySortValues?.hasAtmos == true ? 8 : 0
        guard includeFormats else { return }
        for metadata in item.versions.compactMap(\.sourceMetadata)
            + [item.mediaInfo].compactMap({ $0 })
        {
            let range = metadata.dynamicRangeBadges
            if range.contains(where: { $0.style == .hdr || $0.style == .dolby }) { formats |= 1 }
            if range.contains(where: { $0.label == "Dolby Vision" }) { formats |= 2 }
            if range.contains(where: { $0.label == "HDR10+" }) { formats |= 4 }
            if metadata.audioBadges.contains(where: { $0.label == "Dolby Atmos" }) { formats |= 8 }
        }
        for version in item.versions {
            if version.isHDR { formats |= 1 }
            if version.hdrLabel == "Dolby Vision" { formats |= 2 }
            if version.hdrLabel == "HDR10+" { formats |= 4 }
            if version.audioLabel == "Atmos" || version.audioLabel == "Dolby Atmos" { formats |= 8 }
        }
    }

    public var identityKey: String {
        LibraryBrowsePreferencesStore.address(
            accountID: reference.accountID ?? "", libraryID: reference.id, mode: kind.rawValue)
    }

    public var identityItem: MediaItem {
        MediaItem(
            id: reference.id, title: title, originalTitle: originalTitle, kind: kind,
            productionYear: year, releaseDate: releaseDate,
            officialRating: contentRating, genres: genres, seriesID: seriesID,
            runtime: runtime, resumePosition: inProgress ? max(1, progress * (runtime ?? 1)) : nil,
            playedPercentage: progress, isPlayed: isPlayed, hasBeenPlayed: completed || inProgress,
            providerIDs: providerIDs,
            sourceAccountID: reference.accountID, sources: reference.sources,
            rejectedSourceIDs: rejectedSourceIDs,
            lastPlayedAt: lastPlayed, librarySortValues: values
        )
    }

    public mutating func includeAlternativeFacts(_ other: Self) {
        formats |= other.formats
        duplicates =
            duplicates || other.duplicates || identityKey != other.identityKey
        matched = matched || other.matched
        if values == nil { values = LibrarySortValues() }
        if values?.audienceRating == nil { values?.audienceRating = other.values?.audienceRating }
        if values?.criticRating == nil { values?.criticRating = other.values?.criticRating }
        if values?.userRating == nil { values?.userRating = other.values?.userRating }
        let playCount = [values?.playCount, other.values?.playCount].compactMap { $0 }.max()
        values?.playCount = playCount
    }

    public var estimatedStorageBytes: Int {
        var bytes: Int = MemoryLayout<Self>.stride
        bytes += title.utf8.count
        bytes += sortName.utf8.count
        bytes += originalTitle?.utf8.count ?? 0
        bytes += contentRating?.utf8.count ?? 0
        bytes += reference.id.utf8.count
        bytes += reference.accountID?.utf8.count ?? 0
        bytes += seriesID?.utf8.count ?? 0
        for genre in genres {
            bytes += genre.utf8.count + 24
        }
        for source in reference.sources {
            bytes += MemoryLayout<MediaSourceRef>.stride
            bytes += source.accountID.utf8.count
            bytes += source.itemID.utf8.count
            bytes += source.libraryID?.utf8.count ?? 0
            bytes += source.serverName?.utf8.count ?? 0
            bytes += source.accountName?.utf8.count ?? 0
            bytes += source.edition?.utf8.count ?? 0
        }
        for (key, value) in providerIDs {
            bytes += key.utf8.count + value.utf8.count + 48
        }
        for id in rejectedSourceIDs { bytes += id.utf8.count + 24 }
        return bytes
    }

    public mutating func includeEpisodeFacts(_ episode: Self) {
        formats |= episode.formats
        duplicates = duplicates || episode.duplicates
        if !isPlayed && (episode.inProgress || episode.isPlayed) { inProgress = true }
    }

    public mutating func includeFileFacts(_ other: Self) {
        formats |= other.formats
        duplicates = duplicates || other.duplicates
    }

    public func applyingRollup(to item: MediaItem) -> MediaItem {
        var result = item
        result.rejectedSourceIDs.formUnion(rejectedSourceIDs)
        result.sources.removeAll { result.rejectedSourceIDs.contains($0.id) }
        guard values?.episodeWatchRollup == true else { return result }
        result.isPlayed = isPlayed
        result.hasBeenPlayed = completed || inProgress
        result.playedPercentage = progress
        result.lastPlayedAt = lastPlayed
        result.librarySortValues = values
        return result
    }

    public func matches(_ filters: LibraryFilters) -> Bool {
        if let genre = filters.genre,
            !genres.contains(where: { $0.caseInsensitiveCompare(genre) == .orderedSame })
        {
            return false
        }
        if let year = filters.year, self.year != year { return false }
        switch filters.filter {
        case .all: return true
        case .hdr: return formats & 1 != 0
        case .dolbyVision: return formats & 2 != 0
        case .hdr10Plus: return formats & 4 != 0
        case .atmos: return formats & 8 != 0
        case .unwatched: return !completed
        case .inProgress: return inProgress
        case .unmatched: return !matched
        case .duplicates: return duplicates
        }
    }

    public func isOrdered(before other: Self, by sort: SortDescriptor) -> Bool {
        let ascending = sort.direction == .ascending
        func compare<T: Comparable>(_ left: T?, _ right: T?) -> Bool? {
            switch (left, right) {
            case (let left?, let right?) where left != right:
                return ascending ? left < right : left > right
            case (nil, .some): return false
            case (.some, nil): return true
            default: return nil
            }
        }
        let order: Bool?
        switch sort.field {
        case .name:
            let result = sortName.compare(
                other.sortName, options: [.numeric, .caseInsensitive, .diacriticInsensitive])
            order =
                result == .orderedSame
                ? nil : (ascending ? result == .orderedAscending : result == .orderedDescending)
        case .year: order = compare(year, other.year)
        case .releaseDate: order = compare(releaseDate, other.releaseDate)
        case .dateAdded: order = compare(values?.dateAdded, other.values?.dateAdded)
        case .communityRating: order = compare(values?.audienceRating, other.values?.audienceRating)
        case .criticRating: order = compare(values?.criticRating, other.values?.criticRating)
        case .userRating: order = compare(values?.userRating, other.values?.userRating)
        case .contentRating: order = compare(contentRating, other.contentRating)
        case .runtime: order = compare(runtime, other.runtime)
        case .progress: order = compare(progress, other.progress)
        case .plays: order = compare(values?.playCount, other.values?.playCount)
        case .lastPlayed: order = compare(lastPlayed, other.lastPlayed)
        case .random:
            // A stable inventory order, rather than reshuffling every page.
            order = compare(Self.randomRank(reference.id), Self.randomRank(other.reference.id))
        }
        if let order { return order }
        let names = sortName.compare(
            other.sortName, options: [.numeric, .caseInsensitive, .diacriticInsensitive])
        if names != .orderedSame { return names == .orderedAscending }
        if reference.accountID != other.reference.accountID {
            return (reference.accountID ?? "") < (other.reference.accountID ?? "")
        }
        return reference.id < other.reference.id
    }

    private static func randomRank(_ id: String) -> UInt64 {
        id.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
    }
}

extension MediaLibraryQueryProviding {
    public func libraryQueryEpisodeInventory(in containerID: String, page: PageRequest) async throws
        -> MediaPage
    {
        throw AppError.notFound
    }

    public func libraryQueryLetterIndex(
        in containerID: String, kind: MediaItemKind, page: PageRequest
    ) async throws -> [LibraryLetterIndexEntry] {
        if page.filters.isEmpty {
            return try await letterIndex(in: containerID, kind: kind, sort: page.sort)
        }
        return LibraryLetterIndex.deferredEntries(direction: page.sort.direction)
    }

    public func libraryQueryLetterPosition(
        in containerID: String, kind: MediaItemKind, letter: String, page: PageRequest
    ) async throws -> Int? {
        if page.filters.isEmpty {
            return try await letterPosition(
                in: containerID, kind: kind, letter: letter, sort: page.sort)
        }
        return try await LibraryLetterIndex.findPosition(
            fetch: { offset, limit in
                try await items(
                    in: containerID, kind: kind,
                    page: PageRequest(
                        startIndex: offset, limit: limit, sort: page.sort, filters: page.filters)
                )
            },
            matches: { MediaItemSortOrder.alphabetBucket(for: $0) == letter }
        )
    }
}
