import CoreModels
import Foundation

/// Playback/root hydration follows routing changes even when a pinned catalog
/// presentation keeps its display id. Status, artwork and copy are not inputs.
public struct HeroPlaybackResolutionKey: Equatable, Sendable {
    private let id: String
    private let kind: MediaItemKind
    private let providerIDs: [String: String]
    private let sourceAccountID: String?
    private let selectedSourceAccountID: String?
    private let explicitSourceSelection: Bool
    private let selectedVersionID: String?
    private let versions: [MediaVersion]
    private let sources: [MediaSourceRef]
    private let seriesID: String?
    private let resumePosition: TimeInterval?
    private let isPlayed: Bool
    private let hasBeenPlayed: Bool
    private let lastPlayedAt: Date?
    private let isDiscovery: Bool
    private let hasValidatedSource: Bool
    private let scopeID: ObjectIdentifier?
    private let identityIndexRevision: Int

    public init(item: MediaItem, scopeID: ObjectIdentifier?, identityIndexRevision: Int) {
        id = item.id
        kind = item.kind
        providerIDs = item.providerIDs
        sourceAccountID = item.sourceAccountID
        selectedSourceAccountID = item.selectedSourceAccountID
        explicitSourceSelection = item.explicitSourceSelection
        selectedVersionID = item.selectedVersionID
        versions = item.versions
        sources = item.sources
        seriesID = item.seriesID
        resumePosition = item.resumePosition
        isPlayed = item.isPlayed
        hasBeenPlayed = item.hasBeenPlayed
        lastPlayedAt = item.lastPlayedAt
        isDiscovery = !item.discoverySources.isEmpty
        hasValidatedSource = item.locallyValidatedPlayableSource
        self.scopeID = scopeID
        self.identityIndexRevision = identityIndexRevision
    }
}

public struct HeroResolutionCacheEntry: Sendable {
    private let key: HeroPlaybackResolutionKey
    private let item: MediaItem

    public init(key: HeroPlaybackResolutionKey, item: MediaItem) {
        self.key = key
        self.item = item
    }

    public func value(for key: HeroPlaybackResolutionKey) -> MediaItem? {
        self.key == key ? item : nil
    }
}

/// Content-loading identity, independent of carousel presentation preferences.
public struct HeroCurationLoadKey: Equatable, Sendable {
    private let continueWatching: [MediaItem]
    private let watchlist: [MediaItem]
    private let recentlyAdded: [MediaItem]
    private let libraries: [AggregatedLibrary]
    private let configuration: HeroConfigurationKey
    private let visibility: HomeLibraryVisibility
    private let freshnessRevision: Int
    private let identityIndexRevision: Int
    private let watchlistMembershipRevision: Int
    private let scopeID: ObjectIdentifier
    private let seerRevision: UUID
    private let discoverySeeds: [HeroDiscoveryRequest.SeedIdentity]

    public init(
        content: HomeViewModel.Content,
        settings: HeroSettings,
        visibility: HomeLibraryVisibility,
        freshnessRevision: Int,
        identityIndexRevision: Int,
        watchlistMembershipRevision: Int = 0,
        scopeID: ObjectIdentifier,
        seerRevision: UUID
    ) {
        continueWatching = settings.isEnabled(.continueWatching) ? content.continueWatching : []
        watchlist = settings.isEnabled(.watchlist) ? content.watchlist : []
        recentlyAdded = settings.isEnabled(.recentlyAdded) ? content.latest : []
        libraries = settings.isEnabled(.randomFromLibrary) ? content.libraries : []
        configuration = HeroConfigurationKey(settings: settings)
        self.visibility = visibility
        self.freshnessRevision = freshnessRevision
        self.identityIndexRevision = settings.isActive && settings.isEnabled(.featured)
            && !settings.discoverySources.isEmpty ? identityIndexRevision : 0
        self.watchlistMembershipRevision = settings.isActive && settings.isEnabled(.watchlist)
            ? watchlistMembershipRevision : 0
        self.scopeID = scopeID
        self.seerRevision = seerRevision
        discoverySeeds = settings.usesDiscoveryWatchlistSeeds
            ? HeroDiscoveryRequest(seeds: content.watchlist).seedIdentities : []
    }
}

/// Restarts optional status work when published titles or request scope change,
/// never when a response merely changes availability or download progress.
public struct HeroStatusRefreshKey: Equatable, Sendable {
    public let isActive: Bool
    private let configuration: HeroConfigurationKey
    private let contextID: String
    private let scopeID: ObjectIdentifier
    private let candidates: [Candidate]

    private struct Candidate: Equatable, Sendable {
        let id: String
        let kind: MediaItemKind
        let tmdbID: String?
    }

    public init(
        requestableItems: [MediaItem],
        settings: HeroSettings?,
        isConfigured: Bool,
        contextID: String,
        scopeID: ObjectIdentifier
    ) {
        configuration = HeroConfigurationKey(settings: settings)
        self.contextID = contextID
        self.scopeID = scopeID
        let enabled = isConfigured && settings?.isActive == true && settings?.isEnabled(.featured) == true
        candidates = enabled ? requestableItems.prefix(HeroSettings.maxItemsRange.upperBound).map {
            Candidate(id: $0.id, kind: $0.kind, tmdbID: $0.providerIDs.providerID(.tmdb))
        } : []
        isActive = enabled && !candidates.isEmpty
    }
}
