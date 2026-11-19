#if os(iOS)
import CoreUI
import FeatureHomeCore
import SwiftUI

extension HomePresentationRow {
    var showsHomeMedia: Bool {
        switch source {
        case let .home(row):
            !row.items.isEmpty || (!row.libraries.isEmpty && row.loadingPlaceholderCount == 0)
        case let .library(row):
            row.failure == nil && row.issue == nil && !row.section.items.isEmpty
                && (!row.isLoading || row.collectionCardStyle == .featured)
        case let .liveTV(channels):
            !channels.isEmpty
        }
    }
}

enum PlozziOSHomeContentEntrance {
    case initial, waiting, revealed

    var opacity: Double { self == .waiting ? 0 : 1 }
}

struct PlozziOSObserveHomeContent: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var entrance: PlozziOSHomeContentEntrance
    let visibleContent: Bool?

    func body(content: Content) -> some View {
        content.onChange(of: visibleContent, initial: true) { _, hasMedia in
            guard let hasMedia, entrance != .revealed else { return }
            if hasMedia {
                let fades = entrance == .waiting && !reduceMotion
                withAnimation(fades ? .easeOut(duration: 0.35) : nil) { entrance = .revealed }
            } else {
                entrance = .waiting
            }
        }
    }
}

struct PlozziOSHomeScrollView<Hero: View, Rows: View, PageActions: View>: View {
    @Environment(\.plozzMetrics) private var metrics
    @State private var viewportWidth: CGFloat = 0
    let heroActive: Bool
    let showsPageActions: Bool
    let mediaOpacity: Double
    let hero: Hero
    let rows: Rows
    let pageActions: PageActions

    init(
        heroActive: Bool,
        showsPageActions: Bool = false,
        mediaOpacity: Double = 1,
        @ViewBuilder hero: () -> Hero,
        @ViewBuilder rows: () -> Rows,
        @ViewBuilder pageActions: () -> PageActions = { EmptyView() }
    ) {
        self.heroActive = heroActive
        self.showsPageActions = showsPageActions
        self.mediaOpacity = mediaOpacity
        self.hero = hero()
        self.rows = rows()
        self.pageActions = pageActions()
    }

    var body: some View {
        if showsPageActions {
            // Read the inset in the same layout pass as the hero. An async window
            // probe starts at zero on profile entry and shifts the entire page later.
            GeometryReader { proxy in
                styledScroll(safeAreaTop: proxy.safeAreaInsets.top)
            }
        } else {
            styledScroll(safeAreaTop: 0)
        }
    }

    @ViewBuilder
    private func styledScroll(safeAreaTop: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            scrollContent(safeAreaTop: safeAreaTop)
                .scrollEdgeEffectStyle(heroActive && !showsPageActions ? .soft : .automatic, for: .top)
        } else {
            scrollContent(safeAreaTop: safeAreaTop)
        }
    }

    private func scrollContent(safeAreaTop: CGFloat) -> some View {
        ScrollView {
            // Eager vertical sizing avoids estimated heights changing during scrolling.
            VStack(alignment: .leading, spacing: PlozziOSMediaRailLayout.sectionGap(metrics: metrics)) {
                if heroActive {
                    hero.opacity(mediaOpacity).overlay(alignment: .top) {
                        if showsPageActions {
                            pageActions.padding(.top, safeAreaTop)
                        }
                    }
                    // Underlap only the artwork, not the scroll view's safe-area boundary.
                    .padding(.top, showsPageActions ? -safeAreaTop : 0)
                } else if showsPageActions {
                    pageActions
                }
                rows.opacity(mediaOpacity)
            }
            .padding(.bottom)
            .environment(\.plozziOSHomeViewportWidth, viewportWidth)
            .plozzDesktopMediaRailLayout()
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        // When the page actions are drawn inside the hero overlay, the scroll view
        // keeps its safe area so the actions sit below the status bar. The page
        // actions read the same top inset to match the native toolbar where the
        // detail page shows its download button.
        .ignoresSafeArea(.container, edges: heroActive && !showsPageActions ? .top : [])
        .modifier(PlozziOSReducedTransparencyScrollFade(enabled: heroActive))
        .background {
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
