import Foundation
import CoreModels
import FeatureHomeCore
import CoreNetworking

extension AggregatedLibraryProvider {
    public func prepareLibraryQueryCapabilities() async throws {
        var succeeded = false
        var failure: Error?
        for source in sources {
            try Task.checkCancellation()
            do {
                try await (source.provider as? any MediaLibraryQueryProviding)?.prepareLibraryQueryCapabilities()
                succeeded = true
            } catch {
                try Self.checkQueryCancellation(error)
                PlozzLog.app.error("Aggregation: capability setup failed for account \(source.accountID)")
                failure = error
            }
        }
        if !succeeded, let failure { throw attributedFailure(failure, sources: sources) }
    }

    static func checkQueryCancellation(_ error: Error) throws {
        try Task.checkCancellation()
        if error is CancellationError || (error as? AppError) == .cancelled {
            throw CancellationError()
        }
    }
    public func libraryQueryInventorySortKey(_ field: SortField) -> SortField {
        sources.contains {
            ($0.provider as? any MediaLibraryQueryProviding)?.libraryQueryInventorySortKey(field) != .name
        } ? field : .name
    }
    actor InventoryCounts {
        var totals: [String: [Int]] = [:]
        var unavailableSources: Set<String> = []
        func values(for key: String) -> [Int]? { totals[key] }
        func save(_ values: [Int], for key: String) { totals[key] = values }
        func exclude(_ key: String) { unavailableSources.insert(key) }
        func excluded() -> Set<String> { unavailableSources }
        func reset() { totals = [:]; unavailableSources = [] }
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
        var succeeded = false
        var failure: Error?
        for source in sources {
            try Task.checkCancellation()
            do {
                guard let provider = source.provider as? any MediaLibraryQueryProviding else { throw AppError.notFound }
                let facets = try await provider.libraryQueryFacets(in: source.containerID, kind: source.kind ?? kind)
                genres += facets.genres
                years += facets.years
                succeeded = true
            } catch {
                try Self.checkQueryCancellation(error)
                PlozzLog.app.error("Aggregation: facets failed for account \(source.accountID)")
                failure = error
            }
        }
        if !succeeded, let failure { throw attributedFailure(failure, sources: sources) }
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
        var excluded = await queryRecovery.sources()
        if episodes { excluded.formUnion(await inventoryCounts.excluded()) }
        let targets = sources.filter {
            !excluded.contains($0.sourceKey) && (!episodes || ($0.kind ?? kind) == .series)
        }
        let key = "\(kind.rawValue):\(episodes):\(page.sort.field.rawValue)"
        let totals: [Int]
        if let saved = await inventoryCounts.values(for: key) { totals = saved }
        else {
            var values: [Int] = []
            var succeeded = false
            var failure: Error?
            for source in targets {
                try Task.checkCancellation()
                do {
                    guard let provider = source.provider as? any MediaLibraryQueryProviding else { throw AppError.notFound }
                    let request = PageRequest(limit: 1, sort: page.sort, filters: page.filters)
                    let first = episodes
                        ? try await provider.libraryQueryEpisodeInventory(in: source.containerID, page: request)
                        : try await provider.libraryQueryInventory(in: source.containerID, kind: source.kind ?? kind, page: request)
                    guard first.totalCount >= 0 else { throw AppError.invalidResponse }
                    values.append(first.totalCount)
                    succeeded = true
                } catch {
                    try Self.checkQueryCancellation(error)
                    PlozzLog.app.error("Aggregation: inventory unavailable for account \(source.accountID)")
                    if !episodes { await inventoryCounts.exclude(source.sourceKey) }
                    values.append(0)
                    failure = error
                }
            }
            if !succeeded, let failure { throw attributedFailure(failure, sources: targets) }
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
            let batch: MediaPage
            do {
                batch = episodes
                    ? try await provider.libraryQueryEpisodeInventory(in: source.containerID, page: request)
                    : try await provider.libraryQueryInventory(in: source.containerID, kind: source.kind ?? kind, page: request)
            } catch {
                try Self.checkQueryCancellation(error)
                throw attributedFailure(error, sources: [source])
            }
            guard batch.startIndex == localStart, batch.totalCount == total,
                  !batch.items.isEmpty, batch.items.count <= request.limit else {
                throw attributedFailure(AppError.invalidResponse, sources: [source])
            }
            result += batch.items.map { $0.taggingSource(source.accountID).taggingLibrary(source.containerID) }
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
            record.duplicates = record.reference.sources.count > 1
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
            ? reference.accountID.map {
                [MediaSourceRef(accountID: $0, itemID: reference.id, libraryID: reference.libraryID)]
            } ?? []
            : reference.sources
        guard !references.isEmpty else { throw AppError.invalidResponse }
        var items: [MediaItem] = []
        var failure: Error?
        var failedSources: [AggregatedLibrarySource] = []
        for ref in references {
            try Task.checkCancellation()
            let source = sources.first {
                $0.accountID == ref.accountID && (ref.libraryID == nil || $0.containerID == ref.libraryID)
            }
            do {
                guard let source else { throw AppError.notFound }
                let item: MediaItem
                if let query = source.provider as? any MediaLibraryQueryProviding {
                    item = try await query.libraryQueryItem(.init(id: ref.itemID, accountID: ref.accountID))
                } else {
                    item = try await source.provider.item(id: ref.itemID)
                }
                items.append(item.taggingSource(ref.accountID).taggingLibrary(source.containerID))
            } catch {
                try Self.checkQueryCancellation(error)
                PlozzLog.app.error("Aggregation: item unavailable for account \(ref.accountID)")
                if let source { failedSources.append(source) }
                failure = error
            }
        }
        if items.isEmpty {
            throw attributedFailure(failure ?? AppError.notFound, sources: failedSources)
        }
        let allowed = Set(references.map(\.id))
        let refined = MediaItemMerger.merge(
            items, serverInfo: { inventoryServerInfo[$0] },
            identitySources: { item in inventoryIdentitySources(item).filter { allowed.contains($0.id) } }
        )
        guard refined.count == 1, let item = refined.first else {
            throw LibraryQueryFailure.refinedSources(items)
        }
        return item
    }
}
