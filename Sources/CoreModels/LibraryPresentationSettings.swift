import Foundation
import Observation
import os

public enum LibraryContentMode: String, CaseIterable, Sendable {
    case recommended, titles, collections, playlists

    public var displayName: LocalizedStringResource {
        switch self {
        case .recommended: "Recommended"
        case .titles: "Browse"
        case .collections: "Collections"
        case .playlists: "Playlists"
        }
    }

    public var cardCaptionView: CardCaptionView {
        switch self {
        case .recommended: .recommended
        case .titles: .browse
        case .collections: .collections
        case .playlists: .playlists
        }
    }
}

/// Saved intent survives temporarily unavailable tabs and recommendation rows.
public struct LibraryContentLayout: Codable, Equatable, Sendable {
    public var order: [String]
    public var hidden: Set<String>

    public init(order: [String] = [], hidden: Set<String> = []) {
        self.order = order
        self.hidden = hidden
    }

    public func sections(available: [String]) -> OrderedVisibilityList.Sections<String> {
        OrderedVisibilityList.resolving(available: available, order: order, hidden: hidden)
    }

    public mutating func apply(
        _ sections: OrderedVisibilityList.Sections<String>, available: [String]
    ) {
        order = OrderedVisibilityList.mergingOrder(sections.combined, into: order, available: available)
        hidden.subtract(available)
        hidden.formUnion(sections.disabled)
    }
}

public struct LibraryPresentationSettings: Codable, Equatable, Sendable {
    public var logoSize: HeroLogoSize
    public var textSize: HeroTextSize
    public var navigation: LibraryContentLayout
    public var recommendedRows: [String: LibraryContentLayout]
    public var collectionCoverLayouts: [String: CollectionCoverLayout]

    public static let `default` = LibraryPresentationSettings()

    public init(
        logoSize: HeroLogoSize = .default,
        textSize: HeroTextSize = .default,
        navigation: LibraryContentLayout = .init(),
        recommendedRows: [String: LibraryContentLayout] = [:],
        collectionCoverLayouts: [String: CollectionCoverLayout] = [:]
    ) {
        self.logoSize = logoSize
        self.textSize = textSize
        self.navigation = navigation
        self.recommendedRows = recommendedRows
        self.collectionCoverLayouts = collectionCoverLayouts
    }

    private enum CodingKeys: String, CodingKey {
        case logoSize, textSize, navigation, recommendedRows, collectionCoverLayouts
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            logoSize: try values.decodeIfPresent(HeroLogoSize.self, forKey: .logoSize) ?? .default,
            textSize: try values.decodeIfPresent(HeroTextSize.self, forKey: .textSize) ?? .default,
            navigation: try values.decodeIfPresent(LibraryContentLayout.self, forKey: .navigation) ?? .init(),
            recommendedRows: try values.decodeIfPresent(
                [String: LibraryContentLayout].self, forKey: .recommendedRows
            ) ?? [:],
            collectionCoverLayouts: try values.decodeIfPresent(
                [String: CollectionCoverLayout].self, forKey: .collectionCoverLayouts
            ) ?? [:]
        )
    }

    public static func collectionCoverAddress(for row: HomeRowID) -> String {
        "home:\(row.presentationID)"
    }

    public static func collectionCoverAddress(accountID: String, libraryID: String, rowID: String = "") -> String {
        LibraryBrowsePreferencesStore.address(
            accountID: accountID, libraryID: libraryID, mode: "collectionCovers:\(rowID)"
        )
    }

    public func collectionCoverLayout(at address: String) -> CollectionCoverLayout {
        collectionCoverLayouts[address] ?? .default
    }

    public func visibleModes(supported: [LibraryContentMode]) -> [LibraryContentMode] {
        let visible = navigation.sections(available: supported.map(\.rawValue))
            .enabled.compactMap(LibraryContentMode.init(rawValue:))
        // A share or a limited provider can support only Browse. Do not overwrite
        // the shared hidden preference just to keep that library accessible.
        return visible.isEmpty ? supported.filter { $0 == .titles } : visible
    }

    public static func rowAddress(accountID: String, libraryID: String) -> String {
        LibraryBrowsePreferencesStore.address(accountID: accountID, libraryID: libraryID, mode: "recommended")
    }

    public func visibleRows(_ rows: [LibrarySection], at address: String) -> [LibrarySection] {
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return (recommendedRows[address] ?? .init()).sections(available: rows.map(\.id))
            .enabled.compactMap { byID[$0] }
    }

    public var showcaseSettings: HeroSettings {
        var settings = HeroSettings.default
        settings.showcaseLogoSize = logoSize
        settings.showcaseTextSize = textSize
        return settings
    }
}

public protocol LibraryPresentationSettingsStoring: Sendable {
    func load() -> LibraryPresentationSettings
    func save(_ settings: LibraryPresentationSettings)
}

public final class LibraryPresentationSettingsStore: LibraryPresentationSettingsStoring, @unchecked Sendable {
    public static let storageKey = "com.plozz.libraryPresentationSettings"
    private static let logger = Logger(subsystem: "com.plozz.app", category: "settings")
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        key = SettingsKey.scoped(Self.storageKey, namespace: namespace)
    }

    public func load() -> LibraryPresentationSettings {
        guard let data = defaults.data(forKey: key) else { return .default }
        do {
            return try JSONDecoder().decode(LibraryPresentationSettings.self, from: data)
        } catch {
            Self.logger.error("Unable to read library presentation settings: \(String(describing: error))")
            return .default
        }
    }

    public func save(_ settings: LibraryPresentationSettings) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            defaults.set(try encoder.encode(settings), forKey: key)
        } catch {
            Self.logger.error("Unable to save library presentation settings: \(String(describing: error))")
        }
    }
}

@MainActor @Observable
public final class LibraryPresentationSettingsModel {
    public var settings: LibraryPresentationSettings {
        didSet { store.save(settings) }
    }
    private let store: any LibraryPresentationSettingsStoring

    public init(store: any LibraryPresentationSettingsStoring = LibraryPresentationSettingsStore()) {
        self.store = store
        settings = store.load()
    }
}
