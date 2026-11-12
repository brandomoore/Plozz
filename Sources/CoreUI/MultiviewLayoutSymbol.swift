import CoreModels
import SwiftUI

/// Native symbol images keep layout previews usable inside system menus and labels.
public struct MultiviewLayoutSymbol {
    static let bundle = Bundle.module
    public let layout: LiveTVMultiviewLayout
    public let count: Int
    public let corner: LiveTVMultiviewCorner
    public let insetSize: LiveTVMultiviewInsetSize
    public let isPortrait: Bool

    public init(
        layout: LiveTVMultiviewLayout, count: Int,
        corner: LiveTVMultiviewCorner = .bottomTrailing,
        insetSize: LiveTVMultiviewInsetSize = .medium,
        isPortrait: Bool = false
    ) {
        precondition((1...LiveTVMultiviewFavorite.maximumChannelCount).contains(count))
        self.layout = layout
        self.count = count
        self.corner = corner
        self.insetSize = insetSize
        self.isPortrait = isPortrait
    }

    public var image: Image {
        if let systemName { return Image(systemName: systemName) }
        return Image(assetName, bundle: Self.bundle)
    }

    var systemName: String? {
        if count == 1 { return "rectangle" }
        guard layout == .sideBySide else { return nil }
        switch count {
        case 2: return isPortrait ? "rectangle.split.1x2" : "rectangle.split.2x1"
        case 4: return "rectangle.split.2x2"
        default: return nil
        }
    }

    var assetName: String {
        switch layout {
        case .sideBySide: "multiview.grid.\(count)"
        case .mainAndStack: "multiview.main-and-stack.\(count)"
        case .corner: "multiview.corner.\(count).\(corner.rawValue).\(insetSize.rawValue)"
        }
    }
}
