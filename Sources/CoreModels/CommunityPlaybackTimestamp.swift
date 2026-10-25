import Foundation

public struct CommunityPlaybackTimestamp: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case intro, credits, recap, preview, highlight
    }

    public enum Release: Equatable, Sendable {
        case streaming, physical, unknown
    }

    public let id: String
    public let kind: Kind
    public let start: TimeInterval
    public let end: TimeInterval
    public let release: Release
    public let contributor: String?
    public let description: String?

    public init(
        id: String, kind: Kind, start: TimeInterval, end: TimeInterval,
        release: Release, contributor: String? = nil, description: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.release = release
        self.contributor = contributor
        self.description = description
    }

    public func fits(duration: TimeInterval) -> Bool {
        duration.isFinite && duration > 0 && start.isFinite && end.isFinite
            && start >= 0 && end > start && end <= duration
    }
}

/// Explicit browsing only. These records carry no verified file/release match
/// and must not be installed as automatic skip markers or server chapters.
@MainActor
public protocol CommunityPlaybackTimestampProviding: AnyObject {
    var name: String { get }
    var isCurrent: Bool { get }
    func timestamps(for item: MediaItem, includeHighlights: Bool) async throws -> [CommunityPlaybackTimestamp]
}
