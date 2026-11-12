#if os(iOS)
import CoreModels
import CoreUI
import FeatureHomeCore
import SwiftUI

private struct PlozziOSHomeViewportWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

/// Content changes inside a row's reserved footprint, never the other way around.
struct PlozziOSHomeRowSlot<Content: View>: View {
    let presentation: HomePresentationRow
    let captions: CardCaptionSettings
    let continueWatchingLayout: ContinueWatchingCardLayout
    let continueWatchingUsesSeriesArtwork: Bool
    @ViewBuilder var content: Content

    private var isLibraryRow: Bool { presentation.id == .libraries }
    private var isLiveTV: Bool { presentation.id == .liveTV }
    private var isContinueWatching: Bool { presentation.id == .global(.continueWatching) }
    private var showsSeriesArtwork: Bool { isContinueWatching && continueWatchingUsesSeriesArtwork }
    private var isFeatured: Bool { presentation.choice.collectionSection?.cardStyle == .featured }
    private var style: PosterCardView.Style {
        if isContinueWatching { return continueWatchingLayout.cardStyle }
        if isLibraryRow { return .landscape }
        switch presentation.source {
        case let .home(row): return row.style == .landscape ? .landscape : .poster
        case let .library(row): return row.section.style == .landscape ? .landscape : .poster
        case .liveTV: return .landscape
        }
    }

    private var title: Text {
        switch presentation.source {
        case let .home(row): row.displayName
        case let .library(row): row.section.displayName
        case .liveTV: presentation.choice.localizedTitle.map(Text.init) ?? Text(verbatim: presentation.choice.title)
        }
    }

    private var showsStatus: Bool {
        switch presentation.source {
        case let .home(row): row.failure != nil && row.items.isEmpty && row.libraries.isEmpty
        case let .library(row): row.issue != nil || row.failure != nil
        case .liveTV: false
        }
    }

    var body: some View {
        PlozziOSHomeRailLayout { metrics in
            PlozziOSHomeRowFootprint(
                metrics: metrics, title: title, style: style, captions: captions,
                isLibraryRow: isLibraryRow, isLiveTV: isLiveTV, isFeatured: isFeatured,
                isContinueWatching: isContinueWatching, showsSeriesArtwork: showsSeriesArtwork
            )
            .environment(\.plozzShimmerEnabled, false)
            .hidden()
            .accessibilityHidden(true)
            .overlay(alignment: .topLeading) {
                // Measure every footprint, but mount rail content only near
                // the viewport. The lazy content never determines row height.
                GeometryReader { geometry in
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Group {
                            if showsStatus {
                                // Keep long diagnostics reachable within the reserved row.
                                ScrollView { content }
                                    .scrollBounceBehavior(.basedOnSize)
                            } else {
                                content
                            }
                        }
                        .frame(height: geometry.size.height, alignment: .top)
                    }
                }
            }
        }
    }
}

/// Item updates do not invalidate the row's unchanged sizing template.
private struct PlozziOSHomeRowFootprint: View {
    @Environment(\.plozzCardStyle) private var cardStyle
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.plozziOSHomeViewportWidth) private var viewportWidth
    let metrics: PlozzMetrics
    let title: Text
    let style: PosterCardView.Style
    let captions: CardCaptionSettings
    let isLibraryRow: Bool
    let isLiveTV: Bool
    let isFeatured: Bool
    let isContinueWatching: Bool
    let showsSeriesArtwork: Bool

    var body: some View {
        sizing(metrics: metrics)
    }

    @ViewBuilder
    private func sizing(metrics: PlozzMetrics) -> some View {
        if isFeatured {
            VStack(alignment: .leading, spacing: 12) {
                BrowseRowHeading(title: title, action: nil)
                    .font(metrics.usesDesktopSizing ? .title3.weight(.semibold) : .title2.bold())
                    .padding(.horizontal, metrics.usesDesktopSizing ? DesktopMediaRailLayout.pageInset : 20)
                Color.clear.frame(height: (metrics.usesDesktopSizing
                    ? DesktopMediaRailLayout.featuredSize(in: viewportWidth, metrics: metrics)
                    : FeaturedCardLayout.size(viewportWidth: viewportWidth > 0 ? viewportWidth : 390, television: false)
                ).height + 8)
            }
        } else {
            PlozziOSMediaSection(
                title: title, artworkInset: !isLibraryRow && cardStyle == .framed ? metrics.cardInset : 0,
                reservesBrowseSpace: !isLibraryRow
            ) {
                Group {
                    if isLibraryRow {
                        PlozziOSHomeLibraryCard(
                            library: nil, artworkSource: nil,
                            width: metrics.usesDesktopSizing ? metrics.landscapeWidth
                                : metrics.density.iOSHomeLibraryWidth(horizontalSizeClass: sizeClass)
                        )
                        .environment(\.plozzCardCaptionSettings, captions)
                    } else if isLiveTV {
                        Color.clear.frame(height: metrics.cardSlotWidth(
                            for: .landscape, cardStyle: cardStyle
                        ) * 9 / 16)
                    } else {
                        SkeletonCardView(
                            style: style == .landscape ? .landscape : .poster,
                            showsCaption: captions.showsLabels(
                                in: .home, hasArtworkTitle: showsSeriesArtwork,
                                isContinueWatching: isContinueWatching
                            ),
                            showsSeriesArtwork: showsSeriesArtwork
                        )
                        .frame(width: metrics.cardSlotWidth(
                            for: style, cardStyle: cardStyle, showsSeriesArtwork: showsSeriesArtwork
                        ))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

extension EnvironmentValues {
    var plozziOSHomeViewportWidth: CGFloat {
        get { self[PlozziOSHomeViewportWidthKey.self] }
        set { self[PlozziOSHomeViewportWidthKey.self] = newValue }
    }
}

/// Home's loaded and placeholder rails share the same platform-specific poster sizes.
struct PlozziOSHomeRailLayout<Content: View>: View {
    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.plozzCardStyle) private var cardStyle
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.plozziOSHomeViewportWidth) private var viewportWidth
    @State private var width: CGFloat = 0
    @ViewBuilder let content: (PlozzMetrics) -> Content

    var body: some View {
        let resolved = Self.posterMetrics(
            in: viewportWidth > 0 ? viewportWidth : width,
            inset: PlozziOSPageLayout.horizontalInset(for: sizeClass),
            metrics: metrics, cardStyle: cardStyle
        )
        content(resolved)
            .environment(\.plozzMetrics, resolved)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    static func posterMetrics(
        in width: CGFloat, inset: CGFloat, metrics: PlozzMetrics, cardStyle: CardStyle
    ) -> PlozzMetrics {
        if metrics.usesDesktopSizing {
            return metrics.fittingDesktopRail(in: width, cardStyle: cardStyle)
        }
        guard width > 0 else { return metrics }
        let gap = PlozziOSMediaRailLayout.visibleSpacing + (cardStyle == .framed ? 2 * metrics.cardInset : 0)
        // Phones get three complete pictures plus a 28% preview. Wider windows
        // add columns instead of stretching phone posters to tablet size.
        let count = max(width < 375 ? 2 : 3, floor((width - inset + gap) / 164))
        let standardWidth = (width - inset - count * gap) / (count + 0.28)
        let artworkWidth = max(44, standardWidth * CGFloat(metrics.density.scale))
        return metrics.scalingPosters(by: artworkWidth / metrics.posterWidth)
    }
}
#endif
