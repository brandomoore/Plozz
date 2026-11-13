#if canImport(UIKit)
import CoreModels
import SwiftUI

#if os(tvOS)
struct HomeRowPreviewViewport: Equatable {
    let width: CGFloat
    let trailingSafeAreaInset: CGFloat
    var leadingSafeAreaInset: CGFloat = 0

    var fullWidth: CGFloat { width + leadingSafeAreaInset + trailingSafeAreaInset }
}

extension EnvironmentValues {
    @Entry var homeRowPreviewViewport: HomeRowPreviewViewport? = nil
    @Entry var mediaRowSizingViewportWidth: CGFloat? = nil
    @Entry var homeRowPreviewOutset: CGFloat = 0
}

struct HomeRowPreviewScrollViewport: ViewModifier {
    @Environment(\.homeRowPreviewOutset) private var outset

    func body(content: Content) -> some View {
        if outset > 0 {
            content
                .contentMargins(.leading, outset, for: .scrollContent)
                .padding(.horizontal, -outset)
        } else {
            content
        }
    }
}
#endif

/// The Home presentation without routing, playback, trailers or context actions.
public struct HomeRowPreviewView: View {
    private let title: Text
    private let items: [MediaItem]
    private let style: CollectionSection.CardStyle
    private let spoilers: SpoilerSettings
    private let hasMore: Bool
    @Environment(\.plozzCardStyle) private var cardStyle
    #if os(tvOS)
    @Environment(\.homeRowPreviewViewport) private var viewport
    @Environment(\.plozzNavigationContentInset) private var navigationInset
    @Environment(\.plozzNavigationRootContentInset) private var rootNavigationInset
    @Environment(\.plozzPinnedSidebarActive) private var pinnedSidebarActive
    @Environment(\.plozzNavigationStyle) private var navigationStyle
    @State private var columnWidth: CGFloat = 0
    #endif

    public init(
        title: Text, items: [MediaItem], style: CollectionSection.CardStyle,
        spoilers: SpoilerSettings = .default, hasMore: Bool = false
    ) {
        self.title = title
        self.items = items
        self.style = style
        self.spoilers = spoilers
        self.hasMore = hasMore
    }

    public var body: some View {
        row
            .environment(\.mediaItemActionHandler, nil)
            .environment(\.mediaItemNavigator, nil)
            .environment(\.homeRowEditAction, nil)
            .environment(\.plozzCardCaptionView, .home)
            #if os(tvOS)
            .environment(\.mediaRowSizingViewportWidth, sizingViewportWidth)
            .environment(\.plozzNavigationContentInset, 0)
            .environment(\.plozzPinnedSidebarActive, false)
            .environment(\.homeRowPreviewOutset, viewport.map {
                columnWidth > 0 ? max(0, ($0.fullWidth - columnWidth) / 2) : 0
            } ?? 0)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { columnWidth = $0 }
            #endif
    }

    #if os(tvOS)
    private var sizingViewportWidth: CGFloat? {
        guard let viewport else { return nil }
        let navigationInset = rootNavigationInset ?? self.navigationInset
        switch style {
        case .poster:
            // Home posters extend through the trailing safe area, but not the navigation gutter.
            return viewport.width + viewport.trailingSafeAreaInset - (pinnedSidebarActive ? navigationInset : 0)
        case .featured:
            return viewport.width + (navigationStyle == .rail ? viewport.trailingSafeAreaInset : 0) - navigationInset
        case .landscape:
            return nil
        }
    }
    #endif

    @ViewBuilder private var row: some View {
        if style == .featured {
            FeaturedMediaRowPresentation(title: title, isEmpty: items.isEmpty, onBrowse: browseAction) { size in
                ForEach(items, id: \.stablePresentationID) { item in
                    FeaturedCardControl(item: item, size: size, spoilers: spoilers, onSelect: {}) {
                        EmptyView()
                    }
                        #if os(iOS)
                        .allowsHitTesting(false)
                        #endif
                        .id(item.stablePresentationID)
                }
                #if os(tvOS)
                if let browseAction {
                    MediaRowBrowseCard(width: size.width, featuredSize: size, onFocus: {}, action: browseAction)
                }
                #endif
            }
        } else {
            #if os(iOS)
            PlozziOSHomeRailLayout { metrics in
                PlozziOSMediaSection(
                    title: title, artworkInset: cardStyle == .framed ? metrics.cardInset : 0,
                    reservesBrowseSpace: true, onBrowse: browseAction
                ) {
                    PlozziOSMediaRailScroll {
                        ForEach(items, id: \.stablePresentationID) { item in
                            PosterCardView(
                                item: item, style: posterStyle, spoilerSettings: spoilers,
                                reservesSubtitleSpace: style == .poster,
                                showsResumeChip: item.kind != .collection && style == .landscape,
                                action: {}
                            )
                            .frame(width: metrics.cardSlotWidth(for: posterStyle, cardStyle: cardStyle))
                            .allowsHitTesting(false)
                        }
                    }
                }
            }
            #else
            MediaRowView(
                title: title, items: items, style: posterStyle, spoilerSettings: spoilers,
                isExposureActive: false, onSelect: { _ in }
            )
            .browsingRow(browseAction)
            #endif
        }
    }

    private var posterStyle: PosterCardView.Style { style == .poster ? .poster : .landscape }
    private var browseAction: (() -> Void)? { hasMore ? {} : nil }
}
#endif
