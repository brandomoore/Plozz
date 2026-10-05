import Foundation

/// Counts only. This contract cannot carry a source identity, address or playlist content.
public struct LiveTVPlaylistLimitDiagnostic: Equatable, Sendable {
    public enum Limit: String, Sendable {
        case responseHeaderBytes, responseBodyBytes, inputBytes, decodedBytes, headerLineBytes, entries
    }

    public static let notification = Notification.Name("com.plozz.liveTV.playlistLimitDiagnostic")
    public let limit: Limit
    public let observed: Int64
    public let maximum: Int64

    public init(limit: Limit, observed: Int64, maximum: Int64) {
        self.limit = limit
        self.observed = observed
        self.maximum = maximum
    }

    public func publish() {
        NotificationCenter.default.post(name: Self.notification, object: self)
    }
}
