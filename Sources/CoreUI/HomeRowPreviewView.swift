#if canImport(UIKit)
import CoreModels
import SwiftUI

/// The Home presentation without routing, playback, trailers or context actions.
public struct HomeRowPreviewView: View {
    private let title: Text
    private let items: [MediaItem]
    private let style: CollectionSection.CardStyle
    private let spoilers: SpoilerSettings
    private let hasMore: Bool
    @Environment(\.plozzCardStyle) private var cardStyle

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
    }

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
