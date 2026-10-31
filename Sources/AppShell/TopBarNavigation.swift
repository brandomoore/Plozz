#if os(tvOS)
import CoreModels
import CoreUI
import FeatureProfiles
import SwiftUI

enum NavigationChromeMotion {
    static let distance: CGFloat = 12
    static let animation: Animation = .easeInOut(duration: 0.22)
}

enum TopBarNavigationMetrics {
    static let maximumWidthFraction: CGFloat = 0.75
    static let topMargin: CGFloat = 40
    static let contentHeight: CGFloat = 36
    static let itemPadding: CGFloat = 8
    static let panelInset: CGFloat = 8
    static let itemSpacing: CGFloat = 8
    static let itemHeight = contentHeight + 2 * itemPadding
    static let panelHeight = itemHeight + 2 * panelInset
    static let panelRadius = panelHeight / 2
    static let foregroundTop = topMargin + panelHeight + 16
}

struct TopBarNavigation: View {
    let destinations: [NavigationRailDestination]
    @Binding var selection: NavigationRailDestination
    let preventsAccidentalExit: Bool
    let content: (NavigationRailDestination, Bool) -> AnyView
    let label: (NavigationRailDestination) -> AnyView
    var profile: Profile?
    var onOpenProfileSwitcher: (() -> Void)?
    var chrome: NavigationChromeModel?
    var pinsSettings = true
    @State private var fallbackChrome = NavigationChromeModel()

    var body: some View {
        let chrome = chrome ?? fallbackChrome
        return GeometryReader { geometry in
            NavigationRailFocusHost(
                contentExitHeading: .down,
                contentTopInset: TopBarNavigationMetrics.foregroundTop
            ) { owner in
                TopBarNavigationContent(
                    destinations: destinations, selection: $selection,
                    preventsAccidentalExit: preventsAccidentalExit,
                    content: content, label: label,
                    profile: profile, onOpenProfileSwitcher: onOpenProfileSwitcher,
                    chrome: chrome, safeAreaInsets: geometry.safeAreaInsets,
                    maximumBarWidth: geometry.size.width * TopBarNavigationMetrics.maximumWidthFraction,
                    pinsSettings: pinsSettings,
                    onNavigationFocusChanged: { [weak owner] in owner?.isNavigationFocused = $0 }
                )
            }
            .ignoresSafeArea()
        }
        .accessibilityElement(children: .contain)
        .environment(chrome)
    }
}

private struct TopBarNavigationContent: View {
    let destinations: [NavigationRailDestination]
    @Binding var selection: NavigationRailDestination
    let preventsAccidentalExit: Bool
    let content: (NavigationRailDestination, Bool) -> AnyView
    let label: (NavigationRailDestination) -> AnyView
    let profile: Profile?
    let onOpenProfileSwitcher: (() -> Void)?
    let chrome: NavigationChromeModel
    let safeAreaInsets: EdgeInsets
    let maximumBarWidth: CGFloat
    let pinsSettings: Bool
    let onNavigationFocusChanged: (Bool) -> Void

    @Namespace private var focusScope
    @State private var isNavigating = true
    @State private var navigationHasFocus = false
    @State private var navigationRequest: Int? = 0
    @State private var navigationGeneration = 0
    @State private var contentRequest: UInt64?
    @State private var contentGeneration: UInt64 = 0
    @State private var returnFocus = NavigationContentFocusRequester.ReturnFocus()
    @State private var destinationFocus = NavigationDestinationFocusHandoff()
    @State private var scroll = TopNavigationScroll()
    @Environment(\.isEnabled) private var isEnabled
    private var contentInsets: EdgeInsets {
        EdgeInsets(
            // Settings retains its root scroll view beneath subpages.
            top: chrome.isChromeHidden && current != .settings
                ? 0 : TopBarNavigationMetrics.topMargin + TopBarNavigationMetrics.panelHeight,
            leading: safeAreaInsets.leading + PlozzTheme.Metrics.screenPadding,
            bottom: 0,
            trailing: safeAreaInsets.trailing + PlozzTheme.Metrics.screenPadding
        )
    }

    private var current: NavigationRailDestination {
        selection == .settings ? .settings : NavigationRailPlan.resolvedSelection(selection, destinations: destinations)
    }

    private var isShellActive: Bool {
        isEnabled && (selection == .settings || destinations.contains(selection))
    }

    var body: some View {
        ZStack(alignment: .top) {
            pages
                .background {
                    NavigationContentFocusRequester(
                        request: contentRequest, onCompleted: contentFocused,
                        returnFocus: returnFocus, restoresPreviousFocus: true
                    )
                    .padding(.top, TopBarNavigationMetrics.foregroundTop)
                }
                .background {
                    NavigationDestinationPresentationAnchor(
                        destination: current, request: destinationFocus.request,
                        onPresented: destinationPresented
                    )
                }
                .disabled(isNavigating && contentRequest == nil)
                .environment(\.plozzTopNavigationContentInsets, contentInsets)
                .environment(\.plozzTopNavigationScroll, scroll)
            TopBarNavigationBar(
                destinations: destinations, current: current,
                profile: profile, onOpenProfileSwitcher: onOpenProfileSwitcher,
                pinsSettings: pinsSettings,
                isNavigating: isNavigating, isShellActive: isShellActive,
                focusScope: focusScope,
                navigationRequest: navigationRequest,
                onEnter: enterContent,
                onFocusPresenceChanged: navigationFocusChanged,
                onNavigationFocused: { request in
                    if navigationRequest == request { navigationRequest = nil }
                },
                label: label
            )
                .frame(maxWidth: maximumBarWidth)
                .padding(.leading, contentInsets.leading)
                .padding(.trailing, contentInsets.trailing)
                .padding(.top, TopBarNavigationMetrics.topMargin)
                .disabled(!isShellActive || chrome.isChromeHidden || chrome.transitionSuppressesFocus)
                .modifier(TopBarScrollPosition(
                    scroll: scroll, chromeHidden: chrome.isChromeHidden,
                    suppressesFocus: chrome.transitionSuppressesFocus
                ))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .focusScope(focusScope)
        .background { NavigationChromeTransitionAnchor(chrome: chrome) }
        .tvNavigationExitProtection(
            isEnabled: preventsAccidentalExit,
            navigationHasFocus: isNavigating && !chrome.isChromeHidden
        )
        .onExitCommand(perform: !isNavigating && !chrome.isChromeHidden ? openNavigation : nil)
        .onAppear {
            if current == .settings {
                enterContent(.settings)
            } else if isNavigating {
                openNavigation()
            }
        }
        .onChange(of: isNavigating && isShellActive, initial: true) { _, value in
            onNavigationFocusChanged(value)
        }
        .onChange(of: isShellActive) { _, active in
            if active {
                openNavigation()
            } else {
                navigationRequest = nil
                contentRequest = nil
                destinationFocus.cancel()
            }
        }
        .onChange(of: current) { _, _ in
            chrome.resetForDestinationChange()
            if destinationFocus.request?.destination != current { destinationFocus.cancel() }
            contentRequest = nil
            returnFocus.clear()
            if current == .settings, destinationFocus.request == nil {
                navigationRequest = nil
                isNavigating = true
                destinationFocus.begin(.settings)
            }
        }
        .onChange(of: profile?.id) { _, _ in
            returnFocus.clear()
            destinationFocus.cancel()
            contentRequest = nil
        }
        .onChange(of: chrome.isChromeHidden) { _, hidden in
            if hidden {
                navigationRequest = nil
                contentRequest = nil
                destinationFocus.cancel()
                isNavigating = false
            }
        }
        .onDisappear {
            navigationRequest = nil
            contentRequest = nil
            destinationFocus.cancel()
            onNavigationFocusChanged(false)
        }
    }

    private var pages: some View {
        ZStack {
            if current != .liveTV {
                content(current, selection == current)
                    .id(current)
                    .transition(.identity)
            }
            // Preserve the guide's filters and sources without keeping every
            // library grid mounted as focus traverses a long navigation list.
            RetainedLiveTVDestination(isActive: current == .liveTV) {
                content(.liveTV, selection == .liveTV)
            }
            .opacity(current == .liveTV ? 1 : 0)
            .disabled(current != .liveTV)
            .allowsHitTesting(current == .liveTV)
            .accessibilityElement(children: .contain)
            .accessibilityHidden(current != .liveTV)
        }
    }

    private func navigationFocusChanged(_ hasFocus: Bool) {
        navigationHasFocus = hasFocus
        guard hasFocus, isShellActive, !destinationFocus.isWaiting else { return }
        isNavigating = true
        contentRequest = nil
        destinationFocus.cancel()
    }

    private func openNavigation() {
        guard isShellActive, !chrome.isChromeHidden, !chrome.transitionSuppressesFocus else { return }
        contentRequest = nil
        destinationFocus.cancel()
        isNavigating = true
        if scroll.scrollToTop() {
            returnFocus.clear()
        } else {
            returnFocus.capture()
        }
        navigationGeneration &+= 1
        navigationRequest = navigationGeneration
    }

    private func enterContent(_ destination: NavigationRailDestination) {
        guard isShellActive, isNavigating, !chrome.transitionSuppressesFocus else { return }
        navigationRequest = nil
        if destination != current { selection = destination }
        destinationFocus.begin(destination)
    }

    private func destinationPresented(_ request: NavigationDestinationFocusHandoff.Request) {
        guard isShellActive, destinationFocus.complete(request), request.destination == current,
              isNavigating, !chrome.isChromeHidden else { return }
        isNavigating = false
        contentGeneration &+= 1
        contentRequest = contentGeneration
    }

    private func contentFocused(_ request: UInt64, didFocus: Bool) {
        guard isShellActive, contentRequest == request else { return }
        contentRequest = nil
        if !didFocus, navigationHasFocus { openNavigation() }
    }
}

private struct TopBarScrollPosition: ViewModifier {
    let scroll: TopNavigationScroll
    let chromeHidden: Bool
    let suppressesFocus: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(chromeHidden ? 0 : 1)
            .offset(y: chromeHidden && !reduceMotion ? -NavigationChromeMotion.distance : 0)
            .animation(
                suppressesFocus || scroll.offset >= TopBarNavigationMetrics.topMargin + TopBarNavigationMetrics.panelHeight
                    ? nil : NavigationChromeMotion.animation,
                value: chromeHidden
            )
            .offset(y: -scroll.offset)
            .disabled(scroll.offset >= TopBarNavigationMetrics.foregroundTop)
            .accessibilityHidden(chromeHidden || scroll.offset >= TopBarNavigationMetrics.foregroundTop)
    }
}

private struct TopBarNavigationBar: View {
    let destinations: [NavigationRailDestination]
    let current: NavigationRailDestination
    let profile: Profile?
    let onOpenProfileSwitcher: (() -> Void)?
    let pinsSettings: Bool
    let isNavigating: Bool
    let isShellActive: Bool
    let focusScope: Namespace.ID
    let navigationRequest: Int?
    let onEnter: (NavigationRailDestination) -> Void
    let onFocusPresenceChanged: (Bool) -> Void
    let onNavigationFocused: (Int) -> Void
    let label: (NavigationRailDestination) -> AnyView

    private enum Target: Hashable {
        case profile
        case destination(NavigationRailDestination)
    }

    @FocusState private var focused: Target?
    @State private var overflow = HorizontalOverflow()
    @State private var destinationContentWidth: CGFloat?
    @Environment(\.themePalette) private var palette

    private var fixesSettings: Bool { pinsSettings && destinations.contains(.settings) }
    private var focusDestination: NavigationRailDestination {
        NavigationRailPlan.resolvedSelection(current, destinations: destinations)
    }
    private var scrollingDestinations: [NavigationRailDestination] {
        destinations.filter { !fixesSettings || $0 != .settings }
    }

    var body: some View {
        HStack(spacing: TopBarNavigationMetrics.itemSpacing) {
            if let profile, let onOpenProfileSwitcher {
                Button(action: onOpenProfileSwitcher) {
                    ProfileAvatarView(profile: profile, size: 32)
                        .frame(width: TopBarNavigationMetrics.contentHeight, height: TopBarNavigationMetrics.contentHeight)
                        .background { focusMarker(for: .profile) }
                }
                .buttonStyle(NavigationRailItemStyle(
                    expansionProgress: 0, isSelected: false, accent: palette.accent,
                    horizontalPadding: 8, verticalPadding: TopBarNavigationMetrics.itemPadding
                ))
                .focused($focused, equals: .profile)
                .disabled(!canFocus(.profile))
                .accessibilityLabel(Text("Switch Profile"))
                .accessibilityValue(Text(verbatim: profile.name))
                .accessibilityIdentifier("top-navigation-profile")
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: TopBarNavigationMetrics.itemSpacing) {
                        ForEach(scrollingDestinations, id: \.storageValue) { destination in
                            destinationButton(destination).id(destination)
                        }
                    }
                    .padding(.vertical, TopBarNavigationMetrics.panelInset)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                        destinationContentWidth = width
                    }
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .mask {
                    HStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .white], startPoint: .leading, endPoint: .trailing)
                            .frame(width: overflow.leading)
                        Rectangle()
                        LinearGradient(colors: [.white, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: overflow.trailing)
                    }
                    .padding(.vertical, -40)
                }
                .onScrollGeometryChange(for: HorizontalOverflow.self) { geometry in
                    HorizontalOverflow(
                        leading: min(40, max(0, geometry.contentOffset.x + geometry.contentInsets.leading)),
                        trailing: min(40, max(0, geometry.contentSize.width
                            - geometry.contentOffset.x - geometry.containerSize.width))
                    )
                } action: { _, value in
                    overflow = value
                }
                .onChange(of: navigationRequest) { _, request in
                    guard request != nil else { return }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { proxy.scrollTo(focusDestination) }
                }
            }
            .frame(maxWidth: destinationContentWidth)
            if fixesSettings {
                destinationButton(.settings, iconOnly: true)
            }
        }
        .padding(.horizontal, TopBarNavigationMetrics.panelInset)
        .frame(height: TopBarNavigationMetrics.panelHeight)
        .plozzGlassPanel(
            cornerRadius: TopBarNavigationMetrics.panelRadius,
            scrimOpacity: 0.08
        )
        .focusSection()
        .onMoveCommand { direction in
            if direction == .down, focused != nil {
                onEnter(current)
            }
        }
        .onChange(of: focused != nil, initial: true) { _, value in
            onFocusPresenceChanged(value)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("top-navigation")
    }

    private func destinationButton(_ destination: NavigationRailDestination, iconOnly: Bool = false) -> some View {
        Button { onEnter(destination) } label: {
            Group {
                if iconOnly {
                    Image(systemName: "gearshape")
                        .frame(width: TopBarNavigationMetrics.contentHeight)
                        .accessibilityLabel(Text("Settings"))
                } else {
                    label(destination)
                }
            }
                .font(.system(size: 24, weight: .semibold))
                .labelStyle(TopBarNavigationLabelStyle())
                .lineLimit(1)
                .frame(maxWidth: iconOnly ? TopBarNavigationMetrics.contentHeight : 280)
                .frame(height: TopBarNavigationMetrics.contentHeight)
                .background { focusMarker(for: .destination(destination)) }
        }
        .buttonStyle(NavigationRailItemStyle(
            expansionProgress: 0, isSelected: current == destination, accent: palette.accent,
            horizontalPadding: iconOnly ? 8 : 12, verticalPadding: TopBarNavigationMetrics.itemPadding
        ))
        .focused($focused, equals: .destination(destination))
        .prefersDefaultFocus(destination == focusDestination, in: focusScope)
        .disabled(!canFocus(.destination(destination)))
        .accessibilityAddTraits(current == destination ? [.isSelected] : [])
        .accessibilityIdentifier("top-navigation-\(destination.storageValue)")
    }

    private func canFocus(_ target: Target) -> Bool {
        guard isShellActive else { return false }
        if navigationRequest != nil { return target == .destination(focusDestination) }
        return isNavigating || target == .destination(focusDestination)
    }

    private func focusMarker(for target: Target) -> some View {
        NavigationRowFocusRequester(
            request: isShellActive && target == .destination(focusDestination) ? navigationRequest : nil
        ) { request, didFocus in
            guard isShellActive, navigationRequest == request else { return }
            if !didFocus { focused = .destination(focusDestination) }
            onNavigationFocused(request)
        }
    }

    private struct HorizontalOverflow: Equatable {
        var leading: CGFloat = 0
        var trailing: CGFloat = 0
    }
}

private struct TopBarNavigationLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
            configuration.title
                .padding(.trailing, 4)
        }
    }
}
#endif
