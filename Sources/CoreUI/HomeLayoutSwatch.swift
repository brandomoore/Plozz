#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Fixed, theme-independent colours for the Home layout preview. A picture of the
/// screen, so it never adapts to the applied theme.
private enum HomeLayoutPreviewColors {
    static let page = Color(red: 0.08, green: 0.08, blue: 0.10)
    /// Stand-in artwork: a cool sky over a dark foreground.
    static let artTop = Color(red: 0.55, green: 0.64, blue: 0.76)
    static let artMiddle = Color(red: 0.32, green: 0.40, blue: 0.52)
    static let artBottom = Color(red: 0.16, green: 0.20, blue: 0.27)
    static let wordmark = Color.white.opacity(0.95)
    static let text = Color.white.opacity(0.55)
    static let icon = Color.white.opacity(0.45)
    static let control = Color.white.opacity(0.18)
    static let tileTop = Color(white: 0.34)
    static let tileBottom = Color(white: 0.24)
}

/// A drawing of Home in one ``HeroStyle``, laid out in the TV's own 1920 × 1080
/// points and scaled to fit, so every piece sits where it does on screen.
///
/// - `.carousel` ("Spotlight"): full-screen art, the wordmark, details, Play and
///   the round actions low on the left, paging dots, and Continue Watching
///   peeking at the bottom.
/// - `.followsFocus` ("Immersive"): the art fitted above the rows on the right,
///   fading left into the page; the title top left with no buttons; one row
///   pinned low with its focused card ringed, and the next row just peeking.
public struct HomeLayoutSwatch: View {
    private let style: HeroStyle
    private let cornerRadius: CGFloat

    public init(style: HeroStyle, cornerRadius: CGFloat = 16) {
        self.style = style
        self.cornerRadius = cornerRadius
    }

    private static let screen = CGSize(width: 1920, height: 1080)

    public var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / Self.screen.width, geo.size.height / Self.screen.height)
            ZStack(alignment: .topLeading) {
                HomeLayoutPreviewColors.page
                switch style {
                case .carousel: spotlight
                case .followsFocus: immersive
                }
                rail
            }
            .frame(width: Self.screen.width, height: Self.screen.height, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: Self.screen.width * scale, height: Self.screen.height * scale, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color(white: 0.5).opacity(0.35), lineWidth: 1)
            )
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityHidden(true)
    }

    // MARK: Spotlight

    private var spotlight: some View {
        ZStack(alignment: .topLeading) {
            art
                .frame(width: 1920, height: 1080)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .white, location: 0.55),
                            .init(color: .white.opacity(0.6), location: 0.72),
                            .init(color: .white.opacity(0.2), location: 0.86),
                            .init(color: .clear, location: 0.98),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            block(144, 608, 500, 48, wordmark: true)
            block(144, 686, 360, 22)
            block(144, 732, 280, 18)
            // Play, then the round Watchlist, More Info and Next actions.
            Capsule().fill(Color.white).frame(width: 168, height: 74).offset(x: 140, y: 782)
            ForEach(0..<3, id: \.self) { index in
                Circle().fill(HomeLayoutPreviewColors.control)
                    .frame(width: 66, height: 66)
                    .offset(x: 328 + CGFloat(index) * 94, y: 786)
            }
            // Paging dots, centred.
            HStack(spacing: 14) {
                Capsule().fill(HomeLayoutPreviewColors.wordmark).frame(width: 34, height: 10)
                ForEach(0..<5, id: \.self) { _ in
                    Circle().fill(HomeLayoutPreviewColors.icon).frame(width: 10, height: 10)
                }
            }
            .frame(width: 1920)
            .offset(y: 904)
            block(144, 954, 250, 30)
            cards(y: 1032, height: 220)
        }
    }

    // MARK: Immersive

    private var immersive: some View {
        ZStack(alignment: .topLeading) {
            // Fitted to the space above the rows at a backdrop's shape, anchored
            // right, fading left into the page and out before the row.
            art
                .frame(width: 780, height: 440)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white.opacity(0.4), location: 0.26),
                            .init(color: .white, location: 0.52),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .mask(
                        LinearGradient(
                            stops: [.init(color: .white, location: 0.5), .init(color: .clear, location: 1)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                )
                .offset(x: 1140)
            block(144, 160, 420, 96, wordmark: true)
            block(144, 282, 300, 22)
            block(144, 326, 640, 18)
            block(144, 358, 480, 18)
            block(144, 560, 280, 30)
            cards(y: 640, height: 270, focusedFirst: true)
            block(144, 976, 200, 30)
            cards(y: 1046, height: 270)
        }
    }

    // MARK: Shared

    /// A stand-in picture — sky, sun and two ridges — so the art reads as a
    /// picture at any size rather than as a wash of colour.
    private var art: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: [HomeLayoutPreviewColors.artTop, HomeLayoutPreviewColors.artMiddle],
                    startPoint: .top,
                    endPoint: .bottom
                )
                Circle()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: w * 0.09, height: w * 0.09)
                    .offset(x: w * 0.72, y: h * 0.16)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h * 0.74))
                    path.addLine(to: CGPoint(x: w * 0.3, y: h * 0.4))
                    path.addLine(to: CGPoint(x: w * 0.52, y: h * 0.66))
                    path.addLine(to: CGPoint(x: w * 0.78, y: h * 0.34))
                    path.addLine(to: CGPoint(x: w, y: h * 0.58))
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.addLine(to: CGPoint(x: 0, y: h))
                    path.closeSubpath()
                }
                .fill(HomeLayoutPreviewColors.artMiddle.opacity(0.9))
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h * 0.86))
                    path.addLine(to: CGPoint(x: w * 0.22, y: h * 0.66))
                    path.addLine(to: CGPoint(x: w * 0.46, y: h * 0.84))
                    path.addLine(to: CGPoint(x: w * 0.66, y: h * 0.62))
                    path.addLine(to: CGPoint(x: w, y: h * 0.8))
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.addLine(to: CGPoint(x: 0, y: h))
                    path.closeSubpath()
                }
                .fill(HomeLayoutPreviewColors.artBottom)
            }
        }
    }

    /// Plozz's rail: the profile, then its column of destination icons, Home lit.
    private var rail: some View {
        ZStack(alignment: .topLeading) {
            Circle().fill(HomeLayoutPreviewColors.wordmark).frame(width: 40, height: 40).offset(x: 40, y: 98)
            ForEach(0..<10, id: \.self) { index in
                let y = 196 + CGFloat(index) * 78
                if index == 1 {
                    Circle().fill(HomeLayoutPreviewColors.control).frame(width: 62, height: 62).offset(x: 29, y: y - 17)
                }
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(index == 1 ? HomeLayoutPreviewColors.wordmark : HomeLayoutPreviewColors.icon)
                    .frame(width: 28, height: 28)
                    .offset(x: 46, y: y)
            }
        }
    }

    /// A text stand-in: a wordmark or a line of copy at screen coordinates.
    private func block(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, wordmark: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: height * (wordmark ? 0.22 : 0.5), style: .continuous)
            .fill(wordmark ? HomeLayoutPreviewColors.wordmark : HomeLayoutPreviewColors.text)
            .frame(width: width, height: height)
            .offset(x: x, y: y)
    }

    /// Continue Watching's landscape cards along a row, running off the right edge.
    private func cards(y: CGFloat, height: CGFloat, focusedFirst: Bool = false) -> some View {
        let width = height * 16 / 9
        return ZStack(alignment: .topLeading) {
            ForEach(0..<4, id: \.self) { index in
                let focused = focusedFirst && index == 0
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [HomeLayoutPreviewColors.tileTop, HomeLayoutPreviewColors.tileBottom],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(focused ? Color.white : .clear, lineWidth: 8)
                    )
                    .frame(width: width, height: height)
                    .scaleEffect(focused ? 1.06 : 1)
                    .offset(x: 150 + CGFloat(index) * (width + 44), y: y)
            }
        }
    }
}
#endif
