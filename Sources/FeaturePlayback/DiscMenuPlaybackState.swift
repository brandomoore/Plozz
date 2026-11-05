#if canImport(UIKit)
import UIKit
import Observation

@MainActor @Observable
public final class DiscMenuPlaybackState {
    public var isActive = false
    public var image: UIImage?
    public var isOpening = true
    public var isMenuVisible = false
    public var isStill = false
    public var hasSubtitleSelection = false
    public var subtitleTrackID: Int?
    public var failure: String?
    private var transientNotice: String?
    public var audioSelectionUnavailable = false
    public var subtitleSelectionUnavailable = false
    public var notice: String? {
        get {
            if let transientNotice { return transientNotice }
            if audioSelectionUnavailable {
                return String(localized: "The disc's selected audio track is unavailable.")
            }
            if subtitleSelectionUnavailable {
                return String(localized: "The disc's selected subtitle track is unavailable.")
            }
            return nil
        }
        set { transientNotice = newValue }
    }
    public var region: UInt32 = 1
    public var playlist: Int?
    public var playItem: Int?
    public var sendKey: (UInt32) -> Void = { _ in }
    public var openMenu: () -> Void = {}

    public init() {}

    public func reset() {
        isActive = false
        image = nil
        isOpening = true
        isMenuVisible = false
        isStill = false
        hasSubtitleSelection = false
        subtitleTrackID = nil
        failure = nil
        notice = nil
        audioSelectionUnavailable = false
        subtitleSelectionUnavailable = false
        region = 1
        playlist = nil
        playItem = nil
        sendKey = { _ in }
        openMenu = {}
    }
}
#endif
