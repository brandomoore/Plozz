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
        .modifier(PlozziOSReducedTransparencyScrollFade(enabled: heroActive))
        .background {
            PlozziOSStationaryNavigationSource()
                .frame(width: 0, height: 0)
        }
    }
}

struct PlozziOSReducedTransparencyScrollFade: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    @Environment(\.plozziOSIsRunningOnMac) private var isRunningOnMac
    @Environment(\.themePalette) private var palette
    @State private var safeAreaTop: CGFloat = 0
    @State private var scrolledFraction: CGFloat = 0
    var enabled = true

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                min(max((geometry.contentOffset.y + geometry.contentInsets.top) / 64, 0), 1)
            } action: { _, fraction in
                scrolledFraction = fraction
            }
            .overlay(alignment: .top) {
                if #available(iOS 26.0, *), enabled, !isRunningOnMac,
                   systemReduceTransparency || reduceTransparency {
                    // Protect status text without restoring the opaque native edge
                    // over the hero. The artwork remains untouched at scroll origin.
                    LinearGradient(
                        stops: [
                            .init(color: palette.backgroundBase, location: 0),
                            .init(color: palette.backgroundBase, location: safeAreaTop / (safeAreaTop + 44)),
                            .init(color: palette.backgroundBase.opacity(0), location: 1)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: safeAreaTop + 44)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(.container, edges: .top)
                    .opacity(scrolledFraction)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .background {
                PlozziOSWindowSafeAreaTopReader { safeAreaTop = $0 }
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

#endif
