import CoreModels
import Foundation

extension JellyfinProvider: MediaLibraryQueryProviding {
    public func supportedSortFields(in containerID: String, kind: MediaItemKind) -> [SortField] {
        [.name, .year, .releaseDate, .criticRating, .communityRating, .contentRating,
         .runtime, .progress, .plays, .lastPlayed, .dateAdded, .random]
    }

    public func libraryQueryCapabilities(in containerID: String, kind: MediaItemKind) -> LibraryQueryCapabilities {
        var nativeFilters: Set<LibraryFilter> = [.all, .unwatched, .inProgress]
        var fields = Set(supportedSortFields(in: containerID, kind: kind))
        fields.remove(.progress)
        if kind == .series {
            nativeFilters.remove(.inProgress)
            fields.remove(.plays)
            if self.kind == .emby { fields.remove(.lastPlayed) }
        }
        return LibraryQueryCapabilities(
            filters: LibraryFilter.allCases, nativeFilters: nativeFilters, nativeSortFields: fields,
            supportsGenres: true, supportsYears: true, nativeFacets: true
        )
    }

    public func libraryQueryFacets(in containerID: String, kind: MediaItemKind) async throws -> LibraryQueryFacets {
        try await client.libraryFacets(
            userID: session.userID, parentID: containerID,
            includeItemTypes: Self.query(forContainerKind: kind).includeItemTypes
        )
    }

    public func libraryQueryInventory(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        let query = Self.query(forContainerKind: kind)
        let fields = libraryQueryCapabilities(in: containerID, kind: kind).nativeSortFields
        let response = try await client.items(
            userID: session.userID, parentID: containerID,
            includeItemTypes: query.includeItemTypes, recursive: query.recursive,
            startIndex: page.startIndex, limit: page.limit,
            sort: page.sort.field != .random && fields.contains(page.sort.field) ? page.sort : .default,
            fields: "PrimaryImageAspectRatio,ProviderIds,SortName,DateCreated,Genres"
                + (page.filters.filter.needsFileMetadata ? ",MediaSources,MediaStreams" : "")
        )
        guard let total = response.TotalRecordCount, total >= 0 else { throw AppError.invalidResponse }
        return MediaPage(items: response.Items.map { dto in
            var item = map(item: dto)
            if page.filters.filter.needsFileMetadata {
                let streams = (dto.MediaStreams ?? []) + (dto.MediaSources ?? []).flatMap { $0.MediaStreams ?? [] }
                item.librarySortValues?.hasAtmos = streams.contains { stream in
                    stream.Type == "Audio" && [stream.Profile, stream.DisplayTitle].compactMap { $0 }.contains {
                        $0.localizedCaseInsensitiveContains("atmos") || $0.localizedCaseInsensitiveContains("joc")
                    }
                }
            }
            return item
        }, startIndex: page.startIndex, totalCount: total)
    }

    public func libraryQueryEpisodeInventory(in containerID: String, page: PageRequest) async throws -> MediaPage {
        try await libraryQueryInventory(in: containerID, kind: .episode, page: page)
    }

    public func libraryQueryLetterIndex(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> [LibraryLetterIndexEntry] {
        try await filteredLetterIndex(in: containerID, kind: kind, sort: page.sort, filters: page.filters)
    }
}
