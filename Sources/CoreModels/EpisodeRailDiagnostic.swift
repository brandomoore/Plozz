import Foundation
import Observation

/// Counts from the same response that supplied the rail, before virtual episodes were removed.
public protocol EpisodeListingEvidenceProviding: MediaProvider {
    func episodeListing(containerID: String, seriesID: String?) async throws -> EpisodeChildListing
}

public struct EpisodeChildListing: Sendable {
    public let items: [MediaItem]
    public let evidence: EpisodeRailDiagnostic.List

    public init(items: [MediaItem], evidence: EpisodeRailDiagnostic.List) {
        self.items = items
        self.evidence = evidence
    }

    public static func fetch(
        from provider: any MediaProvider, containerID: String, seriesID: String? = nil
    ) async throws -> Self {
        if let source = provider as? any EpisodeListingEvidenceProviding {
            return try await source.episodeListing(containerID: containerID, seriesID: seriesID)
        }
        let items: [MediaItem]
        if let seriesID {
            items = try await provider.episodes(inSeason: containerID, ofSeries: seriesID)
        } else {
            items = try await provider.children(of: containerID)
        }
        return Self(items: items, evidence: .unknown)
    }
}

/// Manual, title-free evidence captured at selection, not reconstructed after playback fails.
public struct EpisodeRailDiagnostic: Encodable, Equatable, Sendable {
    public struct List: Encodable, Equatable, Sendable {
        public enum Origin: String, Encodable, Sendable { case seasonRequest, childrenRequest, snapshot, unknown }
        public let origin: Origin
        public let returnedEpisodes: Int?

        public init(origin: Origin, returnedEpisodes: Int? = nil) {
            self.origin = origin
            self.returnedEpisodes = returnedEpisodes
        }

        public static let unknown = Self(origin: .unknown)
        public static let snapshot = Self(origin: .snapshot)
    }

    public let list: List
    public let libraryCards: Int
    public let upcomingCards: Int
    public let displayedCards: Int
    public let selectedUpcoming: Bool
    public let episodeNumber: Int?
    public let seasonNumber: Int?

    public init(list: List, libraryCards: Int, upcomingCards: Int, selected: MediaItem) {
        self.list = list
        self.libraryCards = libraryCards
        self.upcomingCards = upcomingCards
        displayedCards = libraryCards + upcomingCards
        selectedUpcoming = selected.isUpcomingUnaired
        episodeNumber = selected.episodeNumber
        seasonNumber = selected.seasonNumber
    }

    // l10n:content — plain-text QR payload; only technical counts, ordinals and fixed codes.
    public var supportText: String {
        let source = selectedUpcoming ? "upcoming" : list.origin.rawValue
        return """
        format=plozz-episode-rail-1 provider=jellyfin
        list=\(list.origin.rawValue) returned_episodes=\(list.returnedEpisodes.map(String.init) ?? "unknown")
        cards=\(displayedCards) library=\(libraryCards) upcoming=\(upcomingCards)
        selected=\(source) season=\(seasonNumber.map(String.init) ?? "unknown") episode=\(episodeNumber.map(String.init) ?? "unknown")
        """
    }
}

/// Owned by the authorized TV profile/account scope; never written to disk.
@MainActor @Observable public final class EpisodeRailDiagnosticStore {
    public private(set) var lastSelection: EpisodeRailDiagnostic?
    private var isActive = true
    public init() {}

    public func record(_ selection: EpisodeRailDiagnostic?) {
        guard isActive else { return }
        lastSelection = selection
    }

    public func invalidate() {
        isActive = false
        lastSelection = nil
    }
}
