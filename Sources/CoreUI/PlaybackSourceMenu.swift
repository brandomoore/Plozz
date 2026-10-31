#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import Observation

/// A provider-neutral action that can share the compact overflow panel with
/// server/version choices.
public struct PlaybackSourceMenuAction: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: LocalizedStringResource
    public let systemImage: String

    public init(id: String, title: LocalizedStringResource, systemImage: String) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
    }

    // `LocalizedStringResource` is Equatable but NOT Hashable, so the synthesized
    // conformance no longer compiles once `title` is localized. Hashing on `id`
    // alone is the right answer regardless: identity must not depend on displayed
    // text, or an action's identity would change with the user's language.
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Keep this owner above adaptive action rows so relayout cannot dismiss a menu.
@MainActor @Observable
public final class PlaybackSourceMenuState {
    public var isPresented = false
    var page = PlaybackSourceMenuButtonPage.root
    var triggerFrame: CGRect = .zero
    var actions: [PlaybackSourceMenuAction] = []

    public init() {}

    public func open(from frame: CGRect, actions: [PlaybackSourceMenuAction] = []) {
        guard !isPresented else { return }
        triggerFrame = frame
        self.actions = actions
        page = .root
        isPresented = true
    }
}

public struct PlaybackSourceMenuTrigger<Label: View>: View {
    let state: PlaybackSourceMenuState
    let actions: [PlaybackSourceMenuAction]
    let label: Label
    @State private var frame: CGRect = .zero

    public init(
        state: PlaybackSourceMenuState,
        actions: [PlaybackSourceMenuAction] = [],
        @ViewBuilder label: () -> Label
    ) {
        self.state = state
        self.actions = actions
        self.label = label()
    }

    public var body: some View {
        Button { state.open(from: frame, actions: actions) } label: { label }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
    }
}

public extension View {
    func playbackSourceMenu(
        state: PlaybackSourceMenuState,
        sources: [MediaSourceRef], selectedSourceID: String?,
        offlineSourceAccountIDs: Set<String> = [],
        versions: [MediaVersion], selectedVersionID: String?,
        loadVersions: MediaVersionInventoryLoader? = nil,
        onSelectSource: @escaping (String) -> Void,
        onSelectVersion: @escaping (String) -> Void,
        onPerformAction: @escaping (String) -> Void = { _ in },
        onDismiss: @escaping () -> Void = {}
    ) -> some View {
        modifier(PlaybackSourceMenuPresentation(
            sources: sources, selectedSourceID: selectedSourceID,
            offlineSourceAccountIDs: offlineSourceAccountIDs,
            versions: versions, selectedVersionID: selectedVersionID,
            loadVersions: loadVersions,
            onSelectSource: onSelectSource, onSelectVersion: onSelectVersion,
            onPerformAction: onPerformAction, onDismiss: onDismiss, state: state
        ))
    }
}

/// Standalone source selector. Adaptive rows use a trigger and a stable owner instead.
public struct PlaybackSourceMenuButton<Label: View>: View {
    private let sources: [MediaSourceRef]
    private let selectedSourceID: String?
    /// Accounts that are currently offline / unreachable — shown greyed with an
    /// "Offline" tag and not selectable.
    private let offlineSourceAccountIDs: Set<String>
    private let versions: [MediaVersion]
    private let selectedVersionID: String?
    private let loadVersions: MediaVersionInventoryLoader?
    private let actions: [PlaybackSourceMenuAction]
    private let onSelectSource: (String) -> Void
    private let onSelectVersion: (String) -> Void
    private let onPerformAction: (String) -> Void
    private let onDismiss: () -> Void
    private let label: Label

    @State private var state = PlaybackSourceMenuState()

    public init(
        sources: [MediaSourceRef],
        selectedSourceID: String?,
        offlineSourceAccountIDs: Set<String> = [],
        versions: [MediaVersion],
        selectedVersionID: String?,
        loadVersions: MediaVersionInventoryLoader? = nil,
        actions: [PlaybackSourceMenuAction] = [],
        onSelectSource: @escaping (String) -> Void,
        onSelectVersion: @escaping (String) -> Void,
        onPerformAction: @escaping (String) -> Void = { _ in },
        onDismiss: @escaping () -> Void = {},
        @ViewBuilder label: () -> Label
    ) {
        self.sources = sources
        self.selectedSourceID = selectedSourceID
        self.offlineSourceAccountIDs = offlineSourceAccountIDs
        self.versions = versions
        self.selectedVersionID = selectedVersionID
        self.loadVersions = loadVersions
        self.actions = actions
        self.onSelectSource = onSelectSource
        self.onSelectVersion = onSelectVersion
        self.onPerformAction = onPerformAction
        self.onDismiss = onDismiss
        self.label = label()
    }

    public var body: some View {
        PlaybackSourceMenuTrigger(state: state, actions: actions) { label }
            .playbackSourceMenu(
                state: state, sources: sources, selectedSourceID: selectedSourceID,
                offlineSourceAccountIDs: offlineSourceAccountIDs,
                versions: versions, selectedVersionID: selectedVersionID,
                loadVersions: loadVersions,
                onSelectSource: onSelectSource, onSelectVersion: onSelectVersion,
                onPerformAction: onPerformAction, onDismiss: onDismiss
            )
    }
}

private struct PlaybackSourceMenuPresentation: ViewModifier {
    let sources: [MediaSourceRef]
    let selectedSourceID: String?
    let offlineSourceAccountIDs: Set<String>
    let versions: [MediaVersion]
    let selectedVersionID: String?
    let loadVersions: MediaVersionInventoryLoader?
    let onSelectSource: (String) -> Void
    let onSelectVersion: (String) -> Void
    let onPerformAction: (String) -> Void
    let onDismiss: () -> Void
    @Bindable var state: PlaybackSourceMenuState
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .plozzFullScreenCover(isPresented: $state.isPresented, onDismiss: onDismiss) {
                #if os(tvOS)
                tvOSPresentation
                #else
                iosPresentation
                #endif
            }
            // Kill the cover's own bottom-up slide: this is a menu anchored to a
            // button, not a drawer. The panel fades/scales in from the trigger
            // instead (see `iosPresentation`).
            .transaction(value: state.isPresented) { $0.disablesAnimations = true }
    }

    #if !os(tvOS)
    /// iOS/iPadOS presentation. Deliberately NOT `.sheet` or `.popover`: both
    /// own a surface of their own (so our panel nests inside a second one), and
    /// neither can animate its own height. This mirrors the tvOS player's
    /// subtitle panel — a plain overlay anchored to the trigger, so the panel is
    /// the one and only surface and its height is an ordinary animatable frame.
    private var iosPresentation: some View {
        GeometryReader { proxy in
            // Lay the menu out inside the SAFE AREA, not the raw screen, so it
            // can never reach into the status bar / notch or the home indicator.
            // The trigger frame is captured in global space, so shift it into
            // this safe-area-relative space before using it.
            let insets = proxy.safeAreaInsets
            let screen = proxy.size
            let anchor = state.triggerFrame
            let trigger = anchor.offsetBy(dx: -insets.leading, dy: -insets.top)
            let margin: CGFloat = 16
            let gap: CGFloat = 12
            let width = min(390, screen.width - margin * 2)
            // Computed fresh every layout pass, NOT captured once on appear:
            // the first pass inside a freshly presented cover can report
            // incomplete geometry, and freezing that snapshot left the panel
            // mispositioned until it was reopened. Safe to recompute because the
            // placement depends only on the trigger and the window — never on
            // the panel's height — so a growing page can't move it.
            let side = PlaybackSourceMenuSide.choose(
                trigger: trigger,
                screen: screen,
                width: width,
                gap: gap,
                margin: margin
            )
            let layout = side.layout(
                trigger: trigger,
                screen: screen,
                width: width,
                gap: gap,
                margin: margin
            )
            // Align to the edge that touches the button so the layout system
            // holds it. The panel's height is then the ONLY thing animating, and
            // the pinned edge physically cannot move while it does.
            ZStack(alignment: layout.pinsBottom ? .bottomLeading : .topLeading) {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { state.isPresented = false }

                panel(maxHeight: layout.available)
                    .frame(width: width)
                    .padding(.leading, layout.x)
                    .padding(layout.pinsBottom ? .bottom : .top, layout.inset)
                    // Placement must never interpolate. The first layout pass in
                    // a freshly presented cover can report incomplete geometry,
                    // and the corrected position lands around the same time as
                    // the fade-in's transaction — which would otherwise animate
                    // it, so the panel appeared to fly in from somewhere else on
                    // the first open. Only the height animates.
                    .animation(nil, value: layout.x)
                    .animation(nil, value: layout.inset)
                    .animation(nil, value: layout.pinsBottom)
                    .scaleEffect(appeared ? 1 : 0.94, anchor: side.growthAnchor)
                    .opacity(appeared ? 1 : 0)
            }
            .frame(width: screen.width, height: screen.height)
            // Placement changes must never interpolate — including the ZStack's
            // alignment, which is a PARENT property that a child's
            // .animation(nil:) can't cover. Flipping it under an ambient
            // transaction slides the panel between the top- and bottom-pinned
            // positions, which reads as the panel flying in.
            .animation(nil, value: layout.pinsBottom)
            .animation(nil, value: layout.inset)
            .animation(nil, value: layout.x)
            .onAppear {
                // Let the panel measure and snap to its natural size before it
                // becomes visible, so the fade-in never shows the placeholder
                // size (or the position derived from it).
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.18)) { appeared = true }
                }
            }
            .onDisappear { appeared = false }
        }
        .presentationBackground(.clear)
    }
    #endif

    #if os(tvOS)
    private var tvOSPresentation: some View {
        GeometryReader { geometry in
            let margin: CGFloat = 32
            let width = min(PlaybackSourceMenuMetrics.panelWidth(for: state.page),
                            max(0, geometry.size.width - margin * 2))
            let height = min(panelHeight, max(0, geometry.size.height - margin * 2))
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { state.isPresented = false }

                panel(maxHeight: height, maxWidth: width)
                    .offset(
                        x: min(max(margin, state.triggerFrame.minX), geometry.size.width - width - margin),
                        y: min(max(margin, state.triggerFrame.minY - height - 12),
                               geometry.size.height - height - margin)
                    )
            }
        }
        .ignoresSafeArea()
        .presentationBackground(.clear)
    }
    #endif

    private func panel(maxHeight: CGFloat = 620, maxWidth: CGFloat = 800) -> some View {
        PlaybackSourceMenuPanel(
            page: $state.page,
            maxHeight: maxHeight,
            maxWidth: maxWidth,
            sources: sources,
            selectedSourceID: selectedSourceID,
            offlineSourceAccountIDs: offlineSourceAccountIDs,
            versions: versions.sortedForPicker(),
            selectedVersionID: selectedVersionID,
            loadVersions: loadVersions,
            actions: state.actions,
            onSelectSource: { id in
                onSelectSource(id)
                state.isPresented = false
            },
            onSelectVersion: { id in
                onSelectVersion(id)
                state.isPresented = false
            },
            onPerformAction: { id in
                onPerformAction(id)
                state.isPresented = false
            }
        )
        #if os(tvOS)
        .onExitCommand {
            handleExit()
        }
        #endif
    }

    private var panelHeight: CGFloat {
        PlaybackSourceMenuMetrics.panelHeight(
            page: state.page,
            sourceCount: sources.count,
            versionCount: versions.count,
            actionCount: state.actions.count
        )
    }

    private func handleExit() {
        if state.page != .root {
            withAnimation(.easeInOut(duration: 0.28)) {
                state.page = .root
            }
        } else {
            state.isPresented = false
        }
    }
}

struct PlaybackSourceMenuPanel: View {
    @Binding var page: PlaybackSourceMenuButtonPage
    /// Ceiling imposed by the room available on the trigger's chosen side.
    /// Past this the rows scroll rather than the panel running off screen.
    #if os(tvOS)
    var maxHeight: CGFloat = 820
    #else
    var maxHeight: CGFloat = 620
    #endif
    var maxWidth: CGFloat = 800
    let sources: [MediaSourceRef]
    let selectedSourceID: String?
    var offlineSourceAccountIDs: Set<String> = []
    let versions: [MediaVersion]
    let selectedVersionID: String?
    var loadVersions: MediaVersionInventoryLoader? = nil
    let actions: [PlaybackSourceMenuAction]
    let onSelectSource: (String) -> Void
    let onSelectVersion: (String) -> Void
    let onPerformAction: (String) -> Void

    @Namespace private var panelFocusScope
    @Environment(\.locale) private var locale
    #if os(tvOS)
    @Environment(\.resetFocus) private var resetFocus
    #endif
    @FocusState private var focusedRowID: String?
    #if !os(tvOS)
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var navDirection: Edge = .trailing
    @State private var contentHeight: CGFloat = 220
    /// The page the current `contentHeight` was measured for. Height changes
    /// only animate when this differs from the page on screen (a real drill-in);
    /// a re-measure of the same page is a geometry correction and snaps.
    @State private var measuredPage: PlaybackSourceMenuButtonPage?
    #endif
    var body: some View {
        panelContent
            #if os(tvOS)
            .frame(width: min(PlaybackSourceMenuMetrics.panelWidth(for: page), maxWidth))
            .frame(height: min(panelHeight, maxHeight), alignment: .top)
            // Page content swaps immediately; only the glass container morphs.
            .animation(nil, value: page)
            // tvOS presents the panel bare inside a full-screen cover, so it has
            // to draw its own glass surface.
            .plozzGlassPanel(cornerRadius: 32, scrimOpacity: 0.08)
            #else
            // The panel is presented as a bare overlay (no sheet, no popover), so
            // it owns the ONE surface and an explicit, animatable height. Width
            // comes from the presenter.
            .frame(height: contentHeight, alignment: .top)
            .onPreferenceChange(PlaybackSourceMenuContentHeightKey.self) { measurements in
                // Read only the page being shown: during the push the outgoing
                // page is still reporting, and letting it win pins the panel at
                // the wrong height for the whole transition (which is what made
                // the height look like it wasn't animating at all).
                guard let measured = measurements.first(where: { $0.page == page })?.height,
                      measured > 0 else { return }
                let total = min(measured, maxHeight)
                guard abs(total - contentHeight) > 0.5 else { return }
                if let measuredPage, measuredPage != page {
                    // The page changed → this is a real drill-in, so morph the
                    // container.
                    self.measuredPage = page
                    withAnimation(.easeInOut(duration: 0.3)) {
                        contentHeight = total
                    }
                } else {
                    // Either the first measurement of this presentation, or the
                    // SAME page re-measuring because the available height
                    // changed — which happens when the cover's first layout pass
                    // reported incomplete geometry and the corrected pass lands
                    // afterwards. Neither is a content change, so snap: animating
                    // them moves the free edge and the panel appears to fly in.
                    measuredPage = page
                    var snap = Transaction()
                    snap.disablesAnimations = true
                    withTransaction(snap) { contentHeight = total }
                }
            }
            .plozzGlassPanel(cornerRadius: 32, scrimOpacity: 0.08)
            #endif
            #if os(tvOS)
            .focusScope(panelFocusScope)
            .focusSection()
            .defaultFocus($focusedRowID, initialRowID)
            #endif
            .onAppear { focusFirstRow() }
            .onChange(of: page) { _, _ in focusFirstRow() }
            .onChange(of: versions.map(\.id)) { _, _ in focusFirstRow() }
    }

    @ViewBuilder
    private var panelContent: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 12) {
            if page != .root {
                header(for: page)
            }
            ScrollView {
                LazyVStack(spacing: 8) { rows(for: page) }
                    .padding(14)
            }
            .scrollIndicators(.hidden)
            // A shorter page must not inherit the outgoing page's native offset.
            .id(page)
        }
        #else
        // Pages slide horizontally as you drill in/out. The column scrolls
        // because the panel has an explicit (animating) height, so a page taller
        // than the cap stays reachable.
        ScrollView {
            pageColumn(for: page)
                .transition(.push(from: navDirection))
                .id(page)
        }
        .scrollIndicators(.hidden)
        #endif
    }

    #if !os(tvOS)
    /// One page of the menu, built for an explicit page value so the instance
    /// left behind by the push transition keeps rendering — and reporting the
    /// height of — *its own* content.
    @ViewBuilder
    private func pageColumn(for pageValue: PlaybackSourceMenuButtonPage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if pageValue != .root {
                header(for: pageValue)
            }
            // Deliberately NOT lazy: during the horizontal push the incoming
            // page starts off-screen, so a LazyVStack only materialises the
            // row the focus lands on and the rest pop in on arrival instead
            // of travelling with the transition. A menu is a handful of rows,
            // so eager layout costs nothing and animates as one page.
            VStack(spacing: 0) { rows(for: pageValue) }
        }
        .padding(14)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: PlaybackSourceMenuContentHeightKey.self,
                    value: [
                        PlaybackSourceMenuPageHeight(
                            page: pageValue,
                            height: proxy.size.height
                        )
                    ]
                )
            }
        )
    }
    #endif

    @ViewBuilder
    private func rows(for pageValue: PlaybackSourceMenuButtonPage) -> some View {
        switch pageValue {
        case .root:
            rootRows
        case .servers:
            serverRows
        case .versions:
            versionRows
        }
    }

    @ViewBuilder
    private func header(for pageValue: PlaybackSourceMenuButtonPage) -> some View {
        HStack(spacing: 12) {
            if pageValue != .root {
                Button {
                    navigate(to: .root)
                } label: {
                    Image(systemName: "chevron.backward")
                        .accessibilityLabel("Back")
                }
                .buttonStyle(PlozzPanelHeaderButtonStyle())
                .focusEffectDisabled()
                .focused($focusedRowID, equals: "header.back")
            }
            Text(pageValue == .servers ? "Servers" : "Versions")
                .font(.headline.weight(.semibold))
            Spacer()
        }
        #if os(tvOS)
        .padding(.horizontal, 20)
        .padding(.top, 18)
        #endif
    }

    @ViewBuilder
    private var rootRows: some View {
        let hasServer = sources.count > 1
        let hasVersion = versions.count > 1
        if hasServer {
            drillInRow(
                id: "root.servers",
                title: "Server",
                detail: selectedSource.map { Text(verbatim: $0.displayName) }
                    ?? Text("Choose a server", comment: "Placeholder shown in Settings when no server is selected yet."),
                destination: .servers
            ) {
                // Carry the active server's provider brand up to the summary row
                // so the collapsed menu already says "this is a Jellyfin server"
                // — the same mark you'd see one level deeper in the list.
                if let provider = selectedSource?.providerKind {
                    ProviderBrandMark(
                        provider: provider,
                        size: providerMarkSize,
                        showsBackground: false
                    )
                } else {
                    Image(systemName: "server.rack")
                        .frame(width: providerMarkSize)
                        .settingsRowIcon()
                }
            }
        }
        if hasVersion {
            #if !os(tvOS)
            if hasServer { rowSeparator }
            #endif
            drillInRow(
                id: "root.versions",
                title: "Version",
                detail: PlaybackSourceMenuVersionSummary(
                    version: selectedVersion,
                    fallback: selectedVersion.map { versionTitleText($0.displayLabel) }
                        ?? Text("Choose a version", comment: "Placeholder shown in Settings when no playback version is selected yet.")
                ),
                destination: .versions
            ) {
                Image(systemName: "film.stack")
                    .frame(width: providerMarkSize)
                    .settingsRowIcon()
            }
        }
        if !actions.isEmpty, hasServer || hasVersion {
            Divider().padding(.vertical, 4)
        }
        ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
            #if !os(tvOS)
            if index > 0 { rowSeparator }
            #endif
            menuRowButton(id: "action.\(action.id)") {
                onPerformAction(action.id)
            } label: {
                Label(action.title, systemImage: action.systemImage)
                    .font(rowTitleFont)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var serverRows: some View {
        ForEach(Array(sources.enumerated()), id: \.element.accountID) { index, source in
            #if !os(tvOS)
            if index > 0 { rowSeparator }
            #endif
            let isOffline = offlineSourceAccountIDs.contains(source.accountID)
            if isOffline {
                offlineServerRow(source)
            } else {
                menuRowButton(id: "server.\(source.accountID)") {
                    onSelectSource(source.accountID)
                } label: {
                    serverRowLabel(source, isOffline: false)
                }
            }
        }
    }

    /// A non-selectable, greyed server row with an "Offline" tag, shown for a
    /// server whose alternate-source fetch failed (unreachable). It's rendered as
    /// plain (non-button) content so the tvOS focus engine skips it entirely — you
    /// can't land on or pick a server that can't load.
    @ViewBuilder
    private func offlineServerRow(_ source: MediaSourceRef) -> some View {
        serverRowLabel(source, isOffline: true)
            .padding(.horizontal, 16)
            .modifier(
                PlaybackSourceMenuRowHeight(
                    fixedHeight: nil,
                    verticalPadding: rowVerticalPadding
                )
            )
            .opacity(0.45)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(source.displayName), offline")
    }

    @ViewBuilder
    private func serverRowLabel(_ source: MediaSourceRef, isOffline: Bool) -> some View {
        HStack(spacing: 14) {
            if let provider = source.providerKind {
                ProviderBrandMark(
                    provider: provider,
                    size: providerMarkSize,
                    showsBackground: false
                )
            } else {
                Image(systemName: "server.rack")
                    .frame(width: providerMarkSize, height: providerMarkSize)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(source.displayName)
                    .font(rowTitleFont)
                if isOffline {
                    Text("Offline")
                        .font(rowDetailFont)
                        .settingsRowSecondary()
                } else if let subtitle = sourceSubtitle(source) {
                    Text(subtitle)
                        .font(rowDetailFont)
                        .settingsRowSecondary()
                }
            }
            Spacer(minLength: 12)
            if isOffline {
                Image(systemName: "exclamationmark.triangle")
                    .font(.headline)
            } else if source.accountID == selectedSourceID {
                Image(systemName: "checkmark")
                    .font(.headline.weight(.bold))
            }
        }
    }

    @ViewBuilder
    private var versionRows: some View {
        MediaVersionInventoryContent(versions: versions, loadVersions: loadVersions) { inventory in
            VStack(spacing: 12) {
                ForEach(inventory.sortedForPicker()) { version in
                    let rowID = "version.\(version.id)"
                    MediaVersionChoiceButton(
                        presentation: .init(version, locale: locale),
                        isSelected: version.id == selectedVersionID,
                        isFocused: focusedRowID == rowID
                    ) {
                        onSelectVersion(version.id)
                    }
                    .focused($focusedRowID, equals: rowID)
                    .accessibilityIdentifier(rowID)
                    #if os(tvOS)
                    .prefersDefaultFocus(rowID == initialRowID, in: panelFocusScope)
                    #endif
                }
            }
            .onAppear {
                #if os(tvOS)
                if let selected = inventory.first(where: { $0.id == selectedVersionID })
                    ?? inventory.sortedForPicker().first {
                    focusedRowID = "version.\(selected.id)"
                    resetFocus(in: panelFocusScope)
                }
                #endif
            }
        }
    }

    /// Renders a `MediaVersion` title: the joined technical facts (or provider
    /// name) verbatim when known, otherwise our own generic "Version" copy —
    /// kept as a real resource here rather than baked into a `String` so it
    /// translates like everything else.
    private func versionTitleText(_ displayLabel: String?) -> Text {
        if let displayLabel {
            return Text(verbatim: displayLabel)
        }
        return Text("Version", comment: "Generic label for a playback version/source with no distinguishing facts (resolution, edition, etc.) known.")
    }

    private func drillInRow<Detail: View, Icon: View>(
        id: String,
        title: LocalizedStringKey,
        detail: Detail,
        destination: PlaybackSourceMenuButtonPage,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        let iconView = icon()
        let category = Text(title)
            .font(rowCategoryFont)
            .textCase(.uppercase)
            .tracking(0.8)
            .settingsRowSecondary()
        let chevron = Image(systemName: "chevron.forward")
            .settingsRowSecondary()
        #if os(tvOS)
        let stacksSummary = false
        #else
        let stacksSummary = destination == .versions && dynamicTypeSize.isAccessibilitySize
        #endif
        return menuRowButton(id: id, fixedHeight: rootRowHeight) {
            navigate(to: destination)
        } label: {
            if stacksSummary {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        category
                        Spacer(minLength: 12)
                        chevron
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    }
                    detail
                        .font(rowTitleFont)
                }
                .multilineTextAlignment(.leading)
            } else {
                HStack(spacing: 14) {
                    iconView
                    VStack(alignment: .leading, spacing: 4) {
                        category
                        detail
                            .font(rowTitleFont)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 12)
                    chevron
                }
            }
        }
    }

    private func menuRowButton<Content: View>(
        id: String,
        fixedHeight: CGFloat? = nil,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Content
    ) -> some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 16)
                .modifier(
                    PlaybackSourceMenuRowHeight(
                       fixedHeight: fixedHeight,
                       verticalPadding: rowVerticalPadding
                    )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
        .focused($focusedRowID, equals: id)
        #if os(tvOS)
        .prefersDefaultFocus(id == initialRowID, in: panelFocusScope)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
        #endif
    }

    #if !os(tvOS)
    /// A hairline divider between flat rows on iOS/iPadOS. The rows sit directly
    /// on the single glass panel (no per-row card), so a leading-inset separator
    /// gives the grouped-list feel without nesting cards inside the panel.
    private var rowSeparator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }
    #endif

    private var selectedSource: MediaSourceRef? {
        sources.first { $0.accountID == selectedSourceID } ?? sources.first
    }

    private var selectedVersion: MediaVersion? {
        versions.first { $0.id == selectedVersionID } ?? versions.first
    }

    private func sourceSubtitle(_ source: MediaSourceRef) -> String? {   // l10n:content — server/source detail from the provider
        var parts: [String] = []
        if let provider = source.providerKind?.displayName,
           provider.caseInsensitiveCompare(source.displayName) != .orderedSame {
            parts.append(provider)
        }
        if let account = source.accountName,
           account.caseInsensitiveCompare(source.displayName) != .orderedSame {
            parts.append(account)
        }
        if source.versions.count > 1 {
            parts.append("\(source.versions.count) versions")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func focusFirstRow() {
        // tvOS only: the focus engine needs an explicit landing row per page.
        // On iOS/iPadOS programmatically focusing a row inside the ScrollView
        // makes UIKit scroll that row into view mid-transition, which is what
        // made the selected server behave differently from its siblings.
        #if os(tvOS)
        focusedRowID = initialRowID
        resetFocus(in: panelFocusScope)
        #endif
    }

    private func navigate(to destination: PlaybackSourceMenuButtonPage) {
        #if !os(tvOS)
        // Deeper (root → servers/versions) slides in from the trailing edge; going
        // back to root slides in from the leading edge.
        navDirection = destination == .root ? .leading : .trailing
        #endif
        withAnimation(.easeInOut(duration: 0.28)) {
            page = destination
        }
    }

    private var initialRowID: String? {
        switch page {
        case .root:
            if sources.count > 1 { return "root.servers" }
            if versions.count > 1 { return "root.versions" }
            return actions.first.map { "action.\($0.id)" }
        case .servers:
            let source = sources.first { $0.accountID == selectedSourceID } ?? sources.first
            return source.map { "server.\($0.accountID)" }
        case .versions:
            let version = versions.first { $0.id == selectedVersionID } ?? versions.first
            return version.map { "version.\($0.id)" }
        }
    }

    private var panelHeight: CGFloat {
        PlaybackSourceMenuMetrics.panelHeight(
            page: page,
            sourceCount: sources.count,
            versionCount: versions.count,
            actionCount: actions.count
        )
    }

    private var providerMarkSize: CGFloat {
        #if os(tvOS)
        34
        #else
        24
        #endif
    }


    private var rowVerticalPadding: CGFloat {
        #if os(tvOS)
        18
        #else
        13
        #endif
    }

    private var rootRowHeight: CGFloat? {
        #if os(tvOS)
        82
        #else
        nil
        #endif
    }

    private var rowTitleFont: Font {
        #if os(tvOS)
        .system(size: 26, weight: .semibold)
        #else
        .body.weight(.semibold)
        #endif
    }

    private var rowDetailFont: Font {
        #if os(tvOS)
        .system(size: 20)
        #else
        .subheadline
        #endif
    }

    private var rowCategoryFont: Font {
        #if os(tvOS)
        .system(size: 14, weight: .semibold)
        #else
        .caption2.weight(.semibold)
        #endif
    }

}

private struct PlaybackSourceMenuVersionSummary: View {
    let version: MediaVersion?
    let fallback: Text

    var body: some View {
        #if os(tvOS)
        fallback
        #else
        let pictureFacts = [
            ("edition", version?.editionLabel),
            ("resolution", version?.resolutionLabel),
            ("range", version?.hdrLabel)
        ].compactMap { id, text in text.map { (id: id, text: $0) } }
        let fileFacts = [
            ("source", version?.sourceQualityLabel),
            ("size", version?.sizeLabel)
        ].compactMap { id, text in text.map { (id: id, text: $0) } }
        VStack(alignment: .leading, spacing: 4) {
            if !pictureFacts.isEmpty {
                PlaybackSourceMenuSummaryFacts(facts: pictureFacts)
                if !fileFacts.isEmpty {
                    PlaybackSourceMenuSummaryFacts(facts: fileFacts)
                        .font(.subheadline)
                        .settingsRowSecondary()
                }
            } else if !fileFacts.isEmpty {
                PlaybackSourceMenuSummaryFacts(facts: fileFacts)
            } else {
                fallback
            }
        }
        .lineLimit(nil)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fallback)
        #endif
    }
}

#if !os(tvOS)
private struct PlaybackSourceMenuSummaryFacts: View {
    let facts: [(id: String, text: String)]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(verbatim: facts.map(\.text).joined(separator: " · "))
                .fixedSize()
            // Separators belong only to a complete inline group, never a line edge.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(facts, id: \.id) { fact in
                    Text(verbatim: fact.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
#endif

private struct PlaybackSourceMenuRowHeight: ViewModifier {
    let fixedHeight: CGFloat?
    let verticalPadding: CGFloat

    func body(content: Content) -> some View {
        if let fixedHeight {
            content.frame(height: fixedHeight)
        } else {
            content.padding(.vertical, verticalPadding)
        }
    }
}

// The generic button's nested type cannot be named in a non-generic panel.
enum PlaybackSourceMenuButtonPage: Hashable {
    case root
    case servers
    case versions
}

#if !os(tvOS)
/// Where the menu panel sits relative to its trigger. Derived from the trigger
/// and the window only — deliberately NOT from the panel's height — so it stays
/// put as the panel grows and can be recomputed on any layout pass. Drives
/// placement, the height cap, and the growth anchor.
struct PlaybackSourceMenuSide: Equatable {
    enum Side { case trailing, leading, above, below }
    let side: Side
    /// For a side placement: whether the panel hangs upward from the trigger's
    /// bottom edge rather than downward from its top edge. Chosen from where the
    /// room actually is, so a button near the bottom of the window opens into the
    /// space above it instead of being squeezed against the bottom edge.
    let growsUp: Bool

    /// Prefer sitting beside the button — that's where a menu reads as attached
    /// to its trigger, and beside it the panel can use the window's full height
    /// because it doesn't have to clear the button. Fall back to above/below,
    /// whichever has more room, only when neither side fits the panel's width.
    static func choose(
        trigger: CGRect,
        screen: CGSize,
        width: CGFloat,
        gap: CGFloat,
        margin: CGFloat
    ) -> PlaybackSourceMenuSide {
        // Beside the trigger, the usable column runs from the trigger's top edge
        // down, or from its bottom edge up. Take whichever is taller.
        let roomDown = screen.height - margin - trigger.minY
        let roomUp = trigger.maxY - margin
        let growsUp = roomUp > roomDown

        let roomTrailing = screen.width - trigger.maxX - gap - margin
        if roomTrailing >= width {
            return .init(side: .trailing, growsUp: growsUp)
        }
        let roomLeading = trigger.minX - gap - margin
        if roomLeading >= width {
            return .init(side: .leading, growsUp: growsUp)
        }
        let roomAbove = trigger.minY - gap - margin
        let roomBelow = screen.height - trigger.maxY - gap - margin
        return .init(side: roomAbove >= roomBelow ? .above : .below, growsUp: false)
    }

    /// Where the panel goes, and how tall it may grow before its rows scroll.
    ///
    /// Returns an INSET FROM A PINNED EDGE rather than a top-left origin: the
    /// caller aligns the panel to that edge, so the edge touching the button is
    /// held by the layout system and only the far edge moves when the height
    /// changes. Computing a top-left origin from the height instead meant the
    /// height and the offset were two separate animations, and any drift between
    /// them showed up as the pinned edge drifting too — the panel overshooting
    /// and settling back.
    ///
    /// `available` is always the room in the chosen direction, so the panel can
    /// never grow off screen.
    func layout(
        trigger: CGRect,
        screen: CGSize,
        width: CGFloat,
        gap: CGFloat,
        margin: CGFloat
    ) -> (x: CGFloat, inset: CGFloat, pinsBottom: Bool, available: CGFloat) {
        switch side {
        case .trailing, .leading:
            let x = side == .trailing
                ? trigger.maxX + gap
                : trigger.minX - gap - width
            if growsUp {
                let bottom = min(screen.height - margin, max(margin + 160, trigger.maxY))
                return (x, screen.height - bottom, true, max(160, bottom - margin))
            } else {
                let top = max(margin, min(trigger.minY, screen.height - margin - 160))
                return (x, top, false, max(160, screen.height - margin - top))
            }
        case .above, .below:
            let x = min(
                max(margin, trigger.midX - width / 2),
                max(margin, screen.width - width - margin)
            )
            if side == .above {
                let bottom = trigger.minY - gap
                return (x, screen.height - bottom, true, max(160, bottom - margin))
            } else {
                let top = trigger.maxY + gap
                return (x, top, false, max(160, screen.height - margin - top))
            }
        }
    }

    /// Scale the opening panel out of the corner/edge pinned to the button.
    var growthAnchor: UnitPoint {
        switch side {
        case .trailing: growsUp ? .bottomLeading : .topLeading
        case .leading: growsUp ? .bottomTrailing : .topTrailing
        case .above: .bottom
        case .below: .top
        }
    }
}
#endif

#if !os(tvOS)
/// Each rendered page's natural height, tagged with the page it belongs to.
/// During the push transition the outgoing and incoming pages are both on
/// screen and both report; an untagged `max()` reduce would hold the taller of
/// the two for the whole transition, so the sheet jumped to its new height at
/// one end instead of easing. Tagging lets the panel read only the page it is
/// currently showing.
private struct PlaybackSourceMenuPageHeight: Equatable {
    let page: PlaybackSourceMenuButtonPage
    let height: CGFloat
}

private struct PlaybackSourceMenuContentHeightKey: PreferenceKey {
    static let defaultValue: [PlaybackSourceMenuPageHeight] = []
    static func reduce(
        value: inout [PlaybackSourceMenuPageHeight],
        nextValue: () -> [PlaybackSourceMenuPageHeight]
    ) {
        value.append(contentsOf: nextValue())
    }
}

#endif

private enum PlaybackSourceMenuMetrics {
    #if os(tvOS)
    static func panelWidth(for page: PlaybackSourceMenuButtonPage) -> CGFloat {
        page == .versions ? 800 : 620
    }
    #endif

    static func panelHeight(
        page: PlaybackSourceMenuButtonPage,
        sourceCount: Int,
        versionCount: Int,
        actionCount: Int
    ) -> CGFloat {
        #if os(tvOS)
        switch page {
        case .root:
            let optionCount = (sourceCount > 1 ? 1 : 0) + (versionCount > 1 ? 1 : 0)
            let rowCount = optionCount + actionCount
            let rowSpacing = CGFloat(max(rowCount - 1, 0)) * 8
            let dividerHeight: CGFloat = optionCount > 0 && actionCount > 0 ? 17 : 0
            let contentHeight = CGFloat(optionCount) * 82
                + CGFloat(actionCount) * 67
                + rowSpacing
                + dividerHeight
            return min(max(contentHeight + 28, 110), 700)
        case .servers:
            return min(max(CGFloat(sourceCount) * 104 + 94, 250), 700)
        case .versions:
            return min(max(CGFloat(versionCount) * 190 + 94, 360), 820)
        }
        #else
        return 620
        #endif
    }
}

#endif
