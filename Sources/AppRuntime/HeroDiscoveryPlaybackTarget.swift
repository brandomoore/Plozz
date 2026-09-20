import CoreModels
import CoreNetworking
import FeatureHomeCore
import Foundation

/// Carries discovery's verified-source boundary across provider play-target
/// resolution. The caller must resolve `resolved` using `selected` and its
/// provider; a sparse episode may rely on that children-request context.
public enum HeroDiscoveryPlaybackTarget {
    /// Keeps the provider hydration hop inside the same verification boundary as
    /// selection and final projection, before any container children are queried.
    public static func resolve(
        original: MediaItem,
        selected: MediaItem,
        provider: any MediaProvider
    ) async -> MediaItem? {
        guard !Task.isCancelled,
              let selection = validatedHydration(selected, original: original, selected: selected)
        else { return nil }
        let response: MediaItem
        do {
            response = try await provider.item(id: selection.id)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return nil }
            PlozzLog.app.error("Hero playback metadata was unavailable; retaining the selected request context.")
            response = selection
        }
        guard !Task.isCancelled,
              let hydrated = validatedHydration(response, original: original, selected: selection),
              var target = await HeroPlayTargetResolver.resolve(item: hydrated, provider: provider),
              !Task.isCancelled else { return nil }
        if target.sourceAccountID == nil, let accountID = hydrated.sourceAccountID {
            target = target.taggingSource(accountID)
        }
        return project(resolved: target, original: original, selected: hydrated)
    }

    public static func validatedHydration(
        _ hydrated: MediaItem,
        original: MediaItem,
        selected: MediaItem
    ) -> MediaItem? {
        if !original.discoverySources.isEmpty {
            guard original.locallyValidatedPlayableSource,
                  selected.locallyValidatedPlayableSource,
                  selected.kind == original.kind,
                  let accountID = selected.sourceAccountID, !accountID.isEmpty,
                  selected.selectedSourceAccountID == nil || selected.selectedSourceAccountID == accountID,
                  hydrated.locallyValidatedPlayableSource,
                  hydrated.id == selected.id, hydrated.kind == selected.kind,
                  hydrated.sourceAccountID == nil || hydrated.sourceAccountID == accountID,
                  hydrated.selectedSourceAccountID == nil || hydrated.selectedSourceAccountID == accountID,
                  !hasConflictingIdentity(original, selected),
                  !hasConflictingIdentity(selected, hydrated),
                  !hasConflictingIdentity(original, hydrated),
                  hasVerifiedSelection(original: original, selected: selected) else {
                PlozzLog.app.error("Hero discovery: contradictory parent metadata rejected before episode resolution.")
                return nil
            }
        }
        if hydrated.sourceAccountID == nil, let accountID = selected.sourceAccountID {
            return hydrated.taggingSource(accountID)
        }
        return hydrated
    }

    private static func hasVerifiedSelection(original: MediaItem, selected: MediaItem) -> Bool {
        guard let accountID = selected.sourceAccountID else { return false }
        let isOriginalCopy = original.sourceAccountID == accountID && original.id == selected.id
        return isOriginalCopy || original.sources.contains {
            $0.accountID == accountID && $0.itemID == selected.id
                && ($0.kind == original.kind || ($0.kind == nil && isOriginalCopy))
        }
    }

    public static func project(
        resolved: MediaItem,
        original: MediaItem,
        selected: MediaItem
    ) -> MediaItem? {
        guard !original.discoverySources.isEmpty else { return resolved }
        guard original.locallyValidatedPlayableSource,
              selected.locallyValidatedPlayableSource,
              selected.kind == original.kind,
              !selected.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let accountID = selected.sourceAccountID,
              !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              selected.selectedSourceAccountID == nil || selected.selectedSourceAccountID == accountID,
              !hasConflictingIdentity(original, selected),
              resolved.locallyValidatedPlayableSource,
              !resolved.isUpcomingUnaired,
              !resolved.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              resolved.sourceAccountID == nil || resolved.sourceAccountID == accountID,
              resolved.selectedSourceAccountID == nil || resolved.selectedSourceAccountID == accountID,
              [.movie, .episode, .video].contains(resolved.kind) else {
            PlozzLog.app.error("Hero discovery: resolved playback target lost its verified source.")
            return nil
        }

        let isOriginalCopy = original.sourceAccountID == accountID && original.id == selected.id
        let verifiedSource = original.sources.first {
            $0.accountID == accountID && $0.itemID == selected.id
                && ($0.kind == original.kind || ($0.kind == nil && isOriginalCopy))
        }
        guard isOriginalCopy || verifiedSource != nil,
              acceptsResolvedIdentity(resolved, original: original, selected: selected) else {
            PlozzLog.app.error("Hero discovery: resolved playback identity could not be verified.")
            return nil
        }

        var target = resolved.taggingSource(accountID)
        target.discoverySources = HeroDiscoverySource.normalized(original.discoverySources)
        target.discoveryURLs = HeroDiscoverySource.validatedURLs(original.discoveryURLs)
        target.selectedSourceAccountID = accountID
        target.explicitSourceSelection = false
        target.additionalSourceAccountIDs = []
        target.availability = nil
        target.downloadProgress = nil
        target.libraryID = resolved.libraryID ?? verifiedSource?.libraryID
            ?? (isOriginalCopy ? original.libraryID : nil)
        // Even a retained version can synthesize a foreign physical source during
        // playback. Only intrinsic versions or exact self-backed versions survive.
        target.versions = resolved.versions.filter {
            ($0.sourceAccountID == nil || $0.sourceAccountID == accountID)
                && ($0.sourceItemID == nil || $0.sourceItemID == resolved.id)
        }
        if let versionID = target.selectedVersionID,
           !target.versions.contains(where: { $0.id == versionID }) {
            target.selectedVersionID = nil
        }
        target.hasBeenPlayed = resolved.hasBeenPlayed || resolved.isPlayed
        target.sources = [MediaSourceRef(
            accountID: accountID,
            itemID: target.id,
            libraryID: target.libraryID,
            kind: target.kind,
            providerKind: verifiedSource?.providerKind,
            serverName: verifiedSource?.serverName,
            accountName: verifiedSource?.accountName,
            locality: verifiedSource?.locality,
            versions: target.versions,
            resumePosition: target.resumePosition,
            playedPercentage: target.playedPercentage,
            isPlayed: target.isPlayed,
            hasBeenPlayed: target.hasBeenPlayed,
            isFavorite: target.isFavorite,
            lastPlayedAt: target.lastPlayedAt
        )]
        return target
    }

    private static func acceptsResolvedIdentity(
        _ resolved: MediaItem, original: MediaItem, selected: MediaItem
    ) -> Bool {
        if resolved.kind == selected.kind {
            guard resolved.id == selected.id,
                  !hasConflictingIdentity(selected, resolved),
                  !hasConflictingIdentity(original, resolved) else { return false }
            if resolved.kind == .episode {
                return agreesIfPresent(selected.seriesID, resolved.seriesID)
                    && agreesIfPresent(selected.seasonID, resolved.seasonID)
            }
            return true
        }
        guard resolved.kind == .episode, resolved.id != selected.id else { return false }
        switch selected.kind {
        case .series:
            // Episode-level catalog IDs need not equal the show's IDs. Physical
            // parent IDs, when supplied, must agree with the verified request.
            return agreesIfPresent(selected.id, resolved.seriesID)
                && !hasConflictingParentIdentity(selected, episode: resolved)
                && !hasConflictingParentIdentity(original, episode: resolved)
        case .season:
            return agreesIfPresent(selected.id, resolved.seasonID)
                && agreesIfPresent(selected.seriesID, resolved.seriesID)
                && !hasConflictingParentIdentity(selected, episode: resolved)
                && !hasConflictingParentIdentity(original, episode: resolved)
        default:
            return false
        }
    }

    private static func hasConflictingParentIdentity(_ selected: MediaItem, episode: MediaItem) -> Bool {
        var expected = episode
        expected.providerIDs = [:]
        expected.providerIDs.mergeSeriesProviderIDs(
            from: selected.providerIDs, promotingBaseIDs: selected.kind == .series
        )
        return hasConflictingIdentity(expected, episode)
    }

    private static func hasConflictingIdentity(_ first: MediaItem, _ second: MediaItem) -> Bool {
        guard first.kind == .episode, second.kind == .episode else {
            return HeroDiscoveryIdentityVerification.hasConflictingStrongIdentity(first, second)
        }
        if let expected = first.seasonNumber, let actual = second.seasonNumber,
           expected != actual { return true }
        if let expected = first.episodeNumber, let actual = second.episodeNumber,
           expected != actual { return true }
        // Physical/request proof already ties these records to one episode.
        // Compare catalog IDs even when a sparse payload omits its slot; the
        // temporary common scope never supplies numbering to the returned item.
        var lhs = first
        var rhs = second
        let season = first.seasonNumber ?? second.seasonNumber ?? 0
        let episode = first.episodeNumber ?? second.episodeNumber ?? 0
        lhs.seasonNumber = season
        rhs.seasonNumber = season
        lhs.episodeNumber = episode
        rhs.episodeNumber = episode
        return HeroDiscoveryIdentityVerification.hasConflictingStrongIdentity(lhs, rhs)
    }

    private static func agreesIfPresent(_ expected: String?, _ actual: String?) -> Bool {
        guard let expected, !expected.isEmpty, let actual, !actual.isEmpty else { return true }
        return expected == actual
    }
}
