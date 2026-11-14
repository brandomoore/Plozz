import CoreModels
import CoreNetworking
import Foundation
import Observation

public struct UpcomingFeedSnapshot: Sendable {
    public var releases: [UpcomingRelease]
    public var failedSourceCount: Int
    public var failedAccountIDs: Set<String>
    public var requestsFailed: Bool
    public var failedTitleKeys: Set<String>

    public init(
        releases: [UpcomingRelease] = [], failedSourceCount: Int = 0,
        failedAccountIDs: Set<String> = [], requestsFailed: Bool = false,
        failedTitleKeys: Set<String> = []
    ) {
        self.releases = releases
        self.failedSourceCount = failedSourceCount
        self.failedAccountIDs = failedAccountIDs
        self.requestsFailed = requestsFailed
        self.failedTitleKeys = failedTitleKeys
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
    public private(set) var hiddenTitles = Set<String>()
    public private(set) var lastHiddenTitle: String?
    public var refreshRevision = 0 {
        didSet {
            task?.cancel()
            task = nil
            generation = UUID()
            refreshedAt = nil
            isLoading = false
        }
    }
    @ObservationIgnored private var hiddenKey: String?
    @ObservationIgnored private var refreshedAt: Date?
    @ObservationIgnored private nonisolated(unsafe) var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    deinit { task?.cancel() }

    public var visibleReleases: [UpcomingRelease] {
        releases.filter { !hiddenTitles.contains($0.titleKey) && filters.includes($0) }
    }

    public var homeReleases: [UpcomingRelease] {
        UpcomingReleaseBuilder.home(releases, hiddenTitles: hiddenTitles)
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
        isCurrent: @escaping @MainActor () -> Bool,
        load: @escaping @Sendable () async throws -> UpcomingFeedSnapshot
    ) async {
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
            return
        }
        if !force, let refreshedAt, Date().timeIntervalSince(refreshedAt) < 6 * 60 * 60 { return }
        isLoading = true
        let generation = generation
        let work = Task { [weak self] in
            defer {
                if let self, self.generation == generation {
                    self.isLoading = false
                    self.task = nil
                }
            }
            do {
                let snapshot = try await load()
                try Task.checkCancellation()
                guard let self, self.generation == generation, isCurrent() else { return }
                let retained = self.releases.filter { previous in
                    let unavailable =
                        (previous.kind == .episode
                            && previous.item.sourceAccountID.map(snapshot.failedAccountIDs.contains) == true)
                        || (snapshot.requestsFailed && previous.interests.contains(.requested))
                        || snapshot.failedTitleKeys.contains(previous.titleKey)
                    return unavailable
                        && !snapshot.releases.contains {
                            $0.id == previous.id
                                || ($0.kind == previous.kind && $0.date == previous.date
                                    && MediaItemMerger.merge([$0.item, previous.item]).count == 1)
                        }
                }
                self.releases =
                    (snapshot.releases
                    + retained.map { release in
                        var release = release
                        if snapshot.requestsFailed, release.kind != .episode, release.interests.contains(.requested) {
                            release.interests = [.requested]
                        }
                        return release
                    }).sorted {
                        $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date
                    }
                self.failedSourceCount = snapshot.failedSourceCount
                self.refreshedAt = snapshot.failedSourceCount == 0 ? Date() : nil
            } catch is CancellationError {
                // Scope invalidation owns clearing the previous identity's data.
            } catch {
                guard let self, self.generation == generation, isCurrent() else { return }
                PlozzLog.networking.error("Upcoming releases could not be refreshed")
                self.failedSourceCount = max(1, self.failedSourceCount)
            }
        }
        task = work
        await work.value
    }
}
