#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Card picker for how Home is arranged, mirroring the navigation and Continue
/// Watching pickers: a drawn preview of each layout with the active one ringed.
struct HomeLayoutPicker: View {
    @Binding var layout: HeroStyle
    @Environment(\.themePalette) private var palette

    /// Matches the Continue Watching picker: each preview carries a whole screen's
    /// worth of detail, and needs the room to read.
    private let swatchHeight: CGFloat = 200

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(HeroStyle.allCases, id: \.self) { option in
                PreviewCard(
                    title: option.layoutTitle,
                    detail: option.layoutDetail,
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

    var layoutDetail: LocalizedStringResource {
        switch self {
        case .carousel: "A rotating showcase above your rows."
        case .followsFocus: "What you're on fills the screen."
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
