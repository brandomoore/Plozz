import CoreModels
import CoreNetworking
import Foundation
import Observation

/// One visible, explicitly approved export. Receipts record delivery, never permission.
@MainActor
@Observable
public final class PublicMetaDBHistoryExportSession {
    public enum Mode: String, Codable, CaseIterable, Sendable { case watched, resume }
    public enum Status: Equatable, Sendable {
        case ready, alreadyMatches, conflict, unsupported, ambiguous, playing, previousAttempt
    }
    public enum Outcome: Sendable { case confirmed, alreadyPresent, unconfirmed }
    public struct Row: Identifiable, Sendable {
        public let id = UUID()
        public let title: String
        public let baseline: TrackerServerHistoryBaseline
        public let content: PublicMetaDB.Content?
        public var exportedWatchDate: Date? { change?.watchedAt }
        public fileprivate(set) var status: Status
        fileprivate let change: Change?
        fileprivate let remote: RemoteState
    }

    fileprivate struct Change: Codable, Equatable, Sendable {
        let mode: Mode
        let content: PublicMetaDB.Content
        let watchedAt: Date?
        let position: Double?
        let runtime: Double?

        var watchDate: PublicMetaDB.WatchDate { watchedAt.map(PublicMetaDB.WatchDate.known) ?? .unknown }
        func resume() throws -> PublicMetaDB.Resume {
            guard mode == .resume, let position, let runtime else { throw PublicMetaDB.Failure.invalidInput }
            return try .init(content: content, positionMilliseconds: position, runtimeMilliseconds: runtime)
        }
    }

    fileprivate struct RemoteState: Equatable, Sendable {
        struct Watch: Equatable, Sendable {
            let id: String
            let date: Date?
            let updated: String?
        }
        struct Resume: Equatable, Sendable {
            let id: String
            let position: Double
            let runtime: Double
            let updated: String?
        }
        var watches: [Watch] = []
        var resumes: [Resume] = []
        var dropped = false

        func matches(_ change: Change) -> Bool {
            switch change.mode {
            case .watched: !watches.isEmpty
            case .resume:
                resumes.count == 1 && resumes[0].position == change.position && resumes[0].runtime == change.runtime
            }
        }
    }

    private struct Receipt: DurableLocalStateValue {
        static let durableLocalStateSchemaID = "com.plozz.publicmetadb-history-export.v1"
        let scope: WatchMutationServerScope
        let accountID: String
        let baseline: TrackerServerHistoryBaseline
        let change: Change
        var confirmed = false
    }

    private struct Delivery {
        let outcome: Outcome
        let acknowledgedUndrop: Bool
    }

    public let source: TrackerServerHistorySource
    public private(set) var rows: [Row] = []
    public private(set) var outcomes: [UUID: Outcome] = [:]
    public private(set) var error: (any Error)?
    public private(set) var isBusy = false
    public private(set) var loadedCount = 0
    public private(set) var hasCompared = false
    private let client: PublicMetaDBClient
    private let connectionID: UUID
    private let store: DurableLocalStateStore
    private let isConnected: @MainActor @Sendable () -> Bool
    private var generation = UUID()
    private var isOpen = true
    private var accountID: String?

    init(
        source: TrackerServerHistorySource, client: PublicMetaDBClient, connectionID: UUID,
        store: DurableLocalStateStore, isConnected: @escaping @MainActor @Sendable () -> Bool
    ) {
        self.source = source
        self.client = client
        self.connectionID = connectionID
        self.store = store
        self.isConnected = isConnected
    }

    public func cancel() {
        isOpen = false
        generation = UUID()
        rows = []
        hasCompared = false
        isBusy = false
    }

    public func resetPreview() {
        guard !isBusy else { return }
        generation = UUID()
        rows = []
        outcomes = [:]
        error = nil
        hasCompared = false
        loadedCount = 0
    }

    private func requireCurrent(_ expected: UUID) throws {
        try source.requireCurrent()
        guard isOpen, generation == expected, isConnected() else { throw TrackerHistoryError.scopeChanged }
    }

    public func compare(accountID: String, library: MediaLibrary, mode: Mode) async {
        guard !isBusy else { return }
        generation = UUID()
        let current = generation
        rows = []
        outcomes = [:]
        error = nil
        loadedCount = 0
        hasCompared = false
        self.accountID = accountID
        isBusy = true
        defer { if generation == current { isBusy = false } }
        do {
            try requireCurrent(current)
            let inventory = try await source.items(accountID: accountID, library: library) { count in
                if self.generation == current { self.loadedCount = count }
            }
            try requireCurrent(current)
            let remote = try await readAllRemote()
            try requireCurrent(current)
            var compared: [Row] = []
            for entry in inventory {
                try requireCurrent(current)
                // Refresh only relevant rows; never manufacture watches from series totals.
                guard mode == .watched ? entry.isPlayed : (entry.resumePosition ?? 0) > 0 else { continue }
                let item = try await source.item(accountID: accountID, itemID: entry.id)
                try requireCurrent(current)
                guard mode == .watched ? item.isPlayed : (item.resumePosition ?? 0) > 0 else {
                    throw TrackerHistoryError.stalePreview
                }
                let content = PublicMetaDB.Content.matching(item)
                let baseline = TrackerServerHistoryBaseline(item: item)
                let change = try Self.change(mode: mode, content: content, baseline: baseline)
                var state = content.flatMap { remote.states[$0] } ?? .init()
                if let content, content.mediaType == .tv { state.dropped = remote.dropped.contains(content.tmdbID) }
                var status: Status = change == nil ? .unsupported : .ready
                if let change {
                    if state.matches(change) {
                        status = .alreadyMatches
                        if var receipt = try store.load(Receipt.self, for: key(change)),
                           receipt.change == change, !receipt.confirmed {
                            receipt.confirmed = true
                            try store.save(receipt, for: key(change))
                        }
                    } else if let receipt = try store.load(Receipt.self, for: key(change)),
                              !receipt.confirmed || receipt.change == change {
                        status = .previousAttempt
                    } else if state.dropped || !state.resumes.isEmpty || (mode == .resume && !state.watches.isEmpty) {
                        status = .conflict
                    }
                    do { try await source.requireNotPlaying(accountID: accountID, itemID: item.id) }
                    catch AppError.conflict { status = .playing }
                }
                try requireCurrent(current)
                compared.append(Row(
                    title: item.title, baseline: baseline, content: content, status: status,
                    change: change, remote: state
                ))
            }
            let duplicates = Dictionary(grouping: compared.compactMap(\.content), by: { $0 })
                .filter { $0.value.count > 1 }
            for index in compared.indices {
                if let content = compared[index].content, duplicates[content] != nil { compared[index].status = .ambiguous }
            }
            try requireCurrent(current)
            rows = compared
            hasCompared = true
        } catch {
            if generation == current {
                self.error = error
                PlozzLog.networking.error("PublicMetaDB history export comparison failed")
            }
        }
    }

    public func apply(rowIDs: Set<UUID>, overridingConflicts: Set<UUID>, confirmed: Bool) async {
        guard !isBusy else { return }
        let current = generation
        error = nil
        isBusy = true
        defer { if generation == current { isBusy = false } }
        do {
            try requireCurrent(current)
            let selected = rows.filter { rowIDs.contains($0.id) }
            guard confirmed, hasCompared, outcomes.isEmpty, let accountID,
                  (1...50).contains(selected.count), selected.count == rowIDs.count,
                  overridingConflicts.isSubset(of: rowIDs),
                  selected.allSatisfy({
                      $0.change != nil && ($0.status == .ready || ($0.status == .conflict && overridingConflicts.contains($0.id)))
                  }) else { throw TrackerHistoryError.invalidSelection }
            for row in selected {
                try await validateSource(row, accountID: accountID, generation: current)
                guard let change = row.change, try await readRemote(change.content) == row.remote else {
                    throw TrackerHistoryError.stalePreview
                }
            }
            var undroppedShows = Set<Int>()
            for row in selected {
                do {
                    var expectedRemote = row.remote
                    if row.change?.mode == .watched, let content = row.content,
                       content.mediaType == .tv, undroppedShows.contains(content.tmdbID) {
                        expectedRemote.dropped = false
                    }
                    let baseline = expectedRemote
                    let delivery = try await client.withMutationTransaction {
                        try await self.deliver(row, expectedRemote: baseline, accountID: accountID, generation: current)
                    }
                    try requireCurrent(current)
                    outcomes[row.id] = delivery.outcome
                    if row.remote.dropped, delivery.acknowledgedUndrop, let content = row.content {
                        undroppedShows.insert(content.tmdbID)
                    }
                } catch {
                    if generation == current { outcomes[row.id] = .unconfirmed }
                    throw error
                }
            }
        } catch {
            if generation == current {
                self.error = error
                PlozzLog.networking.error("PublicMetaDB history export stopped before all selected changes were confirmed")
            }
        }
    }

    private func validateSource(_ row: Row, accountID: String, generation: UUID) async throws {
        try requireCurrent(generation)
        try await source.requireNotPlaying(accountID: accountID, itemID: row.baseline.itemID)
        let item = try await source.item(accountID: accountID, itemID: row.baseline.itemID)
        try requireCurrent(generation)
        guard TrackerServerHistoryBaseline(item: item) == row.baseline,
              PublicMetaDB.Content.matching(item) == row.content else { throw TrackerHistoryError.stalePreview }
        try await source.requireNotPlaying(accountID: accountID, itemID: row.baseline.itemID)
        try requireCurrent(generation)
    }

    private func deliver(_ row: Row, expectedRemote: RemoteState, accountID: String, generation: UUID) async throws -> Delivery {
        try await validateSource(row, accountID: accountID, generation: generation)
        guard let change = row.change, try await readRemote(change.content) == expectedRemote else {
            throw TrackerHistoryError.stalePreview
        }
        try requireCurrent(generation)
        let key = try key(change)
        let previous = try store.load(Receipt.self, for: key)
        if let previous,
           !previous.confirmed || previous.change == change { throw PublicMetaDB.Failure.uncertainWrite }
        var receipt = Receipt(scope: source.scope, accountID: accountID, baseline: row.baseline, change: change)
        try store.save(receipt, for: key)
        let outcome: Delivery
        do {
            outcome = try await PublicMetaDBOperationAuthorization.$current.withValue({ beforeWrite in
                try await self.requireCurrent(generation)
                if beforeWrite {
                    try await self.validateSource(row, accountID: accountID, generation: generation)
                }
            }) {
                try await self.writeAndVerify(change)
            }
        } catch PublicMetaDB.Failure.uncertainWrite {
            throw PublicMetaDB.Failure.uncertainWrite
        } catch {
            // Transport ambiguity and failed readback are always uncertainWrite.
            // A definite refusal/undispatched request can be reconsidered by a new preview.
            if let previous { try store.save(previous, for: key) }
            else { try store.remove(key) }
            throw error
        }
        try requireCurrent(generation)
        receipt.confirmed = true
        try store.save(receipt, for: key)
        return outcome
    }

    private func writeAndVerify(_ change: Change) async throws -> Delivery {
        var returnedWatch: PublicMetaDB.Record<PublicMetaDB.Watch>?
        do {
            switch change.mode {
            case .watched: returnedWatch = try await client.backfillWatch(change.content, at: change.watchDate)
            case .resume: _ = try await client.saveResume(change.resume())
            }
        } catch PublicMetaDB.Failure.uncertainWrite {
            // Independent readback can establish the desired state, not who wrote it.
        }
        do {
            let after = try await readRemote(change.content)
            guard after.matches(change) else { throw PublicMetaDB.Failure.uncertainWrite }
            if change.mode == .watched {
                if let returnedWatch {
                    guard after.watches.contains(where: {
                        $0.id == returnedWatch.id && $0.date == returnedWatch.value.watchedAt
                    }) else { throw PublicMetaDB.Failure.uncertainWrite }
                    return Delivery(
                        outcome: change.watchDate.matches(returnedWatch.value.watchedAt) ? .confirmed : .alreadyPresent,
                        acknowledgedUndrop: change.content.mediaType == .tv && !after.dropped
                    )
                }
                return Delivery(outcome: .alreadyPresent, acknowledgedUndrop: false)
            }
            return Delivery(outcome: .confirmed, acknowledgedUndrop: false)
        } catch {
            throw PublicMetaDB.Failure.uncertainWrite
        }
    }

    private func key(_ change: Change) throws -> DurableLocalStateKey {
        let content = change.content
        return try .init(
            collection: .trackerDeliveryReceipt,
            scope: .source(profileID: source.scope.profileID, sourceID: connectionID.uuidString),
            recordID: "publicmetadb-export:\(change.mode.rawValue):\(content.mediaType.rawValue):\(content.tmdbID):\(content.season ?? -1):\(content.episode ?? -1)"
        )
    }

    private static func change(
        mode: Mode, content: PublicMetaDB.Content?, baseline: TrackerServerHistoryBaseline
    ) throws -> Change? {
        guard let content, content.isPlayable else { return nil }
        switch mode {
        case .watched:
            guard baseline.played, baseline.lastPlayedAt.map({
                $0.timeIntervalSince1970.isFinite && $0 <= Date()
            }) ?? true else { return nil }
            // During a rewatch, lastPlayedAt can describe the unfinished play,
            // not the older completion represented by the watched flag.
            let date = (baseline.resumePosition ?? 0) > 0 ? nil : baseline.lastPlayedAt
            return Change(mode: mode, content: content, watchedAt: date, position: nil, runtime: nil)
        case .resume:
            guard let position = baseline.resumePosition, let runtime = baseline.runtime,
                  position.isFinite, runtime.isFinite, position > 0, runtime > 0, position <= runtime,
                  (position * 1_000).isFinite, (runtime * 1_000).isFinite else { return nil }
            let resume = try PublicMetaDB.Resume(
                content: content, positionMilliseconds: position * 1_000, runtimeMilliseconds: runtime * 1_000
            )
            guard resume.expectedDisposition == .saved else { return nil }
            return Change(
                mode: mode, content: content, watchedAt: nil,
                position: resume.positionMilliseconds, runtime: resume.runtimeMilliseconds
            )
        }
    }

    private func readAllRemote() async throws -> (states: [PublicMetaDB.Content: RemoteState], dropped: Set<Int>) {
        let current = generation
        let watches = try await client.completeHistory()
        try requireCurrent(current)
        let resumes = try await client.completeResumePoints()
        try requireCurrent(current)
        let dropped = try await readDropped()
        try requireCurrent(current)
        var result: [PublicMetaDB.Content: RemoteState] = [:]
        for record in watches {
            result[record.value.content, default: .init()].watches.append(
                .init(id: record.id, date: record.value.watchedAt, updated: record.updated)
            )
        }
        for record in resumes {
            result[record.value.content, default: .init()].resumes.append(
                .init(id: record.id, position: record.value.positionMilliseconds,
                      runtime: record.value.runtimeMilliseconds, updated: record.updated)
            )
        }
        for content in result.keys {
            result[content]?.watches.sort { $0.id < $1.id }
            guard result[content]?.resumes.count ?? 0 <= 1 else { throw PublicMetaDB.Failure.incompleteResponse }
        }
        return (result, dropped)
    }

    private func readDropped() async throws -> Set<Int> {
        let records = try await client.completePages(maximumPages: 100) {
            try await self.client.dropped(page: $0, perPage: 500)
        }
        guard records.allSatisfy({ $0.value.mediaType == .tv && $0.value.season == nil && $0.value.episode == nil }),
              Set(records.map(\.value.tmdbID)).count == records.count else { throw PublicMetaDB.Failure.incompleteResponse }
        return Set(records.map(\.value.tmdbID))
    }

    private func readRemote(_ content: PublicMetaDB.Content) async throws -> RemoteState {
        let watches = try await client.completePages(maximumPages: 100) {
            try await self.client.history(content: content, page: $0, perPage: 500)
        }
        let resumes = try await client.completePages(maximumPages: 100) {
            try await self.client.resumePoints(content: content, page: $0, perPage: 500)
        }
        guard watches.allSatisfy({ $0.value.content == content }),
              resumes.count <= 1, resumes.allSatisfy({ $0.value.content == content }) else {
            throw PublicMetaDB.Failure.incompleteResponse
        }
        var result = RemoteState(
            watches: watches.map { .init(id: $0.id, date: $0.value.watchedAt, updated: $0.updated) }.sorted { $0.id < $1.id },
            resumes: resumes.map {
                .init(id: $0.id, position: $0.value.positionMilliseconds, runtime: $0.value.runtimeMilliseconds, updated: $0.updated)
            }
        )
        if content.mediaType == .tv { result.dropped = try await readDropped().contains(content.tmdbID) }
        return result
    }
}
