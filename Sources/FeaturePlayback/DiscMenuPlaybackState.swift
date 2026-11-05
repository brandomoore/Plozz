#if canImport(UIKit)
import UIKit
import Observation

@MainActor @Observable
public final class DiscMenuPlaybackState {
    public var image: UIImage?
    public var isOpening = true
    public var isMenuVisible = false
    public var failure: String?
    public var notice: String?
    public var region: UInt32 = 1
    public var playlist: Int?
    public var sendKey: (UInt32) -> Void = { _ in }
    public var openMenu: () -> Void = {}

    public init() {}

    public func reset() {
        image = nil
        isOpening = true
        isMenuVisible = false
        failure = nil
        notice = nil
        region = 1
        playlist = nil
        sendKey = { _ in }
        openMenu = {}
    }
}
#endif
