import CoreModels
import CoreNetworking
import Foundation

struct PlexCommonSenseMediaResponse: Decodable {
    struct Container: Decodable {
        let CommonSenseMedia: [PlexCommonSenseMedia]?
    }
    let MediaContainer: Container
}

struct PlexCommonSenseMedia: Decodable {
    struct AgeRatingValue: Decodable {
        let age: Double?
        let rating: Double?
        let type: String?

        enum CodingKeys: String, CodingKey { case age, rating, type }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            age = values.flexibleDouble(.age)
            rating = values.flexibleDouble(.rating)
            type = values.flexibleString(.type)
        }
    }

    struct Topic: Decodable {
        let id: String?
        let label: String?
        let rating: Double?
        let tag: String?
        let positive: Bool?

        enum CodingKeys: String, CodingKey { case id, label, rating, tag, positive }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = values.flexibleString(.id)
            label = values.flexibleString(.label)
            rating = values.flexibleDouble(.rating)
            tag = values.flexibleString(.tag)
            positive = values.flexibleBool(.positive)
        }
    }

    struct TalkingPointValue: Decodable { let tag: String? }

    let AgeRating: [AgeRatingValue]?
    let ParentalAdvisoryTopic: [Topic]?
    let TalkingPoint: [TalkingPointValue]?
    let oneLiner: String?
    let parentsNeedToKnow: String?
    let anyGood: String?

    var summary: FamilyGuidanceSummary {
        let official = AgeRating?.first { $0.type == "official" }
        return FamilyGuidanceSummary(
            recommendedAge: valid(official?.age, in: 2...18),
            qualityRating: valid(official?.rating, in: 0...5),
            overview: nonempty(oneLiner)
        )
    }

    var guidance: FamilyGuidance {
        var audiences = Set<FamilyGuidance.AudienceRating.Audience>()
        let ratings: [FamilyGuidance.AudienceRating] = (AgeRating ?? []).compactMap { value in
            let audience: FamilyGuidance.AudienceRating.Audience
            switch value.type {
            case "official": audience = .official
            case "adult": audience = .parents
            case "child": audience = .kids
            default: return nil
            }
            guard audiences.insert(audience).inserted else { return nil }
            return .init(
                audience: audience, recommendedAge: valid(value.age, in: 2...18),
                qualityRating: valid(value.rating, in: 0...5)
            )
        }
        var topicIDs = Set<String>()
        let topics: [FamilyGuidance.Topic] = (ParentalAdvisoryTopic ?? []).compactMap { topic in
            guard let id = nonempty(topic.id), let label = nonempty(topic.label),
                  topicIDs.insert(id).inserted else { return nil }
            return .init(
                id: id, label: label, rating: valid(topic.rating, in: 0...5),
                explanation: nonempty(topic.tag),
                isPositive: topic.positive ?? ["message", "role_model", "diverse"].contains(id)
            )
        }
        return FamilyGuidance(
            summary: summary, audienceRatings: ratings, topics: topics,
            parentsNeedToKnow: nonempty(parentsNeedToKnow), qualityOverview: nonempty(anyGood),
            talkingPoints: (TalkingPoint ?? []).compactMap { nonempty($0.tag) }
        )
    }

    private func valid(_ value: Double?, in range: ClosedRange<Double>) -> Double? {
        guard let value else { return nil }
        guard value.isFinite, range.contains(value) else {
            PlozzLog.networking.error("Plex family guidance contained an invalid age or score")
            return nil
        }
        return value
    }

    private func nonempty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

extension PlexProvider: FamilyGuidanceProviding {
    public func familyGuidance(for item: MediaItem, accountToken: String?) async throws -> FamilyGuidanceAvailability {
        guard item.kind == .movie || item.kind == .series,
              let metadataID = PlexClient.watchlistMetadataID(fromGuid: item.providerIDs["PlexGuid"]) else {
            return .unavailable
        }
        return try await client.withDiscoverToken(accountToken).commonSenseMedia(metadataID: metadataID)
    }
}
