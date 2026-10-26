import Foundation

public enum TrackerHistoryError: Error, Equatable, Sendable {
    case invalidObservation, incompleteSnapshot, invalidSelection, scopeChanged, stalePreview
}

/// List membership is protection evidence, not an individual watch or playback position.
public enum TrackerHistoryListState: String, Codable, CaseIterable, Hashable, Sendable {
    case planning, watching, waiting, paused, dropped, completed
}

/// Read evidence, not an authoritative history store or a request to change a server.
public struct TrackerHistoryObservation: Equatable, Sendable {
    public enum Fact: Encodable, Equatable, Hashable, Sendable {
        case watched(at: Date?)
        case explicitlyUnwatched
        case resume(seconds: TimeInterval, runtime: TimeInterval, updatedAt: Date?)
        case resumePercentage(percent: Double, updatedAt: Date?)
        case explicitlyClearedResume
        case episodeCount(watched: Int, repeats: Int?)
        case animeList(TrackerAnimeListProgress)
        case listState(TrackerHistoryListState)
    }

    public let recordID: String
    public let sourceTitle: String?
    public let kind: MediaItemKind
    public let identities: [MediaIdentity]
    public let season: Int?
    public let episode: Int?
    public let episodeOrdering: EpisodeOrdering?
    public let requiresExactEpisodeIdentity: Bool
    public let fact: Fact

    public init(
        recordID: String, kind: MediaItemKind, identities: [MediaIdentity], sourceTitle: String? = nil,
        season: Int? = nil, episode: Int? = nil, episodeOrdering: EpisodeOrdering? = nil,
        requiresExactEpisodeIdentity: Bool = false, fact: Fact
    ) throws {
        guard !recordID.isEmpty, !identities.isEmpty,
              identities.allSatisfy({
                  if case .external(let source, let value) = $0 { return !source.isEmpty && !value.isEmpty }
                  return false
              }),
              kind == .movie || kind == .episode || kind == .series,
              kind != .episode || (season.map { $0 >= 0 } == true && episode.map { $0 > 0 } == true),
              kind == .episode || (season == nil && episode == nil && !requiresExactEpisodeIdentity) else {
            throw TrackerHistoryError.invalidObservation
        }
        switch fact {
        case .watched(let date):
            guard date.map({ $0.timeIntervalSince1970.isFinite }) ?? true else {
                throw TrackerHistoryError.invalidObservation
            }
        case .resume(let seconds, let runtime, let date):
            guard seconds.isFinite, runtime.isFinite, runtime > 0, seconds > 0, seconds < runtime,
                  date.map({ $0.timeIntervalSince1970.isFinite }) ?? true else {
                throw TrackerHistoryError.invalidObservation
            }
        case .resumePercentage(let percent, let date):
            guard percent.isFinite, (0...100).contains(percent),
                  date.map({ $0.timeIntervalSince1970.isFinite }) ?? true else {
                throw TrackerHistoryError.invalidObservation
            }
        case .episodeCount(let watched, let repeats):
            guard kind == .series, watched >= 0, repeats.map({ $0 >= 0 }) ?? true else {
                throw TrackerHistoryError.invalidObservation
            }
        case .animeList:
            guard kind == .series || kind == .movie else { throw TrackerHistoryError.invalidObservation }
        case .explicitlyUnwatched, .explicitlyClearedResume, .listState: break
        }
        self.recordID = recordID
        self.sourceTitle = sourceTitle
        self.kind = kind
        self.identities = identities
        self.season = season
        self.episode = episode
        self.episodeOrdering = episodeOrdering
        self.requiresExactEpisodeIdentity = requiresExactEpisodeIdentity
        self.fact = fact
    }

    public func matches(_ item: MediaItem) -> Bool {
        Self.matches(
            item, kind: kind, identities: identities, season: season, episode: episode,
            episodeOrdering: episodeOrdering, requiresExactEpisodeIdentity: requiresExactEpisodeIdentity
        )
    }

    public static func matches(
        _ item: MediaItem, kind: MediaItemKind, identities: [MediaIdentity],
        season: Int? = nil, episode: Int? = nil, episodeOrdering: EpisodeOrdering? = nil,
        requiresExactEpisodeIdentity: Bool = false
    ) -> Bool {
        guard item.kind == kind, kind != .episode || (
            item.seasonNumber == season && item.episodeNumber == episode
            && (item.episodeNumberEnd == nil || item.episodeNumberEnd == episode)
        ) else { return false }
        let serverIDs = MediaItemIdentity.identities(for: item)
        guard !Set(identities).isDisjoint(with: serverIDs),
              !MediaItemIdentity.externalIdentitiesConflict(identities, serverIDs) else { return false }
        guard kind == .episode else { return true }
        if requiresExactEpisodeIdentity {
            // Both sides must distinguish the episode ID from the same parent's ID.
            // A server's inherited show IDs are not episode identity evidence.
            return identities.contains { identity in
                guard case .external(let source, let value) = identity,
                      !source.hasPrefix("series-"), serverIDs.contains(identity) else { return false }
                return identities.contains { parent in
                    guard case .external(let parentSource, let parentValue) = parent else { return false }
                    return parentSource == "series-\(source)" && parentValue != value && serverIDs.contains(parent)
                }
            }
        }
        return episodeOrdering != nil && episodeOrdering != .unknown && item.episodeOrdering == episodeOrdering
    }

    public var seriesIdentities: [MediaIdentity] {
        guard kind == .episode, let season, let episode else { return [] }
        let suffix = ":s\(season)e\(episode)"
        return identities.compactMap {
            guard case .external(let source, let value) = $0,
                  source.hasPrefix("series-"), source.hasSuffix(suffix) else { return nil }
            return .external(source: String(source.dropFirst(7).dropLast(suffix.count)), value: value)
        }
    }

    public func matchesHistoryExport(_ item: MediaItem) -> Bool {
        if matches(item) { return true }
        guard kind == .series, item.kind == .episode, case .listState(let state) = fact,
              [.planning, .paused, .dropped].contains(state) else { return false }
        let parentIDs = MediaItemIdentity.seriesIdentities(for: item)
        return !Set(identities).isDisjoint(with: parentIDs)
            && !MediaItemIdentity.externalIdentitiesConflict(identities, parentIDs)
    }
}

public struct TrackerHistorySnapshot: Sendable {
    public enum Completeness: Sendable {
        case apiCount(Int)
        /// Only for endpoints documented to return their whole, unpaginated response.
        case completeResponse
        /// For an adapter that validated every page through the API's explicit
        /// end marker when that API does not provide a reliable total.
        case exhaustedPagination
    }
    public let trackerID: String
    public let connectionID: String
    public let observations: [TrackerHistoryObservation]

    /// The adapter calls this only after all required pages/categories finish.
    /// Expected counts are API counts, never the number of successfully decoded rows.
    public init(
        trackerID: String, connectionID: String, observations: [TrackerHistoryObservation], expectedCount: Int
    ) throws {
        try self.init(
            trackerID: trackerID, connectionID: connectionID, observations: observations,
            completeness: .apiCount(expectedCount)
        )
    }

    public init(
        trackerID: String, connectionID: String, observations: [TrackerHistoryObservation], completeness: Completeness
    ) throws {
        if case .apiCount(let count) = completeness, count != observations.count {
            throw TrackerHistoryError.incompleteSnapshot
        }
        guard !trackerID.isEmpty, !connectionID.isEmpty,
              Set(observations.map(\.recordID)).count == observations.count else {
            throw TrackerHistoryError.incompleteSnapshot
        }
        self.trackerID = trackerID
        self.connectionID = connectionID
        self.observations = observations
    }
}

public struct TrackerServerHistoryCandidate: Sendable {
    public let accountID: String
    public let item: MediaItem
    public let canWriteWatched: Bool
    public let canWriteResume: Bool
    public let isPlaying: Bool

    public init(
        accountID: String, item: MediaItem, canWriteWatched: Bool, canWriteResume: Bool, isPlaying: Bool
    ) {
        self.accountID = accountID
        self.item = item
        self.canWriteWatched = canWriteWatched
        self.canWriteResume = canWriteResume
        self.isPlaying = isPlaying
    }
}

public struct TrackerServerHistoryBaseline: Codable, Equatable, Sendable {
    public let itemID: String
    public let played: Bool
    public let hasBeenPlayed: Bool
    public let resumePosition: TimeInterval?
    public let runtime: TimeInterval?
    public let lastPlayedAt: Date?
    public let identities: [MediaIdentity]

    public init(item: MediaItem) {
        itemID = item.id
        played = item.isPlayed
        hasBeenPlayed = item.hasBeenPlayed
        resumePosition = item.resumePosition
        runtime = item.runtime
        lastPlayedAt = item.lastPlayedAt
        identities = MediaItemIdentity.identities(for: item)
    }
}

public struct TrackerHistoryImportPlan: Sendable {
    public enum Comparison: Equatable, Sendable {
        case ready, alreadyMatches, serverConflict, trackerConflict
        case unmatched, ambiguous, unsupported, playing, incompatibleRuntime
    }
    public enum Change: Equatable, Hashable, Sendable {
        case watched(Bool)
        case resume(TimeInterval)
        public var isDestructive: Bool {
            switch self {
            case .watched(let value): !value
            case .resume(let value): value == 0
            }
        }
    }
    public struct Row: Identifiable, Sendable {
        public let id: UUID
        public var recordIDs: [String]
        public let observation: TrackerHistoryObservation
        public let target: WatchMutationTarget?
        public let title: String?
        public let baseline: TrackerServerHistoryBaseline?
        public let change: Change?
        public var comparison: Comparison
    }

    public let id = UUID()
    public let snapshot: TrackerHistorySnapshot
    public let serverScope: WatchMutationServerScope
    public let rows: [Row]

    public init(
        snapshot: TrackerHistorySnapshot, serverScope: WatchMutationServerScope,
        candidates: [TrackerServerHistoryCandidate]
    ) {
        self.snapshot = snapshot
        self.serverScope = serverScope
        struct CandidateKey: Hashable {
            let kind: MediaItemKind
            let identity: MediaIdentity
        }
        struct ChangeKey: Hashable {
            let target: WatchMutationTarget
            let change: Change
        }
        let permittedAccounts = Set(serverScope.accounts.map(\.accountID))
        var candidatesByIdentity: [CandidateKey: [Int]] = [:]
        for (index, candidate) in candidates.enumerated() where permittedAccounts.contains(candidate.accountID) {
            guard candidate.item.sourceAccountID == nil || candidate.item.sourceAccountID == candidate.accountID else { continue }
            for identity in MediaItemIdentity.identities(for: candidate.item) {
                candidatesByIdentity[CandidateKey(kind: candidate.item.kind, identity: identity), default: []].append(index)
            }
        }
        var result: [Row] = []
        var existingChanges: [ChangeKey: Int] = [:]
        for observation in snapshot.observations {
            let matchingIndices = Set(observation.identities.flatMap {
                candidatesByIdentity[CandidateKey(kind: observation.kind, identity: $0)] ?? []
            })
            let scoped = matchingIndices.sorted().map { candidates[$0] }.filter { observation.matches($0.item) }
            if scoped.isEmpty {
                result.append(Row(
                    id: UUID(), recordIDs: [observation.recordID], observation: observation,
                    target: nil, title: nil, baseline: nil, change: nil, comparison: .unmatched
                ))
                continue
            }
            let accounts = Dictionary(grouping: scoped, by: \.accountID)
            for accountID in accounts.keys.sorted() {
                guard let matches = accounts[accountID], matches.count == 1, let candidate = matches.first else {
                    result.append(Row(
                        id: UUID(), recordIDs: [observation.recordID], observation: observation,
                        target: nil, title: nil, baseline: nil, change: nil, comparison: .ambiguous
                    ))
                    continue
                }
                let target = WatchMutationTarget(
                    accountID: accountID, itemID: candidate.item.id,
                    providerKind: serverScope.accounts.first(where: { $0.accountID == accountID })?.providerKind
                )
                let (change, comparison) = Self.compare(observation, to: candidate)
                if let change, let existing = existingChanges[ChangeKey(target: target, change: change)] {
                    result[existing].recordIDs.append(observation.recordID)
                    continue
                }
                if let change { existingChanges[ChangeKey(target: target, change: change)] = result.count }
                result.append(Row(
                    id: UUID(), recordIDs: [observation.recordID], observation: observation,
                    target: target, title: candidate.item.title, baseline: .init(item: candidate.item),
                    change: change, comparison: comparison
                ))
            }
        }
        let rowsByTarget = Dictionary(grouping: result.indices.filter { result[$0].target != nil }, by: { result[$0].target })
        for indices in rowsByTarget.values {
            if Set(indices.compactMap { result[$0].change }).count > 1 {
                for index in indices where result[index].comparison == .ready || result[index].comparison == .serverConflict {
                    result[index].comparison = .trackerConflict
                }
            }
        }
        rows = result
    }

    private static func compare(
        _ observation: TrackerHistoryObservation, to candidate: TrackerServerHistoryCandidate
    ) -> (Change?, Comparison) {
        let item = candidate.item
        guard item.kind == .movie || item.kind == .episode else { return (nil, .unsupported) }
        guard !candidate.isPlaying else { return (nil, .playing) }
        switch observation.fact {
        case .watched, .animeList:
            if case .animeList(let progress) = observation.fact {
                guard item.kind == .movie, progress.status == .completed else { return (nil, .unsupported) }
            }
            guard candidate.canWriteWatched else { return (nil, .unsupported) }
            if item.isPlayed { return (.watched(true), .alreadyMatches) }
            return (.watched(true), item.hasBeenPlayed || item.lastPlayedAt != nil || (item.resumePosition ?? 0) > 0
                    ? .serverConflict : .ready)
        case .explicitlyUnwatched:
            guard candidate.canWriteWatched else { return (nil, .unsupported) }
            return (.watched(false), item.isPlayed ? .serverConflict : .alreadyMatches)
        case .resume(let seconds, let runtime, _):
            guard candidate.canWriteResume else { return (nil, .unsupported) }
            guard let serverRuntime = item.runtime, serverRuntime.isFinite,
                  abs(serverRuntime - runtime) <= 1, seconds < serverRuntime else { return (nil, .incompatibleRuntime) }
            if let position = item.resumePosition, abs(position - seconds) <= 0.5 {
                return (.resume(seconds), .alreadyMatches)
            }
            return (.resume(seconds), item.isPlayed || item.hasBeenPlayed || (item.resumePosition ?? 0) > 0
                    ? .serverConflict : .ready)
        case .explicitlyClearedResume:
            guard candidate.canWriteResume else { return (nil, .unsupported) }
            return (.resume(0), item.resumePosition == 0 ? .alreadyMatches : .serverConflict)
        case .episodeCount, .listState:
            return (nil, .unsupported)
        case .resumePercentage:
            return (nil, .incompatibleRuntime)
        }
    }

    public func approve(
        rowIDs: Set<UUID>, overridingConflicts: Set<UUID> = [], confirmsDestructiveChanges: Bool = false
    ) throws -> TrackerHistoryImportApproval {
        let selected = rows.filter { rowIDs.contains($0.id) }
        guard !selected.isEmpty, selected.count == rowIDs.count,
              overridingConflicts.isSubset(of: rowIDs),
              selected.allSatisfy({ row in
                  guard let change = row.change, row.target != nil, row.baseline != nil,
                        !change.isDestructive || confirmsDestructiveChanges else { return false }
                  return row.comparison == .ready || (
                    (row.comparison == .serverConflict || row.comparison == .trackerConflict)
                        && overridingConflicts.contains(row.id)
                  )
              }),
              Set(selected.compactMap(\.target)).count == selected.count else {
            throw TrackerHistoryError.invalidSelection
        }
        return TrackerHistoryImportApproval(plan: self, rows: selected)
    }
}

/// Ephemeral approval: never decoded as a grant after relaunch.
public struct TrackerHistoryImportApproval: Sendable {
    public let planID: UUID
    public let trackerID: String
    public let connectionID: String
    public let serverScope: WatchMutationServerScope
    public let rows: [TrackerHistoryImportPlan.Row]

    fileprivate init(plan: TrackerHistoryImportPlan, rows: [TrackerHistoryImportPlan.Row]) {
        planID = plan.id
        trackerID = plan.snapshot.trackerID
        connectionID = plan.snapshot.connectionID
        serverScope = plan.serverScope
        self.rows = rows
    }

    /// Reuse the guarded watch outbox. Imports neither expand their target set
    /// nor construct tracker scrobbles, even when cross-server sync is enabled.
    public func mutations<Owner: AnyObject & Sendable>(
        currentScope: WatchMutationServerScope, currentTrackerID: String, currentConnectionID: String,
        capturedAt: Date = Date(), owner: Owner,
        validate: @escaping @Sendable (
            Owner, WatchMutationServerScope, String, String, TrackerHistoryImportPlan.Row
        ) async -> Bool,
        loadCurrentItem: @escaping @Sendable (
            Owner, any MediaProvider, TrackerHistoryImportPlan.Row
        ) async throws -> MediaItem
    ) throws -> [WatchMutation] {
        guard currentScope == serverScope, currentTrackerID == trackerID, currentConnectionID == connectionID else {
            throw TrackerHistoryError.scopeChanged
        }
        return try rows.map { row in
            guard let target = row.target, let change = row.change else { throw TrackerHistoryError.invalidSelection }
            let identities = row.observation.identities.compactMap { identity -> String? in
                if case .external(let source, let value) = identity { return "\(source.utf8.count):\(source)\(value.utf8.count):\(value)" }
                return nil
            }.sorted().joined()
            let played: Bool?
            let resume: TimeInterval?
            switch change {
            case .watched(let value): played = value; resume = nil
            case .resume(let value): played = nil; resume = value
            }
            return WatchMutation(
                capturedAt: capturedAt, canonicalMediaID: "tracker-import:\(row.observation.kind.rawValue):\(identities)",
                seasonNumber: row.observation.season, episodeNumber: row.observation.episode,
                resumePosition: resume, played: played, targets: [target], kind: row.observation.kind
            )
            .bindingServerScope(serverScope)
            .requiringAuthorization(
                owner: owner,
                sourcePrecondition: { owner, provider, dispatchedTarget in
                    guard dispatchedTarget == target else { throw WatchMutationAuthorizationError.denied }
                    switch change {
                    case .watched:
                        guard provider is any WatchStateProviding || provider is any PlayedStateWriting else {
                            throw WatchMutationAuthorizationError.unsupportedApplier
                        }
                    case .resume:
                        guard provider is any ResumeStateWriting else { throw WatchMutationAuthorizationError.unsupportedApplier }
                    }
                    let current = try await loadCurrentItem(owner, provider, row)
                    guard row.observation.matches(current), TrackerServerHistoryBaseline(item: current) == row.baseline else {
                        throw TrackerHistoryError.stalePreview
                    }
                },
                validator: { owner in await validate(owner, serverScope, trackerID, connectionID, row) }
            )
        }
    }
}
