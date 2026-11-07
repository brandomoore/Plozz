#if os(iOS)
import CoreUI
import SwiftUI

struct PlozziOSHomeScrollView<Hero: View, Rows: View>: View {
    @Environment(\.plozzMetrics) private var metrics
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
            .environment(\.plozziOSHomeViewportWidth, viewportWidth)
            .plozzDesktopMediaRailLayout()
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .ignoresSafeArea(.container, edges: heroActive ? .top : [])
        .background {
            PlozziOSStationaryNavigationSource()
                .frame(width: 0, height: 0)
        }
    }
}

#endif
