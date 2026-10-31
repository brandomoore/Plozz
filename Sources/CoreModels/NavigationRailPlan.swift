import Foundation

/// A top-level destination shared by every TV navigation style. Library grids
/// are root screens, rather than pages pushed on top of Home.
public enum NavigationRailDestination: Hashable, Sendable {
    case home
    case search
    case watchlist
    case liveTV
    case music
    case settings
    /// A single library, addressed by its ``AggregatedLibrary/key``.
    case library(String)
    /// The synthetic combined browse over every visible library.
    case allLibraries

    /// A stable string form for scene storage.
    public var storageValue: String {
        switch self {
        case .home: return "home"
        case .search: return "search"
        case .watchlist: return "watchlist"
        case .liveTV: return "liveTV"
        case .music: return "music"
        case .settings: return "settings"
        case .allLibraries: return "allLibraries"
        case let .library(key): return "library:\(key)"
        }
    }

    public init?(storageValue: String) {
        switch storageValue {
        case "home": self = .home
        case "search": self = .search
        case "watchlist": self = .watchlist
        case "liveTV": self = .liveTV
        case "music": self = .music
        case "settings": self = .settings
        case "allLibraries": self = .allLibraries
        default:
            guard storageValue.hasPrefix("library:") else { return nil }
            self = .library(String(storageValue.dropFirst("library:".count)))
        }
    }
}

/// One library slot in the rail: either a real library or the synthetic
/// "All Libraries" entry.
public struct NavigationRailLibraryEntry: Hashable, Sendable, Identifiable {
    /// The arrangement key — an ``AggregatedLibrary/key``, or
    /// ``NavigationLibraryLayout/allLibrariesKey`` for the combined entry.
    public let key: String
    /// The backing library; `nil` for the combined "All Libraries" entry.
    public let library: AggregatedLibrary?
    public let isOffline: Bool

    public init(key: String, library: AggregatedLibrary?, isOffline: Bool = false) {
        self.key = key
        self.library = library
        self.isOffline = isOffline
    }

    public var id: String { key }

    /// Whether this is the synthetic combined entry.
    public var isAllLibraries: Bool { library == nil }

    public var destination: NavigationRailDestination {
        library == nil ? .allLibraries : .library(key)
    }
}

/// Pure resolution of the rail's library slots from the live library set plus the
/// profile's saved arrangement. SwiftUI-free so the ordering/visibility rules are
/// unit-testable without a running view hierarchy.
public enum NavigationDestinationDefaults {
    public static func topBar(
        destinations: [NavigationRailDestination],
        layout: NavigationLibraryLayout = .default
    ) -> [NavigationRailDestination] {
        let visible = destinations.filter { $0 != .settings || !layout.hiddenKeys.contains(NavigationLibraryLayout.settingsKey) }
        if visible.isEmpty, destinations.contains(.settings) { return [.settings] }
        guard layout.pinsSettingsInTopBar, visible.contains(.settings) else { return visible }
        return visible.filter { $0 != .settings } + [.settings]
    }

    public static func iPhoneOverflowKeys(visible: [String]) -> Set<String> {
        visible.count > 5 ? Set(visible.dropFirst(4)) : []
    }

    public static func compact(hasMusic: Bool) -> [String] {
        var keys = [NavigationLibraryLayout.homeKey, NavigationLibraryLayout.watchlistKey]
        keys.append(NavigationLibraryLayout.liveTVKey)
        keys.append(NavigationLibraryLayout.searchKey)
        if hasMusic { keys.append(NavigationLibraryLayout.musicKey) }
        keys.append(NavigationLibraryLayout.settingsKey)
        return keys
    }

    public static func sidebar(visibleLibraries: [AggregatedLibrary], hasMusic: Bool) -> [String] {
        var keys = compact(hasMusic: hasMusic)
        keys.insert(
            contentsOf: NavigationRailPlan.availableKeys(visibleLibraries: visibleLibraries),
            at: keys.count - 1
        )
        return keys
    }

    public static func rail(visibleLibraries: [AggregatedLibrary], hasMusic: Bool) -> [String] {
        var keys = sidebar(visibleLibraries: visibleLibraries, hasMusic: hasMusic)
        keys.removeAll { $0 == NavigationLibraryLayout.searchKey }
        keys.insert(NavigationLibraryLayout.searchKey, at: 0)
        return keys
    }

    public static let iOSDefaultVisibleKeys = [
        NavigationLibraryLayout.homeKey,
        NavigationLibraryLayout.downloadsKey,
        NavigationLibraryLayout.searchKey,
    ]

    /// The editor's catalogue, not the default enabled tabs.
    public static var iOS: [String] {
        iOSDefaultVisibleKeys + [
            NavigationLibraryLayout.watchlistKey,
            NavigationLibraryLayout.liveTVKey,
            NavigationLibraryLayout.settingsKey,
        ]
    }

    public static func iOS(visibleLibraries: [AggregatedLibrary]) -> [String] {
        var keys = iOS
        let libraries = NavigationRailPlan.browsableLibraries(visibleLibraries)
        keys.insert(
            contentsOf: (libraries.count > 1 ? [NavigationLibraryLayout.allLibrariesKey] : [])
                + libraries.map(\.key),
            at: keys.count - 1
        )
        return keys
    }

    public static var iOSAutomaticallyHiddenKeys: Set<String> {
        iOSAutomaticallyHiddenKeys(available: iOS)
    }

    /// New libraries stay in the editor until explicitly shown. This is a
    /// presentation default, not a persisted hide or a content restriction.
    public static func iOSAutomaticallyHiddenKeys(available: [String]) -> Set<String> {
        Set(available).subtracting(iOSDefaultVisibleKeys)
    }
}

public enum NavigationRailPlan {
    /// Every key offered by Settings' shared navigation arranger. Built-ins are
    /// present even with no connected libraries so a temporarily-offline server
    /// cannot make Home, Search, Settings, or another app destination disappear
    /// from the editor.
    public static func customizableKeys(
        visibleLibraries: [AggregatedLibrary],
        style: NavigationStyle = .sidebar
    ) -> [String] {
        let keys: [String]
        switch style {
        case .tabBar:
            keys = NavigationDestinationDefaults.sidebar(visibleLibraries: visibleLibraries, hasMusic: true)
        case .sidebar:
            keys = NavigationDestinationDefaults.sidebar(visibleLibraries: visibleLibraries, hasMusic: true)
        case .rail: keys = NavigationDestinationDefaults.rail(visibleLibraries: visibleLibraries, hasMusic: true)
        }
        return deduplicated(keys)
    }

    /// The arrangeable library keys: the combined entry first, then each visible
    /// non-music library in discovery order.
    public static func availableKeys(visibleLibraries: [AggregatedLibrary]) -> [String] {
        [NavigationLibraryLayout.allLibrariesKey] + browsableLibraries(visibleLibraries).map(\.key)
    }

    /// The libraries the rail can offer: everything that is not a music library.
    public static func browsableLibraries(_ libraries: [AggregatedLibrary]) -> [AggregatedLibrary] {
        libraries.filter { !$0.library.isMusic }
    }

    /// The rail's library slots, in the viewer's order, with hidden entries removed.
    public static func entries(
        visibleLibraries: [AggregatedLibrary],
        layout: NavigationLibraryLayout,
        offlineAccountIDs: Set<String> = []
    ) -> [NavigationRailLibraryEntry] {
        let browsable = browsableLibraries(visibleLibraries)
        let byKey = Dictionary(
            browsable.map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let available = availableKeys(visibleLibraries: visibleLibraries)
        return layout.visibleKeys(available: available).compactMap { key in
            if key == NavigationLibraryLayout.allLibrariesKey {
                // The combined entry is pointless with nothing to combine, and
                // actively misleading with exactly one library.
                guard browsable.count > 1 else { return nil }
                return NavigationRailLibraryEntry(
                    key: key, library: nil,
                    isOffline: browsable.allSatisfy { offlineAccountIDs.contains($0.accountID) }
                )
            }
            guard let library = byKey[key] else { return nil }
            return NavigationRailLibraryEntry(
                key: key, library: library,
                isOffline: offlineAccountIDs.contains(library.accountID)
            )
        }
    }

    /// Resolves the complete ordered destination list for one navigation style.
    ///
    /// `availableKeys` is both the style's supported set and its historical
    /// default order. All styles include libraries by default. A saved arrangement
    /// wins in every style.
    public static func destinations(
        visibleLibraries: [AggregatedLibrary],
        layout: NavigationLibraryLayout,
        availableKeys: [String]
    ) -> [NavigationRailDestination] {
        destinations(
            libraryEntries: entries(visibleLibraries: visibleLibraries, layout: layout),
            layout: layout,
            availableKeys: availableKeys
        )
    }

    public static func destinations(
        libraryEntries: [NavigationRailLibraryEntry],
        layout: NavigationLibraryLayout,
        availableKeys: [String]
    ) -> [NavigationRailDestination] {
        let libraryDestinations = Dictionary(
            uniqueKeysWithValues: libraryEntries.map { ($0.key, $0.destination) }
        )
        let validKeys = deduplicated(availableKeys).filter { key in
            if key == NavigationLibraryLayout.allLibrariesKey {
                return libraryDestinations[key] != nil
            }
            if isBuiltInKey(key) {
                return true
            }
            return libraryDestinations[key] != nil
        }
        let orderedKeys = layout.visibleKeys(available: validKeys)
        var destinations = orderedKeys.compactMap { key -> NavigationRailDestination? in
            if let libraryDestination = libraryDestinations[key] {
                return libraryDestination
            }
            return destination(for: key)
        }

        if validKeys.contains(NavigationLibraryLayout.settingsKey),
           !destinations.contains(.settings) {
            destinations.append(.settings)
        }
        return destinations
    }

    /// Maps a persisted arrangement key to its built-in destination.
    public static func destination(for key: String) -> NavigationRailDestination? {
        switch key {
        case NavigationLibraryLayout.homeKey: return .home
        case NavigationLibraryLayout.searchKey: return .search
        case NavigationLibraryLayout.watchlistKey: return .watchlist
        case NavigationLibraryLayout.liveTVKey: return .liveTV
        case NavigationLibraryLayout.musicKey: return .music
        case NavigationLibraryLayout.settingsKey: return .settings
        case NavigationLibraryLayout.allLibrariesKey: return .allLibraries
        default: return nil
        }
    }

    /// Stable arrangement key for any destination.
    public static func key(for destination: NavigationRailDestination) -> String {
        switch destination {
        case .home: return NavigationLibraryLayout.homeKey
        case .search: return NavigationLibraryLayout.searchKey
        case .watchlist: return NavigationLibraryLayout.watchlistKey
        case .liveTV: return NavigationLibraryLayout.liveTVKey
        case .music: return NavigationLibraryLayout.musicKey
        case .settings: return NavigationLibraryLayout.settingsKey
        case .allLibraries: return NavigationLibraryLayout.allLibrariesKey
        case let .library(key): return key
        }
    }

    /// Resolves a selected destination to the first destination the active style
    /// can actually show. Settings is the final invariant fallback.
    public static func resolvedSelection(
        _ selection: NavigationRailDestination,
        destinations: [NavigationRailDestination]
    ) -> NavigationRailDestination {
        destinations.contains(selection) ? selection : (destinations.first ?? .settings)
    }

    private static func isBuiltInKey(_ key: String) -> Bool {
        destination(for: key) != nil
    }

    private static func deduplicated(_ keys: [String]) -> [String] {
        var seen: Set<String> = []
        return keys.filter { seen.insert($0).inserted }
    }
}
