import Foundation
import CoreModels

extension ShareProvider {
    public func libraryQueryCapabilities(in containerID: String, kind: MediaItemKind) -> LibraryQueryCapabilities {
        guard ShareCatalogID.catalogLibrary(forID: containerID) != nil,
              libraryConfiguration?.contentType != .personalVideos else { return LibraryQueryCapabilities() }
        return LibraryQueryCapabilities(
            filters: LibraryFilter.allCases, nativeFilters: [.all],
            nativeSortFields: [.name, .dateAdded, .releaseDate, .runtime, .random],
            supportsGenres: true, supportsYears: true, nativeFacets: false
        )
    }

    public func libraryQueryFacets(in containerID: String, kind: MediaItemKind) async throws -> LibraryQueryFacets {
        guard let library = ShareCatalogID.catalogLibrary(forID: containerID) else { throw AppError.notFound }
        return try await catalog.libraryQueryFacets(in: library)
    }

    public func libraryQueryInventory(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        var result = try await items(in: containerID, kind: kind,
                                    page: .init(startIndex: page.startIndex, limit: page.limit))
        if kind == .series {
            result = MediaPage(items: result.items.map { item in
                var copy = item
                if copy.librarySortValues == nil { copy.librarySortValues = LibrarySortValues() }
                copy.librarySortValues?.episodeWatchRollup = true
                return copy
            }, startIndex: result.startIndex, totalCount: result.totalCount)
        }
        guard page.filters.filter.needsFileMetadata, kind != .series else { return result }
        var hydrated: [MediaItem] = []
        for summary in result.items {
            try Task.checkCancellation()
            guard var detail = await catalog.item(id: summary.id) else { throw AppError.notFound }
            detail = await watchState.stamp(detail)
            detail.librarySortValues = summary.librarySortValues
            hydrated.append(detail)
        }
        return MediaPage(items: hydrated, startIndex: result.startIndex, totalCount: result.totalCount)
    }

    public func libraryQueryEpisodeInventory(in containerID: String, page: PageRequest) async throws -> MediaPage {
        guard let library = ShareCatalogID.catalogLibrary(forID: containerID) else { throw AppError.notFound }
        let result = try await catalog.libraryQueryEpisodes(in: library, offset: page.startIndex, limit: page.limit)
        if page.filters.filter.needsFileMetadata {
            var details: [MediaItem] = []
            for summary in result.items {
                try Task.checkCancellation()
                guard let detail = await catalog.item(id: summary.id) else { throw AppError.notFound }
                details.append(await watchState.stamp(detail))
            }
            return MediaPage(items: details, startIndex: result.startIndex, totalCount: result.totalCount)
        }
        return MediaPage(items: await watchState.stamp(result.items), startIndex: result.startIndex, totalCount: result.totalCount)
    }

    public func libraryQueryItem(_ reference: LibraryQueryReference) async throws -> MediaItem {
        guard let item = await catalog.item(id: reference.id) else { throw AppError.notFound }
        return await watchState.stamp(item)
    }
}
