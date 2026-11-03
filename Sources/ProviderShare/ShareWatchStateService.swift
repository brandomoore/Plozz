import Foundation
import CoreModels
import CoreNetworking

/// Owns all device-local watch-state policy for a share: overlaying saved
/// resume/played state onto freshly-built items (stamping), folding several
/// legacy version records onto one canonical id, and persisting progress/played
/// writes. `ShareProvider` delegates here so the facade keeps only browse/
/// playback orchestration and this type has one reason to change.
///
/// A value type over a `ShareWatchStore` actor + the catalog reader; holds no
/// mutable state of its own.
struct ShareWatchStateService: Sendable {
    private let watchStore: ShareWatchStore
    private let catalog: @Sendable () async -> any ShareCatalogReading
    private let accountID: String
    private let usesCatalogClassification: Bool

    init(
        watchStore: ShareWatchStore,
        accountID: String,
        usesCatalogClassification: Bool = true,
        catalog: @escaping @Sendable () async -> any ShareCatalogReading
    ) {
        self.watchStore = watchStore
        self.accountID = accountID
        self.usesCatalogClassification = usesCatalogClassification
        self.catalog = catalog
    }

    // MARK: Stamping

    /// Overlay saved resume/played state onto a freshly-built item so the detail
    /// Play button shows "Resume" and cards show a checkmark / progress.
    func stamp(_ item: MediaItem) async -> MediaItem {
        switch item.kind {
        case .folder, .collection:
            return item
        case .series, .season:
            return await stampContainers([item])[0]
        default:
            break
        }
        let records = await records(for: [item.id])
        let canonicalID = await watchItemID(for: item.id)
        let record = records[canonicalID]
        return Self.stamped(item, with: record)
    }

    func stamp(_ items: [MediaItem]) async -> [MediaItem] {
        let playableIDs = items.compactMap { item -> String? in
            switch item.kind {
            case .folder, .collection, .series, .season: return nil
            default: return item.id
            }
        }
        let records = await records(for: playableIDs)
        let catalog: (any ShareCatalogReading)?
        if usesCatalogClassification {
            catalog = await self.catalog()
        } else {
            catalog = nil
        }
        var stamped: [MediaItem] = []
        stamped.reserveCapacity(items.count)
        for item in items {
            switch item.kind {
            case .folder, .collection, .series, .season:
                stamped.append(item)
            default:
                let canonical: String
                if let catalog {
                    canonical = await watchItemID(for: item.id, catalog: catalog)
                } else {
                    canonical = item.id
                }
                stamped.append(Self.stamped(item, with: records[canonical]))
            }
        }
        return await stampContainers(stamped)
    }

    /// Containers derive their state from indexed episode files, never a
    /// synthetic container record. One identity query and record batch per show,
    /// even when the page includes all its seasons. Evicted records conservatively
    /// count as unwatched under the store's existing bounded-history policy.
    private func stampContainers(
        _ items: [MediaItem], keepingActiveRewatches: Bool = false
    ) async -> [MediaItem] {
        guard usesCatalogClassification else { return items }
        var indicesBySeries: [String: [Int]] = [:]
        for index in items.indices {
            let item = items[index]
            let key: String?
            switch item.kind {
            case .series:
                key = ShareCatalogID.seriesKey(forSeriesID: item.id)
            case .season:
                key = ShareCatalogID.seasonComponents(forSeasonID: item.id)?.seriesKey
            default:
                key = nil
            }
            if let key { indicesBySeries[key, default: []].append(index) }
        }
        guard !indicesBySeries.isEmpty else { return items }
        let catalog = await self.catalog()
        var result = items
        for (key, indices) in indicesBySeries {
            let identities = await catalog.episodeWatchIdentities(seriesKey: key)
            let records = await watchStore.records(for: Set(identities.map(\.fileID)))
            var bySeason: [Int: [String: [ShareWatchStore.Record]]] = [:]
            for identity in identities {
                bySeason[identity.season, default: [:]][identity.logicalKey, default: []]
                    += records[identity.fileID].map { [$0] } ?? []
            }
            for index in indices {
                let item = items[index]
                let episodes: [[ShareWatchStore.Record]]
                if item.kind == .season,
                   let scope = ShareCatalogID.seasonComponents(forSeasonID: item.id) {
                    episodes = bySeason[scope.season].map { Array($0.values) } ?? []
                } else {
                    episodes = bySeason.values.flatMap { $0.values }
                }
                result[index] = Self.stampedContainer(
                    item, episodes: episodes, keepingActiveRewatches: keepingActiveRewatches
                )
            }
        }
        return result
    }

    /// Indexed local reads only, for the bounded Home candidate window. All
    /// share transports use the same profile/account-scoped watch store.
    func stampRecentlyAdded(_ items: [MediaItem]) async throws -> [MediaItem] {
        var result = items
        for index in result.indices {
            try Task.checkCancellation()
            guard result[index].kind == .series else { continue }
            result[index] = await stampContainers([result[index]], keepingActiveRewatches: true)[0]
        }
        try Task.checkCancellation()
        return result
    }

    private static func stampedContainer(
        _ item: MediaItem, episodes: [[ShareWatchStore.Record]], keepingActiveRewatches: Bool = false
    ) -> MediaItem {
        guard !episodes.isEmpty else { return item }
        // A completed alternate copy must not hide an active Recently Added rewatch.
        let played = episodes.filter { records in
            records.contains(where: \.played)
                && (!keepingActiveRewatches || !records.contains { !$0.played && $0.position > 1 })
        }.count
        let inProgress = episodes.contains { $0.contains { !$0.played && $0.position > 1 } }
        var copy = item
        copy.unwatchedEpisodeCount = episodes.count - played
        copy.isPlayed = played == episodes.count
        copy.playedPercentage = played > 0 ? Double(played) / Double(episodes.count) : nil
        copy.hasBeenPlayed = played > 0 || inProgress
        copy.lastPlayedAt = episodes.flatMap { $0 }.map(\.updatedAt).max()
        return copy
    }

    /// Apply a resolved record onto an item (pure). Exposed so Continue Watching,
    /// which already folds all records itself, can stamp its rebuilt items.
    static func stamped(_ item: MediaItem, with record: ShareWatchStore.Record?) -> MediaItem {
        guard let record else { return item }
        var copy = item
        copy.isPlayed = record.played
        copy.resumePosition = (!record.played && record.position > 1) ? record.position : nil
        copy.lastPlayedAt = record.updatedAt
        // Carry the learned duration onto the item (a share item has no runtime
        // until it's played once) and derive the played fraction the Continue
        // Watching / poster progress bar renders. Only in-progress records get a
        // fraction — a finished (played) or unstarted item shows no bar.
        if let duration = record.duration, duration > 0 {
            if copy.runtime == nil { copy.runtime = duration }
            if !record.played, record.position > 1 {
                copy.playedPercentage = min(max(record.position / duration, 0), 1)
            }
        }
        return copy
    }

    // MARK: Record lookup

    /// Full-history fold used only by Continue Watching, which inherently needs all
    /// resumable state before sorting/limiting.
    func allCanonicalRecords() async -> [String: ShareWatchStore.Record] {
        let snapshot = await watchStore.recordsSnapshot()
        let catalog = await self.catalog()
        var result: [String: ShareWatchStore.Record] = [:]
        for (id, record) in snapshot {
            if usesCatalogClassification,
               ShareExtraDiscoveryPolicy.isRecognizedExtraItemID(id) {
                continue
            }
            let canonical: String
            if usesCatalogClassification {
                canonical = await catalog.canonicalItemID(id)
            } else if let key = ShareCatalogID.movieKey(forMovieID: id),
                      let relPath = await catalog.defaultMovieRelPath(forKey: key) {
                // Reclassifying an existing indexed share as Personal Videos must
                // not strand its movie-level progress. The retained catalog path
                // alias carries that state onto the raw file identity; new writes
                // then stay raw.
                canonical = ShareCatalogID.file(relPath)
            } else {
                canonical = id
            }
            if let existing = result[canonical], existing.updatedAt >= record.updatedAt {
                continue
            }
            result[canonical] = record
        }
        return result
    }

    /// Bounded watch lookup for normal item/page operations. The catalog returns
    /// only aliases relevant to requested ids; the watch store then performs direct
    /// dictionary lookups for that small set.
    func records(for itemIDs: [String]) async -> [String: ShareWatchStore.Record] {
        guard usesCatalogClassification else {
            let catalog = await self.catalog()
            let aliases = await catalog.watchStateAliases(for: itemIDs)
            let stored = await watchStore.records(
                for: Set(itemIDs).union(aliases.keys).union(aliases.values)
            )
            var result: [String: ShareWatchStore.Record] = [:]
            for id in itemIDs {
                let candidates = [stored[id], aliases[id].flatMap { stored[$0] }]
                    .compactMap { $0 }
                if let newest = candidates.max(by: { $0.updatedAt < $1.updatedAt }) {
                    result[id] = newest
                }
            }
            return result
        }
        let catalog = await self.catalog()
        var aliases = await catalog.watchStateAliases(for: itemIDs)
        for id in itemIDs {
            if ShareExtraDiscoveryPolicy.isRecognizedExtraItemID(id) {
                aliases[id] = id
            }
        }
        let stored = await watchStore.records(for: aliases.keys)
        var result: [String: ShareWatchStore.Record] = [:]
        for (storedID, canonicalID) in aliases {
            guard let record = stored[storedID] else { continue }
            if let existing = result[canonicalID], existing.updatedAt >= record.updatedAt { continue }
            result[canonicalID] = record
        }
        return result
    }

    // MARK: Writes

    /// Persist live playback progress locally (a share has no server to report to).
    func recordPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async {
        // A share reports `.stop` with the final position too (the outbox — which
        // owns the played-vs-resume decision that needs duration — may not even
        // target a local share), so `.stop` persists the resume directly here. A
        // later `setPlayed(true)` drained from the outbox (newer `capturedAt`) still
        // supersedes it and clears the resume, so a fully-watched title doesn't
        // linger in Continue Watching.
        PlozzLog.playback.info("share.reportPlayback event=\(String(describing: event)) item=\(progress.itemID) pos=\(Int(progress.positionSeconds)) account=\(accountID)")
        guard await mayPersistWatchState(for: progress.itemID) else { return }
        switch event {
        case .progress, .pause, .stop:
            let id = await watchItemID(for: progress.itemID)
            await watchStore.setResume(progress.positionSeconds, itemID: id, capturedAt: Date(), duration: progress.durationSeconds)
        case .start, .unpause:
            break
        }
    }

    func setPlayed(_ played: Bool, itemID: String, capturedAt: Date) async {
        guard await mayPersistWatchState(for: itemID) else { return }
        if usesCatalogClassification {
            let season = ShareCatalogID.seasonComponents(forSeasonID: itemID)
            if let key = ShareCatalogID.seriesKey(forSeriesID: itemID) ?? season?.seriesKey {
                let identities = await catalog().episodeWatchIdentities(seriesKey: key)
                let files = identities.filter { season == nil || $0.season == season?.season }.map(\.fileID)
                await watchStore.setPlayed(played, itemIDs: files, capturedAt: capturedAt)
                return
            }
        }
        await watchStore.setPlayed(played, itemID: await watchItemID(for: itemID), capturedAt: capturedAt)
    }

    func setResumePosition(_ seconds: TimeInterval, itemID: String, capturedAt: Date) async {
        guard await mayPersistWatchState(for: itemID) else { return }
        if seconds == 0, usesCatalogClassification,
           ShareCatalogID.seriesKey(forSeriesID: itemID) != nil
            || ShareCatalogID.seasonComponents(forSeasonID: itemID) != nil {
            // The outbox follows a played write with a resume clear. The episode
            // batch already cleared progress; containers have no independent resume.
            PlozzLog.playback.debug("share.clearResume container already handled by episode watch state")
            return
        }
        await watchStore.setResume(seconds, itemID: await watchItemID(for: itemID), capturedAt: capturedAt)
    }

    func dismissFromContinueWatching(itemID: String, at date: Date = Date()) async {
        guard await mayPersistWatchState(for: itemID) else { return }
        await watchStore.dismissFromContinueWatching(itemID: await watchItemID(for: itemID), at: date)
    }

    private func mayPersistWatchState(for itemID: String) async -> Bool {
        guard usesCatalogClassification else { return true }
        let stored = await catalog().extraResumeBehavior(fileID: itemID)
        return stored
            ?? ShareExtraDiscoveryPolicy.resumeBehavior(forItemID: itemID)
            ?? true
    }

    private func watchItemID(for itemID: String) async -> String {
        guard usesCatalogClassification else { return itemID }
        let catalog = await self.catalog()
        return await watchItemID(for: itemID, catalog: catalog)
    }

    private func watchItemID(
        for itemID: String,
        catalog: any ShareCatalogReading
    ) async -> String {
        if ShareExtraDiscoveryPolicy.isRecognizedExtraItemID(itemID) { return itemID }
        return await catalog.canonicalItemID(itemID)
    }
}
