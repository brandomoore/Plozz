import CoreModels
import Foundation

extension PublicMetaDB {
    public struct MappingReview: Sendable {
        public let mapping: Mapping
        public let records: [Record<Mapping>]
        public let reverseMatches: [Content]
        public let connectionID: UUID
    }
}

public extension PublicMetaDBService {
    func mappingsForManagement(
        _ content: PublicMetaDB.Content, expectedConnectionID: UUID
    ) async throws -> [PublicMetaDB.Record<PublicMetaDB.Mapping>] {
        guard content.season == nil, content.episode == nil else { throw PublicMetaDB.Failure.invalidInput }
        let client = try confirmedClient(expectedConnectionID)
        let result = try await client.mappings(for: content)
        _ = try confirmedClient(expectedConnectionID)
        guard result.tmdbID == content.tmdbID, result.mediaType == content.mediaType else {
            throw PublicMetaDB.Failure.incompleteResponse
        }
        var records: [PublicMetaDB.Record<PublicMetaDB.Mapping>] = []
        for (key, values) in result.mappings {
            guard let type = PublicMetaDB.ExternalIDType(rawValue: key) else {
                throw PublicMetaDB.Failure.incompleteResponse
            }
            for record in values {
                guard !record.value.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PublicMetaDB.Failure.incompleteResponse
                }
                records.append(try record.map { try .init(content: content, idType: type, idValue: $0.value) })
            }
        }
        guard result.total == records.count, Set(records.map(\.id)).count == records.count else {
            throw PublicMetaDB.Failure.incompleteResponse
        }
        return records.sorted { $0.id < $1.id }
    }

    func lookupMapping(
        idType: PublicMetaDB.ExternalIDType, idValue: String,
        mediaType: PublicMetaDB.MediaType? = nil, expectedConnectionID: UUID
    ) async throws -> [PublicMetaDB.Content] {
        let client = try confirmedClient(expectedConnectionID)
        let result = try await client.lookup(idType: idType, idValue: idValue, mediaType: mediaType)
        _ = try confirmedClient(expectedConnectionID)
        guard result.total == result.results.count, Set(result.results).count == result.results.count,
              result.results.allSatisfy({
                  $0.season == nil && $0.episode == nil && (mediaType == nil || $0.mediaType == mediaType)
              }) else { throw PublicMetaDB.Failure.incompleteResponse }
        return result.results.sorted {
            if $0.mediaType != $1.mediaType { return $0.mediaType.rawValue < $1.mediaType.rawValue }
            return $0.tmdbID < $1.tmdbID
        }
    }

    func reviewMapping(
        _ mapping: PublicMetaDB.Mapping, expectedConnectionID: UUID
    ) async throws -> PublicMetaDB.MappingReview {
        let records = try await mappingsForManagement(mapping.content, expectedConnectionID: expectedConnectionID)
        let matches = try await lookupMapping(
            idType: mapping.idType, idValue: mapping.idValue, expectedConnectionID: expectedConnectionID
        )
        return .init(mapping: mapping, records: records, reverseMatches: matches, connectionID: expectedConnectionID)
    }

    func submitManagedMapping(_ review: PublicMetaDB.MappingReview) async throws {
        let connection = review.connectionID
        let client = try confirmedClient(connection)
        try await createManagedContribution(review.mapping, expectedConnectionID: connection) {
            try await self.mappingsForManagement(review.mapping.content, expectedConnectionID: connection)
        } create: {
            let current = try await self.reviewMapping(review.mapping, expectedConnectionID: connection)
            guard current.records == review.records, current.reverseMatches == review.reverseMatches else {
                throw AppError.conflict
            }
            return try await client.submitMapping(review.mapping)
        }
    }

    func deleteManagedMapping(
        _ record: PublicMetaDB.Record<PublicMetaDB.Mapping>, expectedConnectionID: UUID
    ) async throws {
        try await deleteManagedContribution(record, category: .mappings, expectedConnectionID: expectedConnectionID) {
            try await self.mappingsForManagement(record.value.content, expectedConnectionID: expectedConnectionID)
        }
    }
}
