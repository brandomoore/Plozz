#if canImport(UIKit)
import UIKit
import Observation

@MainActor @Observable
public final class DiscMenuPlaybackState {
    public var isActive = false
    public var image: UIImage?
    public var isOpening = true
    public var isMenuVisible = false {
        didSet {
            if isMenuVisible { hasPresentedMenu = true }
            else if isMenuRequestPending { hasPresentedMenu = false }
        }
    }
    public private(set) var hasPresentedMenu = false
    public var showsLoadingIndicator: Bool {
        failure == nil && !isMenuVisible && (!hasPresentedMenu || isMenuRequestPending || isOpening)
    }
    public var isMenuRequestPending = true
    public var presentsMenu: Bool {
        failure != nil || isMenuRequestPending || showsLoadingIndicator || isMenuVisible || image != nil
    }
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
    public var sendPointerClick: (UInt16, UInt16) -> Void = { _, _ in }
    public var openMenu: () -> Void = {}

    public init() {}

    public func activate(at point: CGPoint, in bounds: CGRect) {
        guard isActive, isMenuVisible, failure == nil, let image = image?.cgImage,
              image.width > 0, image.height > 0,
              image.width <= Int(UInt16.max), image.height <= Int(UInt16.max),
              point.x.isFinite, point.y.isFinite,
              let rect = SubtitleOverlayGeometry.aspectFitRect(
                in: bounds, aspectRatio: CGFloat(image.width) / CGFloat(image.height)
              ), rect.contains(point) else { return }
        let x = min(image.width - 1, Int((point.x - rect.minX) * CGFloat(image.width) / rect.width))
        let y = min(image.height - 1, Int((point.y - rect.minY) * CGFloat(image.height) / rect.height))
        sendPointerClick(UInt16(x), UInt16(y))
    }

    public func reset() {
        isActive = false
        image = nil
        isOpening = true
        isMenuVisible = false
        hasPresentedMenu = false
        isMenuRequestPending = true
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
        sendPointerClick = { _, _ in }
        openMenu = {}
    }
}
#endif
