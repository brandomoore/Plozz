import CoreModels
import CoreNetworking
import Foundation

extension JellyfinProvider {
    var collectionDirectoryID: String { "\(kind.rawValue):collections" }

    func collectionDirectoryHasItems(in libraryID: String) async throws -> Bool {
        let response = try await client.collectionDirectoryHasItems(
            userID: session.userID, libraryID: libraryID == collectionDirectoryID ? nil : libraryID
        )
        try Task.checkCancellation()
        var seen = Set<String>()
        let ids = try Self.validatedScopeIDs(response, stage: .collectionCandidates, start: 0, seen: &seen)
        return !ids.isEmpty
    }

    public func collections(in libraryID: String, page: PageRequest) async throws -> MediaPage {
        guard !libraryID.isEmpty, page.startIndex >= 0, page.limit > 0 else {
            throw AppError.invalidResponse
        }
        let key = "\(libraryID)#\(page.sort.field.rawValue)#\(page.sort.direction.rawValue)"
        let snapshot = try await collectionLibraryCache.snapshot(
            key: key, refresh: page.startIndex == 0
        ) {
            try await self.collectionSnapshot(libraryID: libraryID, sort: page.sort)
        }
        try Task.checkCancellation()
        return MediaPage(
            items: Array(snapshot.dropFirst(page.startIndex).prefix(page.limit)),
            startIndex: page.startIndex, totalCount: snapshot.count
        )
    }

    private func collectionSnapshot(
        libraryID: String, sort: CoreModels.SortDescriptor
    ) async throws -> [MediaItem] {
        let pageSize = 500
        // A fresh server-side shuffle on every HTTP page cannot be enumerated
        // without omissions/duplicates. Shuffle the complete list once.
        let enumerationSort: CoreModels.SortDescriptor = sort.field == .random ? .default : sort
        var candidates: [MediaItem] = []
        var seen = Set<String>()
        var start = 0
        while true {
            try Task.checkCancellation()
            let response = try await client.collectionCandidates(
                userID: session.userID, libraryID: libraryID == collectionDirectoryID ? nil : libraryID,
                page: PageRequest(startIndex: start, limit: pageSize, sort: enumerationSort)
            )
            let ids = try Self.validatedScopeIDs(response, stage: .collectionCandidates, start: start, seen: &seen)
            let additions = Set(ids)
            candidates.append(contentsOf: response.Items.filter { additions.contains($0.Id) }
                .map { map(item: $0).taggingLibrary(libraryID) })
            start += response.Items.count
            if response.Items.isEmpty || (!ids.isEmpty && response.TotalRecordCount.map({ start >= $0 }) == true) { break }
        }
        if sort.field == .random { candidates.shuffle() }
        return candidates
    }

    private static func validatedScopeIDs(
        _ response: ItemsResponse, stage: LibraryPagingDiagnostic.Stage, start: Int, seen: inout Set<String>
    ) throws -> [String] {
        func invalid(_ reason: LibraryPagingDiagnostic.Reason) -> AppError {
            HTTPResponseDiagnostics.recordPagingFailure(.init(
                stage: stage, reason: reason, start: start,
                rows: response.Items.count, total: response.TotalRecordCount
            ))
            return .invalidResponse
        }
        let ids = response.Items.map(\.Id)
        guard response.TotalRecordCount.map({ $0 >= 0 }) != false else { throw invalid(.negativeTotal) }
        guard ids.allSatisfy({ !$0.isEmpty }) else { throw invalid(.emptyID) }
        guard Set(ids).count == ids.count else { throw invalid(.duplicateInPage) }
        if stage == .collectionCandidates, !response.Items.allSatisfy({ $0.Type == "BoxSet" }) {
            throw invalid(.unexpectedItemType)
        }
        if ids.isEmpty {
            guard response.TotalRecordCount.map({ start >= $0 }) != false else {
                throw invalid(.emptyBeforeTotal)
            }
            return []
        }
        if response.TotalRecordCount.map({ start >= $0 }) == true { throw invalid(.itemsPastEnd) }
        // A short server page can overlap the next page's prefix.
        let additions = Array(ids.drop(while: { seen.contains($0) }))
        if additions.isEmpty, let total = response.TotalRecordCount,
           start < total, ids.count == total - start {
            // A sparse final page can contain only the previous page's tail.
            // The caller must confirm the end with one more request, not stop here.
            return []
        }
        guard !additions.isEmpty else { throw invalid(.nonAdvancing) }
        guard additions.allSatisfy({ !seen.contains($0) }) else { throw invalid(.nonPrefixOverlap) }
        seen.formUnion(additions)
        return additions
    }
}

/// Provider instances bind this cache to one server/user/credential session.
/// Page zero refreshes; later pages share the same complete, ordered snapshot.
actor MediaBrowserCollectionLibraryCache {
    typealias Progress = @Sendable (LibraryCollectionProgress) async -> Void
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var consumers: [UUID: CheckedContinuation<[MediaItem], Error>]
        var observers: [UUID: Progress]
    }
    private var cached: [String: [MediaItem]] = [:]
    private var recentKeys: [String] = []
    private var flights: [String: Flight] = [:]

    func snapshot(
        key: String,
        refresh: Bool,
        load: @escaping @Sendable () async throws -> [MediaItem]
    ) async throws -> [MediaItem] {
        try await snapshot(key: key, refresh: refresh, progress: nil) { _ in try await load() }
    }

    func snapshot(
        key: String,
        refresh: Bool,
        progress: Progress?,
        load: @escaping @Sendable (@escaping Progress) async throws -> [MediaItem]
    ) async throws -> [MediaItem] {
        try Task.checkCancellation()
        let consumerID = UUID()
        return try await withTaskCancellationHandler {
            let result = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<[MediaItem], Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                register(
                    continuation, consumerID: consumerID, key: key,
                    refresh: refresh, progress: progress, load: load
                )
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            Task { await self.cancelConsumer(consumerID, key: key) }
        }
    }

    func activeConsumerCount(for key: String) -> Int {
        flights[key]?.consumers.count ?? 0
    }

    private func register(
        _ continuation: CheckedContinuation<[MediaItem], Error>,
        consumerID: UUID,
        key: String,
        refresh: Bool,
        progress: Progress?,
        load: @escaping @Sendable (@escaping Progress) async throws -> [MediaItem]
    ) {
        if var flight = flights[key] {
            if !flight.task.isCancelled {
                flight.consumers[consumerID] = continuation
                flight.observers[consumerID] = progress
                flights[key] = flight
                return
            }
            flights[key] = nil
            for consumer in flight.consumers.values {
                consumer.resume(throwing: CancellationError())
            }
        }
        if !refresh, let items = cached[key] {
            continuation.resume(returning: items)
            return
        }
        let id = UUID()
        let task = Task {
            let result: Result<[MediaItem], Error>
            do {
                let items = try await load { update in
                    await self.publish(update, flightID: id, key: key)
                }
                try Task.checkCancellation()
                result = .success(items)
            } catch {
                result = .failure(error)
            }
            completeFlight(id, key: key, result: result)
        }
        flights[key] = Flight(
            id: id, task: task, consumers: [consumerID: continuation],
            observers: progress.map { [consumerID: $0] } ?? [:]
        )
    }

    private func publish(_ update: LibraryCollectionProgress, flightID: UUID, key: String) async {
        guard let flight = flights[key], flight.id == flightID else { return }
        for consumerID in flight.observers.keys {
            guard let current = flights[key], current.id == flightID, !current.task.isCancelled else { return }
            if let observer = current.observers[consumerID] { await observer(update) }
        }
    }

    private func cancelConsumer(_ consumerID: UUID, key: String) {
        guard var flight = flights[key],
              let continuation = flight.consumers.removeValue(forKey: consumerID) else { return }
        flight.observers[consumerID] = nil
        if flight.consumers.isEmpty {
            // Detach before cancelling so a newcomer cannot join doomed work.
            flights[key] = nil
            flight.task.cancel()
        } else {
            flights[key] = flight
        }
        continuation.resume(throwing: CancellationError())
    }

    private func completeFlight(
        _ id: UUID, key: String, result: Result<[MediaItem], Error>
    ) {
        guard let flight = flights[key], flight.id == id else { return }
        flights[key] = nil
        switch result {
        case let .success(items):
            cached[key] = items
            recentKeys.removeAll { $0 == key }
            recentKeys.append(key)
            while recentKeys.count > 4 {
                cached.removeValue(forKey: recentKeys.removeFirst())
            }
        case .failure:
            cached[key] = nil
        }
        for consumer in flight.consumers.values {
            consumer.resume(with: result)
        }
    }
}
