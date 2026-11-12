#if canImport(UIKit)
import CoreModels
import SwiftUI

/// Shared featured-row chrome; playback and selection remain with the caller.
public struct FeaturedMediaRowPresentation<Cards: View>: View {
    private let title: Text
    private let isEmpty: Bool
    private let isLoading: Bool
    private let usesRowBrowsing: Bool
    private let onBrowse: (() -> Void)?
    private let onSeeAll: (() -> Void)?
    private let onSettled: (Bool) -> Void
    private let cards: (CGSize) -> Cards
    @Binding private var selectedID: String?
    @State private var viewportWidth: CGFloat = 390
    #if os(tvOS)
    @Environment(\.mediaRowSizingViewportWidth) private var sizingViewportWidth
    #endif
    @Environment(\.plozzNavigationContentInset) private var navigationInset
    @Environment(\.plozzPinnedSidebarActive) private var pinnedSidebarActive
    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.plozzRowTitleTightening) private var titleTightening
    @Environment(\.themePalette) private var palette

    public init(
        title: Text, isEmpty: Bool = false, isLoading: Bool = false,
        usesRowBrowsing: Bool = true, onBrowse: (() -> Void)? = nil,
        onSeeAll: (() -> Void)? = nil, selectedID: Binding<String?> = .constant(nil),
        onSettled: @escaping (Bool) -> Void = { _ in },
        @ViewBuilder cards: @escaping (CGSize) -> Cards
    ) {
        self.title = title
        self.isEmpty = isEmpty
        self.isLoading = isLoading
        self.usesRowBrowsing = usesRowBrowsing
        self.onBrowse = onBrowse
        self.onSeeAll = onSeeAll
        self._selectedID = selectedID
        self.onSettled = onSettled
        self.cards = cards
    }

    private var television: Bool {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }

    private var inset: CGFloat {
        metrics.usesDesktopSizing ? DesktopMediaRailLayout.pageInset
            : (television ? PlozzTheme.Metrics.screenPadding : 20)
    }

    private var cardSpacing: CGFloat {
        metrics.usesDesktopSizing ? metrics.cardSpacing : (television ? 32 : 16)
    }

    private var size: CGSize {
        #if os(tvOS)
        let viewportWidth = sizingViewportWidth ?? self.viewportWidth
        #endif
        if metrics.usesDesktopSizing {
            return DesktopMediaRailLayout.featuredSize(in: viewportWidth, metrics: metrics)
        }
        return FeaturedCardLayout.size(
            viewportWidth: viewportWidth - (television ? navigationInset : 0), television: television
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: television ? metrics.sectionTitleSpacing - titleTightening : 12) {
            #if os(tvOS)
            MediaRowHeader(title: title, onSeeAll: usesRowBrowsing ? nil : onSeeAll)
            #else
            HStack {
                BrowseRowHeading(title: title, action: onBrowse)
                    .font(metrics.usesDesktopSizing ? .title3.weight(.semibold) : .title2.bold())
                Spacer()
                if !usesRowBrowsing, let onSeeAll { Button("See all", action: onSeeAll) }
            }
            .padding(.horizontal, inset)
            #endif
            if isEmpty && !isLoading {
                Text("No titles in this collection.")
                    .plozzForeground(.secondary)
                    .padding(.leading, inset + (television ? navigationInset : 0))
                    .padding(.trailing, inset)
            }
            if isLoading {
                ScrollView(.horizontal) {
                    HStack(spacing: cardSpacing) {
                        ForEach(0..<(metrics.usesDesktopSizing
                            ? max(3, Int(ceil(viewportWidth / (size.width + cardSpacing))) + 1) : 3), id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 24)
                                .fill(palette.fill)
                                .frame(width: size.width, height: size.height)
                        }
                    }
                    .padding(.vertical, television ? metrics.railShadowClearance : 4)
                }
                .contentMargins(.horizontal, inset, for: .scrollContent)
                .scrollDisabled(true)
                .shimmering()
                .accessibilityHidden(true)
            } else if !isEmpty || onBrowse != nil {
                rail.environment(\.homeRowEditAction, nil)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
    }

    @ViewBuilder private var rail: some View {
        #if os(tvOS)
        PinnedSidebarLeadingFade(
            isActive: pinnedSidebarActive, inset: navigationInset,
            verticalOverhang: metrics.railShadowClearance, cardPitch: size.width + cardSpacing
        ) { scroll }
        #else
        scroll
        #endif
    }

    private var scroll: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: cardSpacing) { cards(size) }
                .scrollTargetLayout()
                #if os(tvOS)
                .padding(.horizontal, inset)
                #endif
                .padding(.vertical, television ? metrics.railShadowClearance : 4)
        }
        #if os(iOS)
        .contentMargins(.horizontal, inset, for: .scrollContent)
        #endif
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        #if os(tvOS)
        .modifier(HomeRowPreviewScrollViewport())
        .padding(.vertical, metrics.railClearanceOffset(for: 24))
        #endif
        #if os(iOS)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $selectedID, anchor: .leading)
        .onScrollPhaseChange { _, phase in onSettled(phase == .idle) }
        #endif
    }
}
#endif
