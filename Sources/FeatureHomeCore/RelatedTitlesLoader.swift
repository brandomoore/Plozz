import CoreModels
import CoreNetworking
import Foundation
import MetadataKit

/// One entry in the Related row: a title related to the one on screen, plus the
/// viewer's own copy when they have it.
public struct RelatedEntry: Sendable, Equatable, Identifiable {
    public let related: RelatedTitle
    /// The viewer's copy, verified by external id. `nil` when they don't have it.
    public let libraryItem: MediaItem?

    public init(related: RelatedTitle, libraryItem: MediaItem?) {
        self.related = related
        self.libraryItem = libraryItem
    }

    public var id: String { related.id }
    public var isInLibrary: Bool { libraryItem != nil }
    public var isContinuation: Bool { related.isContinuation }
    public var title: String {  // l10n:content — provider/server-supplied media title
        libraryItem?.title ?? related.title
    }

    /// Library copy when available; otherwise a navigable external discovery
    /// item carrying the provider's ids/artwork.
    public var item: MediaItem {
        if let libraryItem { return libraryItem }
        return MediaItem(
            id: "related:\(related.id)",
            title: related.title,
            kind: related.kind,
            productionYear: related.year,
            posterURL: related.posterURL,
            providerIDs: related.providerIDs,
            availability: .unknown,
            locallyValidatedPlayableSource: false
        )
    }
}

/// Builds the Related row: resolves related titles, then binds each to the
/// viewer's own library.
///
/// Deliberately **library-first in what it shows**. A row of titles the viewer
/// can't play is a row of dead ends, and Plozz has no way to get them — requesting
/// needs Seerr, which is opt-in and most people won't have. So an unmatched title
/// is dropped rather than shown as an unreachable poster.
@MainActor
@Observable
public final class RelatedTitlesLoader {
    public enum DisplayMode: Sendable, Equatable {
        case libraryOnly
        case includeExternal
    }
    public private(set) var entries: [RelatedEntry] = []
    public private(set) var isLoading = false
    /// Whether a load has finished for the current item. Distinguishes "still
    /// working" from "finished, and there is genuinely nothing" — the row reserves
    /// its space for the first and collapses for the second, so the page below it
    /// doesn't jump once results land.
    public private(set) var hasResolved = false

    private let resolver: RelatedTitlesResolver
    private let store: RelatedTitlesStore
    private let search: @Sendable (String, Int) async -> [MediaItem]
    // Read-only by design: the future unified Plozz identity layer can back this
    // seam with its durable UUID, but merely browsing Related must never allocate
    // or persist identity records.
    private let indexedLibrarySources: @Sendable (MediaItem) -> [MediaSourceRef]
    private let loadIndexedItem: (@Sendable (MediaSourceRef) async -> MediaItem?)?
    private let now: @Sendable () -> Date
    private let displayMode: DisplayMode
    private var loadedSeedKey: String?
    private var activeLoadID: UUID?

    public init(
        resolver: RelatedTitlesResolver,
        store: RelatedTitlesStore = .shared,
        search: @escaping @Sendable (String, Int) async -> [MediaItem],
        indexedLibrarySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef] = { _ in [] },
        loadIndexedItem: (@Sendable (MediaSourceRef) async -> MediaItem?)? = nil,
        displayMode: DisplayMode = .libraryOnly,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.resolver = resolver
        self.store = store
        self.search = search
        self.indexedLibrarySources = indexedLibrarySources
        self.loadIndexedItem = loadIndexedItem
        self.displayMode = displayMode
        self.now = now
    }

    /// Loads the row for `item`, cache-first.
    ///
    /// Safe to call on every open: a fresh record skips the provider chain
    /// entirely, and re-entering the same page is a no-op.
    public func load(for item: MediaItem, displayMode override: DisplayMode? = nil) async {
        guard !Task.isCancelled else { return }
        guard item.allowsTitleBasedMetadataMatching else {
            activeLoadID = nil
            loadedSeedKey = nil
            entries = []
            isLoading = false
            hasResolved = true
            return
        }
        let mode = override ?? displayMode
        let query = MetadataQuery(item).seriesScoped
        let seedKey = query.enrichmentCacheKey
        let key = "\(seedKey)#\(mode == .libraryOnly ? "library" : "external")"
        guard loadedSeedKey != key else { return }
        let loadID = UUID()
        activeLoadID = loadID
        loadedSeedKey = key
        entries = []
        hasResolved = false
        isLoading = true
        // Finalising is guarded on still being the current load. A superseded load
        // can finish first — its searches were already in flight — and an
        // unconditional finish would then mark the NEW page resolved while it is
        // still working, collapsing its placeholder row to nothing.
        defer {
            if activeLoadID == loadID {
                activeLoadID = nil
                isLoading = false
                hasResolved = !Task.isCancelled
                if Task.isCancelled { loadedSeedKey = nil }
            }
        }

        let titles = await resolvedTitles(for: query, key: seedKey)
        guard !titles.isEmpty else { return }
        guard !Task.isCancelled, activeLoadID == loadID else { return }
        if mode == .includeExternal {
            // Resolve against the eager identity index before publishing. Destination
            // routing used to do this only after selection, so an owned title wore an
            // external/requestable mark until it was tapped. The synchronous index
            // lookup keeps this path network-free while making card state and routing
            // agree.
            let capabilities = MediaCapabilities.detected()
            entries = Self.collapsingExternalDuplicates(titles)
                .prefix(Self.maximumEntries)
                .map {
                    RelatedEntry(
                        related: $0,
                        libraryItem: indexedLibraryItem(
                            for: $0,
                            capabilities: capabilities
                        )
                    )
                }
            return
        }
        await matchToLibrary(titles, loadID: loadID)
    }

    /// The owner cancels its task and invalidates publication before a page can
    /// resume the same seed. A late response from the old attempt cannot win.
    public func cancel() {
        guard isLoading else { return }
        activeLoadID = nil
        loadedSeedKey = nil
        isLoading = false
        hasResolved = false
    }

    /// Builds a validated library item from the shared identity index. Related
    /// providers must contribute a strong id: title/year fallback is intentionally
    /// rejected because a wrong ownership match can route playback to another work.
    private func indexedLibraryItem(
        for related: RelatedTitle,
        capabilities: MediaCapabilities
    ) -> MediaItem? {
        // One shared retarget, used by a person's credits too — same strong-id
        // requirement, same kind scoping, same "clear the provider's availability".
        // Capabilities are passed because this row needs an id a server can load:
        // the external item's own id is a provider id like `related:tmdb:tv:456`.
        RelatedEntry(related: related, libraryItem: nil).item
            .retargetedToOwnedLibraryCopy(
                indexedSources: indexedLibrarySources,
                capabilities: capabilities
            )
    }

    /// Cross-provider Related results often describe the same work under disjoint
    /// ids (AniList vs TMDb).
    ///
    /// Uses the shared ``TitleDedupe`` — the same engine, split guard and kind
    /// scoping as person credits, the cast strip and the cross-server credit merge.
    /// This row previously carried its own union-find with its own token format and
    /// its own conflict rule, which is why fixes to one never reached the other.
    ///
    /// The policy is the only thing that differs, and it is `.titleAndYear`
    /// deliberately: tapping a Related card starts something, so a false merge here
    /// sends the viewer to the wrong work rather than costing a poster.
    static func collapsingExternalDuplicates(
        _ titles: [RelatedTitle]
    ) -> [RelatedTitle] {
        TitleDedupe.collapsed(titles, policy: .titleAndYear)
    }

    private func resolvedTitles(for query: MetadataQuery, key: String) async -> [RelatedTitle] {
        if let cached = await store.record(for: key), !cached.isRefreshDue(now: now()) {
            return cached.titles
        }
        let resolved = await resolver.relatedTitles(for: query)
        guard !Task.isCancelled else { return [] }
        // An empty answer is cached too, so a title no provider covers doesn't
        // re-run the whole chain on every open.
        await store.store(RelatedTitlesRecord(seedKey: key, titles: resolved, refreshedAt: now()))
        return resolved
    }

    /// Fetch known native copies directly; search only when the index cannot
    /// supply a verified copy. Both paths share the same bounded work budget.
    private func matchToLibrary(
        _ titles: [RelatedTitle],
        loadID: UUID
    ) async {
        let search = self.search
        let loadIndexedItem = self.loadIndexedItem
        let capabilities = MediaCapabilities.detected()
        let ordered = Array(titles.prefix(Self.maximumLookups))
        var matched: [Int: MediaItem] = [:]
        let clock = ContinuousClock()
        var lastPublish = clock.now

        func resolvedEntries() -> (entries: [RelatedEntry], lastIndex: Int?) {
            var seen = Set<String>()
            var result: [RelatedEntry] = []
            var lastIndex: Int?
            for (index, related) in ordered.enumerated() {
                guard let item = matched[index] else { continue }
                let overlap = MediaItemIdentity.overlapKeys(for: item)
                let keys: Set<String> = overlap.isEmpty
                    ? ["\(item.sourceAccountID ?? "_"):\(item.id)"] : overlap
                guard seen.isDisjoint(with: keys) else { continue }
                seen.formUnion(keys)
                result.append(RelatedEntry(related: related, libraryItem: item))
                lastIndex = index
                if result.count == Self.maximumEntries { break }
            }
            return (result, lastIndex)
        }

        await withTaskGroup(of: (Int, MediaItem?).self) { group in
            var next = 0
            var pending = Set<Int>()
            var indexedPending = Set<Int>()
            @MainActor func addTask(_ index: Int) {
                let related = ordered[index]
                let indexed = loadIndexedItem == nil ? nil
                    : indexedLibraryItem(for: related, capabilities: capabilities)
                let source = indexed.flatMap { item in
                    item.sources.first { $0.accountID == item.sourceAccountID && $0.itemID == item.id }
                }
                group.addTask {
                    guard !Task.isCancelled else { return (index, nil) }
                    if let source, let loadIndexedItem {
                        let native = await loadIndexedItem(source)
                        guard !Task.isCancelled else { return (index, nil) }
                        if let native {
                            let expected = RelatedEntry(related: related, libraryItem: nil).item
                            if native.id == source.itemID,
                               native.sourceAccountID == source.accountID,
                               native.locallyValidatedPlayableSource,
                               HeroDiscoveryIdentityVerification.matches(expected, native) {
                                return (index, native)
                            }
                            PlozzLog.app.error("Related: stale or unverified indexed copy; falling back to library search.")
                        }
                    }
                    for query in RelatedTitleMatcher.searchQueries(for: related) {
                        guard !Task.isCancelled else { return (index, nil) }
                        let hits = await search(query, Self.searchLimit)
                        guard !Task.isCancelled else { return (index, nil) }
                        if let hit = RelatedTitleMatcher.match(related, in: hits) {
                            return (index, hit)
                        }
                    }
                    return (index, nil)
                }
                pending.insert(index)
                if source != nil { indexedPending.insert(index) }
            }
            while next < min(Self.concurrentLookups, ordered.count) {
                addTask(next)
                next += 1
            }
            for await (index, hit) in group {
                pending.remove(index)
                indexedPending.remove(index)
                guard !Task.isCancelled, activeLoadID == loadID else {
                    group.cancelAll()
                    return
                }
                if let hit { matched[index] = hit }
                let resolved = resolvedEntries()
                let batch = resolved.entries
                let full = batch.count == Self.maximumEntries
                if full, let lastIndex = resolved.lastIndex,
                   !pending.contains(where: { $0 < lastIndex }) {
                    if entries != batch { entries = batch }
                    group.cancelAll()
                    return
                }
                // Known copies reserve slots to avoid speculative tail searches.
                // Unknown candidates keep bounded lookahead: a slow search must
                // not prevent faster later matches from filling the row.
                while next < ordered.count, pending.count < Self.concurrentLookups,
                      batch.count + indexedPending.count < Self.maximumEntries {
                    addTask(next)
                    next += 1
                }
                let now = clock.now
                // Fast index-backed rows publish together as soon as complete.
                // Slow fallback searches retain bounded progressive publication.
                guard full || pending.isEmpty || lastPublish.duration(to: now) >= Self.publishInterval else {
                    continue
                }
                lastPublish = now
                if entries != batch { entries = batch }
            }
        }
    }

    /// Maximum candidate budget, including indexed lookups and search fallbacks.
    ///
    /// Comfortably more than the row shows, because a candidate is only kept when
    /// its ids can be verified against the library — and which candidates those are
    /// depends on who catalogued the library. An anime shelf managed by Shoko
    /// verifies TMDb ids and not AniList ones, so a budget sized to the visible row
    /// would be spent entirely on candidates that can never match.
    static let maximumLookups = 24
    /// Coalesces incomplete fallback matches; a full or finished row publishes
    /// immediately rather than waiting for this interval.
    private static let publishInterval: Duration = .milliseconds(400)

    /// The most entries the row will show, once matching has filtered the rest.
    static let maximumEntries = 12
    /// Concurrent native lookups/searches, bounded for servers also streaming.
    static let concurrentLookups = 6
    /// Hits per search: a handful is plenty to find an exact id match, and a large
    /// page costs the server real work.
    static let searchLimit = 8
}
