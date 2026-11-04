import CoreModels
import CoreNetworking
import Foundation
import Observation

public struct DiscoverRow: Identifiable {
    public let feed: DiscoverFeed
    public var items: [MediaItem] = []
    public var isLoading = false
    public var error: DiscoverFeedError?
    public var nextPage: Int? = 1
    public var id: DiscoverFeed { feed }
}

@MainActor
@Observable
public final class DiscoverBrowseModel {
    public typealias Loader = @MainActor @Sendable (DiscoverFeed, Int) async throws -> DiscoverPage
    public typealias LibraryResolver = @MainActor @Sendable ([MediaItem]) async -> [MediaItem]
    public private(set) var rows = DiscoverFeed.defaultOrder.map { DiscoverRow(feed: $0) }
    public var visibleRows: [DiscoverRow] { rows.filter { filters.shows($0.feed) } }
    public var filters: DiscoverFilters {
        get { storedFilters }
        set {
            let saved = store.load()
            var updated = saved
            if newValue.availableNow != storedFilters.availableNow { updated.availableNow = newValue.availableNow }
            if newValue.hideWatched != storedFilters.hideWatched { updated.hideWatched = newValue.hideWatched }
            storedFilters = updated
            if updated != saved { store.save(updated) }
        }
    }
    private var storedFilters: DiscoverFilters
    @ObservationIgnored private let store: DiscoverFiltersStore
    @ObservationIgnored private var observation: UserDefaultsObservation?
    @ObservationIgnored private let isCurrent: @MainActor @Sendable () -> Bool
    @ObservationIgnored private let loadPage: Loader
    @ObservationIgnored private let resolveLibrarySources: LibraryResolver
    @ObservationIgnored private let pendingWatchedStates: @MainActor @Sendable () async -> [MediaItemMutation]
    @ObservationIgnored private var mutations: [MediaItemMutation] = []
    @ObservationIgnored private var generation = UUID()

    public init(
        store: DiscoverFiltersStore,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        pendingWatchedStates: @escaping @MainActor @Sendable () async -> [MediaItemMutation] = { [] },
        resolveLibrarySources: @escaping LibraryResolver = { $0 },
        loadPage: @escaping Loader
    ) {
        self.store = store
        self.storedFilters = store.load()
        self.isCurrent = isCurrent
        self.pendingWatchedStates = pendingWatchedStates
        self.loadPage = loadPage
        self.resolveLibrarySources = resolveLibrarySources
        observation = UserDefaultsObservation { [weak self] in
            guard let self else { return }
            let saved = self.store.load()
            if self.storedFilters != saved { self.storedFilters = saved }
        }
    }

    public func load() async {
        guard !Task.isCancelled else { return }
        guard isCurrent() else { invalidate(); return }
        let pending = visibleRows.filter { $0.nextPage == 1 && !$0.isLoading && $0.error == nil }.map(\.feed)
        await withTaskGroup(of: Void.self) { group in
            var iterator = pending.makeIterator()
            for _ in 0..<2 {
                if let feed = iterator.next() { group.addTask { await self.loadMore(feed) } }
            }
            while await group.next() != nil {
                guard !Task.isCancelled, isCurrent() else { group.cancelAll(); break }
                if let feed = iterator.next() { group.addTask { await self.loadMore(feed) } }
            }
        }
    }

    public func loadMore(_ feed: DiscoverFeed) async {
        guard !Task.isCancelled else { return }
        guard isCurrent() else { invalidate(); return }
        guard filters.shows(feed), let index = rows.firstIndex(where: { $0.feed == feed }),
              !rows[index].isLoading, let page = rows[index].nextPage else { return }
        let token = generation
        let initialMutations = mutations
        rows[index].isLoading = true
        rows[index].error = nil
        defer { if token == generation { rows[index].isLoading = false } }
        do {
            let pendingBefore = await pendingWatchedStates()
            try Task.checkCancellation()
            guard token == generation, isCurrent() else { return }
            let result = try await loadPage(feed, page)
            let pendingAfter = await pendingWatchedStates()
            try Task.checkCancellation()
            guard token == generation, isCurrent() else { return }
            guard result.nextPage == nil || result.nextPage == page + 1 else {
                throw AppError.invalidResponse
            }
            retireConfirmedMutations(in: result.items, pending: pendingBefore + pendingAfter, initial: initialMutations)
            var seen = Set(rows[index].items.map(\.stablePresentationID))
            let added = result.items.filter { seen.insert($0.stablePresentationID).inserted }
            rows[index].items += applyingWatchedStates(added, pending: pendingBefore + pendingAfter)
            // A repeated upstream page must not become an endless Load More loop.
            rows[index].nextPage = !result.items.isEmpty && added.isEmpty ? nil : result.nextPage
        } catch is CancellationError {
            // Cancelled rows remain retryable; cancellation is not an empty feed.
        } catch {
            guard !Task.isCancelled, token == generation, isCurrent() else { return }
            PlozzLog.app.error("Discover feed failed: \(feed.rawValue)")
            rows[index].error = (error as? DiscoverFeedError)
                ?? .service((error as? AppError) ?? .unknown(""))
        }
    }

    public func invalidate() {
        generation = UUID()
        mutations = []
        rows = DiscoverFeed.defaultOrder.map { DiscoverRow(feed: $0) }
    }

    public func loadMoreVisibleItems(_ feed: DiscoverFeed) async {
        guard let index = rows.firstIndex(where: { $0.feed == feed }) else { return }
        let token = generation
        let visibleIDs = rows[index].items.filter(filters.includes).map(\.stablePresentationID)
        while !Task.isCancelled, token == generation, isCurrent(), rows[index].error == nil,
              let page = rows[index].nextPage {
            await loadMore(feed)
            guard token == generation, rows[index].nextPage != page else { return }
            // A filtered or unmappable page does not move the rail's trailing edge.
            if rows[index].items.filter(filters.includes).map(\.stablePresentationID) != visibleIDs {
                return
            }
        }
    }

    public func refreshLibrarySources() async {
        guard !Task.isCancelled, isCurrent() else { return }
        let token = generation
        let snapshot = rows
        let initialMutations = mutations
        let items = snapshot.flatMap(\.items)
        guard !items.isEmpty else { return }
        let pendingBefore = await pendingWatchedStates()
        guard !Task.isCancelled, token == generation, isCurrent() else { return }
        let refreshed = await resolveLibrarySources(items)
        let pendingAfter = await pendingWatchedStates()
        guard !Task.isCancelled, token == generation, isCurrent() else { return }
        guard refreshed.count == items.count else {
            PlozzLog.app.error("Discover library refresh returned an incomplete result")
            return
        }
        retireConfirmedMutations(in: refreshed, pending: pendingBefore + pendingAfter, initial: initialMutations)
        var offset = 0
        for index in rows.indices {
            let count = snapshot[index].items.count
            // Pagination or a watched mutation may have changed a row while resolving.
            if rows[index].items == snapshot[index].items {
                rows[index].items = applyingWatchedStates(
                    Array(refreshed[offset..<(offset + count)]), pending: pendingBefore + pendingAfter
                )
            }
            offset += count
        }
    }

    public func applyWatchedState(_ mutation: MediaItemMutation) {
        guard isCurrent() else { invalidate(); return }
        if mutation.played != nil {
            mutations.removeAll {
                $0.played != nil && $0.itemIDs == mutation.itemIDs
                    && $0.scopedItemIDs == mutation.scopedItemIDs
                    && $0.cascadesToSeasonEpisodes == mutation.cascadesToSeasonEpisodes
            }
            mutations.append(mutation)
        }
        for index in rows.indices {
            rows[index].items = rows[index].items.map { mutation.applied(to: $0) }
        }
    }

    private func applyingWatchedStates(_ items: [MediaItem], pending: [MediaItemMutation]) -> [MediaItem] {
        items.map { item in
            (pending + mutations).reduce(item) { $1.applied(to: $0) }
        }
    }

    private func retireConfirmedMutations(
        in items: [MediaItem], pending: [MediaItemMutation], initial: [MediaItemMutation]
    ) {
        mutations.removeAll { mutation in
            guard initial.contains(mutation), let played = mutation.played else { return false }
            let targets = items.filter(mutation.targets)
            return !targets.isEmpty && targets.allSatisfy { item in
                guard !pending.contains(where: { $0.targets(item) }) else { return false }
                let sources = item.sources.filter {
                    mutation.matches(accountID: $0.accountID, itemID: $0.itemID)
                }
                // Servers need not echo synthetic completion percentages or cleared resume values.
                return sources.isEmpty ? item.isPlayed == played : sources.allSatisfy { $0.isPlayed == played }
            }
        }
    }
}
