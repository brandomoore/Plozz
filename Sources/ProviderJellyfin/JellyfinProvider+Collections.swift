import CoreModels
import Foundation

extension JellyfinProvider {
    public func collections(in libraryID: String, page: PageRequest) async throws -> MediaPage {
        guard !libraryID.isEmpty, page.startIndex >= 0, page.limit > 0 else {
            throw AppError.invalidResponse
        }
        let key = "\(libraryID)#\(page.sort.field.rawValue)#\(page.sort.direction.rawValue)"
        let snapshot = try await collectionLibraryCache.snapshot(
            key: key, refresh: page.startIndex == 0
        ) {
            try await self.scopedCollectionSnapshot(libraryID: libraryID, sort: page.sort)
        }
        try Task.checkCancellation()
        return MediaPage(
            items: Array(snapshot.dropFirst(page.startIndex).prefix(page.limit)),
            startIndex: page.startIndex, totalCount: snapshot.count
        )
    }

    private func scopedCollectionSnapshot(
        libraryID: String, sort: CoreModels.SortDescriptor
    ) async throws -> [MediaItem] {
        let pageSize = 200
        // A fresh server-side shuffle on every HTTP page cannot be enumerated
        // without omissions/duplicates. Shuffle the completed scoped snapshot.
        let enumerationSort: CoreModels.SortDescriptor = sort.field == .random ? .default : sort
        var candidates: [MediaItem] = []
        var seen = Set<String>()
        var start = 0
        while true {
            try Task.checkCancellation()
            let response = try await client.collectionCandidates(
                userID: session.userID,
                page: PageRequest(startIndex: start, limit: pageSize, sort: enumerationSort)
            )
            guard response.Items.allSatisfy({ $0.Type == "BoxSet" }) else {
                throw AppError.invalidResponse
            }
            let ids = try Self.validatedScopeIDs(response, start: start, seen: &seen)
            candidates.append(contentsOf: response.Items.map(map(item:)))
            start += ids.count
            if ids.isEmpty || response.TotalRecordCount.map({ start >= $0 }) == true { break }
        }
        guard !candidates.isEmpty else { return [] }

        var libraryIDs = Set<String>()
        start = 0
        while true {
            try Task.checkCancellation()
            let response = try await client.collectionScopeItems(
                userID: session.userID, parentID: libraryID, recursive: true,
                start: start, limit: pageSize
            )
            let ids = try Self.validatedScopeIDs(response, start: start, seen: &libraryIDs)
            start += ids.count
            if ids.isEmpty || response.TotalRecordCount.map({ start >= $0 }) == true { break }
        }
        guard !libraryIDs.isEmpty else { return [] }

        // One bounded membership probe per candidate, not per rendered poster.
        // Subsequent grid pages read the account-bound snapshot instead.
        let client = client
        let userID = session.userID
        let libraryMembership = libraryIDs
        let matching = try await withThrowingTaskGroup(of: (Int, Bool).self) { group in
            var nextIndex = min(4, candidates.count)
            for index in 0..<nextIndex {
                let collectionID = candidates[index].id
                group.addTask {
                    (index, try await Self.hasLibraryMember(
                        client: client, userID: userID, collectionID: collectionID,
                        libraryIDs: libraryMembership, pageSize: pageSize
                    ))
                }
            }
            var matches = Set<Int>()
            for try await (index, matchesLibrary) in group {
                if matchesLibrary { matches.insert(index) }
                if nextIndex < candidates.count {
                    let index = nextIndex
                    let collectionID = candidates[index].id
                    nextIndex += 1
                    group.addTask {
                        (index, try await Self.hasLibraryMember(
                            client: client, userID: userID, collectionID: collectionID,
                            libraryIDs: libraryMembership, pageSize: pageSize
                        ))
                    }
                }
            }
            return matches
        }
        var scoped = candidates.enumerated().compactMap { index, item in
            matching.contains(index) ? item.taggingLibrary(libraryID) : nil
        }
        if sort.field == .random { scoped.shuffle() }
        return scoped
    }

    private static func hasLibraryMember(
        client: JellyfinClient, userID: String, collectionID: String,
        libraryIDs: Set<String>, pageSize: Int
    ) async throws -> Bool {
        var seen = Set<String>()
        var start = 0
        while true {
            try Task.checkCancellation()
            let response = try await client.collectionScopeItems(
                userID: userID, parentID: collectionID, recursive: false,
                start: start, limit: pageSize
            )
            let ids = try validatedScopeIDs(response, start: start, seen: &seen)
            if ids.contains(where: libraryIDs.contains) { return true }
            start += ids.count
            if ids.isEmpty || response.TotalRecordCount.map({ start >= $0 }) == true {
                return false
            }
        }
    }

    private static func validatedScopeIDs(
        _ response: ItemsResponse, start: Int, seen: inout Set<String>
    ) throws -> [String] {
        let ids = response.Items.map(\.Id)
        guard response.TotalRecordCount.map({ $0 >= 0 }) != false,
              ids.allSatisfy({ !$0.isEmpty }) else { throw AppError.invalidResponse }
        if ids.isEmpty {
            guard response.TotalRecordCount.map({ start >= $0 }) != false else {
                throw AppError.invalidResponse
            }
        } else {
            guard ids.allSatisfy({ seen.insert($0).inserted }) else {
                throw AppError.invalidResponse
            }
        }
        return ids
    }
}

/// Provider instances bind this cache to one server/user/credential session.
/// Page zero refreshes; later pages share the same complete, ordered snapshot.
actor MediaBrowserCollectionLibraryCache {
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var consumers: [UUID: CheckedContinuation<[MediaItem], Error>]
    }
    private var cached: [String: [MediaItem]] = [:]
    private var recentKeys: [String] = []
    private var flights: [String: Flight] = [:]

    func snapshot(
        key: String,
        refresh: Bool,
        load: @escaping @Sendable () async throws -> [MediaItem]
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
                    refresh: refresh, load: load
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
        load: @escaping @Sendable () async throws -> [MediaItem]
    ) {
        if var flight = flights[key] {
            if !flight.task.isCancelled {
                flight.consumers[consumerID] = continuation
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
                let items = try await load()
                try Task.checkCancellation()
                result = .success(items)
            } catch {
                result = .failure(error)
            }
            completeFlight(id, key: key, result: result)
        }
        flights[key] = Flight(id: id, task: task, consumers: [consumerID: continuation])
    }

    private func cancelConsumer(_ consumerID: UUID, key: String) {
        guard var flight = flights[key],
              let continuation = flight.consumers.removeValue(forKey: consumerID) else { return }
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
