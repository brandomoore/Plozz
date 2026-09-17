import Foundation

public struct FamilyGuidanceSummary: Codable, Hashable, Sendable {
    public let recommendedAge: Double?
    public let qualityRating: Double?
    public let overview: String?

    public init(recommendedAge: Double?, qualityRating: Double?, overview: String? = nil) {
        self.recommendedAge = recommendedAge
        self.qualityRating = qualityRating
        self.overview = overview
    }

    public var hasContent: Bool {
        recommendedAge != nil || qualityRating != nil || overview != nil
    }
}

public struct FamilyGuidance: Equatable, Sendable {
    public struct AudienceRating: Equatable, Sendable, Identifiable {
        public enum Audience: String, Sendable {
            case official, parents, kids
        }
        public let audience: Audience
        public let recommendedAge: Double?
        public let qualityRating: Double?
        public var id: Audience { audience }

        public init(audience: Audience, recommendedAge: Double?, qualityRating: Double?) {
            self.audience = audience
            self.recommendedAge = recommendedAge
            self.qualityRating = qualityRating
        }
    }

    public struct Topic: Equatable, Sendable, Identifiable {
        public let id: String
        public let label: String
        public let rating: Double?
        public let explanation: String?
        public let isPositive: Bool

        public init(id: String, label: String, rating: Double?, explanation: String?, isPositive: Bool) {
            self.id = id
            self.label = label
            self.rating = rating
            self.explanation = explanation
            self.isPositive = isPositive
        }
    }

    public let summary: FamilyGuidanceSummary
    public let audienceRatings: [AudienceRating]
    public let topics: [Topic]
    public let parentsNeedToKnow: String?
    public let qualityOverview: String?
    public let talkingPoints: [String]

    public init(
        summary: FamilyGuidanceSummary,
        audienceRatings: [AudienceRating] = [],
        topics: [Topic] = [],
        parentsNeedToKnow: String? = nil,
        qualityOverview: String? = nil,
        talkingPoints: [String] = []
    ) {
        self.summary = summary
        self.audienceRatings = audienceRatings
        self.topics = topics
        self.parentsNeedToKnow = parentsNeedToKnow
        self.qualityOverview = qualityOverview
        self.talkingPoints = talkingPoints
    }

    public var hasDetails: Bool {
        !topics.isEmpty || parentsNeedToKnow != nil || qualityOverview != nil || !talkingPoints.isEmpty
            || audienceRatings.contains { $0.audience != .official }
    }
}

public enum FamilyGuidanceAvailability: Equatable, Sendable {
    case available(FamilyGuidance)
    case restricted
    case unavailable
}

/// Optional provider capability; unsupported backends need no synthetic ratings.
public protocol FamilyGuidanceProviding: MediaProvider {
    func familyGuidance(for item: MediaItem, accountToken: String?) async throws -> FamilyGuidanceAvailability
}

/// Resolves the current profile's provider and cloud authorization at activation.
@MainActor
public protocol FamilyGuidanceLoading: AnyObject, Sendable {
    var contextID: String { get }
    func loadFamilyGuidance(for item: MediaItem) async throws -> FamilyGuidanceAvailability
}
