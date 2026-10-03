#if canImport(SwiftUI)
import SwiftUI

/// Pre-rendered alpha for the shared Home/detail legibility treatment. Only the image
/// shading is baked; the theme's opaque black/white tone stays live.
public struct HeroLegibilityTexture: View {
    private let tone: Color
    private let extendsLeadingFade: Bool
    @Environment(\.layoutDirection) private var layoutDirection

    public init(tone: Color, extendsLeadingFade: Bool = false) {
        self.tone = tone
        self.extendsLeadingFade = extendsLeadingFade
    }

    @ViewBuilder
    public var body: some View {
        if layoutDirection == .leftToRight && (tone == .black || tone == .white) {
            Image(
                extendsLeadingFade ? "HomeHeroLegibilityPinned" : "HomeHeroLegibility",
                bundle: .module
            )
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(tone)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            HeroLegibilityScrim(
                tone: tone, edgePeak: 0.55,
                edges: [.leading, .bottom],
                sideDarkeningStart: extendsLeadingFade ? 0 : 0.34
            )
        }
    }
}

public typealias HomeHeroLegibilityTexture = HeroLegibilityTexture
#endif
