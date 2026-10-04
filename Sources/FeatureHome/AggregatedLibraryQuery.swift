import Foundation
import CoreModels

extension AggregatedLibraryProvider {
    public func prepareLibraryQueryCapabilities() async throws {
        for source in sources {
            try Task.checkCancellation()
            try await (source.provider as? any MediaLibraryQueryProviding)?.prepareLibraryQueryCapabilities()
        }
    }
    public func libraryQueryInventorySortKey(_ field: SortField) -> SortField {
        sources.contains {
            ($0.provider as? any MediaLibraryQueryProviding)?.libraryQueryInventorySortKey(field) != .name
        } ? field : .name
    }
    actor InventoryCounts {
        var totals: [String: [Int]] = [:]
        func values(for key: String) -> [Int]? { totals[key] }
        func save(_ values: [Int], for key: String) { totals[key] = values }
        func reset() { totals = [:] }
    }

    public func supportedSortFields(in containerID: String, kind: MediaItemKind) -> [SortField] {
        SortField.allCases.filter { field in
            sources.contains {
                (($0.provider as? any MediaSortFieldProviding)?
                    .supportedSortFields(in: $0.containerID, kind: $0.kind ?? kind) ?? SortField.legacyFields).contains(field)
            }
        }
    }

    public func libraryQueryCapabilities(in containerID: String, kind: MediaItemKind) -> LibraryQueryCapabilities {
        let capabilities = sources.compactMap { source in
            (source.provider as? any MediaLibraryQueryProviding)?
                .libraryQueryCapabilities(in: source.containerID, kind: source.kind ?? kind)
        }
        guard capabilities.count == sources.count else { return LibraryQueryCapabilities() }
        return LibraryQueryCapabilities(
            filters: LibraryFilter.allCases.filter { filter in capabilities.allSatisfy { $0.filters.contains(filter) } },
            nativeFilters: [.all], nativeSortFields: [.name, .random],
            supportsGenres: capabilities.allSatisfy(\.supportsGenres),
            supportsYears: capabilities.allSatisfy(\.supportsYears), nativeFacets: false
        )
    }

    public func libraryQueryFacets(in containerID: String, kind: MediaItemKind) async throws -> LibraryQueryFacets {
        var genres: [String] = []
        var years: [Int] = []
        for source in sources {
            try Task.checkCancellation()
            guard let provider = source.provider as? any MediaLibraryQueryProviding else { throw AppError.notFound }
            let facets = try await provider.libraryQueryFacets(in: source.containerID, kind: source.kind ?? kind)
            genres += facets.genres
            years += facets.years
        }
        return LibraryQueryFacets(genres: genres, years: years)
    }

    public func libraryQueryInventory(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        try await inventoryPage(kind: kind, page: page, episodes: false)
    }

    public func libraryQueryEpisodeInventory(in containerID: String, page: PageRequest) async throws -> MediaPage {
        try await inventoryPage(kind: .series, page: page, episodes: true)
    }

    public func finishLibraryQueryInventory() async {
        await inventoryCounts.reset()
        for source in sources {
            await (source.provider as? any MediaLibraryQueryProviding)?.finishLibraryQueryInventory()
        }
    }

    private func inventoryPage(kind: MediaItemKind, page: PageRequest, episodes: Bool) async throws -> MediaPage {
        let targets = episodes ? sources.filter { ($0.kind ?? kind) == .series } : sources
        let key = "\(kind.rawValue):\(episodes):\(page.sort.field.rawValue)"
        let totals: [Int]
        if let saved = await inventoryCounts.values(for: key) { totals = saved }
        else {
            var values: [Int] = []
            for source in targets {
                try Task.checkCancellation()
                guard let provider = source.provider as? any MediaLibraryQueryProviding else { throw AppError.notFound }
                let request = PageRequest(limit: 1, sort: page.sort, filters: page.filters)
                let first = episodes
                    ? try await provider.libraryQueryEpisodeInventory(in: source.containerID, page: request)
                    : try await provider.libraryQueryInventory(in: source.containerID, kind: source.kind ?? kind, page: request)
                guard first.totalCount >= 0 else { throw AppError.invalidResponse }
                values.append(first.totalCount)
            }
            await inventoryCounts.save(values, for: key)
            totals = values
        }
        var base = 0
        var result: [MediaItem] = []
        for (index, source) in targets.enumerated() {
            let total = totals[index]
            defer { base += total }
            let localStart = max(0, page.startIndex + result.count - base)
            guard localStart < total, page.startIndex + result.count < base + total else { continue }
            guard let provider = source.provider as? any MediaLibraryQueryProviding else { throw AppError.notFound }
            let request = PageRequest(
                startIndex: localStart, limit: min(page.limit - result.count, total - localStart),
                sort: page.sort, filters: page.filters
            )
            let batch = episodes
                ? try await provider.libraryQueryEpisodeInventory(in: source.containerID, page: request)
                : try await provider.libraryQueryInventory(in: source.containerID, kind: source.kind ?? kind, page: request)
            guard batch.startIndex == localStart, batch.totalCount == total,
                  !batch.items.isEmpty, batch.items.count <= request.limit else { throw AppError.invalidResponse }
            result += batch.items.map { $0.taggingSource(source.accountID) }
            if result.count >= page.limit { break }
            // A server's shorter page must be continued before crossing a source.
            if localStart + batch.items.count < total { break }
        }
        return MediaPage(items: result, startIndex: page.startIndex, totalCount: totals.reduce(0, +))
    }

    public func libraryQueryMergeInventory(_ records: [LibraryQueryRecord]) -> [LibraryQueryRecord] {
        let bySource = Dictionary(uniqueKeysWithValues: records.map { ($0.identityKey, $0) })
        let merged = MediaItemMerger.merge(records.map(\.identityItem), serverInfo: { inventoryServerInfo[$0] },
                                           identitySources: inventoryIdentitySources)
        return merged.map { item in
            var record = LibraryQueryRecord(item, includeFormats: false)
            record.reference.sources = record.reference.sources.filter { source in
                bySource[LibraryBrowsePreferencesStore.address(
                    accountID: source.accountID, libraryID: source.itemID, mode: item.kind.rawValue
                )] != nil
            }
            var historicalSources: [MediaSourceRef] = []
            for source in record.reference.sources {
                if let original = bySource[LibraryBrowsePreferencesStore.address(
                    accountID: source.accountID, libraryID: source.itemID, mode: item.kind.rawValue
                )] {
                    record.includeAlternativeFacts(original)
                    var historical = source
                    historical.isPlayed = original.completed
                    historicalSources.append(historical)
                }
            }
            if let original = bySource[record.identityKey] { record.includeAlternativeFacts(original) }
            if !historicalSources.isEmpty {
                record.completed = MediaItemMerger.unifiedWatchState(from: historicalSources).isPlayed
            }
            record.values?.watched = record.completed
            return record
        }
    }

    public func libraryQueryItem(_ reference: LibraryQueryReference) async throws -> MediaItem {
        let references = reference.sources.isEmpty
            ? reference.accountID.map { [MediaSourceRef(accountID: $0, itemID: reference.id)] } ?? []
            : reference.sources
        guard !references.isEmpty else { throw AppError.invalidResponse }
        var items: [MediaItem] = []
        for ref in references {
            try Task.checkCancellation()
            guard let source = sources.first(where: { $0.accountID == ref.accountID }) else { throw AppError.notFound }
            let item: MediaItem
            if let query = source.provider as? any MediaLibraryQueryProviding {
                item = try await query.libraryQueryItem(.init(id: ref.itemID, accountID: ref.accountID))
            } else {
                item = try await source.provider.item(id: ref.itemID)
            }
            items.append(item.taggingSource(ref.accountID))
        }
        let merged = MediaItemMerger.merge(items, serverInfo: { inventoryServerInfo[$0] })
        guard merged.count == 1, let item = merged.first else { throw AppError.conflict }
        return item
    }
}
