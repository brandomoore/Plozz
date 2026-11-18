#if canImport(SwiftUI)
import SwiftUI
import CoreModels

public extension MusicPlayerAppearance {
    func resolved(palette: ThemePalette, gradientEnabled: Bool) -> Self {
        guard self == .matchTheme else { return self }
        if gradientEnabled { return .artwork }
        if palette == .pureBlack { return .pureBlack }
        return palette.isLight ? .light : .dark
    }

    var neutralBackground: Color {
        switch self {
        case .light: ThemePalette.light.backgroundBase
        case .dark: ThemePalette.dark.backgroundBase
        case .pureBlack, .artwork, .matchTheme: .black
        }
    }
}

/// Shared preview content; each platform supplies its actual player background.
public struct MusicPlayerPreview<Background: View>: View {
    private let isLight: Bool
    private let cornerRadius: CGFloat
    private let background: Background

    public static var artworkColors: [Color] {
        [Color(red: 0.98, green: 0.42, blue: 0.55), Color(red: 0.42, green: 0.38, blue: 0.95)]
    }

    public init(isLight: Bool, cornerRadius: CGFloat = 16, @ViewBuilder background: () -> Background) {
        self.isLight = isLight
        self.cornerRadius = cornerRadius
        self.background = background()
    }

    public var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let art = max(0, min(geometry.size.width - 32, height * 0.5))
            let foreground: Color = isLight ? .black : .white
            VStack(spacing: height * 0.06) {
                RoundedRectangle(cornerRadius: art * 0.12)
                    .fill(LinearGradient(colors: Self.artworkColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: art, height: art)
                Capsule().fill(foreground.opacity(0.7)).frame(width: art * 0.7, height: 4)
                HStack(spacing: 0) {
                    Capsule().fill(foreground).frame(width: art * 0.4)
                    Capsule().fill(foreground.opacity(0.25))
                }
                .frame(height: 3)
                HStack(spacing: 18) {
                    Image(systemName: "backward.end.fill")
                    Image(systemName: "pause.fill")
                    Image(systemName: "forward.end.fill")
                }
                .font(.system(size: max(8, height * 0.08)))
                .foregroundStyle(foreground)
            }
            .padding(16)
            .frame(width: geometry.size.width, height: height)
            .background { background }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color(white: 0.5).opacity(0.35), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

public struct MusicStyleSwatch: View {
    private let appearance: MusicPlayerAppearance
    private let cornerRadius: CGFloat
    @Environment(\.themePalette) private var palette
    @Environment(\.gradientBackgroundsEnabled) private var gradientEnabled

    public init(appearance: MusicPlayerAppearance, cornerRadius: CGFloat = 16) {
        self.appearance = appearance
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        let resolved = appearance.resolved(palette: palette, gradientEnabled: gradientEnabled)
        MusicPlayerPreview(isLight: resolved == .light, cornerRadius: cornerRadius) {
            if resolved == .artwork {
                LiquidArtworkBackground(
                    palette: MusicPlayerPreview<Color>.artworkColors, animate: false, style: .dark
                )
            } else {
                resolved.neutralBackground
            }
        }
    }
}
#endif
