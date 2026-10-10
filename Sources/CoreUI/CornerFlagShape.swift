#if canImport(SwiftUI)
import SwiftUI

/// A solid right-triangle that fills the **top-trailing** corner of its frame —
/// the classic "unwatched" corner flag (Infuse / old Plex). Its right angle sits
/// in the corner; the diagonal (hypotenuse) runs from the top-leading point down
/// to the bottom-trailing point. Because a card overlays it *before* clipping to
/// the artwork's rounded rectangle, the flag's outer corner is trimmed to match
/// the poster's radius for free.
///
/// Shared by `PosterCardView` (the real card mark) and
/// `WatchStatusIndicatorSwatch` (the Settings preview) so the two never drift.
public struct TopTrailingCornerFlag: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Just the diagonal edge of `TopTrailingCornerFlag` (top-leading → bottom-
/// trailing), stroked as a thin glass rim so the flag reads off bright artwork.
public struct TopTrailingCornerFlagEdge: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}

struct TopTrailingCurvedCornerEdge: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = max(0, min(radius, min(rect.width, rect.height)))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addArc(
            center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius),
            radius: radius, startAngle: .degrees(180), endAngle: .degrees(90),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}
#endif
