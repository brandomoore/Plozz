#if canImport(UIKit)
import CoreModels
import CoreUI
import FeatureHomeCore
import SwiftUI

#if os(iOS)
private struct FeaturedArtworkSelectionKey: EnvironmentKey {
    static let defaultValue: ((MediaItem, MediaArtworkZoomSource) -> Void)? = nil
}

private extension EnvironmentValues {
    var featuredArtworkSelection: ((MediaItem, MediaArtworkZoomSource) -> Void)? {
        get { self[FeaturedArtworkSelectionKey.self] }
        set { self[FeaturedArtworkSelectionKey.self] = newValue }
    }
}
#endif

public struct FeaturedMediaRow: View {
    private let title: Text
    private let items: [MediaItem]
    private let scope: ObjectIdentifier
    private let coordinator: FeaturedTrailerCoordinator
    private let controller: HeroTrailerController
    private let settings: HeroBackgroundSettings
    private let resolver: HeroTrailerResolving
    private let isActive: Bool
    private let spoilers: SpoilerSettings
    private let onFocus: ((MediaItem) -> Void)?
    private let onSeeAll: (() -> Void)?
    private let onSelect: (MediaItem) -> Void
    @State private var rowID = UUID()
    @State private var selectedID: String?
    @State private var focusedID: String?
    @State private var priority: Int?
    @State private var isSettled = true
    @State private var viewportWidth: CGFloat = 390
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.plozzNavigationContentInset) private var navigationContentInset
    @Environment(\.plozzPinnedSidebarActive) private var pinnedSidebarActive
    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.plozzRowTitleTightening) private var titleTightening
    @Environment(\.themePalette) private var palette
    private var onBrowse: (() -> Void)?
    private var usesRowBrowsing = false
    private var isLoading = false

    public func loading(_ loading: Bool) -> Self {
        var copy = self
        copy.isLoading = loading
        return copy
    }

    #if os(iOS)
    private var onSelectArtwork: ((MediaItem, MediaArtworkZoomSource) -> Void)?

    public func artworkNavigation(
        _ action: @escaping (MediaItem, MediaArtworkZoomSource) -> Void
    ) -> Self {
        var copy = self
        copy.onSelectArtwork = action
        return copy
    }
    #endif

    public func browsingRow(_ action: (() -> Void)?) -> Self {
        var copy = self
        copy.onBrowse = action
        copy.usesRowBrowsing = true
        return copy
    }

    public init(
        title: Text, items: [MediaItem], scope: ObjectIdentifier,
        coordinator: FeaturedTrailerCoordinator, controller: HeroTrailerController,
        settings: HeroBackgroundSettings, resolver: @escaping HeroTrailerResolving,
        isActive: Bool, spoilers: SpoilerSettings = .default,
        onFocus: ((MediaItem) -> Void)? = nil, onSeeAll: (() -> Void)? = nil,
        onSelect: @escaping (MediaItem) -> Void
    ) {
        self.title = title
        self.items = items
        self.scope = scope
        self.coordinator = coordinator
        self.controller = controller
        self.settings = settings
        self.resolver = resolver
        self.isActive = isActive
        self.spoilers = spoilers
        self.onFocus = onFocus
        self.onSeeAll = onSeeAll
        self.onSelect = onSelect
    }

    private var television: Bool {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }
    private var inset: CGFloat {
        metrics.usesDesktopSizing ? DesktopMediaRailLayout.pageInset : (television ? PlozzTheme.Metrics.screenPadding : 20)
    }
    private var cardSpacing: CGFloat {
        metrics.usesDesktopSizing ? metrics.cardSpacing : (television ? 32 : 16)
    }
    private var size: CGSize {
        if metrics.usesDesktopSizing {
            return DesktopMediaRailLayout.featuredSize(in: viewportWidth, metrics: metrics)
        }
        return FeaturedCardLayout.size(
            viewportWidth: viewportWidth - (television ? navigationContentInset : 0),
            television: television
        )
    }
    private var candidate: MediaItem? {
        guard !isLoading, isActive, scenePhase == .active, !reduceMotion,
              settings.homeTrailerEnabled, !controller.isPlaybackSuppressed,
              television || (priority != nil && isSettled) else { return nil }
        let id = television ? focusedID : (selectedID ?? items.first?.stablePresentationID)
        return items.first { $0.stablePresentationID == id }
    }
    private struct Request: Equatable {
        let itemID: String?
        let scope: ObjectIdentifier
        let priority: Int?
        let muted: Bool
    }
    private var request: Request {
        Request(itemID: candidate?.stablePresentationID, scope: scope,
                priority: priority, muted: settings.homeTrailerMuted)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: television ? metrics.sectionTitleSpacing - titleTightening : 12) {
            #if os(tvOS)
            MediaRowHeader(
                title: title,
                onSeeAll: !usesRowBrowsing ? onSeeAll.map { action in {
                    coordinator.stop()
                    action()
                } } : nil
            )
            #else
            HStack {
                if let onBrowse {
                    BrowseRowHeading(title: title) { coordinator.stop(); onBrowse() }
                        .font(metrics.usesDesktopSizing ? .title3.weight(.semibold) : .title2.bold())
                } else {
                    title.font(metrics.usesDesktopSizing ? .title3.weight(.semibold) : .title2.bold())
                }
                Spacer()
                if !usesRowBrowsing, let onSeeAll {
                    Button("See all") {
                        coordinator.stop()
                        onSeeAll()
                    }
                }
            }
            .padding(.horizontal, inset)
            #endif
            if items.isEmpty && !isLoading {
                Text("No titles in this collection.")
                    .plozzForeground(.secondary)
                    .padding(.leading, inset + (television ? navigationContentInset : 0))
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
            } else if !items.isEmpty || onBrowse != nil {
                rail
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .onGeometryChange(for: Int?.self) { geometry in
            let frame = geometry.frame(in: .scrollView(axis: .vertical))
            guard let bounds = geometry.bounds(of: .scrollView(axis: .vertical)),
                  frame.height > 0 else { return nil }
            let visible = max(0, min(frame.maxY, bounds.height) - max(frame.minY, 0))
            guard visible / frame.height >= 0.75 else { return nil }
            return Int(abs(frame.midY - bounds.height / 2) / 20)
        } action: { priority = $0 }
        .task(id: request) {
            if let candidate {
                coordinator.update(
                    rowID: rowID, item: candidate, scope: scope, priority: priority ?? 0,
                    muted: settings.homeTrailerMuted, controller: controller, resolve: resolver
                )
            } else {
                coordinator.withdraw(rowID: rowID)
            }
        }
        .onDisappear { coordinator.withdraw(rowID: rowID) }
    }

    @ViewBuilder
    private var rail: some View {
        #if os(tvOS)
        PinnedSidebarLeadingFade(
            isActive: pinnedSidebarActive, inset: navigationContentInset,
            verticalOverhang: metrics.railShadowClearance, cardPitch: size.width + cardSpacing
        ) {
            scroll
        }
        #else
        scroll
        #endif
    }

    private var scroll: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: cardSpacing) {
                ForEach(items, id: \.stablePresentationID) { item in
                    FeaturedMediaCard(
                        item: item, size: size, spoilers: spoilers,
                        controller: controller,
                        showsVideo: coordinator.activeRowID == rowID
                            && coordinator.activeItemID == item.stablePresentationID
                            && controller.currentItemID == coordinator.playerItemID
                            && controller.isPlaying,
                        onFocus: { focused in
                            if focused {
                                focusedID = item.stablePresentationID
                                onFocus?(item)
                            } else if focusedID == item.stablePresentationID {
                                focusedID = nil
                            }
                        },
                        onSelect: {
                            coordinator.stop()
                            onSelect(item)
                        }
                    )
                    .id(item.stablePresentationID)
                }
                #if os(tvOS)
                if let onBrowse {
                    MediaRowBrowseCard(
                        width: size.width, featuredSize: size,
                        onFocus: { focusedID = nil; coordinator.stop() },
                        action: { coordinator.stop(); onBrowse() }
                    )
                }
                #endif
            }
            .scrollTargetLayout()
            #if os(tvOS)
            .padding(.horizontal, inset)
            #endif
            .padding(.vertical, television ? metrics.railShadowClearance : 4)
        }
        #if os(iOS)
        .environment(\.featuredArtworkSelection, { item, source in
            coordinator.stop()
            if let onSelectArtwork {
                onSelectArtwork(item, source)
            } else {
                onSelect(item)
            }
        })
        .contentMargins(.horizontal, inset, for: .scrollContent)
        #endif
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        #if os(tvOS)
        .padding(.vertical, metrics.railClearanceOffset(for: 24))
        #endif
        #if os(iOS)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $selectedID, anchor: .leading)
        .onScrollPhaseChange { _, phase in isSettled = phase == .idle }
        #endif
    }
}

private struct FeaturedMediaCard: View {
    let item: MediaItem
    let size: CGSize
    let spoilers: SpoilerSettings
    let controller: HeroTrailerController
    let showsVideo: Bool
    let onFocus: (Bool) -> Void
    let onSelect: () -> Void
    @PlozzCardFocus private var focused: Bool
    @Environment(\.plozzCardFocusStyle) private var focusStyle
    #if os(iOS)
    @Environment(\.featuredArtworkSelection) private var artworkNavigator
    #endif

    private func artwork(usesNativeClipping: Bool = false) -> FeaturedCardArtwork<some View> {
        FeaturedCardArtwork(
            item: item, size: size, spoilerSettings: spoilers, usesNativeClipping: usesNativeClipping
        ) {
            if showsVideo {
                HeroTrailerVideoLayer(controller: controller, role: .featured)
            }
        }
    }

    var body: some View {
        #if os(tvOS)
        televisionControl
            .mediaItemContextMenu(for: item)
            .onChange(of: focused) { _, value in onFocus(value) }
        #else
        MediaArtworkZoomButton(id: item.stablePresentationID) { source in
            if let artworkNavigator {
                artworkNavigator(item, source)
            } else {
                onSelect()
            }
        } label: {
            artwork()
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .mediaArtworkZoomSource(cornerRadius: 20)
                .mediaItemContextMenu(for: item)
        }
            .buttonStyle(.plain)
        #endif
    }

    #if os(tvOS)
    @ViewBuilder
    private var televisionControl: some View {
        if focusStyle.usesSystemEffect {
            artwork().nativeButton(focus: $focused, action: onSelect)
        } else {
            artwork()
                .plozzFocusHalo(cornerRadius: 20, focusScale: 1.04, isFocused: focused)
                .focusableCard(isFocused: $focused, cornerRadius: 20, action: onSelect)
                .accessibilityLabel(Text(verbatim: item.title))
                .plozzCardFocusTransition(isFocused: focused)
        }
    }
    #endif
}
#endif
