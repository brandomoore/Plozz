#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Fixed, theme-independent colours for the Home layout preview, matching the
/// navigation-style swatch so the two pickers read as one set.
private enum HomeLayoutPreviewColors {
    static let bgTop = Color(red: 0.17, green: 0.17, blue: 0.19)
    static let bgBottom = Color(red: 0.10, green: 0.10, blue: 0.12)
    /// The artwork area: the hero panel in Spotlight, the whole screen in Immersive.
    static let art = Color(red: 0.28, green: 0.28, blue: 0.32)
    static let artBorder = Color.white.opacity(0.16)
    static let itemIdle = Color.white.opacity(0.34)
    static let tileTop = Color(white: 0.30)
    static let tileBottom = Color(white: 0.22)
    static let tileBorder = Color.white.opacity(0.10)
}

/// A tiny mock of Home in one ``HeroStyle``, drawn in the navigation swatch's
/// style: a padded window, grey stand-ins, brand blue for what's active.
/// - `.carousel` ("Spotlight"): a hero panel with a Play button, and the rows
///   beneath it.
/// - `.followsFocus` ("Immersive"): the artwork fills the window, the title sits
///   top left with no buttons, and the focused card is in a row over the artwork.
public struct HomeLayoutSwatch: View {
    private let style: HeroStyle
    private let cornerRadius: CGFloat

    public init(style: HeroStyle, cornerRadius: CGFloat = 16) {
        self.style = style
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let pad = min(w, h) * 0.10
            let availW = max(0, w - pad * 2)
            let availH = max(0, h - pad * 2)

            Group {
                switch style {
                case .carousel: spotlight(availW: availW, availH: availH)
                case .followsFocus: immersive(availW: availW, availH: availH)
                }
            }
            .frame(width: availW, height: availH, alignment: .topLeading)
            .padding(pad)
            .frame(width: w, height: h)
            .background(
                LinearGradient(
                    colors: [HomeLayoutPreviewColors.bgTop, HomeLayoutPreviewColors.bgBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color(white: 0.5).opacity(0.35), lineWidth: 1)
        )
        .accessibilityHidden(true)
    }

    // MARK: Spotlight

    private func spotlight(availW: CGFloat, availH: CGFloat) -> some View {
        let gap = availH * 0.08
        let panelHeight = availH * 0.58
        let line = lineThickness(availH)
        return VStack(alignment: .leading, spacing: gap) {
            artPanel
                .frame(width: availW, height: panelHeight)
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: line * 1.2) {
                        pill(width: availW * 0.32, thickness: line)
                        pill(width: availW * 0.2, thickness: line)
                        HStack(spacing: line * 1.2) {
                            Capsule(style: .continuous)
                                .fill(ThemePalette.brandBlue)
                                .frame(width: availW * 0.16, height: line * 2)
                            Capsule(style: .continuous)
                                .fill(HomeLayoutPreviewColors.itemIdle)
                                .frame(width: line * 2, height: line * 2)
                        }
                        .padding(.top, line * 0.6)
                    }
                    .padding(line * 2)
                }
            tileRow(availW: availW, focused: false)
        }
    }

    // MARK: Immersive

    private func immersive(availW: CGFloat, availH: CGFloat) -> some View {
        let line = lineThickness(availH)
        let inset = line * 2
        return artPanel
            .frame(width: availW, height: availH)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: line * 1.2) {
                    pill(width: availW * 0.32, thickness: line)
                    pill(width: availW * 0.44, thickness: line * 0.7)
                    pill(width: availW * 0.3, thickness: line * 0.7)
                }
                .padding(inset)
            }
            .overlay(alignment: .bottomLeading) {
                tileRow(availW: availW - inset * 2, focused: true)
                    .padding(inset)
            }
    }

    // MARK: Shared pieces

    private func lineThickness(_ availH: CGFloat) -> CGFloat { max(3, availH * 0.05) }

    private var artPanel: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(HomeLayoutPreviewColors.art)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(HomeLayoutPreviewColors.artBorder, lineWidth: 1)
            )
    }

    private func pill(width: CGFloat, thickness: CGFloat) -> some View {
        Capsule(style: .continuous)
            .fill(HomeLayoutPreviewColors.itemIdle)
            .frame(width: width, height: thickness)
    }

    /// Three landscape cards filling `availW`. In Immersive the first is focused.
    private func tileRow(availW: CGFloat, focused: Bool) -> some View {
        let gap = availW * 0.05
        let width = (availW - gap * 2) / 3
        let height = width * 9 / 16
        let corner = width * 0.1
        return HStack(spacing: gap) {
            ForEach(0..<3, id: \.self) { index in
                let isFocused = focused && index == 0
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [HomeLayoutPreviewColors.tileTop, HomeLayoutPreviewColors.tileBottom],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .strokeBorder(
                                isFocused ? ThemePalette.brandBlue : HomeLayoutPreviewColors.tileBorder,
                                lineWidth: isFocused ? 2 : 1
                            )
                    )
                    .frame(width: width, height: height)
            }
        }
    }
}
#endif
