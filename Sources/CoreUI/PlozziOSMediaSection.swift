#if os(iOS)
import CoreModels
import SwiftUI

public enum PlozziOSPageHeaderLayout {
    public static let actionDiameter: CGFloat = 44
    public static let profileInset: CGFloat = 2
    public static let horizontalInset: CGFloat = 20
    public static let actionSpacing: CGFloat = 12
}

public struct PlozziOSPageHeading: View {
    private let title: Text
    @Environment(\.themePalette) private var palette

    public init(_ title: Text) { self.title = title }

    public var body: some View {
        title
            .font(.largeTitle.bold())
            .foregroundStyle(palette.primaryText)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public struct PlozziOSPageHeader<Actions: View>: View {
    private let title: Text
    private let actions: Actions

    public init(_ title: Text, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.actions = actions()
    }

    public var body: some View {
        HStack(spacing: PlozziOSPageHeaderLayout.actionSpacing) {
            PlozziOSPageHeading(title)
            HStack(spacing: PlozziOSPageHeaderLayout.actionSpacing) { actions }.fixedSize()
        }
        .frame(minHeight: PlozziOSPageHeaderLayout.actionDiameter)
        .padding(.horizontal, PlozziOSPageHeaderLayout.horizontalInset)
    }
}

public extension View {
    func plozziOSPageAction(diameter: CGFloat = PlozziOSPageHeaderLayout.actionDiameter) -> some View {
        modifier(PlozziOSPageActionStyle(diameter: diameter))
    }
}

private struct PlozziOSPageActionStyle: ViewModifier {
    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    let diameter: CGFloat

    func body(content: Content) -> some View {
        let action = content
            .labelStyle(PlozziOSPageActionLabelStyle(diameter: diameter))
            .buttonStyle(.plain)
            .fixedSize()
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
        if #available(iOS 26.0, *), !reduceTransparency {
            action.glassEffect(.regular.interactive(), in: .circle)
        } else {
            action
                .plozzFrostedBackground(Circle())
                .plozzFrostedBorder(Circle())
        }
    }
}

private struct PlozziOSPageActionLabelStyle: LabelStyle {
    let diameter: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        Label(configuration)
            .labelStyle(.iconOnly)
            .font(.system(size: 20))
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
    }
}

public enum PlozziOSMediaRailLayout {
    public static let headingFont: Font = .title3.weight(.semibold)
    public static let sectionSpacing: CGFloat = 32
    public static let headingSpacing: CGFloat = 12
    public static let visibleSpacing: CGFloat = 12
    public static let shadowClearance: CGFloat = 10
    public static let desktopBrowseThreshold = 10

    public static func pageInset(
        for sizeClass: UserInterfaceSizeClass?, usesDesktopSizing: Bool = false
    ) -> CGFloat {
        usesDesktopSizing ? DesktopMediaRailLayout.pageInset : (sizeClass == .compact ? 22 : 36)
    }

    public static func sectionGap(metrics: PlozzMetrics) -> CGFloat {
        metrics.usesDesktopSizing ? metrics.rowSpacing : sectionSpacing
    }

    public static func visibleGap(metrics: PlozzMetrics) -> CGFloat {
        metrics.usesDesktopSizing ? metrics.cardSpacing : visibleSpacing
    }

    public static func artworkAlignedInset(_ pageInset: CGFloat, metrics: PlozzMetrics, cardStyle: CardStyle) -> CGFloat {
        pageInset - (cardStyle == .framed ? metrics.cardInset : metrics.borderlessCardSideMargin)
    }

    /// Exclude the card's invisible side margins from the visible artwork gap.
    public static func stackSpacing(
        metrics: PlozzMetrics, cardStyle: CardStyle,
        visibleSpacing: CGFloat? = nil
    ) -> CGFloat {
        let visibleSpacing = visibleSpacing ?? visibleGap(metrics: metrics)
        return switch cardStyle {
        case .framed:
            visibleSpacing
        case .borderless:
            max(0, visibleSpacing - metrics.borderlessCardSideMargin * 2)
        }
    }
}

public struct PlozziOSPosterGridLayout {
    public let columns: Int
    public let metrics: PlozzMetrics
    public let spacing: CGFloat

    public init(contentWidth: CGFloat, metrics: PlozzMetrics, cardStyle: CardStyle) {
        spacing = PlozziOSMediaRailLayout.stackSpacing(metrics: metrics, cardStyle: cardStyle)
        let slot = metrics.cardSlotWidth(for: .poster, cardStyle: cardStyle)
        let width = contentWidth > 0 ? contentWidth : slot
        columns = max(1, Int(floor((width + spacing) / (slot + spacing))))
        let margin = slot - metrics.posterWidth
        let artworkWidth = (width - CGFloat(columns - 1) * spacing) / CGFloat(columns) - margin
        self.metrics = metrics.sizingPosters(width: max(1, artworkWidth))
    }
}

public struct PlozziOSMediaSection<Content: View>: View {
    @Environment(\.homeRowEditAction) private var editAction
    @Environment(\.themePalette) private var palette
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.plozzMetrics) private var metrics
    let title: Text
    var horizontalInset: CGFloat?
    var artworkInset: CGFloat = 0
    var reservesBrowseSpace = false
    var reservesRefreshStatusSpace = false
    var onSeeAll: (() -> Void)? = nil
    var onBrowse: (() -> Void)? = nil
    var onHeadingTap: (() -> Void)? = nil
    @ViewBuilder var content: Content

    public init(
        title: Text, horizontalInset: CGFloat? = nil, artworkInset: CGFloat = 0,
        reservesBrowseSpace: Bool = false, reservesRefreshStatusSpace: Bool = false,
        onSeeAll: (() -> Void)? = nil,
        onBrowse: (() -> Void)? = nil, onHeadingTap: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.horizontalInset = horizontalInset
        self.artworkInset = artworkInset
        self.reservesBrowseSpace = reservesBrowseSpace
        self.reservesRefreshStatusSpace = reservesRefreshStatusSpace
        self.onSeeAll = onSeeAll
        self.onBrowse = onBrowse
        self.onHeadingTap = onHeadingTap
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: PlozziOSMediaRailLayout.headingSpacing) {
            HStack {
                Group {
                    if onBrowse != nil || reservesBrowseSpace || editAction != nil {
                        BrowseRowHeading(title: title, action: onBrowse)
                    }
                    else if let onHeadingTap { title.onTapGesture(perform: onHeadingTap) }
                    else { title }
                }
                    .font(PlozziOSMediaRailLayout.headingFont)
                    // Resolve from the active theme, not the hosting view's
                    // inherited primary colour: the offscreen Mac snapshot hosted
                    // this section with a light primary while the rest of the page
                    // was dark, leaving the heading nearly invisible.
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                MediaRowRefreshIndicator()
                if onBrowse == nil, let onSeeAll {
                    Spacer()
                    Button("See all", action: onSeeAll)
                        .font(.subheadline)
                }
            }
                .frame(minHeight: reservesRefreshStatusSpace ? MediaRowRefreshIndicator.size : nil)
                .padding(.horizontal, horizontalInset ?? PlozziOSMediaRailLayout.pageInset(
                    for: sizeClass, usesDesktopSizing: metrics.usesDesktopSizing
                ))
            content
                .environment(\.homeRowEditAction, nil)
                .environment(\.mediaRowRefreshStatus, nil)
                .padding(.vertical, -artworkInset)
        }
    }
}

public extension View {
    func plozziOSMediaRailClearance() -> some View {
        // Preserve shadow/press-effect room without inflating visible section gaps.
        contentMargins(.vertical, PlozziOSMediaRailLayout.shadowClearance, for: .scrollContent)
            .padding(.vertical, -PlozziOSMediaRailLayout.shadowClearance)
            .scrollIndicators(.hidden)
    }
}

private struct PlozziOSHomeViewportWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

public extension EnvironmentValues {
    var plozziOSHomeViewportWidth: CGFloat {
        get { self[PlozziOSHomeViewportWidthKey.self] }
        set { self[PlozziOSHomeViewportWidthKey.self] = newValue }
    }
}

public struct PlozziOSHomeRailLayout<Content: View>: View {
    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.plozzCardStyle) private var cardStyle
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.plozziOSHomeViewportWidth) private var viewportWidth
    @State private var width: CGFloat = 0
    private let isContinueWatching: Bool
    private let content: (PlozzMetrics) -> Content

    public init(isContinueWatching: Bool = false, @ViewBuilder content: @escaping (PlozzMetrics) -> Content) {
        self.isContinueWatching = isContinueWatching
        self.content = content
    }

    public var body: some View {
        let resolved = Self.posterMetrics(
            in: viewportWidth > 0 ? viewportWidth : width,
            inset: PlozziOSMediaRailLayout.pageInset(for: sizeClass),
            metrics: metrics, cardStyle: cardStyle,
            isContinueWatching: isContinueWatching && UIDevice.current.userInterfaceIdiom == .pad
        )
        content(resolved)
            .environment(\.plozzMetrics, resolved)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    public static func posterMetrics(
        in width: CGFloat, inset: CGFloat, metrics: PlozzMetrics, cardStyle: CardStyle,
        isContinueWatching: Bool = false
    ) -> PlozzMetrics {
        if metrics.usesDesktopSizing {
            return metrics.fittingDesktopRail(in: width, cardStyle: cardStyle)
        }
        guard width > 0 else { return metrics }
        let gap = PlozziOSMediaRailLayout.visibleSpacing + (cardStyle == .framed ? 2 * metrics.cardInset : 0)
        // Phones show complete pictures plus a 28% preview; wider windows add columns.
        let count = max(width < 375 ? 2 : 3, floor((width - inset + gap) / 164))
        let standardWidth = (width - inset - count * gap) / (count + 0.28)
        let artworkWidth = max(44, standardWidth * CGFloat(metrics.density.scale))
        let resolved = metrics.scalingPosters(by: artworkWidth / metrics.posterWidth)
        guard isContinueWatching else { return resolved }
        let frameInset = cardStyle == .framed ? metrics.cardInset : 0
        let leadingInset = inset - frameInset
        let posterStride = resolved.posterWidth + gap
        // Align the next card's visible edge with the unchanged poster rails,
        // rather than exposing a fraction of the much wider landscape card.
        let peek = (width - leadingInset).truncatingRemainder(dividingBy: posterStride)
        return resolved.fittingContinueWatchingRail(
            in: width, leadingInset: leadingInset, peek: peek,
            spacing: PlozziOSMediaRailLayout.visibleSpacing, cardStyle: cardStyle
        )
    }
}

public struct PlozziOSMediaRailScroll<Content: View>: View {
    @Environment(\.plozzCardStyle) private var cardStyle
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.plozzMetrics) private var metrics
    private let content: Content
    private let onLoadMore: (@MainActor () async -> Void)?
    private let trailingPlaceholderWidth: CGFloat
    private let onNavigationInteraction: () -> Void

    public init(
        onLoadMore: (@MainActor () async -> Void)? = nil, trailingPlaceholderWidth: CGFloat = 0,
        onNavigationInteraction: @escaping () -> Void = {},
        @ViewBuilder content: () -> Content
    ) {
        self.onLoadMore = onLoadMore
        self.trailingPlaceholderWidth = trailingPlaceholderWidth
        self.onNavigationInteraction = onNavigationInteraction
        self.content = content()
    }

    public var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(
                alignment: .top,
                spacing: PlozziOSMediaRailLayout.stackSpacing(metrics: metrics, cardStyle: cardStyle)
            ) { content }
        }
        .loadingMoreOnScroll(onLoadMore, trailingPlaceholderWidth: trailingPlaceholderWidth)
        .contentMargins(
            .horizontal,
            PlozziOSMediaRailLayout.artworkAlignedInset(
                PlozziOSMediaRailLayout.pageInset(for: sizeClass, usesDesktopSizing: metrics.usesDesktopSizing),
                metrics: metrics, cardStyle: cardStyle
            ),
            for: .scrollContent
        )
        .plozziOSMediaRailClearance()
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { old, new in
            if old != new { onNavigationInteraction() }
        }
    }
}
#endif
