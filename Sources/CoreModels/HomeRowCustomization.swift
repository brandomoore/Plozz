import Foundation

/// Stable row identity, never a localized heading or a changing recommendation subject.
public enum HomeRowID: Hashable, Codable, Sendable {
    case global(HomeGlobalRow)
    case libraries
    case liveTV
    case library(key: String, section: String)
    case server(accountID: String, section: String)
    case section(String)

    public static func library(_ key: String, kind: LibraryHomeRowKind) -> Self {
        .library(key: key, section: kind.rawValue)
    }

    public var libraryKey: String? {
        guard case let .library(key, _) = self else { return nil }
        return key
    }

    public var libraryKind: LibraryHomeRowKind? {
        guard case let .library(_, section) = self else { return nil }
        return LibraryHomeRowKind(rawValue: section) ?? .hubs
    }

    public var presentationID: String {
        switch self {
        case let .global(row): return "home-\(row.rawValue)"
        case .libraries: return "home-libraries"
        case .liveTV: return "home-live-tv"
        case let .section(id): return "home-section-\(id)"
        case let .library(key, section):
            return "home-library-\(key.utf8.count):\(key)-\(section)"
        case let .server(accountID, section):
            return "home-server-\(accountID.utf8.count):\(accountID)-\(section)"
        }
    }
}

/// One arranger entry. Server-authored titles stay content, not localization keys.
public struct HomeRowChoice: Identifiable, Equatable, Sendable {
    public let id: HomeRowID
    public let title: String // l10n:content — provider heading or stable fallback
    public let localizedTitle: LocalizedStringResource?
    public let library: AggregatedLibrary?
    public let isProviderDefault: Bool
    public let isLegacyDefault: Bool
    public let serverRow: HomeServerRowDefinition?
    public let collectionSection: CollectionSection?
    public let hasCollectionCovers: Bool

    public init(
        id: HomeRowID, title: String, localizedTitle: LocalizedStringResource? = nil,
        library: AggregatedLibrary? = nil, isProviderDefault: Bool, isLegacyDefault: Bool = true,
        serverRow: HomeServerRowDefinition? = nil, collectionSection: CollectionSection? = nil,
        hasCollectionCovers: Bool = false
    ) {
        self.id = id
        self.title = title
        self.localizedTitle = localizedTitle
        self.library = library
        self.isProviderDefault = isProviderDefault
        self.isLegacyDefault = isLegacyDefault
        self.serverRow = serverRow
        self.collectionSection = collectionSection
        self.hasCollectionCovers = hasCollectionCovers
    }

    public static var shared: [Self] {
        HomeGlobalRow.allCases.map {
            Self(id: .global($0), title: $0.rawValue, localizedTitle: $0.title,
                 isProviderDefault: $0 != .recentlyAdded)
        } + [
            Self(id: .libraries, title: "Libraries", localizedTitle: "Libraries",
                 isProviderDefault: true),
            Self(id: .liveTV, title: "Live TV", localizedTitle: "Live TV",
                 isProviderDefault: false, isLegacyDefault: false)
        ]
    }

    public init(serverRow: HomeServerRowDefinition) {
        self.init(
            id: serverRow.id, title: serverRow.section.title ?? serverRow.section.kind.rawValue,
            localizedTitle: serverRow.section.title == nil ? serverRow.section.kind.title : nil,
            isProviderDefault: true, isLegacyDefault: false, serverRow: serverRow
        )
    }

    public init(collectionSection: CollectionSection, library: AggregatedLibrary? = nil) {
        self.init(
            id: collectionSection.rowID, title: collectionSection.title, library: library,
            isProviderDefault: false, isLegacyDefault: false, collectionSection: collectionSection
        )
    }

    public static func baseRows(for library: AggregatedLibrary) -> [Self] {
        LibraryHomeRowKind.available(for: library).filter { $0 != .hubs }.map {
            Self(
                id: .library(library.key, kind: $0),
                title: $0.rawValue, localizedTitle: $0.displayName,
                library: library, isProviderDefault: true,
                hasCollectionCovers: library.library.kind == .collection
            )
        }
    }

    public init(section: LibrarySection, library: AggregatedLibrary) {
        self.init(
            id: .library(key: library.key, section: section.id),
            title: section.title, localizedTitle: section.localizedTitle,
            library: library,
            isProviderDefault: section.isHomeDefault
                ?? (section.id == "recentlyAdded" || section.id == "nextUp" || library.providerKind == .plex),
            isLegacyDefault: section.isLegacyHomeDefault ?? true,
            hasCollectionCovers: CollectionCoverLayout.isCollectionGroup(section.items)
                || library.library.kind == .collection
        )
    }
}

/// Profile-synced intent. Missing/offline rows retain both order and visibility.
public struct HomeRowCustomization: Codable, Equatable, Sendable {
    public enum Defaults: String, Codable, CaseIterable, Sendable {
        case matchServer
        case provider
        case combined
        case legacy
        case custom

        public var title: LocalizedStringResource {
            switch self {
            case .matchServer: return "Match server"
            case .provider: return "Server defaults"
            case .combined: return "Combined rows"
            case .legacy: return "Previous layout"
            case .custom: return "Custom"
            }
        }
    }

    public var defaults: Defaults
    public var order: [HomeRowID]
    public var hidden: Set<HomeRowID>
    public var shown: Set<HomeRowID>
    public var serverRows: [HomeServerRowDefinition]
    /// Effective server defaults are runtime state, not profile-synced intent.
    public var resolvedDefaults: HomeResolvedRowDefaults?

    public var effectiveOrder: [HomeRowID] {
        defaults == .matchServer ? resolvedDefaults?.order ?? order : order
    }

    public var availableServerRows: [HomeServerRowDefinition] {
        defaults == .matchServer ? resolvedDefaults?.serverRows ?? [] : serverRows
    }

    public init(
        defaults: Defaults = .provider, order: [HomeRowID] = [],
        hidden: Set<HomeRowID> = [], shown: Set<HomeRowID> = [],
        serverRows: [HomeServerRowDefinition] = []
    ) {
        self.defaults = defaults
        self.order = order
        self.hidden = hidden
        self.shown = shown.subtracting(hidden)
        self.serverRows = serverRows
    }

    public func isVisible(_ id: HomeRowID, providerDefault: Bool) -> Bool {
        if hidden.contains(id) { return false }
        if shown.contains(id) { return true }
        switch defaults {
        case .matchServer:
            guard let resolvedDefaults else { return providerDefault }
            switch resolvedDefaults.mode {
            case .server: return resolvedDefaults.order.contains(id)
            case .combined:
                if Self.isCombinedRow(id) || resolvedDefaults.order.contains(id) { return true }
                guard let key = id.libraryKey else { return false }
                return providerDefault && resolvedDefaults.fallbackAccountIDs.contains {
                    key.hasPrefix($0 + ":")
                }
            case .providerFallback: return providerDefault
            }
        case .provider, .legacy: return providerDefault
        case .combined: return Self.isCombinedRow(id)
        case .custom: return false
        }
    }

    private static func isCombinedRow(_ id: HomeRowID) -> Bool {
        switch id {
        case .global, .libraries, .liveTV: return true
        case .library, .server, .section: return false
        }
    }

    public func sections(choices: [HomeRowChoice]) -> OrderedVisibilityList.Sections<HomeRowID> {
        sections(
            available: choices.map(\.id),
            hidden: Set(choices.filter { !isVisible($0.id, providerDefault: $0.isProviderDefault) }.map(\.id))
        )
    }

    func sections(
        available: [HomeRowID], hidden: Set<HomeRowID>
    ) -> OrderedVisibilityList.Sections<HomeRowID> {
        var result = OrderedVisibilityList.resolving(
            available: available, order: effectiveOrder, hidden: hidden
        )
        // Include newly discovered/fallback rows before placing Libraries last.
        // Older Combined arrangements with an explicit order remain customized.
        if defaults == .matchServer || (defaults == .combined && order.isEmpty),
           let index = result.enabled.firstIndex(of: .libraries) {
            result.enabled.remove(at: index)
            result.enabled.append(.libraries)
        }
        return result
    }

    public mutating func setVisible(_ visible: Bool, for id: HomeRowID) {
        if defaults == .matchServer {
            let rows = availableServerRows
            let choices = HomeRowChoice.shared + rows.map(HomeRowChoice.init(serverRow:))
            let current = sections(choices: choices)
            order = current.combined
            shown.formUnion(current.enabled)
            hidden.formUnion(current.disabled)
            serverRows = rows
            defaults = .custom
            resolvedDefaults = nil
        }
        updateVisibility(visible, for: id)
    }

    private mutating func updateVisibility(_ visible: Bool, for id: HomeRowID) {
        if visible {
            hidden.remove(id)
            shown.insert(id)
        } else {
            shown.remove(id)
            hidden.insert(id)
        }
    }

    public mutating func apply(
        _ sections: OrderedVisibilityList.Sections<HomeRowID>, choices: [HomeRowChoice]
    ) {
        let available = Set(choices.map(\.id))
        let previous = self.sections(choices: choices)
        if defaults == .matchServer {
            order = effectiveOrder
        }
        var seen = Set<HomeRowID>()
        let edited = sections.combined.filter { available.contains($0) && seen.insert($0).inserted }
        var iterator = edited.makeIterator()
        var result: [HomeRowID] = []
        for id in order {
            if available.contains(id) {
                if let next = iterator.next() { result.append(next) }
            } else {
                result.append(id)
            }
        }
        while let next = iterator.next() { result.append(next) }
        seen.removeAll()
        order = result.filter { seen.insert($0).inserted }
        let enabled = Set(sections.enabled)
        for id in Set(previous.enabled).symmetricDifference(enabled).intersection(available) {
            updateVisibility(enabled.contains(id), for: id)
        }
        // A saved arrangement also remembers automatically hidden choices, so
        // loading placeholders cannot turn optional rows back on.
        hidden.formUnion(Set(sections.disabled).intersection(available))
        shown.formUnion(enabled.intersection(available))
        shown.subtract(hidden)
        let incoming = choices.compactMap(\.serverRow)
        let incomingIDs = Set(incoming.map(\.id))
        serverRows = incoming + availableServerRows.filter { !incomingIDs.contains($0.id) }
        if defaults != .legacy { defaults = .custom }
        resolvedDefaults = nil
    }

    private enum CodingKeys: String, CodingKey {
        case defaults, order, hidden, shown, serverRows
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        defaults = try values.decode(Defaults.self, forKey: .defaults)
        order = try values.decode([HomeRowID].self, forKey: .order)
        hidden = try values.decode(Set<HomeRowID>.self, forKey: .hidden)
        shown = try values.decode(Set<HomeRowID>.self, forKey: .shown)
        serverRows = try values.decodeIfPresent([HomeServerRowDefinition].self, forKey: .serverRows) ?? []
        shown.subtract(hidden)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(defaults, forKey: .defaults)
        try values.encode(order, forKey: .order)
        try values.encode(hidden.sorted { $0.presentationID < $1.presentationID }, forKey: .hidden)
        try values.encode(shown.sorted { $0.presentationID < $1.presentationID }, forKey: .shown)
        if !serverRows.isEmpty { try values.encode(serverRows, forKey: .serverRows) }
    }
}
