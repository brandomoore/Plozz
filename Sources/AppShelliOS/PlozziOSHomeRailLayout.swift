#if os(iOS)
import CoreModels
import CoreUI
import SwiftUI

private struct PlozziOSHomeViewportWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var plozziOSHomeViewportWidth: CGFloat {
        get { self[PlozziOSHomeViewportWidthKey.self] }
        set { self[PlozziOSHomeViewportWidthKey.self] = newValue }
    }
}

/// Home's loaded and placeholder rails share the same platform-specific poster sizes.
struct PlozziOSHomeRailLayout<Content: View>: View {
    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.plozzCardStyle) private var cardStyle
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.plozziOSHomeViewportWidth) private var viewportWidth
    @State private var width: CGFloat = 0
    @ViewBuilder let content: (PlozzMetrics) -> Content

    var body: some View {
        let resolved = Self.posterMetrics(
            in: viewportWidth > 0 ? viewportWidth : width,
            inset: PlozziOSPageLayout.horizontalInset(for: sizeClass),
            metrics: metrics, cardStyle: cardStyle
        )
        content(resolved)
            .environment(\.plozzMetrics, resolved)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    static func posterMetrics(
        in width: CGFloat, inset: CGFloat, metrics: PlozzMetrics, cardStyle: CardStyle
    ) -> PlozzMetrics {
        if metrics.usesDesktopSizing {
            return metrics.fittingDesktopRail(in: width, cardStyle: cardStyle)
        }
        guard width > 0 else { return metrics }
        let gap = PlozziOSMediaRailLayout.visibleSpacing + (cardStyle == .framed ? 2 * metrics.cardInset : 0)
        // Phones get three complete pictures plus a 28% preview. Wider windows
        // add columns instead of stretching phone posters to tablet size.
        let count = max(width < 375 ? 2 : 3, floor((width - inset + gap) / 164))
        let standardWidth = (width - inset - count * gap) / (count + 0.28)
        let artworkWidth = max(44, standardWidth * CGFloat(metrics.density.scale))
        return metrics.scalingPosters(by: artworkWidth / metrics.posterWidth)
    }
}
#endif
