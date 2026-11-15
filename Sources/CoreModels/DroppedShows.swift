import Foundation
import Observation

/// A show the viewer has given up on.
///
/// Dropping is a statement about the whole show, not a card: "stop offering me
/// this". It takes every episode of it off Continue Watching, Next Up and
/// Upcoming, on every server, until the viewer watches it again — finishing an
/// episode or marking one watched is them changing their mind, and the drop is
/// taken back without anyone having to remember to.
///
/// Nothing on the server is changed to achieve that. Saved positions and watched
/// marks are left exactly as they were, so taking a drop back restores the show
/// where it was. A server that can hold the decision itself (Jellyfin's dislike,
/// which AIOMetadata reads as a drop) is told as well — see ``ShowDropSyncing``.
public struct DroppedShow: Codable, Equatable, Sendable {
    /// Every identity the show is known by — see ``DroppedShowKeys``.
    public var keys: [String]
    /// The show's title when it was dropped, for diagnostics and any future
    /// "dropped shows" list. Never used for matching.
    public var title: String?
    public var droppedAt: Date

    public init(keys: [String], title: String?, droppedAt: Date) {
        self.keys = keys
        self.title = title
        self.droppedAt = droppedAt
    }
}

/// The identities a show is matched by.
///
/// The same show lives on several servers under unrelated ids, so a drop is keyed
/// first by the series' external ids — identical everywhere — and then by the
/// owning server's own series id for shows that carry none. These are the same
/// keys remembered audio and subtitle choices use, so "this show" means one
/// thing across the app.
public enum DroppedShowKeys {
    /// Keys for the show `item` belongs to: itself for a series, its series for a
    /// season or episode. Empty for anything that is not part of a show.
    public static func keys(for item: MediaItem) -> [String] {
        switch item.kind {
        case .series:
            // A series carries its external ids as its own; promote them to the
            // series namespaces an episode's ids are folded under.
            var seriesIDs = item.providerIDs
            seriesIDs.mergeSeriesProviderIDs(from: item.providerIDs, promotingBaseIDs: true)
            var keys = SeriesTrackPreferenceKey.crossServerKeys(providerIDs: seriesIDs)
            keys.append(SeriesTrackPreferenceKey.make(sourceAccountID: item.sourceAccountID, seriesID: item.id))
            // A merged card stands for the same series on every server holding it.
            keys += item.sources.map {
                SeriesTrackPreferenceKey.make(sourceAccountID: $0.accountID, seriesID: $0.itemID)
            }
            return unique(keys)
        case .season, .episode:
            guard let seriesID = item.seriesID, !seriesID.isEmpty else { return [] }
            return unique(
                SeriesTrackPreferenceKey.crossServerKeys(providerIDs: item.providerIDs)
                    + [SeriesTrackPreferenceKey.make(sourceAccountID: item.sourceAccountID, seriesID: seriesID)]
            )
        case .movie, .video, .folder, .collection, .playlist, .unknown:
            return []
        }
    }

    private static func unique(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }
}

/// Persists one profile's dropped shows.
public final class DroppedShowsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    /// - Parameter namespace: per-profile scope, mirroring the other settings
    ///   stores: `nil` is the primary profile, other profiles pass their id.
    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.key = SettingsKey.scoped("com.plozz.droppedShows", namespace: namespace)
    }

    public func load() -> [DroppedShow] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([DroppedShow].self, from: data)) ?? []
    }

    public func save(_ shows: [DroppedShow]) {
        guard !shows.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let data = try? encoder.encode(shows) { defaults.set(data, forKey: key) }
    }
}

public extension Notification.Name {
    /// Posted on the main actor after a profile's dropped shows change. The
    /// `object` is the ``DroppedShowsModel`` that changed.
    static let droppedShowsDidChange = Notification.Name("com.plozz.droppedShowsDidChange")
}

/// The live, observable set of one profile's dropped shows.
///
/// Read from view bodies — every card's menu asks whether its show is dropped —
/// so answers come from memory, and from a single empty check when nothing is
/// dropped, which is the usual case. Reading ``isDropped(_:)`` inside a SwiftUI
/// body records a dependency, so a menu or hero redraws when a drop changes.
@MainActor
@Observable
public final class DroppedShowsModel {
    public private(set) var shows: [DroppedShow]
    @ObservationIgnored private var keySet: Set<String>
    @ObservationIgnored private let store: DroppedShowsStore

    public init(store: DroppedShowsStore) {
        self.store = store
        let shows = store.load()
        self.shows = shows
        self.keySet = Set(shows.flatMap(\.keys))
    }

    private static var shared: [String: DroppedShowsModel] = [:]

    /// One model per profile, shared by every surface, so a drop made from a menu
    /// is seen at once by Home and by every other card.
    public static func shared(namespace: String?) -> DroppedShowsModel {
        let key = namespace ?? ""
        if let model = shared[key] { return model }
        let model = DroppedShowsModel(store: DroppedShowsStore(namespace: namespace))
        shared[key] = model
        return model
    }

    public var isEmpty: Bool { shows.isEmpty }

    /// Whether the show `item` belongs to has been dropped.
    public func isDropped(_ item: MediaItem) -> Bool {
        guard !shows.isEmpty else { return false }
        return DroppedShowKeys.keys(for: item).contains(where: keySet.contains)
    }

    /// `items` without the episodes, seasons and series of dropped shows.
    public func excludingDropped(_ items: [MediaItem]) -> [MediaItem] {
        guard !shows.isEmpty else { return items }
        return items.filter { !isDropped($0) }
    }

    /// Drops the show `item` belongs to. Returns `false` when `item` is not part
    /// of a show, or the show was already dropped under every key it has.
    @discardableResult
    public func drop(_ item: MediaItem, title: String? = nil, at date: Date = Date()) -> Bool {
        let keys = DroppedShowKeys.keys(for: item)
        guard !keys.isEmpty else { return false }
        // The same show met through another server, or once its external ids are
        // known, may bring keys this record lacks: fold them in so the drop then
        // matches there too.
        if let index = shows.firstIndex(where: { !Set($0.keys).isDisjoint(with: keys) }) {
            let missing = keys.filter { !shows[index].keys.contains($0) }
            guard !missing.isEmpty else { return false }
            shows[index].keys += missing
        } else {
            shows.append(DroppedShow(keys: keys, title: title, droppedAt: date))
        }
        commit()
        return true
    }

    /// Takes back every drop that matches the show `item` belongs to. Returns
    /// `false` when it was not dropped.
    @discardableResult
    public func undrop(_ item: MediaItem) -> Bool {
        let keys = Set(DroppedShowKeys.keys(for: item))
        guard !keys.isEmpty else { return false }
        let remaining = shows.filter { Set($0.keys).isDisjoint(with: keys) }
        guard remaining.count != shows.count else { return false }
        shows = remaining
        commit()
        return true
    }

    private func commit() {
        keySet = Set(shows.flatMap(\.keys))
        store.save(shows)
        NotificationCenter.default.post(name: .droppedShowsDidChange, object: self)
    }
}

/// A server that can hold "this viewer dropped this show" itself.
///
/// Optional: a drop always takes effect in Plozz, and a provider that conforms
/// additionally records it where other clients — and services built on the
/// server, such as AIOMetadata's tracker sync — can see it.
public protocol ShowDropSyncing: Sendable {
    /// Records or clears the drop on the show `itemID` belongs to.
    /// - Parameters:
    ///   - seriesID: the server's id for the series when already known; `nil`
    ///     means `itemID` may be an episode or season and must be resolved.
    func setShowDropped(_ dropped: Bool, itemID: String, seriesID: String?) async throws
}
