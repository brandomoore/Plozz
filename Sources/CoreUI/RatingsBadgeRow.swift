#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// A horizontal row of external rating badges (IMDb, Rotten Tomatoes, …) for
/// the item detail screen, sized to sit inline beside the year/runtime facts.
/// Renders nothing when there are no ratings.
public struct RatingsBadgeRow: View {
    private let ratings: [ExternalRating]
    private let familyGuidanceAge: Double?
    @Environment(\.metadataTextScale) private var textScale
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    public init(ratings: [ExternalRating], familyGuidanceAge: Double? = nil) {
        self.ratings = ratings
        self.familyGuidanceAge = familyGuidanceAge
    }

    public var body: some View {
        if !ratings.isEmpty || familyGuidanceAge != nil {
            WrappingHStackLayout(
                alignment: alignment,
                spacing: MetadataBadgeSpacing.betweenRatings * textScale,
                lineSpacing: 8 * textScale
            ) {
                if let familyGuidanceAge {
                    FamilyGuidanceAgeBadge(age: familyGuidanceAge)
                }
                ForEach(ratings) { rating in
                    RatingBadge(rating: rating)
                }
            }
        }
    }

    private var alignment: WrappingHStackLayout.RowAlignment {
        #if os(iOS)
        return horizontalSizeClass == .compact ? .center : .leading
        #else
        return .leading
        #endif
    }
}

/// An age recommendation, deliberately separate from a review score or certification.
public struct FamilyGuidanceAgeBadge: View {
    private let age: Double
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.mediaBadgeScale) private var containerScale
    @Environment(\.metadataTextScale) private var textScale
    @ScaledMetric(relativeTo: .subheadline) private var mobileScale: CGFloat = 1

    public init(age: Double) {
        self.age = age
    }

    public var body: some View {
        HStack(spacing: iconToAgeSpacing) {
            FamilyGuidanceIcon(size: iconSize)
            Text(verbatim: age.formatted(.number.locale(locale).precision(.fractionLength(0...1))) + "+")
                .font(valueFont)
                .monospacedDigit()
                .plozzForeground(.primary)
        }
        .fixedSize(horizontal: true, vertical: false)
        .layoutValue(
            key: WrappingHStackLayout.AdjacentSpacing.self,
            value: MetadataBadgeSpacing.ratingGap(for: dynamicTypeSize) * containerScale * textScale
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Common Sense Media, recommended age \(age, format: .number.precision(.fractionLength(0...1))) and older")
        .accessibilityIdentifier("family-guidance-age-badge")
    }

    private var iconToAgeSpacing: CGFloat {
        #if os(tvOS)
        // Compensate the artwork's trailing inset without resizing the mark.
        -textScale
        #else
        MetadataBadgeSpacing.iconToValue * badgeScale
        #endif
    }

    private var iconSize: CGFloat {
        #if os(iOS)
        24 * badgeScale
        #else
        32 * textScale
        #endif
    }

    private var badgeScale: CGFloat {
        #if os(iOS)
        mobileScale * textScale
        #else
        textScale
        #endif
    }

    private var valueFont: Font {
        #if os(iOS)
        textScale == 1 ? .subheadline.weight(.medium) : .system(size: 15 * badgeScale, weight: .medium)
        #else
        .system(size: 23 * textScale, weight: .medium)
        #endif
    }
}

/// A single source's rating: a compact branded icon (a filled star for
/// user/community scores, the IMDb / TMDB logo chips, a tomato/popcorn for
/// Rotten Tomatoes, or a coloured Metacritic chip) beside the formatted score.
/// The score itself is rendered in one neutral, uniform-weight style so the row
/// reads as a single line of facts; only the icons carry brand colour.
public struct RatingBadge: View {
    private let rating: ExternalRating
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.mediaBadgeScale) private var containerScale
    @Environment(\.metadataTextScale) private var textScale
    @ScaledMetric(relativeTo: .subheadline) private var mobileScale: CGFloat = 1
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// One shared type scale + weight for every score, matching the adjacent
    /// year/runtime metadata line so the whole bottom row reads consistently.
    private var valueFont: Font {
        #if os(iOS)
        return textScale == 1 ? .subheadline.weight(.medium) : .system(size: 15 * badgeScale, weight: .medium)
        #else
        return .system(size: 23 * textScale, weight: .medium)
        #endif
    }

    private var iconSize: CGFloat {
        #if os(iOS)
        return horizontalSizeClass == .compact ? 18 : 20
        #else
        return 24
        #endif
    }

    private var badgeScale: CGFloat {
        #if os(iOS)
        mobileScale * textScale
        #else
        textScale
        #endif
    }

    public init(rating: ExternalRating) {
        self.rating = rating
    }

    public var body: some View {
        HStack(spacing: MetadataBadgeSpacing.iconToValue * badgeScale) {
            icon
            Text(rating.displayValue)
                .font(valueFont)
                .monospacedDigit()
                // Full strength, like the tile variant below and like the
                // certificate and capability chips this sits beside. At
                // `.secondary` the score read as disabled next to them.
                .plozzForeground(.primary)
        }
        // Preserve each icon + score as one indivisible badge. Without this,
        // SwiftUI compresses the numeric text first when several ratings share a
        // row, producing values such as "8…".
        .fixedSize(horizontal: true, vertical: false)
        .layoutValue(
            key: WrappingHStackLayout.AdjacentSpacing.self,
            value: MetadataBadgeSpacing.ratingGap(for: dynamicTypeSize) * containerScale * textScale
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(rating.displayName) rating \(rating.displayValue)")
    }

    @ViewBuilder
    private var icon: some View {
        RatingSourceIcon(rating: rating, size: iconSize * textScale)
    }
}

/// The branded icon for a rating source, extracted so both the inline
/// ``RatingBadge`` and the larger ``RatingTile`` render an identical logo (a
/// filled star for user/community scores, the IMDb / TMDB logo chips, a
/// tomato/popcorn for Rotten Tomatoes, or a coloured Metacritic chip). `size` is
/// the shared cap height the glyph is laid out against.
public struct RatingSourceIcon: View {
    private let rating: ExternalRating
    private let size: CGFloat
    @Environment(\.themePalette) private var palette

    public init(rating: ExternalRating, size: CGFloat) {
        self.rating = rating
        self.size = size
    }

    public var body: some View {
        if let display = rating.providerDisplay, rating.source != .tmdb {
            Text(verbatim: display.name)
                .font(.system(size: size * 0.65, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        } else {
            brandedIcon
        }
    }

    @ViewBuilder
    private var brandedIcon: some View {
        switch rating.source.icon {
        case .star:
            Image(systemName: "star.fill")
                .font(.system(size: size * 0.8, weight: .semibold))
                .foregroundStyle(Self.starGold)
        case .anilist:
            // AniList ships two lock-ups: the "A" is white on one and near-black
            // on the other, and only the blue bar is constant. Pick by the theme's
            // own luminance rather than the system colour scheme, because the tile
            // sits on the palette's surface — which a user can set independently of
            // the device appearance. tvOS focus keeps that surface (it deliberately
            // never inverts to a white plate), so the same choice holds focused.
            ratingArtwork(
                palette.isLight ? "AniListLogoOnLight" : "AniListLogoOnDark",
                aspect: 1.309
            )
        case .imdb:
            Image("IMDbLogo", bundle: .module)
                .resizable()
                .scaledToFit()
                .frame(width: size * 1.83, height: size * 0.92)
        case .tmdb:
            Image("TMDBPrimaryShortBlue", bundle: .module)
                .resizable()
                .scaledToFit()
                .frame(width: size * 1.75, height: size * 0.75)
        case .tomato:
            // The Tomatometer's two states. `freshness` already applies the
            // standard 60% cutoff (and defers to an explicit verdict when the
            // source supplied one) — it just had nothing rendering it until now,
            // so a 24% film wore the same cheerful tomato as a 98% one.
            rating.freshness == .rotten
                ? ratingArtwork("RatingTomatoRotten", aspect: 1.029)
                : ratingArtwork("RatingTomatoFresh", aspect: 0.967)
        case .popcorn:
            // The audience pair carries white inside the tub, and the light
            // theme's card surface is pure white — so unlike the solid-colour
            // tomato and splat, these need the light/dark variant treatment.
            rating.freshness == .rotten
                ? ratingArtwork(popcornAsset(rotten: true), aspect: 1.331)
                : ratingArtwork(popcornAsset(rotten: false), aspect: 0.754)
        case .metacritic:
            metacriticChip
        case .critic:
            Image(systemName: "quote.bubble.fill")
                .font(.system(size: size * 0.78, weight: .semibold))
                .plozzForeground(.secondary)
        }
    }

    /// A branded rating mark, sized so every source carries the same optical
    /// weight beside its score.
    ///
    /// Height alone is the wrong yardstick here: these marks run from a tall
    /// narrow tub (0.75) to a wide tipped one (1.33), and matching their heights
    /// would leave the tall one towering over the wide one. Holding the geometric
    /// mean constant instead keeps them looking the same size whatever their
    /// proportions.
    ///
    /// Each asset's canvas is cropped to its artwork, so the frame *is* the mark.
    /// A square frame around a centred mark keeps the canvas margin as dead space
    /// between the icon and its number — which is why the tomato and popcorn used
    /// to sit noticeably further from their scores than the tight-cropped IMDb and
    /// TMDB lock-ups did.
    private func ratingArtwork(_ name: String, aspect: CGFloat) -> some View {
        let mass = size * 0.95
        return Image(name, bundle: .module)
            .resizable()
            .scaledToFit()
            .frame(width: mass * sqrt(aspect), height: mass / sqrt(aspect))
    }

    private func popcornAsset(rotten: Bool) -> String {
        let base = rotten ? "RatingPopcornRotten" : "RatingPopcornFresh"
        return palette.isLight ? base + "OnLight" : base
    }

    private var metacriticChip: some View {
        Text(String(Int(rating.value.rounded())))
            .font(.system(size: size * 0.75, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: size * 1.42, height: size * 1.42)
            .background(metacriticColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var metacriticColor: Color {
        let score = rating.value
        if score >= 61 { return Self.metacriticGreen }
        if score >= 40 { return Self.metacriticYellow }
        return Self.metacriticRed
    }

    static let starGold = Color(red: 0.96, green: 0.77, blue: 0.13)
    static let metacriticGreen = Color(red: 0.40, green: 0.73, blue: 0.27)
    static let metacriticYellow = Color(red: 1.0, green: 0.80, blue: 0.0)
    static let metacriticRed = Color(red: 0.98, green: 0.27, blue: 0.20)
}

/// A score and its source, optionally content-sized for a compact detail strip.
public struct RatingTile: View {
    private let rating: ExternalRating
    private let compact: Bool

    public init(rating: ExternalRating, compact: Bool = false) {
        self.rating = rating
        self.compact = compact
    }

    public var body: some View {
        RatingValue(rating: rating, compact: compact)
            .frame(maxHeight: compact ? nil : .infinity)
            .padding(.vertical, compact ? PlozzTheme.Spacing.small : DetailInformationLayout.cellPadding)
            .padding(.horizontal, compact ? PlozzTheme.Spacing.medium : DetailInformationLayout.cellPadding)
            .plozzFocusableCard(cornerRadius: DetailInformationLayout.cornerRadius)
    }
}

/// Shared score geometry inside a rating tile.
struct RatingValue: View {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    private let rating: ExternalRating
    private let compact: Bool

    init(rating: ExternalRating, compact: Bool = false) {
        self.rating = rating
        self.compact = compact
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: valueSpacing) {
                RatingSourceIcon(rating: rating, size: iconSize)
                    .frame(height: iconRowHeight)
                Text(rating.displayValue)
                    .font(valueFont)
                    .plozzForeground(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            subtitle
                .frame(height: subtitleHeight)
        }
        .frame(maxWidth: compact ? nil : .infinity)
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(rating.displayName) \(rating.displayValue)"))
    }

    @ViewBuilder
    private var subtitle: some View {
        Text(subtitleText)
            .font(subtitleFont)
            .plozzForeground(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    /// The rating's **source** — AniList / IMDb / TMDB / Community / Critics /
    /// Audience — so you can tell each score apart even when two share a star icon
    /// (e.g. AniList vs a server's generic Community score). Vote count appended
    /// when the source reports one.
    private var subtitleText: String {
        if let count = rating.ratingCountText {
            return "\(rating.shortLabel) · \(count)"
        }
        return rating.shortLabel
    }

    private var iconSize: CGFloat {
        if compact { return 24 }
        #if os(tvOS)
        return 32
        #else
        return horizontalSizeClass == .compact ? 24 : 28
        #endif
    }

    private var iconRowHeight: CGFloat { iconSize * 1.5 }

    private var valueFont: Font {
        #if os(tvOS)
        return .system(size: compact ? 24 : 28, weight: .semibold)
        #else
        return .title2.weight(.semibold)
        #endif
    }

    private var subtitleFontSize: CGFloat {
        #if os(tvOS)
        return 18
        #else
        return horizontalSizeClass == .compact ? 12 : 14
        #endif
    }

    private var subtitleRowHeight: CGFloat { subtitleFontSize * 1.4 }

    private var subtitleHeight: CGFloat? {
        #if os(tvOS)
        compact ? nil : subtitleRowHeight
        #else
        nil
        #endif
    }

    private var subtitleFont: Font {
        #if os(iOS)
        return .caption.weight(.medium)
        #else
        return .system(size: subtitleFontSize, weight: .medium)
        #endif
    }

    private var valueSpacing: CGFloat {
        iconSize * 0.5
    }
}

#endif
