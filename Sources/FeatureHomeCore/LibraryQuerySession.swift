import CoreModels
import Foundation

public enum LibraryQueryFailure: Error, Sendable {
    case memoryBudget
    case changedInventory
    case refinedSources([MediaItem])
    case restartRequired

    public var message: LocalizedStringResource {
        switch self {
        case .memoryBudget:
            "This library is too large to index safely on this device. Use a server-supported filter or sort."
        case .changedInventory, .refinedSources, .restartRequired:
            "The library changed while preparing this filter. Try again."
        }
    }
}

/// Per-destination, off-main compact cache. The native path never inventories.
actor LibraryQuerySession {
    private let provider: any MediaProvider
    private let containerID: String
    private let kind: MediaItemKind
    private var records: [LibraryQueryRecord]?
    private var recordKey: Key?
    private var ordered: [LibraryQueryRecord] = []
    private var orderedQuery: LibraryBrowsePreferences?
    private var revision = 0
    private let materialization = ConcurrencyLimiter(limit: 3)
    private var inventoryDate: Date?
    private var fileFacts: [LibraryQueryRecord]?
    private var fileFactsDate: Date?
    private var pendingInventory: (id: UUID, key: Key, task: Task<[LibraryQueryRecord], Error>)?

    private struct Key: Equatable {
        let files: Bool
        let sort: SortField
        let episodes: Bool
    }

    init(provider: any MediaProvider, containerID: String, kind: MediaItemKind) {
        self.provider = provider
        self.containerID = containerID
        self.kind = kind
    }

    func invalidate(preservingFileFacts: Bool = false) async {
        revision += 1
        let pending = pendingInventory
        pending?.task.cancel()
        records = nil
        recordKey = nil
        ordered = []
        orderedQuery = nil
        inventoryDate = nil
        if !preservingFileFacts {
            fileFacts = nil
            fileFactsDate = nil
        }
        if let pending {
            _ = await pending.task.result
            if pendingInventory?.id == pending.id { pendingInventory = nil }
        }
    }

    func page(_ page: PageRequest, progress: @escaping @Sendable (Int, Int) async -> Void)
        async throws -> MediaPage
    {
        guard page.startIndex >= 0, page.limit > 0 else { throw AppError.invalidResponse }
        guard let source = provider as? any MediaLibraryQueryProviding,
            source.libraryQueryCapabilities(in: containerID, kind: kind).needsIndex(for: page)
        else {
            return try await provider.items(in: containerID, kind: kind, page: page)
        }
        var correctedSources = Set<String>()
        var generation = revision
        while true {
            try await prepare(source, page: page, progress: progress)
            do {
                let result = try await materializedPage(page, source: source)
                guard generation == revision else { throw CancellationError() }
                return result
            } catch LibraryQueryFailure.refinedSources(let items) {
                try Task.checkCancellation()
                guard generation == revision else { throw CancellationError() }
                let corrections = items.map { LibraryQueryRecord($0) }
                let keys = Set(corrections.map(\.identityKey))
                guard !keys.isEmpty, correctedSources.isDisjoint(with: keys),
                      let existing = records else { throw LibraryQueryFailure.changedInventory }
                correctedSources.formUnion(keys)
                let byKey = Dictionary(uniqueKeysWithValues: corrections.map { ($0.identityKey, $0) })
                guard keys.isSubset(of: Set(existing.map(\.identityKey))) else {
                    throw LibraryQueryFailure.changedInventory
                }
                // Keep the original per-source episode/file facts. Only identity
                // evidence was refined by the parent-item fetch.
                let rebuilt = existing.map { record in
                    guard let correction = byKey[record.identityKey] else { return record }
                    var updated = record
                    updated.providerIDs = correction.providerIDs
                    updated.rejectedSourceIDs.formUnion(correction.rejectedSourceIDs)
                    updated.title = correction.title
                    updated.originalTitle = correction.originalTitle
                    updated.year = correction.year
                    return updated
                }
                guard rebuilt.reduce(0, { $0 + $1.estimatedStorageBytes }) <= 24 * 1024 * 1024 else {
                    throw LibraryQueryFailure.memoryBudget
                }
                records = rebuilt
                if fileFacts != nil { fileFacts = rebuilt }
                orderedQuery = nil
                revision += 1
                generation = revision
                // Recompute filters, rollups and offsets before publishing page
                // zero. An exposed later page requires a visible restart.
                guard page.startIndex == 0 else { throw LibraryQueryFailure.restartRequired }
            }
        }
    }

    private func materializedPage(_ page: PageRequest, source: any MediaLibraryQueryProviding)
        async throws -> MediaPage
    {
        try Task.checkCancellation()
        let start = min(page.startIndex, ordered.count)
        let selection = Array(ordered.dropFirst(start).prefix(page.limit))
        let total = ordered.count
        var items: [MediaItem] = []
        // Bound materialization independently of the library's size.
        for offset in stride(from: 0, to: selection.count, by: 3) {
            try Task.checkCancellation()
            let batch = Array(selection[offset..<min(offset + 3, selection.count)])
            let result = try await withThrowingTaskGroup(of: (Int, MediaItem).self) { group in
                for (index, record) in batch.enumerated() {
                    group.addTask { [materialization] in
                        try await materialization.runUnlessCancelled {
                            (
                                index,
                                record.applyingRollup(
                                    to: try await source.libraryQueryItem(record.reference))
                            )
                        }
                    }
                }
                var result: [(Int, MediaItem)] = []
                for try await item in group { result.append(item) }
                return result.sorted { $0.0 < $1.0 }.map(\.1)
            }
            items += result
        }
        return MediaPage(items: items, startIndex: page.startIndex, totalCount: total)
    }

    func letterIndex(page: PageRequest) async throws -> [LibraryLetterIndexEntry] {
        if orderedQuery == LibraryBrowsePreferences(sort: page.sort, filters: page.filters) {
            var seen = Set<String>()
            return ordered.enumerated().compactMap { index, record in
                let letter = LibraryLetterIndex.bucket(forPrefix: record.sortName)
                guard seen.insert(letter).inserted else { return nil }
                return LibraryLetterIndexEntry(letter: letter, startIndex: index)
            }
        }
        if let source = provider as? any MediaLibraryQueryProviding {
            return try await source.libraryQueryLetterIndex(in: containerID, kind: kind, page: page)
        }
        return try await provider.letterIndex(in: containerID, kind: kind, sort: page.sort)
    }

    func letterPosition(_ letter: String, page: PageRequest) async throws -> Int? {
        if orderedQuery == LibraryBrowsePreferences(sort: page.sort, filters: page.filters) {
            return ordered.firstIndex {
                LibraryLetterIndex.bucket(forPrefix: $0.sortName) == letter
            }
        }
        if let source = provider as? any MediaLibraryQueryProviding {
            return try await source.libraryQueryLetterPosition(
                in: containerID, kind: kind, letter: letter, page: page)
        }
        return try await provider.letterPosition(
            in: containerID, kind: kind, letter: letter, sort: page.sort)
    }

    private func prepare(
        _ source: any MediaLibraryQueryProviding, page: PageRequest,
        progress: @escaping @Sendable (Int, Int) async -> Void
    ) async throws {
        let key = Key(
            files: page.filters.filter.needsFileMetadata,
            sort: source.libraryQueryInventorySortKey(page.sort.field),
            episodes: (kind == .series || kind == .unknown)
                && (page.filters.filter.needsFileMetadata
                    || [.inProgress, .unwatched].contains(page.filters.filter)
                    || [.plays, .lastPlayed, .progress].contains(page.sort.field))
        )
        let generation = revision
        let filesFresh = fileFactsDate.map { Date().timeIntervalSince($0) < 120 } ?? false
        let cachedFiles = filesFresh ? fileFacts : nil
        let covered =
            recordKey.map {
                ($0.files || !key.files) && ($0.episodes || !key.episodes) && $0.sort == key.sort
            } ?? false
        if records == nil || !covered
            || inventoryDate.map({ Date().timeIntervalSince($0) > 120 }) == true
            || (key.files && !filesFresh)
        {
            await progress(0, 0)
            let result: [LibraryQueryRecord]
            while true {
                try Task.checkCancellation()
                guard generation == revision else { throw CancellationError() }
                let pending: (id: UUID, key: Key, task: Task<[LibraryQueryRecord], Error>)
                if let existing = pendingInventory {
                    if existing.key != key || existing.task.isCancelled {
                        existing.task.cancel()
                        _ = await existing.task.result
                        if pendingInventory?.id == existing.id { pendingInventory = nil }
                        continue
                    }
                    pending = existing
                } else {
                    let task = Task.detached(priority: .utility) { [containerID, kind] in
                        do {
                            let result = try await Self.inventory(
                                source, containerID: containerID, kind: kind, page: page,
                                episodes: key.episodes,
                                cachedFiles: cachedFiles, progress: progress)
                            await source.finishLibraryQueryInventory()
                            return result
                        } catch {
                            await source.finishLibraryQueryInventory()
                            throw error
                        }
                    }
                    pending = (UUID(), key, task)
                    pendingInventory = pending
                }
                let task = pending.task
                do {
                    result = try await withTaskCancellationHandler {
                        try await task.value
                    } onCancel: {
                        task.cancel()
                    }
                } catch {
                    if generation == revision, case LibraryQueryFailure.changedInventory = error {
                        fileFacts = nil
                        fileFactsDate = nil
                    }
                    if pendingInventory?.id == pending.id { pendingInventory = nil }
                    // A cancelled coalesced caller must not cancel a still-live query.
                    if task.isCancelled && !Task.isCancelled && generation == revision { continue }
                    throw error
                }
                if pendingInventory?.id == pending.id { pendingInventory = nil }
                try Task.checkCancellation()
                guard generation == revision else { throw CancellationError() }
                break
            }
            records = result
            recordKey = Key(
                files: key.files || cachedFiles != nil, sort: key.sort, episodes: key.episodes)
            inventoryDate = Date()
            if key.files || cachedFiles != nil {
                fileFacts = result
                if cachedFiles == nil { fileFactsDate = inventoryDate }
            } else {
                fileFacts = nil
                fileFactsDate = nil
            }
            orderedQuery = nil
        }
        let query = LibraryBrowsePreferences(sort: page.sort, filters: page.filters)
        if orderedQuery != query {
            ordered = source.libraryQueryMergeInventory(records ?? []).filter { $0.matches(page.filters) }
                .sorted { $0.isOrdered(before: $1, by: page.sort) }
            orderedQuery = query
        }
    }

    private static func inventory(
        _ source: any MediaLibraryQueryProviding, containerID: String, kind: MediaItemKind,
        page: PageRequest, episodes: Bool,
        cachedFiles: [LibraryQueryRecord]?,
        progress: @escaping @Sendable (Int, Int) async -> Void
    ) async throws -> [LibraryQueryRecord] {
        var records: [LibraryQueryRecord] = []
        var identities = Set<String>()
        var expectedTotal: Int?
        var bytes = 0
        let memoryBudget = 24 * 1024 * 1024
        var offset = 0
        var fileRecords: [String: LibraryQueryRecord] = [:]
        if let cachedFiles {
            for record in cachedFiles {
                fileRecords[record.identityKey] = record
                for reference in record.reference.sources {
                    fileRecords[
                        LibraryBrowsePreferencesStore.address(
                            accountID: reference.accountID, libraryID: reference.itemID,
                            mode: record.kind.rawValue
                        )] = record
                }
            }
        }
        let inventoryFilters: LibraryFilters = cachedFiles == nil ? page.filters : .all
        repeat {
            try Task.checkCancellation()
            let batch = try await source.libraryQueryInventory(
                in: containerID, kind: kind,
                page: PageRequest(
                    startIndex: offset, limit: 120, sort: page.sort, filters: inventoryFilters)
            )
            guard batch.startIndex == offset, batch.totalCount >= offset + batch.items.count,
                batch.items.count <= 120, !batch.items.isEmpty || offset == batch.totalCount
            else {
                throw AppError.invalidResponse
            }
            if let expectedTotal, expectedTotal != batch.totalCount {
                throw LibraryQueryFailure.changedInventory
            }
            expectedTotal = batch.totalCount
            for item in batch.items {
                var record = LibraryQueryRecord(
                    item,
                    includeFormats: cachedFiles == nil && page.filters.filter.needsFileMetadata)
                if cachedFiles != nil {
                    guard let old = fileRecords[record.identityKey] else {
                        throw LibraryQueryFailure.changedInventory
                    }
                    record.includeFileFacts(old)
                }
                guard identities.insert(record.identityKey).inserted else {
                    throw LibraryQueryFailure.changedInventory
                }
                if episodes, record.kind == .series { record.values?.episodeWatchRollup = true }
                bytes += record.estimatedStorageBytes
                guard bytes <= memoryBudget else { throw LibraryQueryFailure.memoryBudget }
                records.append(record)
            }
            offset += batch.items.count
            await progress(offset, batch.totalCount)
            await Task.yield()
        } while offset < (expectedTotal ?? 0)
        if episodes && records.contains(where: { $0.kind == .series }) {
            struct EpisodeState {
                var played: Bool
                var inProgress: Bool
                var lastPlayed: Date?
                var plays: Int?
                var progress: Double
            }
            var episodeStates: [String: [String: EpisodeState]] = [:]
            var bySeries: [String: Int] = [:]
            for (index, record) in records.enumerated() where record.kind == .series {
                bySeries[
                    Self.seriesKey(accountID: record.reference.accountID, id: record.reference.id)] =
                    index
            }
            offset = 0
            expectedTotal = nil
            identities = []
            repeat {
                try Task.checkCancellation()
                let batch = try await source.libraryQueryEpisodeInventory(
                    in: containerID,
                    page: PageRequest(
                        startIndex: offset, limit: 120, sort: page.sort, filters: inventoryFilters)
                )
                guard batch.startIndex == offset, batch.totalCount >= offset + batch.items.count,
                    batch.items.count <= 120, !batch.items.isEmpty || offset == batch.totalCount
                else {
                    throw AppError.invalidResponse
                }
                if let expectedTotal, expectedTotal != batch.totalCount {
                    throw LibraryQueryFailure.changedInventory
                }
                expectedTotal = batch.totalCount
                for item in batch.items {
                    let episode = LibraryQueryRecord(
                        item, includeFormats: page.filters.filter.needsFileMetadata)
                    guard identities.insert(episode.identityKey).inserted else {
                        throw LibraryQueryFailure.changedInventory
                    }
                    if let seriesID = episode.seriesID,
                        let index = bySeries[
                            Self.seriesKey(accountID: episode.reference.accountID, id: seriesID)]
                    {
                        records[index].includeEpisodeFacts(episode)
                        let parent = Self.seriesKey(
                            accountID: episode.reference.accountID, id: seriesID)
                        let logical =
                            episode.episodeNumber.map {
                                "\(episode.seasonNumber ?? 1):\($0)"
                            } ?? episode.reference.id
                        let old = episodeStates[parent]?[logical]
                        if old != nil { records[index].duplicates = true }
                        episodeStates[parent, default: [:]][logical] = EpisodeState(
                            played: (old?.played ?? false) || episode.completed,
                            inProgress: (old?.inProgress ?? false) || episode.inProgress,
                            lastPlayed: [old?.lastPlayed, episode.lastPlayed].compactMap { $0 }
                                .max(),
                            plays: [old?.plays, episode.values?.playCount].compactMap { $0 }.max(),
                            progress: max(
                                old?.progress ?? 0, episode.isPlayed ? 1 : episode.progress)
                        )
                    }
                }
                // Only bounded episode pages survive; no episode catalog is retained.
                offset += batch.items.count
                guard identities.count * 128 <= memoryBudget else {
                    throw LibraryQueryFailure.memoryBudget
                }
                await progress(offset, batch.totalCount)
                await Task.yield()
            } while offset < (expectedTotal ?? 0)
            for (parent, states) in episodeStates {
                guard let index = bySeries[parent] else { continue }
                let playCounts = states.values.compactMap(\.plays)
                records[index].values?.playCount =
                    playCounts.isEmpty ? nil : playCounts.reduce(0, +)
                if records[index].values?.episodeWatchRollup == true {
                    let played = states.values.filter(\.played).count
                    records[index].completed = played == states.count
                    records[index].progress =
                        states.values.reduce(0) { $0 + $1.progress } / Double(states.count)
                    records[index].inProgress =
                        (!records[index].completed && played > 0)
                        || states.values.contains(where: \.inProgress)
                    records[index].isPlayed = records[index].completed && !records[index].inProgress
                    records[index].lastPlayed =
                        ([records[index].lastPlayed]
                        + states.values.map(\.lastPlayed)).compactMap { $0 }.max()
                    let completed = records[index].completed
                    records[index].values?.watched = completed
                }
            }
        }
        return records
    }

    private static func seriesKey(accountID: String?, id: String) -> String {
        LibraryBrowsePreferencesStore.address(
            accountID: accountID ?? "", libraryID: id, mode: "series")
    }
}
