#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Card picker for how Home is arranged, mirroring the navigation and Continue
/// Watching pickers: a drawn preview of each layout with the active one ringed.
struct HomeLayoutPicker: View {
    @Binding var layout: HeroStyle
    var homeLogoSize: HeroLogoSize = .default
    var showcaseLogoSize: HeroLogoSize = .default
    var homeTextSize: HeroTextSize = .default
    var showcaseTextSize: HeroTextSize = .default
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
                HomeLayoutOptionCard(
                    style: option,
                    isSelected: layout == option,
                    swatchHeight: swatchHeight,
                    logoSize: option == .carousel ? homeLogoSize : showcaseLogoSize,
                    textSize: option == .carousel ? homeTextSize : showcaseTextSize,
                    action: { layout = option }
                )
                .settingsSearchAnchor(
                    option == .carousel && layout == .followsFocus ? "hero-enabled" : "home-layout-\(option.rawValue)",
                    fallbackFor: fallbackTargets(for: option)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func fallbackTargets(for option: HeroStyle) -> [String] {
        if option == layout { return ["home-layout"] }
        if option == .carousel { return SettingsSearchCatalog.carouselHeroTargets }
        return ["showcase-logo-size", "showcase-text-size", "showcase-discovery-row"]
    }
}

#endif
