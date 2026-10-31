#if os(tvOS)
import CoreModels
import CoreUI
import SwiftUI

struct HomeHeroEnabledPicker: View {
    @Binding var settings: HeroSettings
    @Environment(\.themePalette) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach([true, false], id: \.self) { enabled in
                PreviewCard(
                    title: enabled ? "On" : "Off",
                    isSelected: settings.spotlightEnabled == enabled,
                    accent: palette.accent,
                    compact: true,
                    swatchAspectRatio: 16.0 / 9.0,
                    action: { settings.spotlightEnabled = enabled }
                ) {
                    HomeLayoutSwatch(
                        style: !enabled && settings.immersiveRows ? .followsFocus : .carousel,
                        cornerRadius: PlozzTheme.Metrics.Radius.content,
                        logoSize: enabled ? settings.logoSize : settings.showcaseLogoSize,
                        textSize: enabled ? settings.textSize : settings.showcaseTextSize,
                        rowsOnly: !enabled
                    )
                }
                .accessibilityIdentifier(enabled ? "home-hero-on" : "home-hero-off")
                .accessibilityAddTraits(settings.spotlightEnabled == enabled ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
