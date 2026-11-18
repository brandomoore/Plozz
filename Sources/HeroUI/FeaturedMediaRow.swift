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
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    private var candidate: MediaItem? {
        guard !isLoading, isActive, scenePhase == .active, !reduceMotion,
              settings.homeTrailerPlaybackEnabled, !controller.isPlaybackSuppressed,
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
        FeaturedMediaRowPresentation(
            title: title, isEmpty: items.isEmpty, isLoading: isLoading, usesRowBrowsing: usesRowBrowsing,
            onBrowse: onBrowse.map { action in { coordinator.stop(); action() } },
            onSeeAll: onSeeAll.map { action in { coordinator.stop(); action() } },
            selectedID: $selectedID, onSettled: { isSettled = $0 }
        ) { size in
            cards(size: size)
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
        #endif
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

    @ViewBuilder private func cards(size: CGSize) -> some View {
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
}

private struct FeaturedMediaCard: View {
    let item: MediaItem
    let size: CGSize
    let spoilers: SpoilerSettings
    let controller: HeroTrailerController
    let showsVideo: Bool
    let onFocus: (Bool) -> Void
    let onSelect: () -> Void
    #if os(iOS)
    @Environment(\.featuredArtworkSelection) private var artworkNavigator
    #endif

    var body: some View {
        FeaturedCardControl(
            item: item, size: size, spoilers: spoilers, onFocus: onFocus, onSelect: onSelect
        ) {
            if showsVideo {
                HeroTrailerVideoLayer(controller: controller, role: .featured)
            }
        }
        #if os(iOS)
        .artworkNavigation { source in
            if let artworkNavigator {
                artworkNavigator(item, source)
            } else {
                onSelect()
            }
        }
        #endif
    }
}
#endif
