import Foundation
import Observation

/// Per-profile configuration for the Home **hero** carousel (pure data model).
///
/// Everything about the hero is data, not hardcoded: whether it shows, which
/// sources feed it and in what order, how many items rotate, whether the
/// (phased-in) background trailer plays, and which libraries the Random source
/// draws from. This is what lets the default move with real feedback and lets a
/// user customise the hero later without a rewrite.
///
/// Decoding is deliberately lenient (`decodeIfPresent` with per-field
/// fallbacks) so that adding a new field in a later version reads back an older
/// persisted blob as "that field at its default" instead of failing the whole
/// decode and resetting every setting.
public struct HeroSettings: Codable, Equatable, Sendable {
    /// Whether the hero section is shown at all. When `false`, Home renders its
    /// classic rows unchanged.
    public var isEnabled: Bool

    /// The enabled sources, in carousel order. Empty means "nothing to show" —
    /// the hero hides itself even when `isEnabled`.
    public var sources: [HeroSourceKind]

    /// Maximum number of items the carousel rotates through (clamped to
    /// ``maxItemsRange``).
    public var maxItems: Int

    /// Whether the background trailer autoplay (phased-in) is allowed. The view
    /// exposes the slot regardless; this gates whether a trailer is resolved and
    /// played once that feature ships.
    public var trailersEnabled: Bool

    /// Whether previously completed movies, series, and episodes are excluded
    /// from every hero source.
    public var hideWatched: Bool

    /// Uses unseen/least-recently-shown picks instead of the established Watchlist order.
    public var watchlistDiscoveryEnabled: Bool
    public var discoverySources: [HeroDiscoverySource]

    /// Optional catalog credits on Home.
    public var showsDiscoverySources: Bool

    /// Scores are optional Home chrome, independent of detail-page rating preferences.
    public var showsRatings: Bool
    public var ratingPreferences: DetailPageSettings

    /// The `AggregatedLibrary.key`s the Random source may draw from. **Empty
    /// means "all currently-visible libraries"** (the sensible default), so a
    /// fresh profile needs no configuration.
    public var randomLibraryKeys: Set<String>

    /// Whether the carousel auto-advances on a timer.
    public var autoAdvance: Bool

    /// Seconds between auto-advances (clamped to ``autoAdvanceRange``).
    public var autoAdvanceSeconds: Int

    /// How Apple TV's Home is arranged. Other platforms always show the carousel.
    /// Lives with the hero's settings because Spotlight is the carousel, but it is
    /// a layout choice, not a hero option: Immersive has no hero section at all.
    public var style: HeroStyle

    /// How the backdrop changes between titles when the hero follows focus.
    public var backdropTransition: HeroBackdropTransition

    /// Whether cards keep their title lines when the hero follows focus. Off by
    /// default: the hero already names whatever is focused.
    public var showsCardCaptions: Bool

    /// Whether the Immersive layout adds a row of discovery picks — what the
    /// Spotlight's Featured source would show. Off by default.
    public var showsDiscoverRow: Bool

    /// Hero on, all content categories enabled, a modest rotation, all libraries
    /// for Random, and gentle auto-advance. Optional discovery credits are hidden.
    /// Feed defaults are defined by ``HeroDiscoverySource/defaultSelection``.
    public static let `default` = HeroSettings(
        isEnabled: true,
        sources: HeroSourceKind.allCases,
        maxItems: 8,
        trailersEnabled: false,
        hideWatched: true,
        randomLibraryKeys: [],
        autoAdvance: true,
        autoAdvanceSeconds: 12
    )

    /// Allowed range for ``maxItems``.
    public static let maxItemsRange: ClosedRange<Int> = 1...20
    /// Allowed range for ``autoAdvanceSeconds``.
    public static let autoAdvanceRange: ClosedRange<Int> = 4...60

    public init(
        isEnabled: Bool,
        sources: [HeroSourceKind],
        maxItems: Int,
        trailersEnabled: Bool,
        hideWatched: Bool = true,
        watchlistDiscoveryEnabled: Bool = false,
        discoverySources: [HeroDiscoverySource] = HeroDiscoverySource.defaultSelection,
        showsDiscoverySources: Bool = false,
        showsRatings: Bool = false,
        ratingPreferences: DetailPageSettings = .default,
        randomLibraryKeys: Set<String>,
        autoAdvance: Bool,
        autoAdvanceSeconds: Int,
        style: HeroStyle = .carousel,
        backdropTransition: HeroBackdropTransition = .crossfade,
        showsCardCaptions: Bool = false,
        showsDiscoverRow: Bool = false
    ) {
        self.isEnabled = isEnabled
        // De-duplicate while preserving order so the picker can't persist a
        // source twice.
        var seen = Set<HeroSourceKind>()
        self.sources = sources.filter { seen.insert($0).inserted }
        self.maxItems = maxItems.clamped(to: HeroSettings.maxItemsRange)
        self.trailersEnabled = trailersEnabled
        self.hideWatched = hideWatched
        self.watchlistDiscoveryEnabled = watchlistDiscoveryEnabled
        self.discoverySources = HeroDiscoverySource.normalized(discoverySources)
        self.showsDiscoverySources = showsDiscoverySources
        self.showsRatings = showsRatings
        self.ratingPreferences = ratingPreferences
        self.randomLibraryKeys = randomLibraryKeys
        self.autoAdvance = autoAdvance
        self.autoAdvanceSeconds = autoAdvanceSeconds.clamped(to: HeroSettings.autoAdvanceRange)
        self.style = style
        self.backdropTransition = backdropTransition
        self.showsCardCaptions = showsCardCaptions
        self.showsDiscoverRow = showsDiscoverRow
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, sources, maxItems, trailersEnabled, hideWatched, showsRatings
        case watchlistDiscoveryEnabled
        case discoverySources, showsDiscoverySources
        case ratingPreferences
        case randomLibraryKeys, autoAdvance, autoAdvanceSeconds
        case style, backdropTransition, showsCardCaptions, showsDiscoverRow
        case offeredSourcesVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HeroSettings.default
        // Flattens `decodeIfPresent`'s `T?` (and any thrown error) down to a
        // concrete value, falling back to the default when the key is absent,
        // null, or fails to decode — so a newly-added field reads as its default
        // from an older blob instead of failing the whole decode.
        func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(type, forKey: key)) ?? nil) ?? fallback
        }
        self.init(
            isEnabled: value(Bool.self, .isEnabled, d.isEnabled),
            sources: HeroSettings.adoptingNewSources(
                value([HeroSourceKind].self, .sources, d.sources),
                offeredVersion: value(Int.self, .offeredSourcesVersion, 0)
            ),
            maxItems: value(Int.self, .maxItems, d.maxItems),
            trailersEnabled: value(Bool.self, .trailersEnabled, d.trailersEnabled),
            hideWatched: value(Bool.self, .hideWatched, d.hideWatched),
            watchlistDiscoveryEnabled: value(
                Bool.self, .watchlistDiscoveryEnabled, d.watchlistDiscoveryEnabled
            ),
            discoverySources: value(
                [String].self, .discoverySources, d.discoverySources.map(\.rawValue)
            ).compactMap(HeroDiscoverySource.init(rawValue:)),
            showsDiscoverySources: value(
                Bool.self, .showsDiscoverySources, d.showsDiscoverySources
            ),
            showsRatings: value(Bool.self, .showsRatings, d.showsRatings),
            ratingPreferences: value(DetailPageSettings.self, .ratingPreferences, d.ratingPreferences),
            randomLibraryKeys: value(Set<String>.self, .randomLibraryKeys, d.randomLibraryKeys),
            autoAdvance: value(Bool.self, .autoAdvance, d.autoAdvance),
            autoAdvanceSeconds: value(Int.self, .autoAdvanceSeconds, d.autoAdvanceSeconds),
            style: value(HeroStyle.self, .style, d.style),
            backdropTransition: value(HeroBackdropTransition.self, .backdropTransition, d.backdropTransition),
            showsCardCaptions: value(Bool.self, .showsCardCaptions, d.showsCardCaptions),
            showsDiscoverRow: value(Bool.self, .showsDiscoverRow, d.showsDiscoverRow)
        )
    }

    /// The generation of ``HeroSourceKind`` a stored selection was last offered.
    /// Bump when adding a case that existing profiles should pick up.
    static let currentOfferedSourcesVersion = 1

    /// Sources introduced since `offeredVersion` was written, appended to a stored
    /// selection.
    ///
    /// Settings persist the exact list the user chose, so a source added later would
    /// stay invisible forever to everyone who already has settings — the people most
    /// likely to want it. A case they were never shown can't be one they declined.
    ///
    /// The version is what makes this a **one-time** adoption, and it is load-
    /// bearing rather than bookkeeping: without it, "not in the stored list" reads
    /// identically whether the source is new or the user switched it off, so turning
    /// Recently Added off would silently switch it back on at the next load.
    ///
    /// Deliberately skipped when the stored list is empty: that means "hero off by
    /// source", and quietly repopulating it would switch the hero back on.
    static func adoptingNewSources(
        _ stored: [HeroSourceKind],
        offeredVersion: Int
    ) -> [HeroSourceKind] {
        guard !stored.isEmpty, offeredVersion < currentOfferedSourcesVersion else { return stored }
        let known = Set(stored)
        return stored + HeroSourceKind.allCases.filter {
            !known.contains($0) && introducedSinceInitialRelease.contains($0)
        }
    }

    /// Sources added after the original four. Only these are adopted into an
    /// existing selection — the first four predate any stored settings, so their
    /// absence is always a deliberate choice.
    static let introducedSinceInitialRelease: Set<HeroSourceKind> = [.recentlyAdded]

    /// Written alongside the values so a saved blob records which generation of
    /// ``HeroSourceKind`` its owner has been shown. Saving means the current source
    /// list was on screen, so anything absent from it was declined rather than
    /// unseen — which is what stops a switched-off source coming back.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(sources, forKey: .sources)
        try c.encode(maxItems, forKey: .maxItems)
        try c.encode(trailersEnabled, forKey: .trailersEnabled)
        try c.encode(hideWatched, forKey: .hideWatched)
        try c.encode(watchlistDiscoveryEnabled, forKey: .watchlistDiscoveryEnabled)
        try c.encode(discoverySources, forKey: .discoverySources)
        try c.encode(showsDiscoverySources, forKey: .showsDiscoverySources)
        try c.encode(showsRatings, forKey: .showsRatings)
        try c.encode(ratingPreferences, forKey: .ratingPreferences)
        try c.encode(randomLibraryKeys, forKey: .randomLibraryKeys)
        try c.encode(autoAdvance, forKey: .autoAdvance)
        try c.encode(autoAdvanceSeconds, forKey: .autoAdvanceSeconds)
        try c.encode(style, forKey: .style)
        try c.encode(backdropTransition, forKey: .backdropTransition)
        try c.encode(showsCardCaptions, forKey: .showsCardCaptions)
        try c.encode(showsDiscoverRow, forKey: .showsDiscoverRow)
        try c.encode(Self.currentOfferedSourcesVersion, forKey: .offeredSourcesVersion)
    }

    /// Whether the given source is currently enabled.
    public func isEnabled(_ source: HeroSourceKind) -> Bool {
        sources.contains(source)
    }

    /// Whether the hero should actually render: switched on **and** has at least
    /// one enabled source.
    public var isActive: Bool {
        isEnabled && !sources.isEmpty
    }

    /// Whether Apple TV's Home uses the Immersive layout. Independent of the
    /// hero's switch and sources, which belong to the Spotlight: every title here
    /// comes from the rows.
    public var followsFocus: Bool {
        style == .followsFocus
    }

    public var usesDiscoveryWatchlistSeeds: Bool {
        isActive && isEnabled(.featured) && discoverySources.contains(where: \.usesTitleSeeds)
    }

    public func shouldShowRatings(for item: MediaItem, spoilerSettings: SpoilerSettings) -> Bool {
        showsRatings && !spoilerSettings.shouldHideRatings(for: item)
    }

    /// Credit actual contributors, including cached or library-bound titles.
    public func discoveryAttributionSources(for item: MediaItem) -> [HeroDiscoverySource] {
        showsDiscoverySources ? HeroDiscoverySource.normalized(item.discoverySources) : []
    }

    /// Whether honoring Hide Watched requires live external watch history beyond
    /// the already-resolved Continue Watching / Watchlist sources. Only the async
    /// discovery sources — Featured and Random-from-library — surface
    /// titles whose current per-profile watch state isn't already known, so this
    /// is the single predicate that gates the extra provider watch-state fetch and
    /// the hero's `externalRefreshRevision` bump.
    public var requiresExternalWatchHistory: Bool {
        isActive && hideWatched
            && (isEnabled(.featured) || isEnabled(.randomFromLibrary))
    }
}

/// How the Home hero chooses what it shows.
public enum HeroStyle: String, Codable, CaseIterable, Sendable {
    /// A rotating spotlight of curated titles, with its own actions, above the rows.
    case carousel
    /// Whatever title is focused in the rows fills the screen; rows hold one position.
    case followsFocus
}

/// How the full-screen backdrop moves from one focused title to the next.
public enum HeroBackdropTransition: String, Codable, CaseIterable, Sendable {
    /// A gentle dissolve.
    case crossfade
    /// The carousel's sideways wipe, entering from the direction of travel.
    case slide
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Persistence

/// Persists ``HeroSettings`` per profile, mirroring `UIDensitySettingsStore` /
/// `HomeLayoutStore`: the primary profile keeps an un-suffixed key so upgrading
/// installs inherit cleanly, and additional profiles pass their `Profile.id`.
public protocol HeroSettingsStoring: Sendable {
    func load() -> HeroSettings
    func save(_ settings: HeroSettings)
}

public final class HeroSettingsStore: HeroSettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.key = SettingsKey.scoped("com.plozz.heroSettings", namespace: namespace)
    }

    public func load() -> HeroSettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(HeroSettings.self, from: data)
        else { return .default }
        return decoded
    }

    public func save(_ settings: HeroSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}

/// In-memory store for tests and previews.
public final class InMemoryHeroSettingsStore: HeroSettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: HeroSettings

    public init(_ initial: HeroSettings = .default) {
        self.settings = initial
    }

    public func load() -> HeroSettings {
        lock.lock(); defer { lock.unlock() }
        return settings
    }

    public func save(_ settings: HeroSettings) {
        lock.lock(); defer { lock.unlock() }
        self.settings = settings
    }
}

/// Observable wrapper so SwiftUI settings screens can two-way bind and have the
/// change persisted + broadcast. Mirrors `UIDensitySettingsModel`.
@MainActor
@Observable
public final class HeroSettingsModel {
    public var settings: HeroSettings {
        didSet { store.save(settings) }
    }

    private let store: HeroSettingsStoring

    public init(store: HeroSettingsStoring = HeroSettingsStore()) {
        self.store = store
        self.settings = store.load()
    }
}
