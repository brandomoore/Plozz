#if canImport(SwiftUI)
import SwiftUI

/// Geometry of a specialty shelf. Width starts at the first *slot*, so the
/// same shelf can fit framed artwork or an avatar with invisible focus room.
public struct MediaRailViewport: Equatable, Sendable {
    public var width: CGFloat
    public var spacing: CGFloat

    public init(width: CGFloat = 0, spacing: CGFloat = 0) {
        self.width = width
        self.spacing = spacing
    }

    public func slot(
        preferred: CGFloat, sideMargin: CGFloat = 0,
        rounding: FloatingPointRoundingRule = .toNearestOrAwayFromZero
    ) -> CGFloat {
        let available = width - sideMargin
        guard available > spacing else { return preferred }
        let count = MediaRailLayout.wholeCards(
            available: available, preferredSlot: preferred, spacing: spacing,
            sideMargin: sideMargin, rounding: rounding
        )
        return MediaRailLayout.slotWidth(
            available: available, count: count, spacing: spacing, sideMargin: sideMargin
        )
    }
}

public extension EnvironmentValues {
    @Entry var specialtyMediaRailViewport = MediaRailViewport()
}

private struct SpecialtyRailSizing: ViewModifier {
    let leadingInset: CGFloat
    let spacing: CGFloat
    let horizontalContentMargins: CGFloat
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .environment(\.specialtyMediaRailViewport, MediaRailViewport(width: width - leadingInset, spacing: spacing))
            .mediaRailViewportWidth($width, horizontalContentMargins: horizontalContentMargins)
    }
}

public extension View {
    func mediaRailViewportWidth(_ width: Binding<CGFloat>, horizontalContentMargins: CGFloat = 0) -> some View {
        #if os(tvOS)
        // tvOS excludes explicit scroll-content margins from containerSize.
        // Recover those margins (not inherited sidebar/safe-area insets) before
        // the rail measures from its first artwork to its physical trailing edge.
        onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.width + horizontalContentMargins } action: { _, value in
            width.wrappedValue = value
        }
        #else
        onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width.wrappedValue = $0 }
        #endif
    }

    /// Measure the scroll container once per resize, never its offset or each cell.
    func fittingSpecialtyMediaRail(leadingInset: CGFloat = 0, spacing: CGFloat, horizontalContentMargins: CGFloat = 0) -> some View {
        modifier(SpecialtyRailSizing(leadingInset: leadingInset, spacing: spacing, horizontalContentMargins: horizontalContentMargins))
    }
}
#endif
