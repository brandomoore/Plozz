import CoreGraphics
import Foundation
import CoreModels

/// Where the See all pop-up card sits beside the focused title.
public enum SeeAllPopupPlacement {
    public static let gap: CGFloat = 24

    /// The trailing side when the card fits there, otherwise the leading side,
    /// and always inside `bounds`: when neither side has room the card is pinned
    /// to the nearer edge, and it is shifted (never resized) to stay within the
    /// vertical extent. `bounds` and `anchor` share one coordinate space.
    public static func frame(
        card: CGSize, anchor: CGRect, bounds: CGRect, isRightToLeft: Bool, gap: CGFloat = gap
    ) -> CGRect {
        let width = min(card.width, bounds.width)
        let height = min(card.height, bounds.height)
        let trailingX = isRightToLeft ? anchor.minX - gap - width : anchor.maxX + gap
        let leadingX = isRightToLeft ? anchor.maxX + gap : anchor.minX - gap - width
        func fits(_ x: CGFloat) -> Bool { x >= bounds.minX && x + width <= bounds.maxX }
        var x = fits(trailingX) ? trailingX : leadingX
        x = min(max(x, bounds.minX), bounds.maxX - width)
        let y = min(max(anchor.midY - height / 2, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// What the pop-up shows for a title, after the profile's spoiler rules.
public struct SeeAllPopupContent: Equatable, Sendable {
    public var title: String
    public var titleResource: LocalizedStringResource?
    public var subtitle: String?
    public var facts: [String]
    public var genres: [String]
    public var overview: String?
    public var ratings: [String]

    /// `item` is the server's detail record when it loaded, else the listed item.
    public init(item: MediaItem, spoilers: SpoilerSettings) {
        let hidesText = spoilers.shouldHideText(for: item)
        title = item.title
        titleResource = hidesText ? spoilers.maskedTitle(for: item) : nil
        var subtitleParts: [String] = []
        if let parent = item.parentTitle, item.kind == .episode || item.kind == .season { subtitleParts.append(parent) }
        subtitle = subtitleParts.isEmpty ? nil : subtitleParts.joined(separator: " · ")
        var facts: [String] = []
        if let year = item.productionYear { facts.append(String(year)) }
        if let rating = item.officialRating, !rating.isEmpty { facts.append(rating) }
        if let runtime = item.runtime?.runtimeBadgeText { facts.append(runtime) }
        self.facts = facts
        genres = Array(item.genres.prefix(3))
        overview = hidesText ? nil : item.overview.flatMap { $0.isEmpty ? nil : $0 }
        ratings = spoilers.shouldHideRatings(for: item)
            ? [] : item.ratings.sorted { $0.sortRank < $1.sortRank }.prefix(3).map {
                "\($0.shortLabel) \($0.displayValue)"
            }
    }
}
