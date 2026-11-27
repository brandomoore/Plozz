#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreNetworking
import CoreText
#if canImport(UIKit)
import UIKit
#endif

enum MetadataBadgeSpacing {
    static let betweenRatings: CGFloat = 14
    static let betweenBadges: CGFloat = 12
    static let iconToValue: CGFloat = 4

    static func textScale(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        #if canImport(UIKit)
        let traits = UITraitCollection(
            preferredContentSizeCategory: dynamicTypeSize.plozzContentSizeCategory
        )
        let standardTraits = UITraitCollection(preferredContentSizeCategory: .large)
        return UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits).pointSize
            / UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: standardTraits).pointSize
        #else
        return 1
        #endif
    }

    static func ratingGap(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        #if os(iOS)
        betweenRatings * textScale(for: dynamicTypeSize)
        #else
        betweenRatings
        #endif
    }
}

private struct MediaBadgeScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

private struct MetadataTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

private struct ContentRatingVisibilityKey: EnvironmentKey {
    static let defaultValue = ContentRatingSettingsStore.defaultShowsRatings
}

extension EnvironmentValues {
    public var plozzShowsContentRatings: Bool {
        get { self[ContentRatingVisibilityKey.self] }
        set { self[ContentRatingVisibilityKey.self] = newValue }
    }

    public var mediaBadgeScale: CGFloat {
        get { self[MediaBadgeScaleKey.self] }
        set { self[MediaBadgeScaleKey.self] = newValue }
    }

    /// Scales text and its badge artwork together, independently of compact badge styling.
    public var metadataTextScale: CGFloat {
        get { self[MetadataTextScaleKey.self] ?? 1 }
        set { self[MetadataTextScaleKey.self] = newValue }
    }

    fileprivate var mediaChipTextScale: CGFloat {
        #if os(tvOS)
        self[MetadataTextScaleKey.self] ?? MetadataBadgeSpacing.textScale(for: dynamicTypeSize)
        #else
        metadataTextScale
        #endif
    }
}

public struct MediaBadgeRow: View {
    @Environment(\.mediaBadgeScale) private var containerScale
    @Environment(\.mediaChipTextScale) private var textScale
    private var scale: CGFloat { containerScale * textScale }
    private let badges: [MediaBadge]

    public init(badges: [MediaBadge]) {
        self.badges = badges
    }

    public var body: some View {
        if !badges.isEmpty {
            WrappingHStackLayout(spacing: MetadataBadgeSpacing.betweenBadges * scale, lineSpacing: 8 * scale) {
                ForEach(badges) { MediaBadgeChip(badge: $0) }
            }
        }
    }
}

/// Compact capability marks that grow with the subheadline metadata beside them.
public struct MetadataMediaBadgeChip: View {
    private let badge: MediaBadge
    private let adjacentSpacing: CGFloat?
    #if !os(tvOS)
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #endif
    @Environment(\.mediaBadgeScale) private var containerScale
    @Environment(\.mediaChipTextScale) private var contentScale

    public init(badge: MediaBadge, adjacentSpacing: CGFloat? = nil) {
        self.badge = badge
        self.adjacentSpacing = adjacentSpacing
    }

    public var body: some View {
        MediaBadgeChip(
            badge: badge,
            adjacentSpacing: adjacentSpacing ?? MetadataBadgeSpacing.betweenBadges * containerScale * textScale
        )
            .environment(\.mediaBadgeScale, containerScale * compactScale)
            .environment(\.metadataTextScale, textScale)
    }

    private var compactScale: CGFloat {
        #if os(iOS)
        18 / (badge.style == .prominent ? 22 : 26)
        #else
        0.75
        #endif
    }

    private var textScale: CGFloat {
        #if os(tvOS)
        contentScale
        #else
        MetadataBadgeSpacing.textScale(for: dynamicTypeSize) * contentScale
        #endif
    }
}

/// Porcelain: filled resolution badges, tinted range capsules, and outlined audio.
public struct MediaBadgeChip: View {
    private let badge: MediaBadge
    private let adjacentSpacing: CGFloat?
    @Environment(\.themePalette) private var palette
    @Environment(\.mediaBadgeScale) private var containerScale
    @Environment(\.mediaChipTextScale) private var textScale
    private var scale: CGFloat { containerScale * textScale }
    @Environment(\.plozzShowsContentRatings) private var showsContentRatings
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    public init(badge: MediaBadge, adjacentSpacing: CGFloat? = nil) {
        self.badge = badge
        self.adjacentSpacing = adjacentSpacing
    }

    public var body: some View {
        if badge.style != .rating || showsContentRatings {
            visibleBadge
        }
    }

    private var visibleBadge: some View {
        Group {
            if badge.style == .rating {
                certificate
            } else if badge.style == .prominent {
                formatLabel
                    .foregroundStyle(palette.backgroundBase)
                    .padding(.horizontal, 6 * scale)
                    .frame(height: 22 * scale)
                    .background(palette.primaryText, in:
                        RoundedRectangle(cornerRadius: 6 * scale, style: .continuous))
            } else {
                outlinedFormat
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .layoutValue(
            key: WrappingHStackLayout.AdjacentSpacing.self,
            value: adjacentSpacing ?? MetadataBadgeSpacing.betweenBadges * scale
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: badge.accessibilityText))
    }

    private var formatLabel: some View {
        Text(verbatim: badge.compactDisplayLabel)
            .font(PorcelainBadgeFont.font(size: 15 * scale, weight: 650))
            .tracking(-0.2 * scale)
            .lineLimit(1)
            .environment(\.layoutDirection, .leftToRight)
    }

    private var outlinedFormat: some View {
        HStack(spacing: 0) {
            formatLabel
                .padding(.leading, 8 * scale)
                .padding(.trailing, (badge.detail?.isEmpty == false ? 4 : 8) * scale)
            if let detail = badge.detail, !detail.isEmpty {
                Text(verbatim: detail)
                    .font(PorcelainBadgeFont.font(size: 12.5 * scale, weight: 600))
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.leading, 4 * scale)
                    .padding(.trailing, 7 * scale)
                    .frame(height: 26 * scale)
                    .background(palette.primaryText.opacity(0.11))
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(palette.primaryText.opacity(0.28))
                            .frame(width: scale)
                    }
            }
        }
        .foregroundStyle(palette.primaryText)
        .frame(height: 26 * scale)
        .background(badge.isAudio ? Color.clear : palette.primaryText.opacity(0.15))
        .clipShape(Capsule())
        .overlay {
            Capsule().strokeBorder(palette.primaryText.opacity(0.72), lineWidth: scale)
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private var certificate: some View {
        let rating = ContentRatingPresentation(badge.label)
        return HStack(spacing: 4 * scale) {
            Text(verbatim: rating.label)
                #if os(tvOS)
                .font(.custom("Bungee-Regular", fixedSize: ratingFontSize * scale))
                #else
                .font(.custom("Bungee-Regular", size: ratingFontSize * scale))
                #endif
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 150 * scale)
            if rating.hasWarning {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: ratingFontSize * scale, weight: .semibold))
            }
        }
            .tracking(0.5 * scale)
            .padding(.horizontal, ratingHPadding * scale)
            .frame(height: ratingHeight * scale)
            .overlay {
                RoundedRectangle(cornerRadius: 6 * scale, style: .continuous)
                    .strokeBorder(lineWidth: ratingBorderWidth * scale)
                    .opacity(0.65)
            }
            .plozzForeground(.primary)
    }

    private var ratingFontSize: CGFloat {
        #if os(iOS)
        horizontalSizeClass == .compact ? 13 : 15
        #else
        18
        #endif
    }

    private var ratingHeight: CGFloat {
        #if os(iOS)
        horizontalSizeClass == .compact ? 28 : 32
        #else
        36
        #endif
    }

    private var ratingHPadding: CGFloat {
        #if os(iOS)
        horizontalSizeClass == .compact ? 8 : 9
        #else
        11
        #endif
    }

    private var ratingBorderWidth: CGFloat {
        #if os(iOS)
        2
        #else
        3
        #endif
    }
}

extension MediaBadge {
    var compactDisplayLabel: String {  // l10n:content - technical format/codec names and standard abbreviations
        switch label {
        case "Dolby Vision": "DV"
        case "Dolby Digital+": "DD+"
        case "Dolby Digital": "DD"
        case "Dolby TrueHD": "TrueHD"
        case "Dolby Atmos": "Atmos"
        default: label
        }
    }
}

@MainActor
enum PorcelainBadgeFont {
    private static let registered: Bool = {
        guard let url = Bundle.module.url(forResource: "Outfit", withExtension: "ttf") else {
            PlozzLog.app.error("Badge font resource is missing; using system typography.")
            return false
        }
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
        let code = error.map { CFErrorGetCode($0.takeRetainedValue()) }
        if code == CFIndex(CTFontManagerError.alreadyRegistered.rawValue) { return true }
        PlozzLog.app.error("Badge font registration failed; using system typography.")
        return false
    }()

    static func font(size: CGFloat, weight: CGFloat) -> Font {
        #if canImport(UIKit)
        Font(uiFont(size: size, weight: weight))
        #else
        .system(size: size, weight: .semibold)
        #endif
    }

    #if canImport(UIKit)
    static func uiFont(size: CGFloat, weight: CGFloat) -> UIFont {
        guard registered else { return .systemFont(ofSize: size, weight: .semibold) }
        let descriptor = UIFontDescriptor(name: "Outfit-Thin", size: size).addingAttributes([
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String):
                [NSNumber(value: 0x77676874): NSNumber(value: Double(weight))]
        ])
        return UIFont(descriptor: descriptor, size: size)
    }
    #endif
}
#endif
