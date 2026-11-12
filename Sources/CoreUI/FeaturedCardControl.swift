#if canImport(UIKit)
import CoreModels
import SwiftUI

public struct FeaturedCardControl<Video: View>: View {
    private let item: MediaItem
    private let size: CGSize
    private let spoilers: SpoilerSettings
    private let onFocus: (Bool) -> Void
    private let onSelect: () -> Void
    private let video: Video
    @PlozzCardFocus private var focused: Bool
    @Environment(\.plozzCardFocusStyle) private var focusStyle
    #if os(iOS)
    private var onArtworkSelect: ((MediaArtworkZoomSource) -> Void)?

    public func artworkNavigation(_ action: @escaping (MediaArtworkZoomSource) -> Void) -> Self {
        var copy = self
        copy.onArtworkSelect = action
        return copy
    }
    #endif

    public init(
        item: MediaItem, size: CGSize, spoilers: SpoilerSettings,
        onFocus: @escaping (Bool) -> Void = { _ in }, onSelect: @escaping () -> Void,
        @ViewBuilder video: () -> Video
    ) {
        self.item = item
        self.size = size
        self.spoilers = spoilers
        self.onFocus = onFocus
        self.onSelect = onSelect
        self.video = video()
    }

    private var artwork: some View {
        FeaturedCardArtwork(item: item, size: size, spoilerSettings: spoilers) { video }
    }

    public var body: some View {
        #if os(tvOS)
        televisionControl
            .mediaItemContextMenu(for: item)
            .onChange(of: focused) { _, value in onFocus(value) }
        #else
        MediaArtworkZoomButton(id: item.stablePresentationID) { source in
            if let onArtworkSelect { onArtworkSelect(source) }
            else { onSelect() }
        } label: {
            artwork
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .mediaArtworkZoomSource(cornerRadius: 20)
                .mediaItemContextMenu(for: item)
        }
        .buttonStyle(.plain)
        #endif
    }

    #if os(tvOS)
    @ViewBuilder private var televisionControl: some View {
        if focusStyle.usesSystemEffect {
            FeaturedCardArtwork(item: item, size: size, spoilerSettings: spoilers) { video }
                .nativeButton(focus: $focused, action: onSelect)
        } else {
            artwork
                .plozzFocusHalo(cornerRadius: 20, focusScale: 1.04, isFocused: focused)
                .focusableCard(isFocused: $focused, cornerRadius: 20, action: onSelect)
                .accessibilityLabel(Text(verbatim: item.title))
                .plozzCardFocusTransition(isFocused: focused)
        }
    }
    #endif
}
#endif
