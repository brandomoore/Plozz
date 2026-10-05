#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// The neutral stand-in for media artwork that is missing or failed to load.
///
/// One definition so a card without a poster looks the same on tvOS, iOS and
/// iPadOS. Before this existed each surface rolled its own: the tvOS cards drew
/// a glyph *and* repeated the title, while the iOS episode rows drew a bare
/// filled rectangle with no glyph at all.
///
/// Normally text-free when a caption names the item. Surfaces that hide their
/// captions supply a spoiler-safe title so missing artwork remains identifiable
/// without changing the card's footprint.
///
/// Marked decorative so VoiceOver reads the card's real label instead of
/// announcing an image.
public struct MediaArtworkPlaceholder: View {
    public enum Symbol: String, Sendable {
        case playback = "play.rectangle"
        case media = "rectangle.dashed"

        public init(for item: MediaItem) {
            self = item.scheduledAirDate != nil || TitleClassifier.isNotOwnedForBadge(item)
                ? .media : .playback
        }
    }

    private let tint: Color
    private let glyphSize: CGFloat
    private let symbol: Symbol
    private let cornerRadius: CGFloat
    private let title: Text?
    private let titleColor: Color

    /// - Parameters:
    ///   - tint: colour the wash and glyph derive from. Defaults to `.secondary`
    ///     so the placeholder tracks the theme; pass an explicit colour where the
    ///     backdrop isn't theme-controlled (e.g. over video).
    ///   - glyphSize: point size of the glyph, so a small episode thumbnail
    ///     and a full poster stay visually proportionate.
    ///   - symbol: use `.media` when no playable content is represented. It
    ///     draws an empty dashed box, without a fill or center glyph.
    ///   - cornerRadius: matches the enclosing artwork's clipping radius.
    ///   - title: identifying text only when no visible caption names the item.
    public init(
        tint: Color = .secondary,
        glyphSize: CGFloat = 40,
        symbol: Symbol = .playback,
        cornerRadius: CGFloat = 6,
        title: Text? = nil,
        titleColor: Color = .primary
    ) {
        self.tint = tint
        self.glyphSize = glyphSize
        self.symbol = symbol
        self.cornerRadius = cornerRadius
        self.title = title
        self.titleColor = titleColor
    }

    public var body: some View {
        ZStack {
            if symbol == .media {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        tint.opacity(0.55),
                        style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [4, 3])
                    )
            } else {
                tint.opacity(0.08)
            }
            ArtworkPlaceholderContent(
                title: title, foreground: titleColor,
                symbol: Group {
                    if symbol != .media {
                        Image(systemName: symbol.rawValue)
                            .font(.system(size: glyphSize))
                            .foregroundStyle(tint)
                    }
                }
            )
        }
        .accessibilityHidden(true)
    }
}

struct ArtworkPlaceholderContent<Symbol: View>: View {
    let title: Text?
    let foreground: Color
    let symbol: Symbol
    @Environment(\.plozzMetrics) private var metrics

    var body: some View {
        if let title {
            ViewThatFits(in: .vertical) {
                VStack(spacing: 8) {
                    symbol
                    label(title)
                }
                .fixedSize(horizontal: false, vertical: true)
                label(title)
            }
            .padding(12)
        } else {
            symbol
        }
    }

    private func label(_ title: Text) -> some View {
        title
            .font(.system(size: metrics.cardTitleFontSize, weight: .semibold))
            .foregroundStyle(foreground)
            .multilineTextAlignment(.center)
            .lineLimit(3)
    }
}
#endif
