import Foundation
import CoreModels

/// Platform-neutral detail-page server and media-version selection.
public enum DetailPlaybackSelection {
    public static func showsPlayPlaceholder(
        for item: MediaItem,
        hasPlayTarget: Bool,
        childrenLoaded: Bool,
        seasonLoadState: SeasonLoadState?
    ) -> Bool {
        guard !hasPlayTarget,
              item.kind == .series || item.kind == .season,
              item.hasPlayableLibraryTarget() else { return false }
        if !childrenLoaded { return true }
        if case .notLoaded? = seasonLoadState { return true }
        return false
    }

    public static func resumeItem(for item: MediaItem, in continueWatching: [MediaItem]) -> MediaItem? {
        guard let account = item.sourceAccountID else { return nil }
        return continueWatching.first { candidate in
            guard candidate.sourceAccountID == account,
                  candidate.locallyValidatedPlayableSource else { return false }
            if item.kind == .series {
                return candidate.kind == .episode && candidate.seriesID == item.id
            }
            return candidate.kind == item.kind && candidate.id == item.id
        }
    }

    public static func applyingResumeItem(_ resume: MediaItem?, to item: MediaItem) -> MediaItem {
        guard let resume,
              resume.id == item.id,
              resume.kind == item.kind,
              resume.sourceAccountID == item.sourceAccountID else { return item }
        var copy = item
        copy.resumePosition = resume.resumePosition
        copy.playedPercentage = resume.playedPercentage
        copy.isPlayed = resume.isPlayed
        copy.hasBeenPlayed = resume.hasBeenPlayed
        copy.lastPlayedAt = resume.lastPlayedAt
        if copy.runtime == nil { copy.runtime = resume.runtime }
        return copy
    }

    public static func serverChoices(from sources: [MediaSourceRef]) -> [MediaSourceRef] {
        var seen = Set<String>()
        return sources.filter { seen.insert($0.accountID).inserted }
    }

    public static func preferredSource(
        sourceOverride: String?,
        libraryOrigin: String?,
        itemSourceAccountID: String?,
        sources: [MediaSourceRef],
        capabilities: MediaCapabilities,
        openingSource: MediaItemSourceIdentity? = nil
    ) -> MediaSourceRef? {
        let choices = serverChoices(from: sources)
        guard choices.count > 1 || sources.count > 1 else { return nil }
        if let sourceOverride,
           let match = choices.first(where: { $0.accountID == sourceOverride }) {
            return match
        }
        if let openingSource,
           let match = sources.first(where: {
               $0.accountID == openingSource.accountID && $0.itemID == openingSource.itemID
           }) {
            return match
        }
        if let libraryOrigin,
           let match = choices.first(where: { $0.accountID == libraryOrigin }) {
            return match
        }
        return CrossSourceSelector.bestSelection(
            from: choices,
            capabilities: capabilities,
            preferring: itemSourceAccountID
        )?.source ?? choices.first ?? sources.first
    }

    public static func versions(
        for item: MediaItem,
        sources: [MediaSourceRef],
        activeAccountID: String?
    ) -> [MediaVersion] {
        guard let activeAccountID else {
            return item.versions.sortedForPicker()
        }
        let active = sources.filter {
            $0.accountID == activeAccountID && ($0.kind == nil || $0.kind == item.kind)
        }
        guard !active.isEmpty else {
            return item.versions.sortedForPicker()
        }
        let versions = active.flatMap { source -> [MediaVersion] in
            guard source.versions.isEmpty,
                  source.itemID == item.id, source.accountID == item.sourceAccountID else {
                return source.selectableVersions
            }
            let own = item.versions.isEmpty ? [MediaVersion.synthesized(from: item)] : item.versions
            return own.map {
                $0.qualified(accountID: source.accountID, itemID: source.itemID, edition: item.edition)
            }
        }
        return versions.isEmpty ? item.versions.sortedForPicker() : versions.sortedForPicker()
    }

    public static func preferredVersionID(
        for item: MediaItem,
        versions: [MediaVersion],
        versionOverride: String?,
        preferences: any VersionPreferenceStoring,
        capabilities: MediaCapabilities
    ) -> String? {
        guard versions.count > 1 else { return nil }
        if let versionOverride, let selected = matchingVersion(versionOverride, in: versions, for: item) {
            return selected.id
        }
        if let selectedID = item.selectedVersionID,
           let selected = matchingVersion(selectedID, in: versions, for: item) {
            return selected.id
        }
        let candidates: [MediaVersion]
        if let opening = item.editionOpeningSource {
            let editionVersions = versions.filter { version in
                if let account = version.sourceAccountID, let id = version.sourceItemID {
                    return account == opening.accountID && id == opening.itemID
                }
                return opening.matches(item)
            }
            candidates = editionVersions.isEmpty ? versions : editionVersions
        } else {
            candidates = versions
        }
        let key = versionPreferenceKey(for: item)
        // An exact file id, but ONLY for a title whose key is its own — a movie
        // you return to, where that id IS the choice.
        //
        // Deliberately skipped for an episode. Its key is the SERIES', so the id
        // stored there is one episode's file: replaying that episode matched the
        // id and returned it, while every other episode fell through to the shape
        // below. One episode played the old pick forever and the rest played the
        // remembered kind — the same show behaving two different ways depending
        // on which episode you happened to have chosen from.
        //
        // A file id cannot express "play this show like that", so for a series it
        // is not consulted at all; the descriptor is the only honest answer.
        if item.seriesID == nil {
            let remembered = preferences.preferredVersionID(forTitle: key)
            if let remembered, let selected = matchingVersion(remembered, in: candidates, for: item) {
                return selected.id
            }
        }
        // Otherwise the remembered SHAPE. This is what carries a choice across a
        // series: every episode's files have their own provider ids, so the id
        // above can never match another episode — only "2160p Dolby Vision
        // Bluray" can. Falls through when nothing is close enough, because
        // forcing a bad match is worse than the device-recommended pick.
        // Legacy unqualified ids cannot prove ownership across servers that reuse
        // numeric ids. Their portable descriptors remain useful during migration.
        let descriptor = preferences.preferredVersionDescriptor(forTitle: key)
            ?? preferences.preferredVersionDescriptor(forTitle: item.seriesID ?? item.id)
        if let descriptor,
           let match = candidates.bestMatch(for: descriptor) {
            return match.id
        }
        return candidates.recommendedSelection(for: capabilities)?.id
    }

    /// The item as it should actually be played: the show's remembered version
    /// resolved against THIS item's own files.
    ///
    /// Exists so version resolution can be applied by construction rather than by
    /// remembering. `preferredVersionID` was already shared, but every play path
    /// had to opt in by calling it — and four of them didn't: the tvOS and iOS
    /// episode auto-advance, and both platforms' Continue Watching rows. Each
    /// handed the player an item straight from the provider, so it played the
    /// server default however deliberately the viewer had chosen otherwise, and
    /// the bug had to be found once per path.
    ///
    /// A no-op when the item already carries an explicit choice, or has nothing
    /// to choose between.
    public static func playbackReady(
        _ item: MediaItem,
        preferences: any VersionPreferenceStoring,
        capabilities: MediaCapabilities
    ) -> MediaItem {
        guard item.selectedVersionID == nil, item.versions.count > 1 else { return item }
        guard let id = preferredVersionID(
            for: item,
            versions: item.versions,
            versionOverride: nil,
            preferences: preferences,
            capabilities: capabilities
        ) else { return item }
        return item.selectingVersion(id)
    }

    public static func versionPreferenceKey(for item: MediaItem) -> String {
        let title = item.seriesID ?? item.id
        guard let account = item.sourceAccountID else { return title }
        return "account:\(Data(account.utf8).base64EncodedString()):\(Data(title.utf8).base64EncodedString())"
    }

    private static func matchingVersion(
        _ id: String,
        in versions: [MediaVersion],
        for item: MediaItem
    ) -> MediaVersion? {
        if let exact = versions.first(where: { $0.id == id }) { return exact }
        let matches = versions.filter { version in
            if version.playbackMediaSourceID == id
                || (version.playbackMediaSourceID == nil
                    && version.sourceItemID.map { "synth:\($0)" } == id) {
                return true
            }
            // Reconstruct the qualified identity from proven ownership rather
            // than stripping a saved token down to a potentially colliding id.
            guard let account = version.sourceAccountID ?? item.sourceAccountID else { return false }
            return version.qualified(
                accountID: account,
                itemID: version.sourceItemID ?? item.id
            ).id == id
        }
        return matches.count == 1 ? matches.first : nil
    }

    public static func playItem(
        for item: MediaItem,
        sources: [MediaSourceRef],
        activeAccountID: String?,
        versionID: String?,
        explicit: Bool
    ) -> MediaItem {
        MediaItem.retargetedForPlayback(
            item: item,
            sources: sources,
            activeAccountID: activeAccountID,
            versionID: versionID,
            explicit: explicit
        )
    }
}

public func preferredDetailSource(
    sourceOverride: String?,
    libraryOrigin: String?,
    itemSourceAccountID: String?,
    sources: [MediaSourceRef],
    serverChoices: [MediaSourceRef],
    capabilities: MediaCapabilities
) -> MediaSourceRef? {
    DetailPlaybackSelection.preferredSource(
        sourceOverride: sourceOverride,
        libraryOrigin: libraryOrigin,
        itemSourceAccountID: itemSourceAccountID,
        sources: sources.isEmpty ? serverChoices : sources,
        capabilities: capabilities
    )
}
