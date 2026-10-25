import CoreModels
import CoreNetworking
import Foundation

public extension PublicMetaDBService {
    func ratingsForManagement(
        _ content: PublicMetaDB.Content, expectedConnectionID: UUID
    ) async throws -> PublicMetaDB.Ratings {
        let client = try confirmedClient(expectedConnectionID)
        let result = try await client.ratings(for: content)
        _ = try confirmedClient(expectedConnectionID)
        guard result.isComplete, Set(result.items.map(\.id)).count == result.items.count,
              result.items.allSatisfy({ $0.value.content == content }) else {
            throw PublicMetaDB.Failure.incompleteResponse
        }
        return result
    }

    func submitManagedRating(
        _ rating: PublicMetaDB.Rating, expectedConnectionID: UUID
    ) async throws {
        let client = try confirmedClient(expectedConnectionID)
        defer { invalidateCommunityRatings(expectedConnectionID: expectedConnectionID) }
        try await createManagedContribution(rating, expectedConnectionID: expectedConnectionID) {
            try await self.ratingsForManagement(rating.content, expectedConnectionID: expectedConnectionID).items
        } create: {
            try await client.submitRating(rating)
        }
    }

    func deleteManagedRating(
        _ record: PublicMetaDB.Record<PublicMetaDB.Rating>, expectedConnectionID: UUID
    ) async throws {
        defer { invalidateCommunityRatings(expectedConnectionID: expectedConnectionID) }
        try await deleteManagedContribution(
            record, category: record.value.content.episode == nil ? .ratings : .episodeRatings,
            expectedConnectionID: expectedConnectionID
        ) {
            try await self.ratingsForManagement(record.value.content, expectedConnectionID: expectedConnectionID).items
        }
    }

    func contributionVotes(
        _ category: PublicMetaDB.Contribution, recordID: String, expectedConnectionID: UUID
    ) async throws -> PublicMetaDB.Votes {
        let client = try confirmedClient(expectedConnectionID)
        let result = try await client.votes(for: category, id: recordID)
        _ = try confirmedClient(expectedConnectionID)
        guard result.total >= result.items.count, result.items.count <= 1,
              result.items.allSatisfy({ !$0.id.isEmpty }),
              result.items.first?.vote == result.userVote,
              result.summary.upvotes >= 0, result.summary.downvotes >= 0,
              result.summary.upvotes <= result.total,
              result.summary.downvotes <= result.total - result.summary.upvotes,
              result.summary.score == result.summary.upvotes - result.summary.downvotes else {
            throw PublicMetaDB.Failure.incompleteResponse
        }
        return result
    }

    func changeContributionVote(
        _ vote: PublicMetaDB.Vote?, category: PublicMetaDB.Contribution, recordID: String,
        observedVote: PublicMetaDB.Vote?, expectedConnectionID: UUID
    ) async throws {
        let client = try confirmedClient(expectedConnectionID)
        let before = try await contributionVotes(category, recordID: recordID, expectedConnectionID: expectedConnectionID)
        guard before.userVote == observedVote else { throw AppError.conflict }
        guard before.userVote != vote else { return }
        _ = try confirmedClient(expectedConnectionID)
        do {
            if let vote { try await client.setVote(vote, for: category, id: recordID) }
            else { try await client.removeVote(for: category, id: recordID) }
        } catch PublicMetaDB.Failure.uncertainWrite {}
        try await confirmContributionChange(expectedConnectionID) {
            let after = try await self.contributionVotes(category, recordID: recordID, expectedConnectionID: expectedConnectionID)
            guard after.userVote == vote else { throw PublicMetaDB.Failure.uncertainWrite }
        }
    }

    func skipsForManagement(
        _ content: PublicMetaDB.Content, expectedConnectionID: UUID
    ) async throws -> [PublicMetaDB.Record<PublicMetaDB.Skip>] {
        guard content.isPlayable else { throw PublicMetaDB.Failure.invalidInput }
        let client = try confirmedClient(expectedConnectionID)
        let result = try await client.completePages(maximumPages: 20) {
            try await client.skips(for: content, page: $0, perPage: 200)
        }
        _ = try confirmedClient(expectedConnectionID)
        guard result.allSatisfy({ $0.value.content == content }) else { throw PublicMetaDB.Failure.incompleteResponse }
        return result
    }

    func highlightsForManagement(
        _ content: PublicMetaDB.Content, expectedConnectionID: UUID
    ) async throws -> [PublicMetaDB.Record<PublicMetaDB.Highlight>] {
        guard content.isPlayable else { throw PublicMetaDB.Failure.invalidInput }
        let client = try confirmedClient(expectedConnectionID)
        let result = try await client.highlights(for: content)
        _ = try confirmedClient(expectedConnectionID)
        guard result.isComplete, Set(result.items.map(\.id)).count == result.items.count,
              result.items.allSatisfy({ $0.value.content == content }) else {
            throw PublicMetaDB.Failure.incompleteResponse
        }
        return result.items
    }

    func submitManagedSkip(_ value: PublicMetaDB.Skip, expectedConnectionID: UUID) async throws {
        let client = try confirmedClient(expectedConnectionID)
        try await createManagedContribution(value, expectedConnectionID: expectedConnectionID) {
            try await self.skipsForManagement(value.content, expectedConnectionID: expectedConnectionID)
        } create: {
            try await client.submitSkip(value)
        }
    }

    func submitManagedHighlight(_ value: PublicMetaDB.Highlight, expectedConnectionID: UUID) async throws {
        let client = try confirmedClient(expectedConnectionID)
        try await createManagedContribution(value, expectedConnectionID: expectedConnectionID) {
            try await self.highlightsForManagement(value.content, expectedConnectionID: expectedConnectionID)
        } create: {
            try await client.submitHighlight(value)
        }
    }

    func deleteManagedSkip(
        _ record: PublicMetaDB.Record<PublicMetaDB.Skip>, expectedConnectionID: UUID
    ) async throws {
        try await deleteManagedContribution(record, category: .skips, expectedConnectionID: expectedConnectionID) {
            try await self.skipsForManagement(record.value.content, expectedConnectionID: expectedConnectionID)
        }
    }

    func deleteManagedHighlight(
        _ record: PublicMetaDB.Record<PublicMetaDB.Highlight>, expectedConnectionID: UUID
    ) async throws {
        try await deleteManagedContribution(record, category: .highlights, expectedConnectionID: expectedConnectionID) {
            try await self.highlightsForManagement(record.value.content, expectedConnectionID: expectedConnectionID)
        }
    }

    internal func createManagedContribution<Value: Decodable & Equatable & Sendable>(
        _ value: Value, expectedConnectionID: UUID,
        read: @MainActor () async throws -> [PublicMetaDB.Record<Value>],
        create: @MainActor () async throws -> PublicMetaDB.Record<Value>
    ) async throws {
        _ = try await read()
        _ = try confirmedClient(expectedConnectionID)
        let created = try await create()
        try await confirmContributionChange(expectedConnectionID) {
            let after = try await read()
            guard after.contains(where: { $0.id == created.id && $0.value == value }) else {
                throw PublicMetaDB.Failure.uncertainWrite
            }
        }
    }

    internal func deleteManagedContribution<Value: Decodable & Equatable & Sendable>(
        _ record: PublicMetaDB.Record<Value>, category: PublicMetaDB.Contribution, expectedConnectionID: UUID,
        read: @MainActor () async throws -> [PublicMetaDB.Record<Value>]
    ) async throws {
        let client = try confirmedClient(expectedConnectionID)
        let before = try await read()
        _ = try confirmedClient(expectedConnectionID)
        guard let current = before.first(where: { $0.id == record.id }) else { return }
        guard current.value == record.value, current.updated == record.updated,
              current.contributor == record.contributor else { throw AppError.conflict }
        do { try await client.deleteContribution(category, id: record.id) }
        catch PublicMetaDB.Failure.uncertainWrite {
            // Only a complete, exact-record absence read can confirm this request.
        }
        try await confirmContributionChange(expectedConnectionID) {
            let after = try await read()
            guard !after.contains(where: { $0.id == record.id }) else { throw PublicMetaDB.Failure.uncertainWrite }
        }
    }

    internal func confirmContributionChange(
        _ connectionID: UUID, readback: @MainActor () async throws -> Void
    ) async throws {
        do {
            try await readback()
            _ = try confirmedClient(connectionID)
        } catch {
            PlozzLog.networking.error("PublicMetaDB contribution readback failed")
            throw PublicMetaDB.Failure.uncertainWrite
        }
    }
}
