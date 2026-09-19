import CoreModels
import CryptoKit
import Foundation

/// Exposure is independent of playback/watch state. Only a visible slide's
/// dwell observer records it; fetching or selecting a candidate never does.
public struct HeroExposureHistory: Codable, Equatable, Sendable {
    public static let maximumEntries = 256
    public static let maximumAliases = 16

    public struct Entry: Codable, Equatable, Sendable {
        public var aliases: [String]
        public var lastSeenAt: Date

        public init(aliases: [String], lastSeenAt: Date) {
            self.aliases = aliases
            self.lastSeenAt = lastSeenAt
        }
    }

    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = Array(entries.compactMap { entry in
            let aliases = Array(Set(entry.aliases.filter(Self.isDigest)).sorted()
                .prefix(Self.maximumAliases))
            return aliases.isEmpty ? nil : Entry(aliases: aliases, lastSeenAt: entry.lastSeenAt)
        }.sorted { $0.lastSeenAt > $1.lastSeenAt }.prefix(Self.maximumEntries))
    }

    private enum CodingKeys: String, CodingKey { case entries }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(entries: try container.decodeIfPresent([Entry].self, forKey: .entries) ?? [])
    }

    public func lastSeenAt(for item: MediaItem) -> Date? {
        let aliases = Self.aliases(for: item)
        return entries.lazy
            .filter { !aliases.isDisjoint(with: $0.aliases) }
            .map(\.lastSeenAt).max()
    }

    public mutating func record(_ item: MediaItem, at date: Date = Date()) {
        var aliases = Self.aliases(for: item)
        var latest = date
        var remaining = entries
        // A hydrated record can bridge aliases recorded on separate servers.
        // Fold transitively so exposing either representation refreshes the title.
        var foundMatch = true
        while foundMatch {
            foundMatch = false
            remaining.removeAll { entry in
                guard !aliases.isDisjoint(with: entry.aliases) else { return false }
                aliases.formUnion(entry.aliases)
                latest = max(latest, entry.lastSeenAt)
                foundMatch = true
                return true
            }
        }
        let currentAliases = Self.aliases(for: item).sorted()
        let olderAliases = aliases.subtracting(currentAliases).sorted()
        remaining.append(Entry(
            aliases: Array((currentAliases + olderAliases).prefix(Self.maximumAliases)),
            lastSeenAt: latest
        ))
        entries = Array(remaining.sorted { $0.lastSeenAt > $1.lastSeenAt }
            .prefix(Self.maximumEntries))
    }

    static func aliases(for item: MediaItem) -> Set<String> {
        Set(HeroDedupe.tokens(for: item).map(digest))
    }

    static func digest(_ value: String) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var encoded: [UInt8] = []
        encoded.reserveCapacity(64)
        for byte in SHA256.hash(data: Data(value.utf8)) {
            encoded.append(digits[Int(byte >> 4)])
            encoded.append(digits[Int(byte & 15)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

/// A curation captures one snapshot. Recording later exposure does not mutate it
/// or publish observable Home state, and equal inputs keep their order.
public struct HeroFreshnessSnapshot: Equatable, Sendable {
    public let history: HeroExposureHistory
    public let sessionSeed: UInt64
    public let isEnabled: Bool

    public static let disabled = HeroFreshnessSnapshot(
        history: HeroExposureHistory(), sessionSeed: 0, isEnabled: false
    )
    public static let refreshInterval: TimeInterval = 600
    public static let rawDiscoveryLimit = 48

    public init(
        history: HeroExposureHistory = HeroExposureHistory(),
        sessionSeed: UInt64,
        isEnabled: Bool = true
    ) {
        self.history = history
        self.sessionSeed = sessionSeed
        self.isEnabled = isEnabled
    }

    public static func candidateLimit(for displayLimit: Int) -> Int {
        min(HeroFreshnessCandidatePool.maximumItemsPerSource, max(12, displayLimit * 2))
    }

    public func ranksDiscovery(_ source: HeroSourceKind, settings: HeroSettings) -> Bool {
        isEnabled && (source == .featured || source == .randomFromLibrary
            || (source == .watchlist && settings.watchlistDiscoveryEnabled))
    }

    public func ranked(
        _ items: [MediaItem],
        source: HeroSourceKind,
        settings: HeroSettings
    ) -> [MediaItem] {
        guard ranksDiscovery(source, settings: settings) else { return items }
        let ranked = items.enumerated().map { index, item in
            (
                index: index,
                item: item,
                seen: history.lastSeenAt(for: item),
                tie: HeroExposureHistory.digest(
                    "\(sessionSeed)|" + HeroDedupe.tokens(for: item).sorted().joined(separator: "\u{1f}")
                )
            )
        }
        return ranked.sorted { lhs, rhs in
            switch (lhs.seen, rhs.seen) {
            case (nil, .some): return true
            case (.some, nil): return false
            case let (.some(left), .some(right)) where left != right: return left < right
            default:
                return lhs.tie == rhs.tie ? lhs.index < rhs.index : lhs.tie < rhs.tie
            }
        }.map(\.item)
    }
}

/// Validated alternatives retain source provenance so cached startup can vary
/// discovery titles without shuffling Continue Watching, recency or Watchlist.
public struct HeroFreshnessCandidatePool: Codable, Equatable, Sendable {
    public static let maximumItemsPerSource = 40

    public struct Bucket: Codable, Equatable, Sendable {
        public var source: HeroSourceKind
        public var items: [MediaItem]

        public init(source: HeroSourceKind, items: [MediaItem]) {
            self.source = source
            self.items = items
        }
    }

    public private(set) var buckets: [Bucket]
    public static let empty = HeroFreshnessCandidatePool()
    public var isEmpty: Bool { buckets.allSatisfy { $0.items.isEmpty } }

    public init(buckets: [Bucket] = []) {
        var seen = Set<HeroSourceKind>()
        self.buckets = buckets.filter { seen.insert($0.source).inserted }.map {
            Bucket(source: $0.source, items: Array($0.items.prefix(Self.maximumItemsPerSource)))
        }
    }

    private enum CodingKeys: String, CodingKey { case buckets }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(buckets: try container.decodeIfPresent([Bucket].self, forKey: .buckets) ?? [])
    }

    public func select(
        settings: HeroSettings,
        freshness: HeroFreshnessSnapshot = .disabled,
        watchMutations: [MediaItemMutation] = [],
        isEligible: (HeroSourceKind, MediaItem) -> Bool = { _, _ in true }
    ) -> [MediaItem] {
        guard settings.isActive else { return [] }
        let curator = HeroCurator()
        let perSource = settings.sources.map { source in
            let candidates = (buckets.first { $0.source == source }?.items ?? [])
                .filter { isEligible(source, $0) }
            let reconciled = curator.reconcile(
                candidates, settings: settings, watchMutations: watchMutations
            )
            let eligible = HeroArtworkEligibility.filterDirect([reconciled])[0]
            return freshness.ranked(eligible, source: source, settings: settings)
        }
        return InterleaveHeroStrategy().compose(perSource, limit: settings.maxItems)
    }

    public func updatingItems(_ items: [MediaItem]) -> HeroFreshnessCandidatePool {
        let replacements = items.map { (item: $0, tokens: HeroDedupe.tokens(for: $0)) }
        return mapItems { original in
            let tokens = HeroDedupe.tokens(for: original)
            guard var replacement = replacements.first(where: {
                !tokens.isDisjoint(with: $0.tokens)
            })?.item else { return original }
            replacement.fillingMissingPresentation(from: original)
            return replacement
        }
    }

    public func mapItems(_ transform: (MediaItem) -> MediaItem) -> HeroFreshnessCandidatePool {
        HeroFreshnessCandidatePool(buckets: buckets.map {
            Bucket(source: $0.source, items: $0.items.map(transform))
        })
    }

    public func durable() -> HeroFreshnessCandidatePool {
        HeroFreshnessCandidatePool(buckets: buckets.filter { $0.source != .continueWatching }.map {
            Bucket(source: $0.source, items: HeroDurableSnapshot.filter($0.items))
        })
    }

    func sanitizedForPersistence() -> HeroFreshnessCandidatePool {
        durable().mapItems { $0.sanitizingArtworkCredentials() }
    }

    func orderedItems(for key: HeroConfigurationKey) -> [MediaItem] {
        InterleaveHeroStrategy().compose(
            key.sources.map { source in buckets.first { $0.source == source }?.items ?? [] },
            limit: key.maxItems
        )
    }
}
