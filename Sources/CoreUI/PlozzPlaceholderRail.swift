import SwiftUI

/// How many placeholder cards actually fit a rail.
///
/// A fixed count either over-renders on a phone (eight cards laid out for a
/// tablet, most of them clipped) or leaves a gap on a wide screen. The count is
/// geometry, not preference, so every rail derives it the same way.
public enum PlozzPlaceholderCapacity {
    public static func cards(
        forWidth width: CGFloat,
        cardWidth: CGFloat,
        spacing: CGFloat
    ) -> Int {
        guard width.isFinite, width > 0, cardWidth.isFinite, cardWidth > 0 else { return 0 }
        let pitch = cardWidth + max(0, spacing)
        return max(1, Int(ceil((width + max(0, spacing)) / pitch)))
    }
}

/// A rail that reserves its geometry with exactly as many placeholder cards as the
/// viewport can show.
///
/// This is the count-driven sibling of `PlozzReservedPlaceholder`, for surfaces that
/// render a *row* of cards (Home rows, Discover, related titles, episode rails).
/// It exists because those surfaces each had their own placeholder count — a
/// hardcoded 6 here, a hardcoded 8 there — which over-rendered on narrow screens
/// and under-filled on wide ones.
///
/// ```swift
/// PlozzPlaceholderRail(isPending: loading, revealsPlaceholder: true, cardWidth: w, spacing: gap) { _ in
///     PosterCardSkeleton()
/// } content: {
///     ForEach(items) { ItemCard($0) }
/// }
/// ```
public struct PlozzPlaceholderRail<Card: View, Content: View>: View {
    private let isPending: Bool
    private let revealsPlaceholder: Bool
    private let cardWidth: CGFloat
    private let spacing: CGFloat
    private let horizontalInset: CGFloat
    private let card: (Int) -> Card
    private let content: Content

    public init(
        isPending: Bool,
        revealsPlaceholder: Bool = true,
        cardWidth: CGFloat,
        spacing: CGFloat,
        horizontalInset: CGFloat = 0,
        @ViewBuilder card: @escaping (Int) -> Card,
        @ViewBuilder content: () -> Content
    ) {
        self.isPending = isPending
        self.revealsPlaceholder = revealsPlaceholder
        self.cardWidth = cardWidth
        self.spacing = spacing
        self.horizontalInset = horizontalInset
        self.card = card
        self.content = content()
    }

    public var body: some View {
        if isPending {
            GeometryReader { proxy in
                let count = PlozzPlaceholderCapacity.cards(
                    forWidth: proxy.size.width - horizontalInset * 2,
                    cardWidth: cardWidth,
                    spacing: spacing
                )
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(0..<count, id: \.self) { index in
                        card(index)
                    }
                }
                .padding(.horizontal, horizontalInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The rail is a placeholder, not content: it must not take focus, be read
            // out, or scroll. Height comes from the cards themselves, which is the
            // reservation this exists for.
            .opacity(revealsPlaceholder ? 1 : 0)
            .accessibilityHidden(!revealsPlaceholder)
            .allowsHitTesting(false)
        } else {
            content
        }
    }
}
