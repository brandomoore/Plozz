import Foundation
import CoreModels

/// Bounds how many candidates a watched-heavy async hero source (Featured/Random)
/// requests so it can refill after filtering without flooding provider detail work.
public enum HeroCandidatePool {
    /// Keep enough candidates to refill a watched-heavy source while bounding
    /// provider detail work and preserving the exact old request when filtering
    /// is disabled.
    public static func requestLimit(finalLimit: Int, hideWatched: Bool) -> Int {
        guard finalLimit > 0 else { return 0 }
        guard hideWatched else { return finalLimit }
        return min(48, max(12, finalLimit * 2))
    }
}

/// Folds live provider watch history onto hero candidates. Ordinary candidates
/// use identity-index references; discovery-tagged candidates refresh only their
/// already-verified copies, without granting ownership to new index hints.
/// Positive live contradictions revoke a copy's routing proof; unavailable or
/// inconclusive responses preserve its previously verified state.
/// Bounded item-detail fetches supply current profile watch state without allowing
/// multi-server setups to flood networking.
///
/// Pure domain logic: it takes injected `sourceRefs`/`fetch` closures and touches
/// no provider or app-shell types, so it lives beside `HeroCurator` in FeatureHome
/// rather than in the composition root.
public enum HeroCandidateWatchStateEnricher {
    private struct Job: Sendable {
        let itemIndex: Int
        let source: MediaSourceRef
    }

    private struct FetchedState: Sendable {
        let itemIndex: Int
        let source: MediaSourceRef
        let item: MediaItem?
    }

    private struct VerifiedStates {
        var accepted: [FetchedState] = []
        var rejectedSourceIDs: Set<String> = []
    }

    private static let maxConcurrentFetches = 4

    public static func enrich(
        _ items: [MediaItem],
        enabled: Bool = true,
        sourceRefs: @escaping @Sendable (MediaItem) -> [MediaSourceRef],
        fetch: @escaping @Sendable (MediaSourceRef) async -> MediaItem?
    ) async -> [MediaItem] {
        guard enabled else { return items }
        var jobs: [Job] = []
        for (itemIndex, item) in items.enumerated() where !item.hasBeenPlayed {
            var seen = Set<String>()
            let references: [MediaSourceRef]
            if item.discoverySources.isEmpty {
                references = sourceRefs(item)
            } else {
                // Discovery runtime already checked active accounts, library
                // visibility and live identity. A watch refresh cannot widen
                // that proof by consulting the global index again.
                references = item.locallyValidatedPlayableSource
                    ? item.sources.filter { $0.kind == item.kind && !$0.itemID.isEmpty }
                    : []
            }
            for source in references where seen.insert(source.id).inserted {
                jobs.append(Job(itemIndex: itemIndex, source: source))
            }
        }
        guard !jobs.isEmpty else { return items }

        let fetched = await withTaskGroup(
            of: FetchedState.self,
            returning: [[FetchedState]].self
        ) { group in
            let concurrency = min(maxConcurrentFetches, jobs.count)
            var nextJob = 0
            for _ in 0..<concurrency {
                let job = jobs[nextJob]
                nextJob += 1
                group.addTask {
                    FetchedState(
                        itemIndex: job.itemIndex,
                        source: job.source,
                        item: await fetch(job.source)
                    )
                }
            }

            var byItem = Array(repeating: [FetchedState](), count: items.count)
            while let state = await group.next() {
                byItem[state.itemIndex].append(state)
                if nextJob < jobs.count, !Task.isCancelled {
                    let job = jobs[nextJob]
                    nextJob += 1
                    group.addTask {
                        FetchedState(
                            itemIndex: job.itemIndex,
                            source: job.source,
                            item: await fetch(job.source)
                        )
                    }
                }
            }
            return byItem
        }
        guard !Task.isCancelled else { return [] }

        var enriched = items
        for index in enriched.indices where !fetched[index].isEmpty {
            let isDiscovery = !enriched[index].discoverySources.isEmpty
            let verification = isDiscovery
                ? verifiedStates(fetched[index], for: items[index])
                : VerifiedStates(accepted: fetched[index])
            let states = verification.accepted
            guard !states.isEmpty || !verification.rejectedSourceIDs.isEmpty else { continue }
            if !verification.rejectedSourceIDs.isEmpty {
                enriched[index] = removingRejectedSources(
                    from: enriched[index], sourceIDs: verification.rejectedSourceIDs
                )
                guard enriched[index].locallyValidatedPlayableSource else { continue }
            }
            let successful = states.compactMap(\.item)
            if !successful.isEmpty {
                enriched[index].hasBeenPlayed = enriched[index].hasBeenPlayed
                    || successful.contains { $0.hasBeenPlayed || (isDiscovery && $0.isPlayed) }
            }
            var refsByID = Dictionary(
                enriched[index].sources.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for state in states {
                var ref = isDiscovery ? refsByID[state.source.id] ?? state.source : state.source
                if let item = state.item {
                    ref.resumePosition = item.resumePosition
                    ref.playedPercentage = item.playedPercentage
                    ref.isPlayed = item.isPlayed
                    ref.hasBeenPlayed = item.hasBeenPlayed || (isDiscovery && item.isPlayed)
                    ref.isFavorite = item.isFavorite
                    ref.lastPlayedAt = item.lastPlayedAt
                }
                refsByID[ref.id] = ref
            }
            enriched[index].sources = refsByID.values.sorted { $0.id < $1.id }
            if isDiscovery {
                let watchState = MediaItemMerger.unifiedWatchState(from: enriched[index].sources)
                enriched[index].resumePosition = watchState.resumePosition
                enriched[index].playedPercentage = watchState.playedPercentage
                enriched[index].isPlayed = watchState.isPlayed
                enriched[index].hasBeenPlayed = enriched[index].sources.contains {
                    $0.hasBeenPlayed || $0.isPlayed
                }
                enriched[index].lastPlayedAt = watchState.lastPlayedAt
                enriched[index].isFavorite = enriched[index].sources.contains(where: \.isFavorite)
            }
        }
        return enriched
    }

    private static func verifiedStates(
        _ states: [FetchedState],
        for candidate: MediaItem
    ) -> VerifiedStates {
        var result = VerifiedStates()
        // Completion order must not decide which conflicting response contributes
        // history. Keep the same stable source order on every refresh.
        for state in states.sorted(by: { $0.source.id < $1.source.id }) {
            guard let record = state.item else { continue }
            if (!record.id.isEmpty && record.id != state.source.itemID)
                || (record.kind != .unknown && record.kind != candidate.kind)
                || !record.locallyValidatedPlayableSource
                || HeroDiscoveryIdentityVerification.hasConflictingStrongIdentity(candidate, record) {
                result.rejectedSourceIDs.insert(state.source.id)
                continue
            }
            guard record.id == state.source.itemID,
                  HeroDiscoveryIdentityVerification.matches(candidate, record) else { continue }
            if result.accepted.contains(where: {
                guard let other = $0.item else { return false }
                return HeroDiscoveryIdentityVerification.hasConflictingStrongIdentity(other, record)
            }) {
                result.rejectedSourceIDs.insert(state.source.id)
            } else {
                result.accepted.append(state)
            }
        }
        // A sparse response may still positively contradict an ID established by
        // another live copy, even when it cannot prove its own identity.
        let acceptedIDs = Set(result.accepted.map(\.source.id))
        for state in states where !acceptedIDs.contains(state.source.id) {
            if let record = state.item,
               result.accepted.contains(where: {
                   guard let other = $0.item else { return false }
                   return HeroDiscoveryIdentityVerification.hasConflictingStrongIdentity(other, record)
               }) {
                result.rejectedSourceIDs.insert(state.source.id)
            }
        }
        // Unavailable or inconclusive records preserve prior proof, but positive
        // disqualification must revoke routing as well as reject watch updates.
        return result
    }

    private static func removingRejectedSources(
        from candidate: MediaItem,
        sourceIDs: Set<String>
    ) -> MediaItem {
        var item = candidate
        let rejectedAccounts = Set(item.sources.filter { sourceIDs.contains($0.id) }.map(\.accountID))
        item.sources.removeAll { sourceIDs.contains($0.id) }
        guard !item.sources.isEmpty else { return item.removingDiscoveryOwnership() }
        let remainingAccounts = Set(item.sources.map(\.accountID))
        item.sources = item.sources.map { source in
            var retained = source
            // Backing-version links can synthesize a routing ref even after that
            // ref was removed. They must not resurrect a disqualified copy.
            retained.versions.removeAll { version in
                let accountID = version.sourceAccountID ?? source.accountID
                let itemID = version.sourceItemID ?? source.itemID
                return sourceIDs.contains("\(accountID):\(itemID)")
                    || (rejectedAccounts.contains(accountID) && !remainingAccounts.contains(accountID))
            }
            return retained
        }
        let primary = item.sources.first {
            $0.accountID == item.sourceAccountID && $0.itemID == item.id
        }
        if primary == nil, let replacement = item.sources.first {
            // selectingSource intentionally preserves old versions when the new
            // ref is sparse. Clear revoked physical metadata before retargeting.
            item.versions = []
            item.mediaInfo = nil
            item = item.selectingSource(replacement)
            item.libraryID = replacement.libraryID
        } else if let selected = item.selectedSourceAccountID, rejectedAccounts.contains(selected) {
            item.selectedSourceAccountID = nil
            item.explicitSourceSelection = false
        }
        item.selectedVersionID = nil
        item.versions = (primary ?? item.sources.first)?.versions ?? []
        item.additionalSourceAccountIDs = remainingAccounts.filter { $0 != item.sourceAccountID }.sorted()
        return item
    }
}
