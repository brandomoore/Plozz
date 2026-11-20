#if canImport(SwiftUI)
import CoreModels
import SwiftUI

private extension LibraryChannelArtworkMood {
    var tint: Color {
        switch self {
        case .neutral: Color(red: 0.45, green: 0.49, blue: 0.52)
        case .cinematic: Color(red: 0.26, green: 0.48, blue: 0.68)
        case .playful: Color(red: 0.82, green: 0.61, blue: 0.25)
        case .calm: Color(red: 0.32, green: 0.57, blue: 0.39)
        case .warm: Color(red: 0.71, green: 0.42, blue: 0.38)
        case .intense: Color(red: 0.76, green: 0.37, blue: 0.22)
        case .mysterious: Color(red: 0.53, green: 0.35, blue: 0.60)
        case .imaginative: Color(red: 0.39, green: 0.43, blue: 0.74)
        }
    }
}

struct PlozzChannelWordmark: View {
    let name: String
    let mood: LibraryChannelArtworkMood
    let size: CGSize
    let cornerRadius: CGFloat
    var usesControlBackground = false
    @Environment(\.themePalette) private var palette
    @Environment(\.colorSchemeContrast) private var contrast

    private var scale: CGFloat { size.height / 128 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            Text(verbatim: name)
                .font(.system(size: 34 * scale, weight: .bold))
                .tracking(-0.9 * scale)
                .lineLimit(2)
                .minimumScaleFactor(0.44)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 5 * scale) {
                PlozzChannelPixelMascot()
                    .fill(style: FillStyle(eoFill: true))
                    .frame(width: 20 * scale, height: 20 * scale)
                Text(verbatim: "plozz")
                    .font(.system(size: 10 * scale, weight: .semibold))
                    .tracking(0.3 * scale)
            }
            .foregroundStyle(palette.primaryText.opacity(contrast == .increased ? 1 : 0.65))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(palette.primaryText)
        .padding(.horizontal, size.width * 0.12)
        .padding(.vertical, 22 * scale)
        .frame(width: size.width, height: size.height)
        .background {
            palette.cardOpaqueSurface
                .overlay(mood.tint.opacity(palette.isLight ? 0.14 : 0.24))
                .modifier(ChannelLogoNativeBackdrop(enabled: usesControlBackground))
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            if !usesControlBackground {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        palette.primaryText.opacity(contrast == .increased ? 0.4 : 0.12),
                        lineWidth: contrast == .increased ? 2 : 1
                    )
                    .allowsHitTesting(false)
            }
        }
        .accessibilityHidden(true)
    }
}

struct ChannelLogoNativeBackdrop: ViewModifier {
    let enabled: Bool
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        // Let native focus illuminate the plate without replacing its colour or dimming the logo.
        content.opacity(enabled && isFocused ? 0.72 : 1)
    }
}
#endif
