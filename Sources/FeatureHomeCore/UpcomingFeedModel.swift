import CoreModels
import CoreNetworking
import Foundation
import Observation

public struct UpcomingFeedSnapshot: Sendable {
    public var releases: [UpcomingRelease]
    public var failedSourceCount: Int
    public var failedAccountIDs: Set<String>
    public var requestsFailed: Bool
    public var failedTitleInterests: [String: Set<UpcomingInterest>]

    public init(
        releases: [UpcomingRelease] = [], failedSourceCount: Int = 0,
        failedAccountIDs: Set<String> = [], requestsFailed: Bool = false,
        failedTitleInterests: [String: Set<UpcomingInterest>] = [:]
    ) {
        self.releases = releases
        self.failedSourceCount = failedSourceCount
        self.failedAccountIDs = failedAccountIDs
        self.requestsFailed = requestsFailed
        self.failedTitleInterests = failedTitleInterests
    }
}

@MainActor
@Observable
public final class UpcomingFeedModel {
    public private(set) var releases: [UpcomingRelease] = []
    public private(set) var isLoading = false
    public private(set) var failedSourceCount = 0
    public private(set) var scopeKey: String?
    public var filters = UpcomingFilters()
    /// Shows the profile has dropped; their episodes leave Upcoming too.
    public var droppedShows: DroppedShowsModel?
    public private(set) var hiddenTitles = Set<String>()
    public private(set) var lastHiddenTitle: String?
    public var refreshRevision = 0 {
        didSet {
            refreshedAt = nil
        }
    }
    @ObservationIgnored private var hiddenKey: String?
    @ObservationIgnored private var refreshedAt: Date?
    @ObservationIgnored private nonisolated(unsafe) var task: Task<Void, Never>?
    @ObservationIgnored private nonisolated(unsafe) var interestObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cache: UpcomingFeedCache?

    public init(defaults: UserDefaults = .standard, cache: UpcomingFeedCache? = nil) {
        self.defaults = defaults
        self.cache = cache
        interestObservers = [
            Notification.Name.universalWatchlistDidChange, .universalWatchlistCacheDidLoad,
            .personalRequestsDidChange
        ].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRevision += 1 }
            }
        }
    }

    deinit {
        task?.cancel()
        for observer in interestObservers { NotificationCenter.default.removeObserver(observer) }
    }

    public var visibleReleases: [UpcomingRelease] {
        releases.filter {
            !hiddenTitles.contains($0.titleKey) && filters.includes($0) && !isDropped($0)
        }
    }

    private func isDropped(_ release: UpcomingRelease) -> Bool {
        droppedShows?.isDropped(release.item) ?? false
    }

    public var homeReleases: [UpcomingRelease] {
        UpcomingReleaseBuilder.home(releases.filter { !isDropped($0) }, hiddenTitles: hiddenTitles)
    }

    public func hide(_ release: UpcomingRelease) {
        hiddenTitles.insert(release.titleKey)
        lastHiddenTitle = release.titleKey
        saveHiddenTitles()
    }

    public func undoHide() {
        guard let lastHiddenTitle else { return }
        hiddenTitles.remove(lastHiddenTitle)
        self.lastHiddenTitle = nil
        saveHiddenTitles()
    }

    public func restoreHiddenTitles() {
        hiddenTitles = []
        lastHiddenTitle = nil
        saveHiddenTitles()
    }

    private func saveHiddenTitles() {
        guard let hiddenKey else { return }
        defaults.set(hiddenTitles.sorted(), forKey: hiddenKey)
    }

    public func refreshIfStale(now: Date = Date()) {
        guard task == nil, needsRefresh(now: now) else { return }
        refreshRevision += 1
    }

    private func needsRefresh(now: Date = Date()) -> Bool {
        guard let refreshedAt else { return true }
        let freshness: TimeInterval = failedSourceCount == 0 ? 6 * 60 * 60 : 60
        return !Calendar.current.isDate(refreshedAt, inSameDayAs: now)
            || now.timeIntervalSince(refreshedAt) >= freshness
    }

    public func invalidate() {
        generation = UUID()
        task?.cancel()
        task = nil
        scopeKey = nil
        releases = []
        refreshedAt = nil
        isLoading = false
        failedSourceCount = 0
        filters = UpcomingFilters()
        hiddenTitles = []
        lastHiddenTitle = nil
        hiddenKey = nil
    }

    public func refresh(
        scope: String, namespace: String?, force: Bool = false,
        cacheScope: String? = nil,
        rehydrate: @escaping @MainActor ([MediaItem]) -> [MediaItem] = { $0 },
        isCurrent: @escaping @MainActor () -> Bool,
        load: @escaping @Sendable () async throws -> UpcomingFeedSnapshot
    ) async {
        await refresh(
            scope: scope, namespace: namespace, force: force, cacheScope: cacheScope,
            rehydrate: rehydrate, isCurrent: isCurrent
        ) { _ in
            try await load()
        }
    }

    public func refresh(
        scope: String, namespace: String?, force: Bool = false,
        cacheScope: String? = nil,
        rehydrate: @escaping @MainActor ([MediaItem]) -> [MediaItem] = { $0 },
        isCurrent: @escaping @MainActor () -> Bool,
        load:
            @escaping @Sendable (
                @escaping @MainActor @Sendable ([UpcomingRelease]) -> Void
            ) async throws -> UpcomingFeedSnapshot
    ) async {
        guard !Task.isCancelled else { return }
        let changedScope = scopeKey != scope
        if scopeKey != scope {
            invalidate()
            scopeKey = scope
            let key = SettingsKey.scoped("upcoming.hiddenTitles", namespace: namespace)
            hiddenKey = key
            hiddenTitles = Set(defaults.stringArray(forKey: key) ?? [])
        }
        guard isCurrent() else {
            invalidate()
            return
        }
        if let task {
            await task.value
            guard !Task.isCancelled, scopeKey == scope, isCurrent() else { return }
            if refreshedAt == nil {
                await refresh(
                    scope: scope, namespace: namespace, force: force, cacheScope: cacheScope,
                    rehydrate: rehydrate, isCurrent: isCurrent, load: load
                )
            }
            return
        }
        if !force, !needsRefresh() { return }
        isLoading = true
        let generation = generation
        let revision = refreshRevision
        let work = Task { [weak self] in
            defer {
                if let self, self.generation == generation {
                    self.isLoading = false
                    self.task = nil
                }
            }
            do {
                if changedScope, let self, let cacheScope, let cache = self.cache,
                   let cached = await cache.load(scope: cacheScope, namespace: namespace) {
                    try Task.checkCancellation()
                    guard self.generation == generation, isCurrent() else { return }
                    let items = rehydrate(cached.releases.map(\.item))
                    if items.count == cached.releases.count {
                        self.releases = zip(cached.releases, items).map { release, item in
                            var release = release
                            release.item = item
                            return release
                        }
                        self.failedSourceCount = cached.failedSourceCount
                        if self.refreshRevision == revision, revision == 0, !force {
                            self.refreshedAt = cached.savedAt
                            if !self.needsRefresh() { return }
                        }
                    } else {
                        PlozzLog.networking.error("Upcoming cached artwork could not be restored; refreshing releases")
                    }
                }
                let snapshot = try await load { [weak self] releases in
                    guard let self, self.generation == generation, isCurrent() else { return }
                    self.releases = UpcomingReleaseBuilder.merging(releases + self.releases)
                }
                try Task.checkCancellation()
                guard let self, self.generation == generation, isCurrent() else { return }
                var refreshed = snapshot.releases
                for previous in self.releases {
                    var retainedInterests = Set<UpcomingInterest>()
                    if previous.item.sourceAccountID.map(snapshot.failedAccountIDs.contains) == true,
                       previous.interests.contains(.watching) {
                        retainedInterests.insert(.watching)
                    }
                    if snapshot.requestsFailed, previous.interests.contains(.requested) {
                        retainedInterests.insert(.requested)
                    }
                    retainedInterests.formUnion(snapshot.failedTitleInterests[previous.titleKey] ?? [])
                    guard !retainedInterests.isEmpty else { continue }
                    if let index = refreshed.firstIndex(where: {
                            $0.id == previous.id
                                || ($0.kind == previous.kind && $0.date == previous.date
                                    && MediaItemMerger.merge([$0.item, previous.item]).count == 1)
                        }) {
                        if retainedInterests.contains(.watching), !refreshed[index].interests.contains(.watching) {
                            refreshed[index].item = previous.item
                        }
                        refreshed[index].interests.formUnion(retainedInterests)
                    } else {
                        var retained = previous
                        retained.interests = retainedInterests
                        refreshed.append(retained)
                    }
                }
                self.releases = UpcomingReleaseBuilder.merging(refreshed)
                self.failedSourceCount = snapshot.failedSourceCount
                self.refreshedAt = self.refreshRevision == revision ? Date() : nil
                if self.refreshRevision == revision, let cacheScope, let cache = self.cache {
                    await cache.save(
                        releases: self.releases, failedSourceCount: self.failedSourceCount,
                        scope: cacheScope, namespace: namespace, savedAt: Date()
                    )
                }
            } catch is CancellationError {
                // Scope invalidation owns clearing the previous identity's data.
            } catch {
                guard let self, self.generation == generation, isCurrent() else { return }
                PlozzLog.networking.error("Upcoming releases could not be refreshed")
                self.failedSourceCount = max(1, self.failedSourceCount)
                self.refreshedAt = self.refreshRevision == revision ? Date() : nil
            }
        }
        task = work
        await work.value
    }
}
