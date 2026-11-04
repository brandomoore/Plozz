import CoreModels
import Foundation

/// A download choice is a physical file; an episode row may contain several choices.
/// Grouping does not assert that equal-sized files contain identical bytes.
public struct EpisodeDownloadSelection: Sendable {
    public struct Option: Identifiable, Sendable {
        public let id: String
        public let originID: String
        public let item: MediaItem
        public let version: MediaVersion
    }

    public struct Episode: Identifiable, Sendable {
        public let id: String
        public let item: MediaItem
        public let options: [Option]
        public let recommendedID: String
    }

    public let episodes: [Episode]
    public private(set) var selectedIDs: Set<String>

    public init(
        items: [MediaItem],
        preferences: any VersionPreferenceStoring,
        capabilities: MediaCapabilities
    ) {
        episodes = Self.groupedItems(items).compactMap { group in
            guard let first = group.first else { return nil }
            var seen = Set<String>()
            var explicitID: String?
            let options = group.flatMap { item -> [Option] in
                let versions = PlayerVersionSelection.versions(for: item)
                let candidates = versions.isEmpty && item.versions.isEmpty && !item.opensExternalSource
                    ? [MediaVersion.synthesized(from: item)] : versions
                return candidates.compactMap { version in
                    var routed: MediaItem
                    if versions.isEmpty {
                        routed = item.selectingVersion(nil)
                    } else {
                        guard let selected = PlayerVersionSelection.selecting(version.id, in: item) else {
                            return nil
                        }
                        routed = selected
                    }
                    routed.explicitSourceSelection = true
                    let qualified = version.qualified(
                        accountID: routed.sourceAccountID ?? "",
                        itemID: routed.id
                    )
                    guard seen.insert(qualified.id).inserted else { return nil }
                    if explicitID == nil, let selected = item.selectedVersionID,
                       selected == version.id
                        || (selected == version.playbackMediaSourceID
                            && routed.id == item.id && routed.sourceAccountID == item.sourceAccountID) {
                        explicitID = qualified.id
                    }
                    return Option(
                        id: qualified.id, originID: item.stablePresentationID,
                        item: routed, version: qualified
                    )
                }
            }
            guard let fallback = options.first else { return nil }
            let preferred = explicitID ?? DetailPlaybackSelection.preferredVersionID(
                for: first.selectingVersion(nil), versions: options.map(\.version),
                versionOverride: nil, preferences: preferences, capabilities: capabilities
            ) ?? fallback.id
            return Episode(
                id: first.stablePresentationID, item: first,
                options: options, recommendedID: preferred
            )
        }
        selectedIDs = Set(episodes.map(\.recommendedID))
    }

    public var selectedOptions: [Option] {
        var seen = Set<String>()
        return episodes.flatMap(\.options).filter {
            selectedIDs.contains($0.id) && seen.insert($0.id).inserted
        }
    }

    public mutating func setSelected(_ selected: Bool, optionID: String) {
        guard episodes.contains(where: { $0.options.contains(where: { $0.id == optionID }) }) else { return }
        if selected {
            selectedIDs.insert(optionID)
        } else {
            selectedIDs.remove(optionID)
        }
    }

    public mutating func setSelected(_ selected: Bool, episode: Episode) {
        for option in episode.options { selectedIDs.remove(option.id) }
        if selected { selectedIDs.insert(episode.recommendedID) }
    }

    /// Do not group by title, across accounts, across series, or across conflicting
    /// episode identities/ranges. Unnumbered entries retain their physical identity.
    public static func groupedItems(_ items: [MediaItem]) -> [[MediaItem]] {
        enum Key: Hashable {
            case episode(String, String, Int, Int, Int)
            case item(String)
        }
        var order: [Key] = []
        var groups: [Key: [MediaItem]] = [:]
        var seen = Set<String>()
        for item in EpisodeSequence.sorted(items) where seen.insert(item.stablePresentationID).inserted {
            let key: Key
            if item.kind == .episode,
               let account = item.sourceAccountID, !account.isEmpty,
               let series = item.seriesID, !series.isEmpty,
               let season = item.seasonNumber, season >= 0,
               let number = item.episodeNumber, number > 0,
               (item.episodeNumberEnd ?? number) >= number {
                key = .episode(account, series, season, number, item.episodeNumberEnd ?? number)
            } else {
                key = .item(item.stablePresentationID)
            }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }
        return order.flatMap { key -> [[MediaItem]] in
            let group = groups[key] ?? []
            let namespaces: [ProviderIDNamespace] = [.tmdb, .tvdb, .imdb]
            let conflictingIdentity = namespaces.contains { provider in
                Set(group.compactMap { $0.providerID(provider) }.filter { !$0.isEmpty }).count > 1
            }
            return conflictingIdentity ? group.map { [$0] } : [group]
        }
    }
}
