#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Row previews omit Spotlight so the two choices stay independent.
struct HomeRowStylePicker: View {
    @Binding var immersive: Bool
    var logoSize: HeroLogoSize = .default
    var textSize: HeroTextSize = .default
    @Environment(\.themePalette) private var palette
    @State private var width: CGFloat = 0

    private static let spacing: CGFloat = 16

    /// The previews are drawings of a TV screen, so each one is exactly 16:9 at
    /// whatever width its card is given.
    private var swatchHeight: CGFloat {
        guard width > 0 else { return 200 }
        let count: CGFloat = 2
        let card = (width - Self.spacing * (count - 1)) / count
        return max(0, card - PlozzTheme.Metrics.Radius.inset * 2) * 9 / 16
    }

    var body: some View {
        HStack(alignment: .top, spacing: Self.spacing) {
            ForEach([false, true], id: \.self) { option in
                PreviewCard(
                    title: option ? "Showcase" : "Classic",
                    isSelected: immersive == option,
                    accent: palette.accent,
                    compact: true,
                    swatchHeight: swatchHeight,
                    action: { immersive = option }
                ) {
                    HomeLayoutSwatch(
                        style: option ? .followsFocus : .carousel,
                        cornerRadius: PlozzTheme.Metrics.Radius.content,
                        logoSize: logoSize, textSize: textSize, rowsOnly: true
                    )
                }
                .accessibilityIdentifier(option ? "home-rows-showcase" : "home-rows-classic")
                .accessibilityAddTraits(immersive == option ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

#endif
