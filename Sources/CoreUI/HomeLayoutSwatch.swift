#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Fixed, theme-independent colours for the Home layout preview. A picture of the
/// layout, so it never adapts to the applied theme.
private enum HomeLayoutPreviewColors {
    static let page = Color(red: 0.10, green: 0.10, blue: 0.12)
    /// The stand-in artwork: a warm sky over a cool horizon.
    static let artTop = Color(red: 0.62, green: 0.44, blue: 0.36)
    static let artBottom = Color(red: 0.20, green: 0.26, blue: 0.38)
    static let text = Color.white.opacity(0.92)
    static let textMuted = Color.white.opacity(0.46)
    static let tileTop = Color(white: 0.34)
    static let tileBottom = Color(white: 0.24)
    static let tileBorder = Color.white.opacity(0.12)
    static let button = Color.white.opacity(0.22)
}

/// A tiny mock of Home in one ``HeroStyle``:
/// - `.carousel` ("Spotlight"): a showcase with a wordmark, two action buttons and
///   paging dots over its artwork, with the first row peeking beneath it.
/// - `.followsFocus` ("Immersive"): the artwork fills the whole screen, the title
///   sits top left with no buttons, and one focused row rests low with the next
///   row just peeking.
///
/// Both draw the same stand-in artwork and tiles, so the two cards read as the
/// same Home arranged two ways.
public struct HomeLayoutSwatch: View {
    private let style: HeroStyle
    private let cornerRadius: CGFloat

    public init(style: HeroStyle, cornerRadius: CGFloat = 16) {
        self.style = style
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                HomeLayoutPreviewColors.page
                switch style {
                case .carousel: spotlight(size)
                case .followsFocus: immersive(size)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color(white: 0.5).opacity(0.35), lineWidth: 1)
        )
        .accessibilityHidden(true)
    }

    // MARK: Spotlight

    private func spotlight(_ size: CGSize) -> some View {
        let w = size.width, h = size.height
        let inset = w * 0.07
        let tileWidth = w * 0.24
        return ZStack(alignment: .topLeading) {
            artwork
                .frame(width: w, height: h * 0.74)
                .mask(fade(from: 0.6))
            VStack(alignment: .leading, spacing: h * 0.035) {
                wordmark(width: w * 0.3, height: h * 0.07)
                textLines(width: w * 0.36, lineHeight: h * 0.022, count: 2)
                HStack(spacing: w * 0.02) {
                    Capsule().fill(HomeLayoutPreviewColors.text)
                        .frame(width: w * 0.12, height: h * 0.07)
                    Capsule().fill(HomeLayoutPreviewColors.button)
                        .frame(width: w * 0.07, height: h * 0.07)
                    Capsule().fill(HomeLayoutPreviewColors.button)
                        .frame(width: w * 0.07, height: h * 0.07)
                }
                HStack(spacing: w * 0.012) {
                    Capsule().fill(HomeLayoutPreviewColors.text).frame(width: w * 0.035, height: h * 0.012)
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().fill(HomeLayoutPreviewColors.textMuted).frame(width: h * 0.012, height: h * 0.012)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(width: w - inset * 2, alignment: .leading)
            .padding(.leading, inset)
            .padding(.top, h * 0.2)
            tileRow(width: tileWidth, height: tileWidth * 9 / 16, spacing: w * 0.025, focused: false)
                .padding(.leading, inset)
                .padding(.top, h * 0.8)
        }
    }

    // MARK: Immersive

    private func immersive(_ size: CGSize) -> some View {
        let w = size.width, h = size.height
        let inset = w * 0.07
        let tileWidth = w * 0.24
        let tileHeight = tileWidth * 9 / 16
        return ZStack(alignment: .topLeading) {
            artwork
                .frame(width: w, height: h)
                .overlay(
                    LinearGradient(
                        stops: [
                            .init(color: HomeLayoutPreviewColors.page.opacity(0.55), location: 0),
                            .init(color: .clear, location: 0.35),
                            .init(color: HomeLayoutPreviewColors.page.opacity(0.75), location: 0.62),
                            .init(color: HomeLayoutPreviewColors.page.opacity(0.95), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            VStack(alignment: .leading, spacing: h * 0.035) {
                wordmark(width: w * 0.3, height: h * 0.07)
                textLines(width: w * 0.42, lineHeight: h * 0.022, count: 3)
            }
            .padding(.leading, inset)
            .padding(.top, h * 0.14)
            tileRow(width: tileWidth, height: tileHeight, spacing: w * 0.025, focused: true)
                .padding(.leading, inset)
                .padding(.top, h * 0.62)
            // The next row, only just showing.
            tileRow(width: tileWidth, height: tileHeight, spacing: w * 0.025, focused: false)
                .opacity(0.7)
                .padding(.leading, inset)
                .padding(.top, h * 0.94)
        }
    }

    // MARK: Shared pieces

    private var artwork: some View {
        LinearGradient(
            colors: [HomeLayoutPreviewColors.artTop, HomeLayoutPreviewColors.artBottom],
            startPoint: .topTrailing,
            endPoint: .bottomLeading
        )
    }

    private func fade(from start: CGFloat) -> LinearGradient {
        LinearGradient(
            stops: [.init(color: .white, location: start), .init(color: .clear, location: 1)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func wordmark(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height * 0.3, style: .continuous)
            .fill(HomeLayoutPreviewColors.text)
            .frame(width: width, height: height)
    }

    private func textLines(width: CGFloat, lineHeight: CGFloat, count: Int) -> some View {
        VStack(alignment: .leading, spacing: lineHeight * 0.8) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(HomeLayoutPreviewColors.textMuted)
                    .frame(width: index == count - 1 ? width * 0.6 : width, height: lineHeight)
            }
        }
    }

    private func tileRow(width: CGFloat, height: CGFloat, spacing: CGFloat, focused: Bool) -> some View {
        HStack(spacing: spacing) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: height * 0.12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [HomeLayoutPreviewColors.tileTop, HomeLayoutPreviewColors.tileBottom],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: height * 0.12, style: .continuous)
                            .strokeBorder(
                                focused && index == 0 ? Color.white : HomeLayoutPreviewColors.tileBorder,
                                lineWidth: focused && index == 0 ? 2 : 1
                            )
                    )
                    .scaleEffect(focused && index == 0 ? 1.08 : 1)
                    .frame(width: width, height: height)
            }
        }
    }
}
#endif
