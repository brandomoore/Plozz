#if canImport(UIKit)
import UIKit
import Observation

@MainActor @Observable
public final class DiscMenuPlaybackState {
    public var image: UIImage?
    public var isOpening = true
    public var isMenuVisible = false
    public var isStill = false
    public var hasSubtitleSelection = false
    public var subtitleTrackID: Int?
    public var failure: String?
    public var notice: String?
    public var region: UInt32 = 1
    public var playlist: Int?
    public var playItem: Int?
    public var sendKey: (UInt32) -> Void = { _ in }
    public var openMenu: () -> Void = {}

    public init() {}

    public func reset() {
        image = nil
        isOpening = true
        isMenuVisible = false
        isStill = false
        hasSubtitleSelection = false
        subtitleTrackID = nil
        failure = nil
        notice = nil
        region = 1
        playlist = nil
        playItem = nil
        sendKey = { _ in }
        openMenu = {}
    }
}
#endif
