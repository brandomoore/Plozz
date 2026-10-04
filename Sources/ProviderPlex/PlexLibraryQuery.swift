import CoreModels
import Foundation

extension PlexProvider: MediaLibraryQueryProviding {
    public func supportedSortFields(in containerID: String, kind: MediaItemKind) -> [SortField] {
        [.name, .year, .releaseDate, .criticRating, .communityRating, .userRating,
         .contentRating, .runtime, .progress, .plays, .lastPlayed, .dateAdded, .random]
    }

    public func libraryQueryCapabilities(in containerID: String, kind: MediaItemKind) -> LibraryQueryCapabilities {
        var nativeFilters: Set<LibraryFilter> = [.all, .hdr, .unwatched, .inProgress, .unmatched, .duplicates]
        var nativeSortFields = Set(supportedSortFields(in: containerID, kind: kind).filter { $0 != .progress })
        if kind == .series {
            nativeFilters.remove(.hdr)
            nativeSortFields.remove(.plays)
        }
        return LibraryQueryCapabilities(
            filters: LibraryFilter.allCases,
            nativeFilters: nativeFilters,
            nativeSortFields: nativeSortFields,
            supportsGenres: true, supportsYears: true, nativeFacets: true
        )
    }

    public func libraryQueryFacets(in containerID: String, kind: MediaItemKind) async throws -> LibraryQueryFacets {
        let type = Self.sectionType(forContainerKind: kind)
        async let genres = libraryGenres(in: containerID, kind: kind)
        async let years = client.libraryFacet(sectionID: containerID, type: type, field: "year")
        return try await LibraryQueryFacets(
            genres: genres.compactMap(\.title),
            years: years.compactMap { $0.title.flatMap(Int.init) }
        )
    }

    func libraryGenreID(_ name: String?, in containerID: String, kind: MediaItemKind) async throws -> String? {
        guard let name else { return nil }
        let genres = try await libraryGenres(in: containerID, kind: kind)
        return genres.first { $0.title?.caseInsensitiveCompare(name) == .orderedSame }?.key
    }

    public func libraryQueryInventory(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        let fields = libraryQueryCapabilities(in: containerID, kind: kind).nativeSortFields
        let sort = page.sort.field != .random && fields.contains(page.sort.field) ? page.sort : .default
        let response = try await client.sectionItems(
            sectionID: containerID, type: Self.sectionType(forContainerKind: kind),
            start: page.startIndex, size: page.limit, sort: sort
        )
        guard let total = response.totalSize, total >= 0 else { throw AppError.invalidResponse }
        return MediaPage(items: (response.Metadata ?? []).map { dto in
            var item = map(metadata: dto)
            item.librarySortValues?.hasAtmos = dto.Media?.contains { media in
                media.audioProfile?.localizedCaseInsensitiveContains("atmos") == true
                    || (media.Part ?? []).contains { part in
                        (part.Stream ?? []).contains { stream in
                            stream.streamType == 2 && [stream.profile, stream.displayTitle].compactMap { $0 }.contains {
                                $0.localizedCaseInsensitiveContains("atmos") || $0.localizedCaseInsensitiveContains("joc")
                            }
                        }
                    }
            }
            return item
        }, startIndex: page.startIndex, totalCount: total)
    }

    public func libraryQueryEpisodeInventory(in containerID: String, page: PageRequest) async throws -> MediaPage {
        try await libraryQueryInventory(
            in: containerID, kind: .episode,
            page: page
        )
    }

    public func libraryQueryLetterIndex(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> [LibraryLetterIndexEntry] {
        guard page.sort.field == .name else { return [] }
        let genreID = try await libraryGenreID(page.filters.genre, in: containerID, kind: kind)
        if page.filters.genre != nil, genreID == nil { return [] }
        let directories = try await client.firstCharacter(
            sectionID: containerID, type: Self.sectionType(forContainerKind: kind),
            filters: page.filters, genreID: genreID
        )
        return LibraryLetterIndex.entries(
            bucketCountsAscending: directories.map {
                (letter: LibraryLetterIndex.bucket(forPrefix: $0.titleSort ?? $0.title ?? "#"),
                 count: max(0, $0.size ?? 0))
            },
            direction: page.sort.direction
        )
    }

    private func libraryGenres(in containerID: String, kind: MediaItemKind) async throws -> [PlexDirectory] {
        let key = "\(kind.rawValue):\(containerID)"
        if let saved = await libraryGenreCache.values(for: key) { return saved }
        let values = try await client.libraryFacet(
            sectionID: containerID, type: Self.sectionType(forContainerKind: kind), field: "genre"
        )
        await libraryGenreCache.save(values, for: key)
        return values
    }
}

actor PlexLibraryGenreCache {
    private var entries: [String: (Date, [PlexDirectory])] = [:]
    func values(for key: String) -> [PlexDirectory]? {
        guard let entry = entries[key], Date().timeIntervalSince(entry.0) < 120 else { return nil }
        return entry.1
    }
    func save(_ values: [PlexDirectory], for key: String) { entries[key] = (Date(), values) }
}
