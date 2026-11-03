import SwiftUI

public extension View {
    /// Fetches ahead only for a visible horizontal rail near its trailing edge.
    func loadingMoreOnScroll(
        _ loadMore: (@MainActor () async -> Void)?,
        trailingPlaceholderWidth: CGFloat = 0
    ) -> some View {
        modifier(MediaRowPagination(loadMore: loadMore, trailingPlaceholderWidth: trailingPlaceholderWidth))
    }
}

private struct MediaRowPagination: ViewModifier {
    let loadMore: (@MainActor () async -> Void)?
    let trailingPlaceholderWidth: CGFloat
    @State private var isVisible = false
    @State private var boundary: CGFloat?

    func body(content: Content) -> some View {
        if let loadMore {
            content
                .onScrollGeometryChange(for: CGFloat?.self) { geometry in
                    let loadedWidth = (geometry.contentSize.width - trailingPlaceholderWidth).rounded()
                    guard geometry.containerSize.width > 0, loadedWidth > 0,
                          loadedWidth - geometry.visibleRect.maxX
                            <= geometry.containerSize.width / 2 else { return nil }
                    return loadedWidth
                } action: { _, boundary in
                    self.boundary = boundary
                }
                .onScrollVisibilityChange(threshold: 0.1) { isVisible = $0 }
                // Skeletons must not cancel/restart the request that displayed them.
                // Loaded content width changes only after the new page has been laid out.
                // A page-number trigger can fetch again against stale geometry.
                .task(id: isVisible ? boundary : nil) {
                    if isVisible, boundary != nil { await loadMore() }
                }
        } else {
            content
        }
    }
}
