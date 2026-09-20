import CoreModels
import CoreNetworking
import CoreSecureStore
import Foundation
import MetadataKit

/// Public discovery is cached upstream. Ownership and watch state are resolved
/// here, per active account/profile, and never written back to that public cache.
public struct HeroDiscoveryRuntime: Sendable {
    private struct LookupKey: Hashable, Sendable {
        let accountID: String
        let itemID: String
    }

    private struct LookupResult: Sendable {
        let key: LookupKey
        let item: MediaItem?
        let failed: Bool
    }

    private let accountsByID: [String: ResolvedAccount]
    private let identitySources: @Sendable (MediaItem) -> [MediaSourceRef]
    private let discovery: HeroDiscoveryContentProviding
    private static let maximumConcurrentLookups = 4

    public init(
        accounts: [ResolvedAccount],
        identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef],
        discovery: HeroDiscoveryContentProviding? = nil
    ) {
        accountsByID = Dictionary(
            accounts.map { ($0.account.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.identitySources = identitySources
        self.discovery = discovery ?? { request, sources in
            await Self.discoverPublicCandidates(request, sources: sources)
        }
    }

    public func candidates(
        _ request: HeroDiscoveryRequest,
        sources: [HeroDiscoverySource],
        hideWatched: Bool,
        visibility: HomeLibraryVisibility = .default
    ) async -> [MediaItem] {
        let enabled = HeroDiscoverySource.normalized(sources)
        guard !Task.isCancelled, request.limit > 0, !enabled.isEmpty else { return [] }
        let fetched = await discovery(request, enabled)
        guard !Task.isCancelled else { return [] }
        let external = Array(fetched.lazy
            .filter { $0.kind == .movie || $0.kind == .series }
            .prefix(request.limit)
            .map(Self.publicCandidate))
        guard !accountsByID.isEmpty else { return external }

        var jobs: [LookupKey] = []
        var scheduled = Set<LookupKey>()
        var indexedLibraries: [LookupKey: Set<String>] = [:]
        let references = external.map { item -> [LookupKey] in
            guard MediaItemIdentity.hasStrongRetargetIdentity(item) else { return [] }
            var seen = Set<LookupKey>()
            return identitySources(item).compactMap { source in
                guard accountsByID[source.accountID] != nil,
                      source.kind == nil || source.kind == item.kind,
                      !source.itemID.isEmpty else { return nil }
                let key = LookupKey(accountID: source.accountID, itemID: source.itemID)
                if let libraryID = source.libraryID {
                    indexedLibraries[key, default: []].insert(libraryID)
                    guard visibility.isEnabled("\(source.accountID):\(libraryID)") else { return nil }
                }
                guard seen.insert(key).inserted else { return nil }
                if scheduled.insert(key).inserted { jobs.append(key) }
                return key
            }
        }
        let resolved = await resolve(jobs)
        guard !Task.isCancelled else { return [] }

        var rejectedIdentity = false
        var result: [MediaItem] = []
        for (index, item) in external.enumerated() {
            guard !Task.isCancelled else { return [] }
            var owned: [MediaItem] = []
            for key in references[index] {
                guard let record = resolved[key], let account = accountsByID[key.accountID] else { continue }
                guard record.id == key.itemID,
                      record.kind == item.kind,
                      record.locallyValidatedPlayableSource,
                      Self.matchesStrongIdentity(item, record),
                      !owned.contains(where: { Self.hasConflictingStrongIdentity($0, record) }) else {
                    rejectedIdentity = true
                    continue
                }
                let library = Self.eligibleLibrary(
                    record, key: key, indexedLibraries: indexedLibraries[key] ?? [],
                    visibility: visibility
                )
                guard library.isEligible else { continue }
                owned.append(Self.verifiedCopy(record, account: account, libraryID: library.id))
            }
            guard !owned.isEmpty else {
                result.append(item)
                continue
            }
            var merged = MediaItemMerger.mergeGroup(owned)
            for copy in owned {
                merged.fillingMissingPresentation(from: copy)
                Self.fillMissingProviderIDs(on: &merged, from: copy)
            }
            merged.fillingMissingPresentation(from: Self.presentationDonor(item, for: merged))
            Self.fillMissingProviderIDs(on: &merged, from: item)
            merged.discoverySources = HeroDiscoverySource.normalized(
                merged.discoverySources + item.discoverySources
            )
            // Filling presentation may copy discovery availability into a nil
            // field. Live library proof, not a global availability flag, owns it.
            merged.availability = nil
            merged.downloadProgress = nil
            merged.locallyValidatedPlayableSource = true
            let state = MediaItemMerger.unifiedWatchState(from: merged.sources)
            merged.resumePosition = state.resumePosition
            merged.playedPercentage = state.playedPercentage
            merged.isPlayed = state.isPlayed
            merged.lastPlayedAt = state.lastPlayedAt
            merged.hasBeenPlayed = owned.contains { $0.hasBeenPlayed || $0.isPlayed }
            if !hideWatched || !merged.hasBeenPlayed { result.append(merged) }
        }
        if rejectedIdentity {
            PlozzLog.app.error("Hero discovery: unverified or conflicting library identity was ignored.")
        }
        return Task.isCancelled ? [] : result
    }

    private func resolve(_ jobs: [LookupKey]) async -> [LookupKey: MediaItem] {
        guard !jobs.isEmpty, !Task.isCancelled else { return [:] }
        let accounts = accountsByID
        return await withTaskGroup(of: LookupResult.self) { group in
            var next = 0
            func enqueue(_ key: LookupKey) {
                guard let provider = accounts[key.accountID]?.provider else { return }
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let item = try await provider.item(id: key.itemID)
                        try Task.checkCancellation()
                        return LookupResult(key: key, item: item, failed: false)
                    } catch {
                        return LookupResult(key: key, item: nil, failed: !Task.isCancelled && !(error is CancellationError))
                    }
                }
            }
            while next < min(Self.maximumConcurrentLookups, jobs.count) {
                enqueue(jobs[next])
                next += 1
            }
            var result: [LookupKey: MediaItem] = [:]
            var hadFailure = false
            while let lookup = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return [:]
                }
                if let item = lookup.item { result[lookup.key] = item }
                hadFailure = hadFailure || lookup.failed
                if next < jobs.count {
                    enqueue(jobs[next])
                    next += 1
                }
            }
            if hadFailure, !Task.isCancelled {
                PlozzLog.app.error("Hero discovery: library verification was unavailable; unverified titles remain external.")
            }
            return result
        }
    }

    private static func publicCandidate(_ item: MediaItem) -> MediaItem {
        var external = item
        external.sourceAccountID = nil
        external.selectedSourceAccountID = nil
        external.explicitSourceSelection = false
        external.artworkSourceAccountIDsByURL = [:]
        external.additionalSourceAccountIDs = []
        external.sources = []
        external.libraryID = nil
        external.mediaInfo = nil
        external.versions = []
        external.selectedVersionID = nil
        external.locallyValidatedPlayableSource = false
        external.availability = .unknown
        external.downloadProgress = nil
        external.isPlayed = false
        external.hasBeenPlayed = false
        external.resumePosition = nil
        external.playedPercentage = nil
        external.lastPlayedAt = nil
        external.isFavorite = false
        external.discoverySources = HeroDiscoverySource.normalized(external.discoverySources)
        return external
    }

    private static func eligibleLibrary(
        _ record: MediaItem,
        key: LookupKey,
        indexedLibraries: Set<String>,
        visibility: HomeLibraryVisibility
    ) -> (isEligible: Bool, id: String?) {
        if let libraryID = record.libraryID {
            return (visibility.isEnabled("\(key.accountID):\(libraryID)"), libraryID)
        }
        // Sparse detail payloads may omit their library. Keep known provenance
        // from the index or this exact copy's self-ref; a foreign copy's visible
        // library must not make a disabled local copy eligible.
        let selfLibraries = record.sources.filter {
            $0.accountID == key.accountID && $0.itemID == key.itemID
                && ($0.kind == nil || $0.kind == record.kind)
        }.compactMap(\.libraryID)
        let known = selfLibraries.isEmpty ? indexedLibraries : Set(selfLibraries)
        guard !known.isEmpty else {
            // An unrestricted account needs no library proof. Once any of its
            // libraries is disabled, unknown provenance cannot safely earn Play.
            let requiresProvenance = visibility.disabledKeys.contains {
                $0.hasPrefix("\(key.accountID):")
            }
            return (!requiresProvenance, nil)
        }
        let eligible = known.sorted().first { visibility.isEnabled("\(key.accountID):\($0)") }
        return (eligible != nil, eligible)
    }

    private static func verifiedCopy(
        _ record: MediaItem, account: ResolvedAccount, libraryID: String?
    ) -> MediaItem {
        var owned = record.taggingSource(account.account.id)
        owned.libraryID = libraryID
        owned.additionalSourceAccountIDs = []
        owned.selectedSourceAccountID = nil
        owned.explicitSourceSelection = false
        owned.selectedVersionID = nil
        owned.availability = nil
        owned.downloadProgress = nil
        owned.hasBeenPlayed = record.hasBeenPlayed || record.isPlayed
        // Neither the index's resume positions nor refs carried by a provider
        // response may import another account/profile's cached watch state.
        owned.sources = [MediaSourceRef(
            accountID: account.account.id,
            itemID: record.id,
            libraryID: owned.libraryID,
            kind: record.kind,
            providerKind: account.provider.kind,
            serverName: account.account.server.name,
            accountName: account.account.userName,
            locality: account.provider.connectionLocality,
            versions: record.versions.isEmpty ? [MediaVersion.synthesized(from: record)] : record.versions,
            resumePosition: record.resumePosition,
            playedPercentage: record.playedPercentage,
            isPlayed: record.isPlayed,
            hasBeenPlayed: owned.hasBeenPlayed,
            isFavorite: record.isFavorite,
            lastPlayedAt: record.lastPlayedAt
        )]
        return owned
    }

    private static func presentationDonor(_ external: MediaItem, for owned: MediaItem) -> MediaItem {
        var donor = external
        let hasServerBackdrop = owned.heroBackdropURL != nil || owned.backdropURL != nil
            || owned.fallbackArtworkURL != nil || owned.artworkSelections.contains {
                ($0.placement == .homeHero || $0.placement == .detailBackdrop) && !$0.references.isEmpty
            }
        // An external heroBackdropURL outranks a server's plain backdropURL in
        // rendering, even though filling the nil field looks like a harmless fill.
        if hasServerBackdrop {
            donor.heroBackdropURL = nil
            donor.backdropURL = nil
            donor.fallbackArtworkURL = nil
        }
        donor.artworkSelections = []
        donor.ratings = donor.ratings.filter { rating in
            !owned.ratings.contains { $0.source == rating.source }
        }
        return donor
    }

    private static func strongIDs(_ item: MediaItem) -> [String: String] {
        Dictionary(MediaItemIdentity.identities(for: item).compactMap { identity in
            guard case let .external(source, value) = identity else { return nil }
            return (source, value)
        }, uniquingKeysWith: { first, _ in first })
    }

    private static func matchesStrongIdentity(_ external: MediaItem, _ record: MediaItem) -> Bool {
        let expected = strongIDs(external)
        let actual = strongIDs(record)
        let shared = Set(expected.keys).intersection(actual.keys)
        // Index membership schedules verification; it is not enough to bless a
        // title-only or sparse live record as a playable copy of this title.
        return !shared.isEmpty && shared.allSatisfy { expected[$0] == actual[$0] }
    }

    private static func hasConflictingStrongIdentity(_ first: MediaItem, _ second: MediaItem) -> Bool {
        let firstIDs = strongIDs(first)
        let secondIDs = strongIDs(second)
        return firstIDs.contains { key, value in
            secondIDs[key].map { $0 != value } ?? false
        }
    }

    private static func fillMissingProviderIDs(on owned: inout MediaItem, from donor: MediaItem) {
        for (key, value) in donor.providerIDs {
            if let namespace = ProviderIDNamespace.allCases.first(where: {
                [key: value].providerID($0) != nil
            }) {
                if owned.providerIDs.providerID(namespace) == nil {
                    owned.providerIDs[namespace.canonicalKey] = value
                }
            } else if !owned.providerIDs.keys.contains(where: {
                $0.caseInsensitiveCompare(key) == .orderedSame
            }) {
                owned.providerIDs[key] = value
            }
        }
    }

    private static func discoverPublicCandidates(
        _ request: HeroDiscoveryRequest, sources: [HeroDiscoverySource]
    ) async -> [MediaItem] {
        await productionCandidates(request, sources: sources, configurationLoader: {
            let config = MetadataProviderConfig.resolved()
            guard sources.contains(.tmdb) else { return config }
            let store = TMDBUserKeyStore(
                secureStore: KeychainStore(service: "com.plozz.app.household")
            )
            return config.withUserToken(store.load())
        }, discover: { request, sources, config in
            await ProductionHeroDiscovery.discover(request, sources: sources, providerConfig: config)
        })
    }

    /// The small seam keeps synchronous secure-store access off MainActor and
    /// lets tests verify that boundary without touching the real Keychain.
    static func productionCandidates(
        _ request: HeroDiscoveryRequest,
        sources: [HeroDiscoverySource],
        configurationLoader: @escaping @Sendable () -> MetadataProviderConfig,
        discover: @escaping @Sendable (HeroDiscoveryRequest, [HeroDiscoverySource], MetadataProviderConfig) async -> [MediaItem]
    ) async -> [MediaItem] {
        guard !Task.isCancelled else { return [] }
        let configTask = Task.detached(priority: .utility) { configurationLoader() }
        return await withTaskCancellationHandler {
            let config = await configTask.value
            guard !Task.isCancelled else { return [] }
            let items = await discover(request, sources, config)
            return Task.isCancelled ? [] : items
        } onCancel: {
            configTask.cancel()
        }
    }
}
