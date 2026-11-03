import SwiftUI

public extension View {
    /// Fetches ahead only for a visible horizontal rail near its trailing edge.
    func loadingMoreOnScroll(_ loadMore: (@MainActor () async -> Void)?) -> some View {
        modifier(MediaRowPagination(loadMore: loadMore))
    }
}

private struct MediaRowPagination: ViewModifier {
    let loadMore: (@MainActor () async -> Void)?
    @State private var isVisible = false
    @State private var boundary: CGFloat?

    func body(content: Content) -> some View {
        if let loadMore {
            content
                .onScrollGeometryChange(for: CGFloat?.self) { geometry in
                    guard geometry.containerSize.width > 0, geometry.contentSize.width > 0,
                          geometry.contentSize.width - geometry.visibleRect.maxX
                            <= geometry.containerSize.width / 2 else { return nil }
                    return geometry.contentSize.width
                } action: { _, boundary in
                    self.boundary = boundary
                }
                .onScrollVisibilityChange(threshold: 0.1) { isVisible = $0 }
                // Content width changes only after the new page has been laid out.
                // A page-number trigger can fetch again against stale geometry.
                .task(id: isVisible ? boundary : nil) {
                    if isVisible, boundary != nil { await loadMore() }
                }
        } else {
            content
        }
    }
}
