#if os(iOS)
import CoreModels
import CoreUI
import SwiftUI

enum PlozziOSMediaRailLayout {
    static let sectionSpacing: CGFloat = 32
    static let headingSpacing: CGFloat = 12
    static let visibleSpacing: CGFloat = 12
    static let shadowClearance: CGFloat = 10

    static func artworkAlignedInset(_ pageInset: CGFloat, metrics: PlozzMetrics, cardStyle: CardStyle) -> CGFloat {
        pageInset - (cardStyle == .framed ? metrics.cardInset : metrics.borderlessCardSideMargin)
    }

    /// Exclude the card's invisible side margins from the visible artwork gap.
    static func stackSpacing(
        metrics: PlozzMetrics, cardStyle: CardStyle,
        visibleSpacing: CGFloat = PlozziOSMediaRailLayout.visibleSpacing
    ) -> CGFloat {
        switch cardStyle {
        case .framed:
            visibleSpacing
        case .borderless:
            max(0, visibleSpacing - metrics.borderlessCardSideMargin * 2)
        }
    }
}

struct PlozziOSMediaSection<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: Text
    var horizontalInset: CGFloat?
    var artworkInset: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: PlozziOSMediaRailLayout.headingSpacing) {
            title
                .font(.title3.weight(.semibold))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, horizontalInset ?? PlozziOSPageLayout.horizontalInset(for: sizeClass))
                .accessibilityAddTraits(.isHeader)
            content
                .padding(.vertical, -artworkInset)
        }
    }
}

extension View {
    func plozziOSMediaRailClearance() -> some View {
        // Preserve shadow/press-effect room without inflating visible section gaps.
        contentMargins(.vertical, PlozziOSMediaRailLayout.shadowClearance, for: .scrollContent)
            .padding(.vertical, -PlozziOSMediaRailLayout.shadowClearance)
            .scrollIndicators(.hidden)
    }
}
#endif
