import CoreModels

/// Explicit Watchlist membership is an eligibility rule, not a novelty refresh.
/// Losing that membership retires a slide only when no other enabled source can
/// supply its title. Missing rows or a failed discovery fetch are not evidence.
public struct HeroSourceEligibility: Sendable {
    public static let unrestricted = HeroSourceEligibility(
        settings: .default, removedFromWatchlist: []
    )

    private let settings: HeroSettings
    private var excludedWatchlistTokens: Set<String>
    private var excludedWatchlistGroups: [Exclusion]
    private let otherSourceTokens: Set<String>
    private let randomLibraries: [HeroRandomLibrary]

    private struct Exclusion: Sendable {
        var tokens: Set<String>
        let representative: MediaItem
    }

    public init(
        settings: HeroSettings,
        removedFromWatchlist: [MediaItem],
        continueWatching: [MediaItem] = [],
        recentlyAdded: [MediaItem] = [],
        randomLibraries: [HeroRandomLibrary] = [],
        supportingCandidates: HeroFreshnessCandidatePool = .empty
    ) {
        var exclusions: [Exclusion] = []
        if settings.isEnabled(.watchlist) {
            for item in removedFromWatchlist {
                Self.addExclusion(HeroDedupe.tokens(for: item), representative: item, to: &exclusions)
            }
        }
        self.init(
            settings: settings, exclusions: exclusions, randomLibraries: randomLibraries
        ) {
            Self.tokens(in: Self.supportingRows(
                settings: settings, continueWatching: continueWatching,
                recentlyAdded: recentlyAdded, candidates: supportingCandidates
            ))
        }
    }

    private init(
        settings: HeroSettings, exclusions: [Exclusion],
        randomLibraries: [HeroRandomLibrary], supportingTokens: () -> Set<String>
    ) {
        self.settings = settings
        excludedWatchlistGroups = Array(exclusions.suffix(128))
        excludedWatchlistTokens = excludedWatchlistGroups.reduce(into: Set<String>()) { $0.formUnion($1.tokens) }
        self.randomLibraries = settings.isEnabled(.randomFromLibrary) ? randomLibraries : []
        // Supporting sources matter only for an explicit removal. Do not index
        // entire Home rows on every render when there is nothing to exclude.
        guard !excludedWatchlistTokens.isEmpty else {
            otherSourceTokens = []
            return
        }
        otherSourceTokens = supportingTokens()
    }

    /// `nil` membership means the durable membership authority is not ready.
    /// Keep prior explicit evidence through that uncertainty, but let a restored
    /// membership undo a failed removal/re-add. The closure is never retained.
    @MainActor
    public static func capture(
        settings: HeroSettings?,
        candidates: [MediaItem],
        continueWatching: [MediaItem] = [],
        recentlyAdded: [MediaItem] = [],
        randomLibraries: [HeroRandomLibrary] = [],
        supportingCandidates: HeroFreshnessCandidatePool = .empty,
        previous: HeroSourceEligibility = .unrestricted,
        supportingIndex: HeroSupportingSourceIndex? = nil,
        watchlistMembership: (MediaItem) -> Bool?
    ) -> HeroSourceEligibility {
        guard let settings, settings.isActive, settings.isEnabled(.watchlist) else {
            supportingIndex?.reset()
            return .unrestricted
        }
        // Removed slides no longer appear among visible candidates. Keep their
        // bounded representatives queryable so a failed removal can roll back.
        let rechecked = previous.excludedWatchlistGroups.map(\.representative) + candidates
        let membership = rechecked.map {
            (item: $0, state: watchlistMembership($0))
        }
        var groups = previous.excludedWatchlistGroups
        for entry in membership where entry.state == true && !groups.isEmpty {
            let tokens = HeroDedupe.tokens(for: entry.item)
            groups.removeAll { !$0.tokens.isDisjoint(with: tokens) }
        }
        // A pending removal on one edition outranks a stale positive answer for
        // another edition in the same pass.
        for entry in membership where entry.state == false {
            Self.addExclusion(HeroDedupe.tokens(for: entry.item), representative: entry.item, to: &groups)
        }
        if groups.isEmpty { supportingIndex?.reset() }
        return HeroSourceEligibility(
            settings: settings,
            exclusions: groups,
            randomLibraries: randomLibraries
        ) {
            let rows = Self.supportingRows(
                settings: settings, continueWatching: continueWatching,
                recentlyAdded: recentlyAdded, candidates: supportingCandidates
            )
            return supportingIndex?.tokens(in: rows) ?? Self.tokens(in: rows)
        }
    }

    public func allows(_ item: MediaItem, from source: HeroSourceKind) -> Bool {
        source != .watchlist || !isExcludedFromWatchlist(item)
    }

    public func allows(_ item: MediaItem) -> Bool {
        guard isExcludedFromWatchlist(item) else { return true }
        let tokens = HeroDedupe.tokens(for: item)
        if !tokens.isDisjoint(with: otherSourceTokens) { return true }
        if settings.isEnabled(.featured) {
            if item.discoverySources.contains(where: settings.discoverySources.contains) { return true }
        }
        guard item.locallyValidatedPlayableSource else { return false }
        let libraryKind: MediaItemKind
        switch item.kind {
        case .movie: libraryKind = .movie
        case .series, .season, .episode: libraryKind = .series
        default: return false
        }
        return randomLibraries.contains { library in
            guard library.kind == libraryKind else { return false }
            if item.sourceAccountID == library.accountID, item.libraryID == library.libraryID {
                return true
            }
            return item.sources.contains { source in
                let compatibleKind = source.kind.map { Self.libraryKind(for: $0) == libraryKind } ?? true
                return source.accountID == library.accountID && source.libraryID == library.libraryID
                    && compatibleKind
            }
        }
    }

    public func filtering(_ items: [MediaItem]) -> [MediaItem] {
        guard !excludedWatchlistTokens.isEmpty else { return items }
        return items.filter(allows)
    }

    /// A title may remain via Featured/Random while its Watchlist provenance is
    /// removed. Persisting the stale Watchlist bucket would bring it back later.
    public func filtering(_ pool: HeroFreshnessCandidatePool) -> HeroFreshnessCandidatePool {
        guard !excludedWatchlistTokens.isEmpty else { return pool }
        return HeroFreshnessCandidatePool(buckets: pool.buckets.map { bucket in
            .init(source: bucket.source, items: bucket.items.filter { allows($0, from: bucket.source) })
        })
    }

    private func isExcludedFromWatchlist(_ item: MediaItem) -> Bool {
        !excludedWatchlistTokens.isEmpty
            && !HeroDedupe.tokens(for: item).isDisjoint(with: excludedWatchlistTokens)
    }

    private static func supportingRows(
        settings: HeroSettings, continueWatching: [MediaItem],
        recentlyAdded: [MediaItem], candidates: HeroFreshnessCandidatePool
    ) -> [[MediaItem]] {
        var rows: [[MediaItem]] = []
        if settings.isEnabled(.continueWatching) { rows.append(continueWatching) }
        if settings.isEnabled(.recentlyAdded) { rows.append(recentlyAdded) }
        for bucket in candidates.buckets
        where bucket.source != .watchlist && settings.isEnabled(bucket.source) {
            rows.append(bucket.items)
        }
        return rows
    }

    fileprivate static func tokens(in rows: [[MediaItem]]) -> Set<String> {
        rows.reduce(into: Set<String>()) { tokens, row in
            for item in row { tokens.formUnion(HeroDedupe.tokens(for: item)) }
        }
    }

    private static func addExclusion(
        _ tokens: Set<String>, representative: MediaItem, to groups: inout [Exclusion]
    ) {
        var combined = tokens
        while let index = groups.firstIndex(where: { !$0.tokens.isDisjoint(with: combined) }) {
            combined.formUnion(groups.remove(at: index).tokens)
        }
        groups.append(Exclusion(tokens: combined, representative: representative))
    }

    private static func libraryKind(for kind: MediaItemKind) -> MediaItemKind? {
        switch kind {
        case .movie: return .movie
        case .series, .season, .episode: return .series
        default: return nil
        }
    }
}

/// Memoizes only supporting-source identities, never Watchlist membership.
/// Unchanged arrays share their storage, so equality avoids re-tokenizing Home
/// during layout. Full values, not item IDs/counts, invalidate ownership changes.
@MainActor
public final class HeroSupportingSourceIndex {
    private var rows: [[MediaItem]]?
    private var storedTokens: Set<String> = []

    public init() {}

    public func reset() {
        rows = nil
        storedTokens = []
    }

    func tokens(in rows: [[MediaItem]]) -> Set<String> {
        if self.rows == rows { return storedTokens }
        storedTokens = HeroSourceEligibility.tokens(in: rows)
        self.rows = rows
        return storedTokens
    }
}
