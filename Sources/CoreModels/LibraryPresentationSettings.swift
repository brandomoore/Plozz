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

/// How a library's See all grid presents the title that has focus.
public enum SeeAllLayout: String, Codable, CaseIterable, Sendable {
    /// The plain grid.
    case grid
    /// The full grid; a floating details card appears once focus has rested on a title.
    case gridWithPopup

    public var displayName: LocalizedStringResource {
        switch self {
        case .grid: "Grid"
        case .gridWithPopup: "Grid with pop-up details"
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
    public var seeAllLayout: SeeAllLayout
    /// Seconds focus must rest on a title before the pop-up appears.
    public var seeAllPopupDelay: Double
    /// Whether the Search screen's cards also get the pop-up (same delay).
    public var searchPopupEnabled: Bool
    /// Seconds the pop-up stays on screen before fading out. 0 never times out.
    public var seeAllPopupDuration: Double

    public static let popupDelayRange = 0.5...5.0
    public static let popupDelayStep = 0.5
    public static let defaultPopupDelay = 2.0
    /// 0.5 s … 5 s in half-second steps.
    public static let popupDelayChoices: [Double] = stride(
        from: popupDelayRange.lowerBound, through: popupDelayRange.upperBound, by: popupDelayStep
    ).map { $0 }

    public static let popupDurationRange = 0.0...10.0
    public static let popupDurationStep = 2.0
    /// Pop-ups stay until focus moves, as they did before this was a setting.
    public static let defaultPopupDuration = 0.0
    /// 0 s (no timeout), then 2 s … 10 s in two-second steps.
    public static let popupDurationChoices: [Double] = stride(
        from: popupDurationRange.lowerBound, through: popupDurationRange.upperBound, by: popupDurationStep
    ).map { $0 }

    public static let `default` = LibraryPresentationSettings()

    /// Snaps to the nearest two seconds within 0 s … 10 s.
    public static func clampedPopupDuration(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return defaultPopupDuration }
        let snapped = (seconds / popupDurationStep).rounded() * popupDurationStep
        return min(max(snapped, popupDurationRange.lowerBound), popupDurationRange.upperBound)
    }

    /// How long a pop-up stays before fading out, or `nil` when it never times out.
    public var popupHideAfter: Duration? {
        let seconds = Self.clampedPopupDuration(seeAllPopupDuration)
        return seconds > 0 ? .seconds(seconds) : nil
    }

    /// Snaps to the nearest half second within 0.5 s … 5 s.
    public static func clampedPopupDelay(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return defaultPopupDelay }
        let snapped = (seconds / popupDelayStep).rounded() * popupDelayStep
        return min(max(snapped, popupDelayRange.lowerBound), popupDelayRange.upperBound)
    }

    /// The Search screen's pop-up delay, or `nil` when search shows no pop-up.
    public var searchPopupDelayIfEnabled: Duration? {
        searchPopupEnabled ? .seconds(Self.clampedPopupDelay(seeAllPopupDelay)) : nil
    }

    /// The pop-up delay, or `nil` when the layout shows no pop-up.
    public var seeAllPopupDelayIfEnabled: Duration? {
        seeAllLayout == .gridWithPopup ? .seconds(Self.clampedPopupDelay(seeAllPopupDelay)) : nil
    }

    public init(
        logoSize: HeroLogoSize = .default,
        textSize: HeroTextSize = .default,
        navigation: LibraryContentLayout = .init(),
        recommendedRows: [String: LibraryContentLayout] = [:],
        collectionCoverLayouts: [String: CollectionCoverLayout] = [:],
        seeAllLayout: SeeAllLayout = .grid,
        seeAllPopupDelay: Double = LibraryPresentationSettings.defaultPopupDelay,
        searchPopupEnabled: Bool = false,
        seeAllPopupDuration: Double = LibraryPresentationSettings.defaultPopupDuration
    ) {
        self.logoSize = logoSize
        self.textSize = textSize
        self.navigation = navigation
        self.recommendedRows = recommendedRows
        self.collectionCoverLayouts = collectionCoverLayouts
        self.seeAllLayout = seeAllLayout
        self.seeAllPopupDelay = Self.clampedPopupDelay(seeAllPopupDelay)
        self.searchPopupEnabled = searchPopupEnabled
        self.seeAllPopupDuration = Self.clampedPopupDuration(seeAllPopupDuration)
    }

    private enum CodingKeys: String, CodingKey {
        case logoSize, textSize, navigation, recommendedRows, collectionCoverLayouts
        case seeAllLayout, seeAllPopupDelay, searchPopupEnabled, seeAllPopupDuration
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
            ) ?? [:],
            seeAllLayout: try values.decodeIfPresent(SeeAllLayout.self, forKey: .seeAllLayout) ?? .grid,
            seeAllPopupDelay: try values.decodeIfPresent(Double.self, forKey: .seeAllPopupDelay)
                ?? Self.defaultPopupDelay,
            searchPopupEnabled: try values.decodeIfPresent(Bool.self, forKey: .searchPopupEnabled) ?? false,
            seeAllPopupDuration: try values.decodeIfPresent(Double.self, forKey: .seeAllPopupDuration)
                ?? Self.defaultPopupDuration
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
