import CoreModels
import Foundation
import Observation

@MainActor @Observable
final class LiveTVChannelOrganizationState {
    var organization = LiveTVChannelOrganization()
    var categories: [LiveTVCategorySummary] = []
    var hiddenChannels: [LiveTVHiddenChannelEntry] = []
    var countries: [String] = []
    var languages: [String] = []
    var favoriteIDs: Set<String> = []
    var effectiveFavoriteIDs: Set<String> = []
    var hiddenIDs: Set<String> = []
    var provisionalBrowse: LiveTVBrowseSummary?
}

public struct LiveTVCategorySummary: Equatable, Identifiable, Sendable {
    public let rule: LiveTVCategoryRule
    public let channelCount: Int
    public let visibleCount: Int
    public var id: String { rule.id }
}

public struct LiveTVHiddenChannelEntry: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let reason: LiveTVChannelHiddenReason
}
