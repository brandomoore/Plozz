#if os(iOS)
import CoreUI
import SwiftUI

struct PlozziOSHomeScrollView<Hero: View, Rows: View, PageActions: View>: View {
    @Environment(\.plozzMetrics) private var metrics
    @State private var viewportWidth: CGFloat = 0
    @State private var safeAreaTop: CGFloat = 0
    let heroActive: Bool
    let showsPageActions: Bool
    let hero: Hero
    let rows: Rows
    let pageActions: PageActions

    init(
        heroActive: Bool,
        showsPageActions: Bool = false,
        @ViewBuilder hero: () -> Hero,
        @ViewBuilder rows: () -> Rows,
        @ViewBuilder pageActions: () -> PageActions = { EmptyView() }
    ) {
        self.heroActive = heroActive
        self.showsPageActions = showsPageActions
        self.hero = hero()
        self.rows = rows()
        self.pageActions = pageActions()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            scrollContent
                .scrollEdgeEffectStyle(heroActive && !showsPageActions ? .soft : .automatic, for: .top)
        } else {
            scrollContent
        }
    }

    private var scrollContent: some View {
        ScrollView {
            // Eager vertical sizing avoids estimated heights changing during scrolling.
            VStack(alignment: .leading, spacing: PlozziOSMediaRailLayout.sectionGap(metrics: metrics)) {
                if heroActive {
                    hero.overlay(alignment: .top) {
                        if showsPageActions {
                            pageActions.padding(.top, safeAreaTop)
                        }
                    }
                    // Underlap only the artwork, not the scroll view's safe-area boundary.
                    .padding(.top, showsPageActions ? -safeAreaTop : 0)
                } else if showsPageActions {
                    pageActions
                }
                rows
            }
            .padding(.bottom)
            .environment(\.plozziOSHomeViewportWidth, viewportWidth)
            .plozzDesktopMediaRailLayout()
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .ignoresSafeArea(.container, edges: heroActive && !showsPageActions ? .top : [])
        .modifier(PlozziOSStatusBarScrollFade(enabled: heroActive))
        .background {
            if showsPageActions && heroActive {
                PlozziOSWindowSafeAreaTopReader { safeAreaTop = $0 }
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            PlozziOSStationaryNavigationSource()
                .frame(width: 0, height: 0)
        }
    }
}

struct PlozziOSHomePageActions: View {
    let showsAudio: Bool
    let isMuted: Bool
    let onToggleMute: () -> Void
    let onShowSettings: () -> Void

    var body: some View {
        HStack(spacing: PlozziOSPageHeaderLayout.actionSpacing) {
            Spacer(minLength: 0)
            if showsAudio {
                PlozziOSHeroAudioMuteToolbarButton(isMuted: isMuted, onToggle: onToggleMute)
                    .plozziOSPageAction()
            }
            PlozziOSSettingsAvatarButton(action: onShowSettings)
        }
        .padding(.horizontal, PlozziOSPageHeaderLayout.horizontalInset)
    }
}

struct PlozziOSStatusBarScrollFade: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    @Environment(\.plozziOSIsRunningOnMac) private var isRunningOnMac
    @Environment(\.themePalette) private var palette
    @State private var safeAreaTop: CGFloat = 0
    @State private var scrolledFraction: CGFloat = 0
    var enabled = true
    var usesMaterial = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                min(max((geometry.contentOffset.y + geometry.contentInsets.top) / 64, 0), 1)
            } action: { _, fraction in
                scrolledFraction = fraction
            }
            .overlay(alignment: .top) {
                if #available(iOS 26.0, *), enabled, !isRunningOnMac,
                   usesMaterial || systemReduceTransparency || reduceTransparency {
                    Group {
                        if systemReduceTransparency || reduceTransparency {
                            Rectangle().fill(palette.backgroundBase)
                        } else {
                            Rectangle().fill(.ultraThinMaterial)
                        }
                    }
                    .frame(height: safeAreaTop + 44)
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: safeAreaTop / (safeAreaTop + 44)),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(.container, edges: .top)
                    // Follow scroll position directly, without a delayed appearance animation.
                    .opacity(scrolledFraction)
                    .animation(nil, value: scrolledFraction)
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
