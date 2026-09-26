#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Card picker for how Home is arranged, mirroring the navigation and Continue
/// Watching pickers: a drawn preview of each layout with the active one ringed.
struct HomeLayoutPicker: View {
    @Binding var layout: HeroStyle
    @Environment(\.themePalette) private var palette
    @State private var width: CGFloat = 0

    private static let spacing: CGFloat = 16

    /// The previews are drawings of a TV screen, so each one is exactly 16:9 at
    /// whatever width its card is given.
    private var swatchHeight: CGFloat {
        guard width > 0 else { return 200 }
        let card = (width - Self.spacing) / 2
        return max(0, card - PlozzTheme.Metrics.Radius.inset * 2) * 9 / 16
    }

    var body: some View {
        HStack(alignment: .top, spacing: Self.spacing) {
            ForEach(HeroStyle.allCases, id: \.self) { option in
                PreviewCard(
                    title: option.layoutTitle,
                    isSelected: layout == option,
                    accent: palette.accent,
                    compact: true,
                    swatchHeight: swatchHeight,
                    action: { layout = option }
                ) {
                    HomeLayoutSwatch(style: option, cornerRadius: PlozzTheme.Metrics.Radius.content)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

extension HeroStyle {
    /// The layout's name. Not "hero": Immersive has no hero section, every title
    /// fills the screen in turn.
    var layoutTitle: LocalizedStringResource {
        switch self {
        case .carousel: "Spotlight"
        case .followsFocus: "Immersive"
        }
    }
}

extension HeroBackdropTransition {
    var settingsTitle: LocalizedStringResource {
        switch self {
        case .crossfade: "Crossfade"
        case .slide: "Slide"
        }
    }
}
#endif
