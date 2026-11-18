import Foundation

/// A playlist is not necessarily the library movie: it may be an extra or another cut.
public struct DiscVideo: Identifiable, Hashable, Sendable {
    public let playlist: Int
    public let duration: TimeInterval
    public let chapterCount: Int
    public var id: Int { playlist }

    public init(playlist: Int, duration: TimeInterval, chapterCount: Int) {
        self.playlist = playlist
        self.duration = duration
        self.chapterCount = chapterCount
    }
}
