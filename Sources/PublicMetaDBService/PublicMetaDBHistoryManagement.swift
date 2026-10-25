import CoreModels
import CoreNetworking
import Foundation

public extension PublicMetaDB {
    struct HistoryDeletionFailure: Error, Sendable {
        public let confirmedIDs: [String]
        public let stoppedRecordID: String
        public let remainingIDs: [String]
        public let cause: any Error
    }
}

public extension PublicMetaDBService {
    /// Stops on the first unconfirmed result. Never replaces exact IDs with a title-wide reset.
    func deleteHistoryPlays(
        _ records: [PublicMetaDB.Record<PublicMetaDB.Watch>], expectedConnectionID: UUID
    ) async throws {
        guard (1...50).contains(records.count), Set(records.map(\.id)).count == records.count else {
            throw PublicMetaDB.Failure.invalidInput
        }
        let client = try confirmedClient(expectedConnectionID)
        for content in Set(records.map(\.value.content)) {
            let current = try await historyRecords(content, client: client)
            _ = try confirmedClient(expectedConnectionID)
            for record in records where record.value.content == content {
                try requireUnchangedPlay(record, in: current)
            }
        }
        var confirmed: [String] = []
        for (index, record) in records.enumerated() {
            do {
                try await deleteHistoryPlay(record, expectedConnectionID: expectedConnectionID)
                confirmed.append(record.id)
            } catch {
                PlozzLog.networking.error("PublicMetaDB multiple-play deletion stopped confirmed=\(confirmed.count)")
                throw PublicMetaDB.HistoryDeletionFailure(
                    confirmedIDs: confirmed, stoppedRecordID: record.id,
                    remainingIDs: records.dropFirst(index + 1).map(\.id), cause: error
                )
            }
        }
    }

    func addHistoryPlay(
        _ content: PublicMetaDB.Content, at date: PublicMetaDB.WatchDate, expectedConnectionID: UUID
    ) async throws {
        try await confirmedClient(expectedConnectionID).withMutationTransaction {
            try await self.addHistoryPlayLocked(content, at: date, expectedConnectionID: expectedConnectionID)
        }
    }

    private func addHistoryPlayLocked(
        _ content: PublicMetaDB.Content, at date: PublicMetaDB.WatchDate, expectedConnectionID: UUID
    ) async throws {
        guard content.isPlayable, date != .now else { throw PublicMetaDB.Failure.invalidInput }
        let client = try confirmedClient(expectedConnectionID)
        let before = try await historyRecords(content, client: client)
        _ = try confirmedClient(expectedConnectionID)
        let created = try await client.recordWatch(content, at: date)
        try await confirmHistoryChange(expectedConnectionID) {
            let after = try await self.historyRecords(content, client: client)
            guard !before.contains(where: { $0.id == created.id }),
                  let confirmed = after.first(where: { $0.id == created.id }),
                  date.matches(confirmed.value.watchedAt) else {
                throw PublicMetaDB.Failure.uncertainWrite
            }
        }
    }

    func changeHistoryDate(
        _ record: PublicMetaDB.Record<PublicMetaDB.Watch>, to date: PublicMetaDB.WatchDate,
        expectedConnectionID: UUID
    ) async throws {
        try await confirmedClient(expectedConnectionID).withMutationTransaction {
            try await self.changeHistoryDateLocked(record, to: date, expectedConnectionID: expectedConnectionID)
        }
    }

    private func changeHistoryDateLocked(
        _ record: PublicMetaDB.Record<PublicMetaDB.Watch>, to date: PublicMetaDB.WatchDate,
        expectedConnectionID: UUID
    ) async throws {
        guard date != .now else { throw PublicMetaDB.Failure.invalidInput }
        let client = try confirmedClient(expectedConnectionID)
        let before = try await historyRecords(record.value.content, client: client)
        try requireUnchangedPlay(record, in: before)
        _ = try confirmedClient(expectedConnectionID)
        if date.matches(record.value.watchedAt) { return }
        do { _ = try await client.updateWatchDate(id: record.id, at: date) }
        catch PublicMetaDB.Failure.uncertainWrite {
            // An exact record/date readback may establish an uncertain PATCH.
        }
        try await confirmHistoryChange(expectedConnectionID) {
            let after = try await self.historyRecords(record.value.content, client: client)
            guard let confirmed = after.first(where: { $0.id == record.id }),
                  date.matches(confirmed.value.watchedAt) else {
                throw PublicMetaDB.Failure.uncertainWrite
            }
        }
    }

    func deleteHistoryPlay(
        _ record: PublicMetaDB.Record<PublicMetaDB.Watch>, expectedConnectionID: UUID
    ) async throws {
        try await confirmedClient(expectedConnectionID).withMutationTransaction {
            try await self.deleteHistoryPlayLocked(record, expectedConnectionID: expectedConnectionID)
        }
    }

    private func deleteHistoryPlayLocked(
        _ record: PublicMetaDB.Record<PublicMetaDB.Watch>, expectedConnectionID: UUID
    ) async throws {
        let client = try confirmedClient(expectedConnectionID)
        let before = try await historyRecords(record.value.content, client: client)
        _ = try confirmedClient(expectedConnectionID)
        guard before.contains(where: { $0.id == record.id }) else { return }
        try requireUnchangedPlay(record, in: before)
        _ = try confirmedClient(expectedConnectionID)
        do { try await client.deleteWatch(id: record.id) }
        catch PublicMetaDB.Failure.uncertainWrite {
            // Only this play's absence, not a changed watched aggregate, confirms deletion.
        }
        try await confirmHistoryChange(expectedConnectionID) {
            let after = try await self.historyRecords(record.value.content, client: client)
            guard !after.contains(where: { $0.id == record.id }) else {
                throw PublicMetaDB.Failure.uncertainWrite
            }
        }
    }

    func clearHistoryResume(
        _ record: PublicMetaDB.Record<PublicMetaDB.Resume>, expectedConnectionID: UUID
    ) async throws {
        try await confirmedClient(expectedConnectionID).withMutationTransaction {
            try await self.clearHistoryResumeLocked(record, expectedConnectionID: expectedConnectionID)
        }
    }

    private func clearHistoryResumeLocked(
        _ record: PublicMetaDB.Record<PublicMetaDB.Resume>, expectedConnectionID: UUID
    ) async throws {
        let client = try confirmedClient(expectedConnectionID)
        let before = try await resumeRecords(record.value.content, client: client)
        _ = try confirmedClient(expectedConnectionID)
        guard let current = before.first(where: { $0.id == record.id }) else {
            guard before.isEmpty else { throw AppError.conflict }
            return
        }
        guard current.value.positionMilliseconds == record.value.positionMilliseconds,
              current.value.runtimeMilliseconds == record.value.runtimeMilliseconds,
              current.updated == record.updated else { throw AppError.conflict }
        _ = try confirmedClient(expectedConnectionID)
        do { try await client.deleteResume(id: record.id) }
        catch PublicMetaDB.Failure.uncertainWrite {
            // A replacement resume is new activity, not confirmation that progress is clear.
        }
        try await confirmHistoryChange(expectedConnectionID) {
            let after = try await self.resumeRecords(record.value.content, client: client)
            guard after.isEmpty else { throw PublicMetaDB.Failure.uncertainWrite }
        }
    }

    func dropTitle(_ content: PublicMetaDB.Content, expectedConnectionID: UUID) async throws {
        try await confirmedClient(expectedConnectionID).withMutationTransaction {
            try await self.dropTitleLocked(content, expectedConnectionID: expectedConnectionID)
        }
    }

    private func dropTitleLocked(_ content: PublicMetaDB.Content, expectedConnectionID: UUID) async throws {
        guard content.mediaType == .tv, content.season == nil else { throw PublicMetaDB.Failure.invalidInput }
        let client = try confirmedClient(expectedConnectionID)
        let before = try await client.completePages(maximumPages: 100) { try await client.dropped(page: $0, perPage: 500) }
        _ = try confirmedClient(expectedConnectionID)
        let matches = before.filter { $0.value == content }
        guard matches.count <= 1 else { throw PublicMetaDB.Failure.incompleteResponse }
        if !matches.isEmpty { return }
        do { try await client.drop(content) }
        catch PublicMetaDB.Failure.uncertainWrite {
            // Dropping is idempotent; only a complete independent read can confirm a lost reply.
        }
        try await confirmHistoryChange(expectedConnectionID) {
            let after = try await client.completePages(maximumPages: 100) { try await client.dropped(page: $0, perPage: 500) }
            guard after.filter({ $0.value == content }).count == 1 else {
                throw PublicMetaDB.Failure.uncertainWrite
            }
        }
    }

    func restoreDroppedTitle(
        _ record: PublicMetaDB.Record<PublicMetaDB.Content>, expectedConnectionID: UUID
    ) async throws {
        try await confirmedClient(expectedConnectionID).withMutationTransaction {
            try await self.restoreDroppedTitleLocked(record, expectedConnectionID: expectedConnectionID)
        }
    }

    private func restoreDroppedTitleLocked(
        _ record: PublicMetaDB.Record<PublicMetaDB.Content>, expectedConnectionID: UUID
    ) async throws {
        guard record.value.mediaType == .tv, record.value.season == nil, record.value.episode == nil else {
            throw PublicMetaDB.Failure.invalidInput
        }
        let client = try confirmedClient(expectedConnectionID)
        let before = try await client.completePages(maximumPages: 100) { try await client.dropped(page: $0, perPage: 500) }
        _ = try confirmedClient(expectedConnectionID)
        guard let current = before.first(where: { $0.id == record.id }) else {
            guard !before.contains(where: { $0.value == record.value }) else { throw AppError.conflict }
            return
        }
        guard current.value == record.value, current.updated == record.updated,
              before.filter({ $0.value == record.value }).count == 1 else { throw AppError.conflict }
        _ = try confirmedClient(expectedConnectionID)
        do { try await client.undrop(record.value) }
        catch PublicMetaDB.Failure.uncertainWrite {}
        try await confirmHistoryChange(expectedConnectionID) {
            let after = try await client.completePages(maximumPages: 100) { try await client.dropped(page: $0, perPage: 500) }
            guard !after.contains(where: { $0.value == record.value }) else {
                throw PublicMetaDB.Failure.uncertainWrite
            }
        }
    }

    private func historyRecords(
        _ content: PublicMetaDB.Content, client: PublicMetaDBClient
    ) async throws -> [PublicMetaDB.Record<PublicMetaDB.Watch>] {
        let records = try await client.completePages(maximumPages: 100) {
            try await client.history(content: content, page: $0, perPage: 500)
        }
        guard records.allSatisfy({ $0.value.content == content }) else { throw PublicMetaDB.Failure.incompleteResponse }
        return records
    }

    private func resumeRecords(
        _ content: PublicMetaDB.Content, client: PublicMetaDBClient
    ) async throws -> [PublicMetaDB.Record<PublicMetaDB.Resume>] {
        let records = try await client.completePages(maximumPages: 100) {
            try await client.resumePoints(content: content, page: $0, perPage: 500)
        }
        guard records.count <= 1, records.allSatisfy({ $0.value.content == content }) else {
            throw PublicMetaDB.Failure.incompleteResponse
        }
        return records
    }

    private func requireUnchangedPlay(
        _ record: PublicMetaDB.Record<PublicMetaDB.Watch>,
        in records: [PublicMetaDB.Record<PublicMetaDB.Watch>]
    ) throws {
        guard let current = records.first(where: { $0.id == record.id }),
              current.value.content == record.value.content, current.value.watchedAt == record.value.watchedAt,
              current.updated == record.updated else { throw AppError.conflict }
    }

    private func confirmHistoryChange(
        _ connectionID: UUID, readback: @MainActor () async throws -> Void
    ) async throws {
        do {
            try await readback()
            _ = try confirmedClient(connectionID)
        } catch {
            PlozzLog.networking.error("PublicMetaDB history management readback failed")
            throw PublicMetaDB.Failure.uncertainWrite
        }
    }
}
