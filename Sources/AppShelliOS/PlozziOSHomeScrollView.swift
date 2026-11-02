#if os(iOS)
import CoreModels
import CoreUI
import SwiftUI

struct PlozziOSHomeScrollView<Hero: View, Rows: View>: View {
    @Environment(\.plozzMetrics) private var metrics
    @State private var position = ScrollPosition(edge: .top)
    @State private var preservation = PlozziOSHomeScrollPreservation()
    @State private var viewportWidth: CGFloat = 0
    let heroActive: Bool
    @ViewBuilder var hero: Hero
    @ViewBuilder var rows: Rows

    var body: some View {
        ScrollView {
            // Eager vertical sizing avoids estimated heights changing during scrolling.
            VStack(alignment: .leading, spacing: PlozziOSMediaRailLayout.sectionGap(metrics: metrics)) {
                if heroActive { hero }
                rows
            }
            .padding(.bottom)
            .coordinateSpace(name: PlozziOSHomeScrollSpace.content)
            .environment(\.plozziOSHomeViewportWidth, viewportWidth)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .scrollPosition($position)
        .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in
            preservation.geometry = geometry
        }
        .onPreferenceChange(PlozziOSHomeRowFrames.self) { frames in
            if let offset = preservation.offset(after: frames) {
                position.scrollTo(y: offset)
            }
        }
        .ignoresSafeArea(.container, edges: heroActive ? .top : [])
    }
}

@MainActor
final class PlozziOSHomeScrollPreservation {
    var geometry: ScrollGeometry? {
        didSet {
            if geometry?.contentOffset != oldValue?.contentOffset
                || geometry?.containerSize != oldValue?.containerSize {
                pendingOffset = nil
            }
        }
    }
    private var frames: [HomeRowID: CGRect] = [:]
    private var containerSize: CGSize?
    private var pendingOffset: CGFloat?

    func offset(after next: [HomeRowID: CGRect]) -> CGFloat? {
        defer {
            frames = next
            containerSize = geometry?.containerSize
        }
        guard let geometry, containerSize == geometry.containerSize,
              geometry.contentOffset.y > -geometry.contentInsets.top + 1 else { return nil }
        let currentOffset = pendingOffset ?? geometry.contentOffset.y
        let viewport = geometry.visibleRect.offsetBy(dx: 0, dy: currentOffset - geometry.contentOffset.y)
        let visible = frames.filter { $0.value.intersects(viewport) }
            .sorted { $0.value.minY < $1.value.minY }
        guard let anchor = visible.first(where: { next[$0.key] != nil }),
              let replacement = next[anchor.key] else { return nil }
        let change = replacement.minY - anchor.value.minY
        guard abs(change) > 0.5 else { return nil }
        let offset = max(-geometry.contentInsets.top, currentOffset + change)
        pendingOffset = offset
        // ScrollPosition's point origin includes the top content inset.
        return offset + geometry.contentInsets.top
    }
}

private enum PlozziOSHomeScrollSpace: Hashable {
    case content
}

private struct PlozziOSHomeRowFrames: PreferenceKey {
    static let defaultValue: [HomeRowID: CGRect] = [:]
    static func reduce(value: inout [HomeRowID: CGRect], nextValue: () -> [HomeRowID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func plozziOSHomeScrollRow(_ id: HomeRowID) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: PlozziOSHomeRowFrames.self,
                    value: [id: geometry.frame(in: .named(PlozziOSHomeScrollSpace.content))]
                )
            }
        }
    }
}
#endif
