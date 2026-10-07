import Foundation
import CoreModels
import CoreNetworking

/// Fans out over every active account's provider and merges the results into the
/// unified Home/Settings content, tagging each item/library with its owning
/// account so callers can route a selection back to the right provider.
///
/// Each row family has a bounded queue and publishes completed rows independently.
/// Each merged row retains deterministic cross-server ordering; unrelated rows
/// never wait for its slowest source. Queries remain indexed and limited.
public struct HomeAggregator: Sendable {
    public init() {}

    /// The merged Home content across all active accounts.
    public struct Content: Equatable, Sendable {
        public var continueWatching: [MediaItem]
        public var latest: [MediaItem]
        /// The unified Watchlist row, merged across every `WatchlistProviding`
        /// account (Jellyfin Favorites today). Empty when nothing is saved or no
        /// active account supports a watchlist — the UI then hides the row.
        public var watchlist: [MediaItem]
        /// Every discovered library (unfiltered); callers apply Home-visibility.
        public var libraries: [AggregatedLibrary]

        public init(
            continueWatching: [MediaItem] = [],
            latest: [MediaItem] = [],
            watchlist: [MediaItem] = [],
            libraries: [AggregatedLibrary] = []
        ) {
            self.continueWatching = continueWatching
            self.latest = latest
            self.watchlist = watchlist
            self.libraries = libraries
        }
    }

    public struct Progress: Equatable, Sendable {
        public var content: UnmergedContent
        public var loadingRows: Set<HomeRowKind>
        public var failures: [HomeRowKind: AppError]
    }

    /// Loads and merges Continue Watching, Recently Added, and Libraries across
    /// `accounts`. Per-account results keep their server order; Recently Added and
    /// Watchlist rows from different servers are round-robin interleaved so every
    /// server gets fair top-of-row representation, while Continue Watching is
    /// additionally sorted by ``MediaItem/lastPlayedAt`` (most-recent-wins across
    /// servers) so it reflects what was actually watched last.
    public func content(
        from accounts: [ResolvedAccount],
        policy: ContinueWatchingPolicy = .default,
        continueWatchingLimit: Int? = nil,
        latestLimit: Int = 20,
        watchlistLimit: Int = 10_000,
        visibility: HomeLibraryVisibility = .default,
        forceLibraryScoping: Bool = false,
        identitySources: @Sendable (MediaItem) -> [MediaSourceRef] = { _ in [] },
        onContinueWatching: @escaping @Sendable (String, [MediaItem]) async -> Void = { _, _ in },
        onProgress: @escaping @Sendable (Progress) async -> Void = { _ in }
    ) async -> Content {
        let result = await Self.loadContent(
            from: accounts, policy: policy,
            continueWatchingLimit: continueWatchingLimit ?? policy.rowLimit,
            latestLimit: latestLimit, watchlistLimit: watchlistLimit,
            perLibraryLimit: nil, visibility: visibility,
            forceLibraryScoping: forceLibraryScoping,
            identitySources: identitySources,
            onContinueWatching: onContinueWatching, onProgress: onProgress
        )
        return Content(
            continueWatching: result.continueWatching, latest: result.latest,
            watchlist: result.watchlist, libraries: result.libraries
        )
    }

    /// Discovers every library across `accounts`, tagged with account/provider
    /// metadata — used by the Settings checklist. Resilient per account.
    public func libraries(from accounts: [ResolvedAccount]) async -> [AggregatedLibrary] {
        await libraryDiscovery(from: accounts).libraries
    }

    /// The result of a cross-account library discovery: the flattened library list
    /// plus the set of accounts whose fetch **failed** (server offline /
    /// unreachable). The failure set lets Settings tell a genuinely-empty server
    /// ("no libraries") apart from one it simply couldn't reach ("offline"),
    /// instead of showing both as "No libraries found".
    public struct LibraryDiscovery: Sendable {
        public let libraries: [AggregatedLibrary]
        public let unreachableAccountIDs: Set<String>
        public let failures: [String: AppError]
        public init(libraries: [AggregatedLibrary], unreachableAccountIDs: Set<String>, failures: [String: AppError] = [:]) {
            self.libraries = libraries
            self.unreachableAccountIDs = unreachableAccountIDs
            self.failures = failures
        }

        public func canSkipSelection(for accounts: [ResolvedAccount]) -> Bool {
            libraries.isEmpty && unreachableAccountIDs.isEmpty && failures.isEmpty
                && !accounts.isEmpty && accounts.allSatisfy { $0.account.server.provider == .iptv }
        }
    }

    /// Like ``libraries(from:)`` but also reports which accounts were unreachable,
    /// so callers can surface a "server offline" state rather than folding a
    /// connection failure into an empty library list.
    public func libraryDiscovery(from accounts: [ResolvedAccount]) async -> LibraryDiscovery {
        let outcomes = await Self.loadPerAccount(accounts) { resolved in
            await Self.libraryOutcome(from: resolved)
        }
        var libraries: [AggregatedLibrary] = []
        var unreachable: Set<String> = []
        var failures: [String: AppError] = [:]
        for outcome in outcomes {
            switch outcome {
            case let .libraries(libs): libraries.append(contentsOf: libs)
            case let .unreachable(accountID, error):
                unreachable.insert(accountID)
                failures[accountID] = error
            }
        }
        return LibraryDiscovery(libraries: libraries, unreachableAccountIDs: unreachable, failures: failures)
    }

    private enum AccountLibraryOutcome: Sendable {
        /// Reachable — carries this server's libraries (possibly empty).
        case libraries([AggregatedLibrary])
        /// The library fetch threw (server offline / unreachable). Carries the
        /// account id so the UI can mark that server offline.
        case unreachable(String, AppError)
    }

    private static func libraryOutcome(from resolved: ResolvedAccount) async -> AccountLibraryOutcome {
        do {
            let libs = try await resolved.provider.libraries()
            return .libraries(libs.map { aggregated($0, from: resolved) })
        } catch {
            PlozzLog.app.error("Aggregation: failed to list libraries for account \(resolved.account.id)")
            return .unreachable(resolved.account.id, (error as? AppError) ?? .unknown(""))
        }
    }

    // MARK: - Unmerged (per-library) content

    /// The Home content when the profile has turned **off** "Merge libraries on
    /// Home": the global Continue Watching + Watchlist rows stay cross-server merged
    /// at the top (built by the merged ``content(from:)`` path so they behave
    /// identically), the full library inventory feeds the Libraries tiles (browse
    /// entry points), and each library the user has opted rows into contributes a
    /// block of those rows.
    public struct UnmergedContent: Equatable, Sendable {
        /// Global, cross-server merged Continue Watching (unfiltered; the view
        /// applies Home-visibility just like the merged layout).
        public var continueWatching: [MediaItem]
        /// Global, cross-server merged Recently Added — the same feed merged mode
        /// shows. Rendered as the global "Recently Added" row when the user has
        /// that row enabled (independent of the opt-in per-library "Recently Added
        /// in X" rows).
        public var latest: [MediaItem]
        /// Global, cross-server merged Watchlist.
        public var watchlist: [MediaItem]
        /// Full (Home-eligible, music-excluded) library inventory — feeds the
        /// Libraries tiles so the user can browse into any library's grid.
        public var libraries: [AggregatedLibrary]
        /// Per-library section blocks for libraries the user opted rows into, in
        /// inventory order. Empty blocks (no enabled/non-empty rows) are dropped.
        public var librarySections: [HomeLibrarySectionGroup]

        public init(
            continueWatching: [MediaItem] = [],
            latest: [MediaItem] = [],
            watchlist: [MediaItem] = [],
            libraries: [AggregatedLibrary] = [],
            librarySections: [HomeLibrarySectionGroup] = []
        ) {
            self.continueWatching = continueWatching
            self.latest = latest
            self.watchlist = watchlist
            self.libraries = libraries
            self.librarySections = librarySections
        }

        public var isEmpty: Bool {
            continueWatching.isEmpty && latest.isEmpty && watchlist.isEmpty
                && libraries.isEmpty && librarySections.isEmpty
        }
    }

    /// Builds unmerged Home with the same global rows. Opted-in library requests
    /// enter the bounded queue as soon as their library inventory arrives:
    ///  - **Recently Added** — the library's newest items (`items(in:)` sorted by
    ///    date added), uniform across providers — when the user enabled it.
    ///  - **Recommended rows** — the provider's native discovery hubs
    ///    (`libraryHubs(...)`, Plex only: "More in Drama", "Because you watched…") —
    ///    when the user enabled them.
    ///
    /// Per-library Continue Watching is intentionally not built here: Continue
    /// Watching is always the single global row (a per-library duplicate is
    /// redundant). A library the user hasn't opted any rows into contributes no
    /// block, so Home stays lean by default. `merged.libraries` still carries the
    /// full inventory for the Libraries tiles (browse entry points).
    public func unmergedContent(
        from accounts: [ResolvedAccount],
        policy: ContinueWatchingPolicy = .default,
        continueWatchingLimit: Int? = nil,
        latestLimit: Int = 20,
        watchlistLimit: Int = 10_000,
        perLibraryLimit: Int = 20,
        visibility: HomeLibraryVisibility = .default,
        identitySources: @Sendable (MediaItem) -> [MediaSourceRef] = { _ in [] },
        onContinueWatching: @escaping @Sendable (String, [MediaItem]) async -> Void = { _, _ in },
        onProgress: @escaping @Sendable (Progress) async -> Void = { _ in }
    ) async -> UnmergedContent {
        await Self.loadContent(
            from: accounts, policy: policy,
            continueWatchingLimit: continueWatchingLimit ?? policy.rowLimit,
            latestLimit: latestLimit, watchlistLimit: watchlistLimit,
            perLibraryLimit: perLibraryLimit, visibility: visibility,
            identitySources: identitySources,
            onContinueWatching: onContinueWatching, onProgress: onProgress
        )
    }

    // MARK: - Per-account loading

    private struct AccountContent: Sendable {
        var continueWatching: [MediaItem] = []
        var latest: [MediaItem] = []
        var watchlist: [MediaItem] = []
        var libraries: [AggregatedLibrary] = []
        var completed: Set<HomeRowKind> = []
        var failures: [HomeRowKind: AppError] = [:]
    }

    /// Bounded account-level fan-out for Home aggregation so launch-time network
    /// and decoding work can't swamp the UI and image pipeline when many accounts
    /// are active. Sized to a typical multi-server household so the last accounts
    /// don't wait behind the first few (a slow/asleep server in the first slots
    /// would otherwise ~double the time the remaining accounts take to surface).
    private static let accountFanoutLimit = 5

    /// Executes per-account work preserving account order while capping how many
    /// accounts run concurrently.
    private static func loadPerAccount<T: Sendable>(
        _ accounts: [ResolvedAccount],
        maxConcurrentAccounts: Int = accountFanoutLimit,
        operation: @escaping @Sendable (ResolvedAccount) async -> T
    ) async -> [T] {
        guard !accounts.isEmpty else { return [] }
        let concurrency = max(1, min(maxConcurrentAccounts, accounts.count))
        return await withTaskGroup(of: (Int, T).self) { group in
            var nextIndex = 0
            for _ in 0..<concurrency {
                let index = nextIndex
                nextIndex += 1
                let resolved = accounts[index]
                group.addTask { (index, await operation(resolved)) }
            }

            var byIndex: [Int: T] = [:]
            while let (index, value) = await group.next() {
                byIndex[index] = value
                // Stop spooling up the remaining accounts once the aggregation has
                // been cancelled (Home dismissed / re-triggered). Without this the
                // window keeps refilling and fires a fetch for every remaining
                // account even though nobody is waiting for the result.
                if nextIndex < accounts.count, !Task.isCancelled {
                    let queuedIndex = nextIndex
                    nextIndex += 1
                    let resolved = accounts[queuedIndex]
                    group.addTask { (queuedIndex, await operation(resolved)) }
                }
            }
            return accounts.indices.compactMap { byIndex[$0] }
        }
    }

    /// Generic bounded, order-preserving fan-out over any element list — used by
    /// the unmerged per-library builder so many libraries don't storm the network
    /// at once. Mirrors ``loadPerAccount(_:maxConcurrentAccounts:operation:)`` but
    /// over arbitrary `Element`s, and stops queueing once cancelled.
    private static func loadBounded<Element: Sendable, T: Sendable>(
        _ elements: [Element],
        maxConcurrent: Int = accountFanoutLimit,
        operation: @escaping @Sendable (Element) async -> T
    ) async -> [T] {
        guard !elements.isEmpty else { return [] }
        let concurrency = max(1, min(maxConcurrent, elements.count))
        return await withTaskGroup(of: (Int, T).self) { group in
            var nextIndex = 0
            for _ in 0..<concurrency {
                let index = nextIndex
                nextIndex += 1
                let element = elements[index]
                group.addTask { (index, await operation(element)) }
            }

            var byIndex: [Int: T] = [:]
            while let (index, value) = await group.next() {
                byIndex[index] = value
                if nextIndex < elements.count, !Task.isCancelled {
                    let queuedIndex = nextIndex
                    nextIndex += 1
                    let element = elements[queuedIndex]
                    group.addTask { (queuedIndex, await operation(element)) }
                }
            }
            return elements.indices.compactMap { byIndex[$0] }
        }
    }

    private enum Feed: CaseIterable, Sendable {
        case continueWatching, latest, watchlist

        var row: HomeRowKind {
            switch self {
            case .continueWatching: .continueWatching
            case .latest: .recentlyAdded
            case .watchlist: .watchlist
            }
        }
    }

    private enum RequestLane: Hashable, Sendable {
        case global(HomeRowKind)
        case libraryRows
    }

    private enum Request: Sendable {
        case libraries(Int)
        case feed(Int, Feed, libraryIDs: [String]?)
        case library(Int, AggregatedLibrary, LibraryHomeRowKind)

        var lane: RequestLane {
            switch self {
            case .libraries: .global(.libraries)
            case .feed(_, let feed, _): .global(feed.row)
            case .library: .libraryRows
            }
        }
    }

    private enum Response: Sendable {
        case libraries(Int, Result<[MediaLibrary], AppError>)
        case feed(Int, Feed, Result<[MediaItem], AppError>)
        case library(String, LibraryHomeRowKind, Result<[LibrarySection], AppError>)
    }

    private struct LibraryContent {
        let library: AggregatedLibrary
        var loadingRows: Set<LibraryHomeRowKind>
        var sections: [LibraryHomeRowKind: [LibrarySection]] = [:]
        var failures: [LibraryHomeRowKind: AppError] = [:]

        var group: HomeLibrarySectionGroup {
            HomeLibrarySectionGroup(
                library: library,
                sections: LibraryHomeRowKind.allCases.flatMap { sections[$0] ?? [] },
                loadingRows: loadingRows,
                failures: failures
            )
        }
    }

    private actor SeriesIdentities {
        private var tasks: [String: Task<[String: [String: String]], Never>] = [:]

        func resolve(_ items: [MediaItem], provider: any MediaProvider) async -> [String: [String: String]] {
            let seriesIDs = Set(items.filter { $0.kind == .episode }.compactMap(\.seriesID))
            let missing = seriesIDs.filter { tasks[$0] == nil }
            if !missing.isEmpty, !Task.isCancelled {
                let pendingItems = items.filter { $0.seriesID.map(missing.contains) ?? false }
                let task = Task { await seriesProviderIDs(for: pendingItems, provider: provider) }
                for id in missing { tasks[id] = task }
            }
            var result: [String: [String: String]] = [:]
            for id in seriesIDs {
                guard !Task.isCancelled else { return [:] }
                if let ids = await tasks[id]?.value[id] { result[id] = ids }
            }
            return result
        }

        func cancel() {
            for task in tasks.values { task.cancel() }
        }
    }

    private static func loadContent(
        from accounts: [ResolvedAccount],
        policy: ContinueWatchingPolicy,
        continueWatchingLimit: Int,
        latestLimit: Int,
        watchlistLimit: Int,
        perLibraryLimit: Int?,
        visibility: HomeLibraryVisibility,
        forceLibraryScoping: Bool = false,
        identitySources: @Sendable (MediaItem) -> [MediaSourceRef],
        onContinueWatching: @escaping @Sendable (String, [MediaItem]) async -> Void,
        onProgress: @escaping @Sendable (Progress) async -> Void
    ) async -> UnmergedContent {
        guard !accounts.isEmpty else { return UnmergedContent() }
        let clock = ContinuousClock()
        let started = clock.now
        let serverInfo = accounts.sourceServerInfo()
        let seriesIdentities = accounts.map { _ in SeriesIdentities() }
        let scopedAccounts = Set(accounts.indices.filter { index in
            forceLibraryScoping || visibility.disabledKeys.contains {
                $0.hasPrefix("\(accounts[index].account.id):")
            }
        })

        return await withTaskCancellationHandler {
            await withTaskGroup(of: (RequestLane, Response).self) { group in
                var requests = accounts.indices.map(Request.libraries)
                for index in accounts.indices {
                    for feed in Feed.allCases where feed == .watchlist || !scopedAccounts.contains(index) {
                        requests.append(.feed(index, feed, libraryIDs: nil))
                    }
                }
                var running: [RequestLane: Int] = [:]
                var perAccount = accounts.map { _ in AccountContent() }
                var perLibrary: [String: LibraryContent] = [:]
                var publishedRows: Set<HomeRowKind> = []
                var content = UnmergedContent()
                var failures: [HomeRowKind: AppError] = [:]

                func enqueueAvailable() {
                    while !Task.isCancelled, let index = requests.firstIndex(where: {
                        running[$0.lane, default: 0] < accountFanoutLimit
                    }) {
                        let request = requests.remove(at: index)
                        let lane = request.lane
                        running[lane, default: 0] += 1
                        group.addTask {
                            let response = await perform(
                                request, accounts: accounts, policy: policy,
                                continueWatchingLimit: continueWatchingLimit,
                                latestLimit: latestLimit, perLibraryLimit: perLibraryLimit ?? 20,
                                seriesIdentities: seriesIdentities,
                                onContinueWatching: onContinueWatching
                            )
                            return (lane, response)
                        }
                    }
                }

                enqueueAvailable()
                while let (lane, response) = await group.next() {
                    running[lane, default: 0] -= 1
                    guard !Task.isCancelled else {
                        group.cancelAll()
                        break
                    }
                    switch response {
                    case let .libraries(index, result):
                        perAccount[index].completed.insert(.libraries)
                        switch result {
                        case let .success(libraries):
                            let resolved = accounts[index]
                            let tagged = libraries.map { aggregated($0, from: resolved) }
                            perAccount[index].libraries = tagged
                            let visible = tagged.filter {
                                !$0.library.isMusic && visibility.isVisibleOnHome($0.key)
                            }
                            if scopedAccounts.contains(index) {
                                for feed in [Feed.continueWatching, .latest] {
                                    requests.append(.feed(index, feed, libraryIDs: visible.map(\.library.id)))
                                }
                            }
                            if perLibraryLimit != nil {
                                for library in visible where perLibrary[library.key] == nil {
                                    let kinds = LibraryHomeRowKind.allCases.filter {
                                        visibility.isLibraryRowEnabled(library.key, kind: $0)
                                    }
                                    guard !kinds.isEmpty else { continue }
                                    perLibrary[library.key] = LibraryContent(
                                        library: library, loadingRows: Set(kinds)
                                    )
                                    for kind in kinds {
                                        requests.append(.library(index, library, kind))
                                    }
                                }
                            }
                        case let .failure(error):
                            perAccount[index].failures[.libraries] = error
                            if scopedAccounts.contains(index) {
                                for kind in [HomeRowKind.continueWatching, .recentlyAdded] {
                                    perAccount[index].completed.insert(kind)
                                    perAccount[index].failures[kind] = error
                                }
                            }
                        }
                    case let .feed(index, feed, result):
                        perAccount[index].completed.insert(feed.row)
                        switch result {
                        case let .success(items):
                            switch feed {
                            case .continueWatching: perAccount[index].continueWatching = items
                            case .latest: perAccount[index].latest = items
                            case .watchlist: perAccount[index].watchlist = items
                            }
                        case let .failure(error):
                            perAccount[index].failures[feed.row] = error
                        }
                    case let .library(key, kind, result):
                        perLibrary[key]?.loadingRows.remove(kind)
                        switch result {
                        case let .success(sections): perLibrary[key]?.sections[kind] = sections
                        case let .failure(error): perLibrary[key]?.failures[kind] = error
                        }
                        PlozzLog.boot(
                            "HomeAgg.libraryRow kind=\(kind.rawValue) ms=\(elapsedMS(from: started, to: clock.now))")
                    }
                    // Refill before publication so drawing a completed row never stalls
                    // the request queue for the remaining libraries.
                    enqueueAvailable()

                    let librariesComplete = perAccount.allSatisfy { $0.completed.contains(.libraries) }
                    content.libraries = perAccount.flatMap(\.libraries).filter { !$0.library.isMusic }
                    for row in HomeRowKind.allCases where !publishedRows.contains(row) {
                        guard perAccount.allSatisfy({ $0.completed.contains(row) }),
                            row == .watchlist || librariesComplete
                        else { continue }
                        publishedRows.insert(row)
                        failures[row] = perAccount.compactMap { $0.failures[row] }.first
                        let groups = perAccount.map { account -> [MediaItem] in
                            let music = Set(account.libraries.filter(\.library.isMusic).map(\.library.id))
                            switch row {
                            case .continueWatching:
                                return policy.curated(
                                    account.continueWatching.filter {
                                        $0.libraryID.map { !music.contains($0) } ?? true
                                    })
                            case .recentlyAdded:
                                return account.latest.filter { $0.libraryID.map { !music.contains($0) } ?? true }
                            case .watchlist: return account.watchlist
                            case .libraries: return []
                            }
                        }
                        switch row {
                        case .continueWatching:
                            logContinueWatchingCuration(perAccount.map(\.continueWatching), curated: groups)
                            logContinueWatchingMergeInputs(groups)
                            content.continueWatching = mergedRow(
                                from: groups, limit: continueWatchingLimit,
                                serverInfo: { serverInfo[$0] }, identitySources: identitySources,
                                sortByRecency: true
                            )
                        case .recentlyAdded:
                            content.latest = mergedRow(
                                from: groups, limit: latestLimit,
                                serverInfo: { serverInfo[$0] }, identitySources: identitySources
                            )
                        case .watchlist:
                            content.watchlist = mergedRow(
                                from: groups, limit: watchlistLimit,
                                serverInfo: { serverInfo[$0] }, identitySources: identitySources
                            )
                        case .libraries: break
                        }
                        PlozzLog.boot(
                            "HomeAgg.rowReady row=\(row.rawValue) ms=\(elapsedMS(from: started, to: clock.now))")
                    }
                    content.librarySections = content.libraries.compactMap {
                        guard let group = perLibrary[$0.key]?.group, !group.isEmpty else { return nil }
                        return group
                    }
                    guard !Task.isCancelled else {
                        group.cancelAll()
                        break
                    }
                    await onProgress(
                        Progress(
                            content: content,
                            loadingRows: Set(HomeRowKind.allCases).subtracting(publishedRows),
                            failures: failures
                        ))
                }
                PlozzLog.boot("HomeAgg.fanout accounts=\(accounts.count) ms=\(elapsedMS(from: started, to: clock.now))")
                return content
            }
        } onCancel: {
            Task {
                for identities in seriesIdentities { await identities.cancel() }
            }
        }
    }

    private static func perform(
        _ request: Request,
        accounts: [ResolvedAccount],
        policy: ContinueWatchingPolicy,
        continueWatchingLimit: Int,
        latestLimit: Int,
        perLibraryLimit: Int,
        seriesIdentities: [SeriesIdentities],
        onContinueWatching: @escaping @Sendable (String, [MediaItem]) async -> Void
    ) async -> Response {
        switch request {
        case let .libraries(index):
            let resolved = accounts[index]
            return .libraries(index, await fetch("libraries", from: resolved) {
                try await resolved.provider.libraries()
            })
        case let .feed(index, feed, libraryIDs):
            let resolved = accounts[index]
            let provider = resolved.provider
            return .feed(index, feed, await fetch(feed.row.rawValue, from: resolved) {
                let items: [MediaItem]
                switch feed {
                case .continueWatching:
                    items = try await provider.continueWatching(
                        limit: continueWatchingLimit, inLibraries: libraryIDs
                    )
                    try Task.checkCancellation()
                    let playable = items.filter {
                        $0.kind == .movie || $0.kind == .episode || $0.kind == .video
                    }
                    await onContinueWatching(
                        resolved.account.id,
                        policy.curated(playable.map { $0.taggingSource(resolved.account.id) })
                    )
                case .latest:
                    items = try await provider.latest(limit: latestLimit, inLibraries: libraryIDs)
                case .watchlist:
                    items = try await (provider as? any WatchlistProviding)?.watchlist() ?? []
                }
                try Task.checkCancellation()
                let identities = feed == .watchlist
                    ? [:]
                    : await seriesIdentities[index].resolve(items, provider: provider)
                return stampSeriesProviderIDs(identities, onto: items).map {
                    $0.taggingSource(resolved.account.id)
                }
            })
        case let .library(index, library, kind):
            let resolved = accounts[index]
            return .library(library.key, kind, await fetch(kind.rawValue, from: resolved) {
                let sections: [LibrarySection]
                switch kind {
                case .recentlyAdded:
                    let page = try await resolved.provider.items(
                        in: library.library.id, kind: library.library.kind,
                        page: PageRequest(
                            startIndex: 0, limit: perLibraryLimit,
                            sort: SortDescriptor(field: .dateAdded, direction: .descending)
                        )
                    )
                    sections = page.items.isEmpty ? [] : [LibrarySection(
                        id: "recentlyAdded", title: "Recently Added in \(library.library.title)",
                        style: .poster, items: page.items
                    )]
                case .hubs:
                    sections = try await resolved.provider.libraryHubs(
                        libraryID: library.library.id, kind: library.library.kind, limit: perLibraryLimit
                    )
                }
                return sections.filter { !$0.items.isEmpty }.map { section in
                    var section = section
                    section.items = section.items.map {
                        $0.taggingSource(library.accountID).taggingLibrary(library.library.id)
                    }
                    return section
                }
            })
        }
    }

    private static func fetch<Value: Sendable>(
        _ row: String,
        from resolved: ResolvedAccount,
        operation: @Sendable () async throws -> Value
    ) async -> Result<Value, AppError> {
        let clock = ContinuousClock()
        let started = clock.now
        defer {
            PlozzLog.boot("HomeAgg.request row=\(row) provider=\(resolved.provider.kind) ms=\(elapsedMS(from: started, to: clock.now))")
        }
        do {
            try Task.checkCancellation()
            return .success(try await operation())
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            let failure = (error as? AppError) ?? .unknown("")
            if failure != .cancelled {
                PlozzLog.app.error("Home row failed: row=\(row) provider=\(resolved.provider.kind)")
            }
            return .failure(failure)
        }
    }

    /// Resolves each distinct parent series once so episode rows carry explicit
    /// show IDs. Managed providers expose episode IDs while filesystem enrichment
    /// exposes series IDs; stamping both under `Series*` gives Home one safe shared
    /// identity when combined with exact season/episode numbers.
    private static func seriesProviderIDs(
        for items: [MediaItem],
        provider: any MediaProvider
    ) async -> [String: [String: String]] {
        var seen = Set<String>()
        let seriesIDs = items.compactMap { item -> String? in
            guard item.kind == .episode,
                  let seriesID = item.seriesID,
                  seen.insert(seriesID).inserted else { return nil }
            return seriesID
        }
        guard !seriesIDs.isEmpty else { return [:] }
        if let batchProvider = provider as? any SeriesIdentityProviding {
            do {
                let resolved = try await batchProvider.seriesProviderIDs(for: seriesIDs)
                return resolved.filter { seen.contains($0.key) }
            } catch is CancellationError {
                return [:]
            } catch let error as AppError where error == .cancelled {
                return [:]
            } catch {
                PlozzLog.networking.error(
                    "Home series identity batch failed; retrying individual details: \(String(describing: error))"
                )
            }
        }
        let resolved: [(String, [String: String])] = await loadBounded(
            seriesIDs,
            maxConcurrent: 4
        ) { seriesID in
            let ids = (try? await provider.item(id: seriesID))?.providerIDs ?? [:]
            return (seriesID, ids)
        }
        return Dictionary(uniqueKeysWithValues: resolved)
    }

    private static func stampSeriesProviderIDs(
        _ resolved: [String: [String: String]],
        onto items: [MediaItem]
    ) -> [MediaItem] {
        return items.map { item in
            guard let seriesID = item.seriesID,
                  let sourceIDs = resolved[seriesID] else { return item }
            var copy = item
            copy.providerIDs.mergeSeriesProviderIDs(from: sourceIDs)
            return copy
        }
    }

    private static func aggregated(_ library: MediaLibrary, from resolved: ResolvedAccount) -> AggregatedLibrary {
        AggregatedLibrary(
            accountID: resolved.account.id,
            accountName: resolved.account.userName,
            serverName: resolved.account.server.name,
            providerKind: resolved.account.server.provider,
            transportKind: MediaShareTransportKind(mediaShareScheme: resolved.account.server.baseURL.scheme),
            library: library.taggingSource(resolved.account.id)
        )
    }

    /// Interleaves and de-duplicates one Home row, then caps the rendered count so
    /// Home remains responsive with many accounts.
    ///
    /// When `sortByRecency` is set (the Continue Watching row) the merged result is
    /// stable-sorted by ``sortedByRecency(_:)`` so the row reflects what the user
    /// actually watched last instead of a round-robin interleave that shuffles
    /// between launches. Recency comes straight from each card's `lastPlayedAt`,
    /// which the cross-server merge already folds to the newest timestamp across a
    /// title's servers (``MediaItemMerger`` — most-recent-wins). Untimestamped "Next
    /// Up" cards — which each provider stamps with their series' recency up front,
    /// and which only remain untimestamped when that lookup genuinely fails — keep
    /// their interleave order *after* the timestamped ones (they never inherit a
    /// neighbouring show's timestamp).
    /// TEMPORARY on-device diagnostic for the Continue Watching duplicate bug.
    /// Emits one line per pre-merge card so a duplicate pair can be compared by
    /// the exact fields the merge keys on. Remove once the cause is confirmed.
    /// Names every next-up suggestion the policy retired, so a title vanishing from
    /// the row is an observation rather than a mystery. Gated; free when off.
    private static func logContinueWatchingCuration(_ raw: [[MediaItem]], curated: [[MediaItem]]) {
        guard ContinueWatchingDiagnostics.isEnabled else { return }
        let keptIDs = Set(curated.flatMap { $0 }.map(\.id))
        let dropped = raw.flatMap { $0 }.filter { !keptIDs.contains($0.id) }
        guard !dropped.isEmpty else { return }
        var line = "curation dropped=\(dropped.count) reason=stale-next-up"
        for item in dropped {
            let age = item.lastPlayedAt.map { Int(Date().timeIntervalSince($0) / 86_400) }
            line += "\n  DROPPED id=\(item.id) title=\"\(item.title)\" "
                + "resume=\(item.resumePosition.map { String(format: "%.0f", $0) } ?? "nil") "
                + "ageDays=\(age.map(String.init) ?? "nil")"
        }
        ContinueWatchingDiagnostics.emit(line)
    }

    private static func logContinueWatchingMergeInputs(_ groups: [[MediaItem]]) {
        let all = groups.flatMap { $0 }
        FanoutDiagnostics.emit("CWDUP begin items=\(all.count) episodes=\(all.filter { $0.kind == .episode }.count)")
        for item in all where item.kind == .episode {
            let identities = MediaItemIdentity.identities(for: item)
            var parts: [String] = ["CWDUP"]
            parts.append("acct=" + (item.sourceAccountID ?? "nil"))
            parts.append("parent=" + (item.parentTitle ?? "nil"))
            parts.append("s=" + (item.seasonNumber.map(String.init) ?? "nil"))
            parts.append("e=" + (item.episodeNumber.map(String.init) ?? "nil"))
            parts.append("key=" + (MediaItemMerger.episodeTitleKey(for: item) ?? "nil"))
            parts.append("idents=" + String(identities.count))
            parts.append("seriesID=" + (item.seriesID ?? "nil"))
            parts.append("first=" + (identities.first.map { "\($0)" } ?? "none"))
            FanoutDiagnostics.emit(parts.joined(separator: " "))
        }
    }

    private static func mergedRow(
        from groups: [[MediaItem]],
        limit: Int,
        serverInfo: (String) -> SourceServerInfo?,
        identitySources: (MediaItem) -> [MediaSourceRef] = { _ in [] },
        sortByRecency: Bool = false
    ) -> [MediaItem] {
        guard limit > 0 else { return [] }
        var merged = MediaItemMerger.merge(
            Self.interleave(groups),
            serverInfo: serverInfo,
            identitySources: identitySources
        )
        if sortByRecency {
            merged = sortedByRecency(merged)
        }
        guard merged.count > limit else { return merged }
        return Array(merged.prefix(limit))
    }

    /// Stable descending sort of a merged Continue Watching row by `lastPlayedAt`.
    ///
    /// Each card's recency is its own `lastPlayedAt`, which for a cross-server card
    /// the merger already sets to the newest timestamp across every server backing
    /// it (``MediaItemMerger`` — most-recent-wins), and which each provider stamps
    /// onto "Next Up" suggestions from their series' recency before the feed ever
    /// reaches here. Cards we still can't timestamp (a suggestion whose series
    /// recency lookup failed) sort *after* the timestamped ones in their incoming
    /// order — they are never handed a neighbouring show's timestamp.
    ///
    /// The sort is stable (equal `lastPlayedAt` breaks by the original offset) and
    /// idempotent, so re-sorting an already-ordered row leaves it unchanged.
    ///
    /// > Note: an earlier version manufactured recency for untimestamped cards by
    /// > carrying the previous card's timestamp forward through each feed. Because a
    /// > feed is ordered "timestamped first, untimestamped tail" (not
    /// > in-progress/next-up pairs), that let an unrelated show's next episode
    /// > inherit the feed's oldest real timestamp and jump ahead of another server's
    /// > genuine progress — the reported "Continue Watching keeps shifting / isn't
    /// > what I watched last" symptom. Provider-side series stamping now handles the
    /// > legitimate case correctly, so the positional carry-forward was removed.
    public static func sortedByRecency(_ items: [MediaItem]) -> [MediaItem] {
        items.enumerated().sorted { lhs, rhs in
            switch (lhs.element.lastPlayedAt, rhs.element.lastPlayedAt) {
            case let (l?, r?):
                return l == r ? lhs.offset < rhs.offset : l > r
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            case (nil, nil):
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    // MARK: - Merge

    /// Round-robin interleave: take the first item of every group, then the
    /// second of every group, and so on. Preserves each group's internal order
    /// and gives every account fair top-of-row placement.
    static func interleave<T>(_ groups: [[T]]) -> [T] {
        let maxCount = groups.map(\.count).max() ?? 0
        var result: [T] = []
        result.reserveCapacity(groups.reduce(0) { $0 + $1.count })
        for offset in 0..<maxCount {
            for group in groups where offset < group.count {
                result.append(group[offset])
            }
        }
        return result
    }

    /// Whole milliseconds between two `ContinuousClock` instants, for PLZBOOT
    /// timing. Env-gated logging only — never on a user-visible path.
    private static func elapsedMS(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Int {
        let comps = (end - start).components
        // 1 ms = 1e15 attoseconds.
        return Int(comps.seconds * 1000 + comps.attoseconds / 1_000_000_000_000_000)
    }
}
