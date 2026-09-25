#if canImport(SwiftUI) && canImport(UIKit)
import AVFoundation
import CoreModels
import CoreUI
import SwiftUI

/// The bottom card's tabs. Guide's card is the EPG grid, taller than the rest.
enum LiveChannelCardTab: Hashable, CaseIterable {
    case info, onNow, guide

    var title: LocalizedStringResource {
        switch self {
        case .info:
            LocalizedStringResource(
                "player.category.info", defaultValue: "Info",
                comment: "Tab in the in-player options panel showing playback details."
            )
        case .onNow: LocalizedStringResource(
            "live.player.tab.onNow", defaultValue: "On Now",
            comment: "Tab beneath the live TV timeline showing what other channels are airing."
        )
        case .guide: LocalizedStringResource(
            "live.player.tab.guide", defaultValue: "Guide",
            comment: "Tab beneath the live TV timeline showing the channel guide under the video."
        )
        }
    }

    var identifier: String {
        switch self {
        case .info: "live-channel-info"
        case .onNow: "live-channel-on-now"
        case .guide: "live-channel-guide"
        }
    }
}

/// The expanded live channel's transport, built from the VOD player's parts.
///
/// Same stack as `PlayerControls`, bottom-up: the card, the tab row
/// (Info · On Now · Guide), the timeline, and the title with its button
/// badges. The card is a permanent member of the stack and the whole cluster is
/// parked by ONE offset — the VOD transport's rule 2 — so the reveal moves as a
/// unit. The track menus float in a layer of their own above the badges, so they
/// can never cover the timeline.
///
/// Remote: the timeline is the hub, as the scrub bar is for VOD. Select plays or
/// pauses, Up reaches the badges, Down lands on the last card tab and opens its
/// card. Channels change on the remote's Channel Up / Down buttons, handled by
/// the player rather than here.
struct LiveChannelOverlay: View {
    let title: String // l10n:content — provider-supplied channel name
    let logoURL: URL?
    let plozzChannelID: String?
    let channelID: String
    let input: LiveChannelInput
    let program: LiveChannelProgramInfo?
    let libraryItem: LibraryChannelItem?
    let openLibraryItem: ((LibraryChannelItem) -> Void)?
    let phase: LiveChannelPlaybackPhase
    let isAtLiveEdge: Bool
    let behindLiveSeconds: TimeInterval
    let canPause: Bool
    let canGoLive: Bool
    @FocusState.Binding var focus: LiveChannelControl?
    let onClose: () -> Void
    let onPrevious: () -> Void
    let onPlayPause: () -> Void
    let onGoLive: () -> Void
    let onNext: () -> Void
    let onMultiview: (() -> Void)?
    /// The EPG grid for the Guide card; nil hides the tab.
    let guideContent: ((LiveChannelGuideEmbedding) -> AnyView)?
    /// The remote's Guide button asked for the Guide card.
    let pendingGuideOpen: Bool
    let consumeGuideOpen: () -> Void
    /// The Guide card is showing, so its grid — not this layer — owns focus.
    let onGuideCardChange: (Bool) -> Void
    let loadOnNow: @MainActor () -> [LiveChannelOnNowItem]
    let onTuneChannel: ((String) -> Void)?
    let tracks: LiveChannelPlayerModel
    /// The VOD player's Playback Info overlay, toggled from the Info card.
    let diagnosticsEnabled: Bool
    let toggleDiagnostics: () -> Void
    /// True while the controls must stay up until the viewer dismisses them: a
    /// track menu, or the pill row with its card. Only the plain transport
    /// (title, badges, timeline) idles out.
    let onTracksPresentationChange: (Bool) -> Void
    let onControlActivity: () -> Void
    /// Touch only: a tap on the bare video with nothing open to put away.
    let onDismissControls: () -> Void

    @Environment(\.playerCardMetrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.themePalette) private var palette
    @State private var openMenu: LiveChannelTrackMenuKind?
    @State private var menuReturnFocus: LiveChannelControl?
    /// The VOD player's options panel, fed the channel's tracks: its model, the
    /// Subtitles screen it shows, its remembered heights, the Menu press that
    /// steps it back, and the focus inside it.
    @State private var trackOptions = PlayerControlsModel()
    @State private var subtitleScreen: PlayerControls.SubtitleScreen = .tracks
    @State private var panelHeights: [PlayerControls.Category: CGFloat] = [:]
    @State private var panelBackRequest = 0
    @FocusState private var panelFocus: PlayerControls.FocusSlot?
    @State private var cardOpen = false
    /// The tab the card draws, kept while it parks so it leaves showing what
    /// the viewer was looking at, and reopened by the next Down.
    @State private var cardTab: LiveChannelCardTab = .info
    @State private var onNowItems: [LiveChannelOnNowItem] = []
    /// Whether the grid should take focus on the playing channel as it opens.
    @State private var guideGrabsFocus = false
    /// When a pill last took native focus while the card was up; nil once
    /// focus has gone into the card. Arms the exit strip and Up press — read
    /// from the pill's own focus, since the shared state lags it (see
    /// `tabFocused`).
    @State private var tabFocusedAt: Date?
    @State private var focusedPill: LiveChannelCardTab?
    @State private var badgesTop: CGFloat = 0
    @State private var layerBottom: CGFloat = 0
    @State private var layerTop: CGFloat = 0
    @State private var badgesBottom: CGFloat = 0
    /// Touch: the overlay's own box, which sizes the cards (see `touchMetrics`).
    @State private var availableSize: CGSize = .zero

    /// Touch, stood up: the cards take their compact, shorter forms.
    private var isTouchPortrait: Bool {
        #if os(iOS)
        availableSize.width > 0 && availableSize.width < availableSize.height
        #else
        false
        #endif
    }

    var body: some View {
        layout
        .animation(.easeInOut(duration: 0.2), value: openMenu)
        .animation(.easeInOut(duration: 0.3), value: styleEditing)
        .onChange(of: trackOptionsSource, initial: true) { _, source in syncTrackOptions(source) }
        .onChange(of: focus) { _, control in focusChanged(control) }
        .onChange(of: openMenu != nil || cardOpen) { _, pinned in onTracksPresentationChange(pinned) }
        .onChange(of: cardOpen && cardTab == .guide) { _, showing in onGuideCardChange(showing) }
        .onChange(of: pendingGuideOpen, initial: true) { _, pending in
            guard pending else { return }
            consumeGuideOpen()
            guideGrabsFocus = true
            if cardOpen { select(.guide) } else { openCard(.guide) }
        }
        .task {
            guard let surface = LiveChannelScreenshotHook.pendingSurface else { return }
            LiveChannelScreenshotHook.pendingSurface = nil
            try? await Task.sleep(for: .milliseconds(600))
            switch surface {
            case .info: openCard(.info)
            case .onNow: openCard(.onNow)
            case .guide: openCard(.guide)
            }
        }
        .onDisappear { onTracksPresentationChange(false) }
        #if os(tvOS)
        .onExitCommand(perform: handleExit)
        .background(TVFocusActivityObserver(onActivity: onControlActivity))
        #endif
    }

    @ViewBuilder
    private var layout: some View {
        #if os(iOS)
        touchLayout
        #else
        ZStack(alignment: .top) {
            // Measured as a sibling so it is the same box the menu layer is laid
            // out in (VOD transport rule 1).
            Color.clear
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    layerTop = $0.minY
                    layerBottom = $0.maxY
                    availableSize = $0.size
                }
            scrim
                .opacity(styleEditing ? 0 : 1)
            topBar
                .opacity(styleEditing ? 0 : 1)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                bottomCluster
            }
            .opacity(styleEditing ? 0 : 1)
            menuLayer
        }
        .ignoresSafeArea()
        #endif
    }

    // MARK: Layout constants (see `PlayerControls` for the parking arithmetic)

    #if os(tvOS)
    private static let horizontalMargin: CGFloat = 60
    private static let bottomMargin: CGFloat = 48
    private static let cardGap: CGFloat = 32
    #else
    private static let horizontalMargin: CGFloat = 16
    private static let bottomMargin: CGFloat = 18
    private static let cardGap: CGFloat = 18
    #endif
    private static let stackSpacing: CGFloat = 18
    private static let panelLift: CGFloat = 18
    private static var cardCatchUp: CGFloat { max(0, bottomMargin - cardGap) }
    private static var cardBottomPad: CGFloat { max(0, horizontalMargin - bottomMargin) }
    private var cardLift: CGFloat { cardHeight + Self.cardBottomPad + Self.cardGap }

    /// Every card shares VOD's height except the guide, which needs room for
    /// several rows. The pill row rises with it rather than covering it.
    private var cardHeight: CGFloat {
        #if os(tvOS)
        cardTab == .guide ? 540 : metrics.cardHeight
        #else
        cardTab == .guide ? touchGuideHeight : touchMetrics.cardHeight
        #endif
    }

    private var availableTabs: [LiveChannelCardTab] {
        LiveChannelCardTab.allCases.filter { $0 != .guide || guideContent != nil }
    }
    private var revealClock: Animation {
        #if os(tvOS)
        reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.5)
        #else
        // VOD's touch card curve (`PlayerTouchCardStrip.cardCurve`).
        .easeInOut(duration: 0.24)
        #endif
    }

    private var status: LocalizedStringResource {
        phase.statusLabel(isAtLiveEdge: isAtLiveEdge, isScheduledChannel: plozzChannelID != nil)
    }

    // MARK: Chrome

    private var scrim: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: min(geometry.size.height * 0.25, 220))
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                    .frame(height: max(geometry.size.height * 0.55, 420))
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    /// Only what has nowhere better to live: the library title shortcut, and on
    /// touch the close control a remote's Menu button provides.
    private var topBar: some View {
        HStack(spacing: 18) {
            #if os(iOS)
            Button(action: onClose) {
                Label("Close", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(PlayerGlassCircleButtonStyle(diameter: 44))
            .accessibilityIdentifier("live-channel-close")
            .focused($focus, equals: .close)
            #endif
            Spacer(minLength: 0)
            #if os(iOS)
            if isTouchPortrait {
                // Opposite the host's PiP / AirPlay / Stop row, clear of the
                // title; the library shortcut moves down beside the title.
                touchTrackBadges
                    .opacity(cardOpen ? 0 : 1)
                    .allowsHitTesting(!cardOpen)
            } else {
                libraryButton
            }
            #else
            libraryButton
            #endif
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Self.horizontalMargin)
        #if os(tvOS)
        .padding(.top, 60)
        .opacity(cardOpen ? 0 : 1)
        #else
        // Level with the host's PiP / AirPlay / Stop row, which is laid out
        // beside the close button (see `touchTopBarInset`). Stays up with a
        // card open: a finger has no Menu button to back out with.
        .padding(.top, Self.touchTopBarInset)
        #endif
        .plozzFocusSection()
    }

    // MARK: Bottom cluster

    private var bottomCluster: some View {
        VStack(alignment: .leading, spacing: Self.stackSpacing) {
            VStack(alignment: .leading, spacing: Self.stackSpacing) {
                titleAndBadgesRow
                timelineRow
                    // Steps aside for the card, in place, so nothing reflows.
                    .opacity(cardOpen ? 0 : 1)
                    .allowsHitTesting(!cardOpen)
                tabRow
            }
            card
                .padding(.top, Self.cardGap - Self.stackSpacing)
                .padding(.bottom, Self.cardBottomPad)
                .offset(y: cardOpen ? 0 : Self.cardCatchUp)
                .disabled(!cardOpen)
        }
        .reportSubtitleControlsFrame(isVisible: !styleEditing) { tracks.subtitles.controlsLayout.frame = $0 }
        // THE reveal: one transform over a fixed stage (VOD rule 2).
        .offset(y: cardOpen ? 0 : cardLift)
        .animation(revealClock, value: cardOpen)
        .padding(.horizontal, Self.horizontalMargin)
        .padding(.bottom, Self.bottomMargin)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleAndBadgesRow: some View {
        HStack(alignment: .bottom, spacing: 32) {
            titleBlock
                .opacity(openMenu == nil && !cardOpen ? 1 : 0)
                .animation(.easeInOut(duration: 0.28), value: openMenu == nil)
            badges
                .layoutPriority(1)
        }
    }

    /// The VOD title block, live flavoured: the channel line sits where the
    /// episode line does, the programme where the series title does.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                ChannelLogoArtwork(
                    name: title, logoURL: logoURL, size: Self.logoSize,
                    cornerRadius: 8, plozzChannelID: plozzChannelID
                )
                if program != nil {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                LiveChannelStatusPill(status: status, isLive: isAtLiveEdge && phase == .playing)
            }
            Text(program?.title ?? title)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var libraryButton: some View {
        if let libraryItem, let openLibraryItem {
            libraryTitleButton(
                LibraryChannelNavigationButton(item: libraryItem, action: openLibraryItem)
                    .focused($focus, equals: .openLibraryTitle)
            )
            .disabled(openMenu != nil || cardOpen)
        }
    }

    @ViewBuilder
    private func libraryTitleButton(_ button: some View) -> some View {
        #if os(iOS)
        if isCompactWidth {
            // A stood-up phone has no width for the title beside the host's
            // presentation controls; the glyph says what it opens.
            button
                .labelStyle(.iconOnly)
                .font(.headline)
                .buttonStyle(PlayerGlassCircleButtonStyle(diameter: 44))
        } else {
            button
                .lineLimit(1)
                .buttonStyle(InfoActionButtonStyle(prominent: false))
        }
        #else
        button.buttonStyle(InfoActionButtonStyle(prominent: false))
        #endif
    }

    private static var logoSize: CGSize {
        #if os(tvOS)
        CGSize(width: 72, height: 44)
        #else
        CGSize(width: 48, height: 30)
        #endif
    }

    // MARK: Track options (the VOD player's panel)

    /// Everything the options panel shows, as one value to follow.
    private struct TrackOptionsSource: Equatable {
        var audio: [MediaTrack]
        var subtitles: [MediaTrack]
        var selectedAudio: Int?
        var selectedSubtitle: Int?
        var style: SubtitleStyle
        var isHDR: Bool
        var capabilities: PlayerEngineCapabilities
    }

    private var trackOptionsSource: TrackOptionsSource {
        TrackOptionsSource(
            audio: tracks.audioTracks, subtitles: tracks.subtitleTracks,
            selectedAudio: tracks.selectedAudioID, selectedSubtitle: tracks.selectedSubtitleID,
            style: tracks.subtitles.style, isHDR: tracks.subtitles.isHDR,
            capabilities: tracks.engine.capabilities
        )
    }

    /// The channel's tracks as the VOD menus list them (`TrackMenuBuilder`: the
    /// same labels, and an Off row for subtitles), with the live style.
    private func syncTrackOptions(_ source: TrackOptionsSource) {
        trackOptions.audioOptions = TrackMenuBuilder.audioOptions(
            tracks: source.audio, selectedID: source.selectedAudio, preferred: []
        )
        trackOptions.subtitleOptions = TrackMenuBuilder.subtitleOptions(
            tracks: source.subtitles, selectedID: source.selectedSubtitle, preferred: [], detectedLanguages: [:]
        )
        trackOptions.subtitleStyle = source.style
        trackOptions.subtitlesRenderHDR = source.isHDR
        trackOptions.engineCapabilities = source.capabilities
        // A live channel has nothing to search.
        trackOptions.subtitleDownload.canSearch = false
    }

    private var trackActions: PlayerOptionsActions {
        let tracks = tracks
        var actions = PlayerOptionsActions()
        actions.selectAudio = { id in
            if let track = tracks.audioTracks.first(where: { $0.id == id }) { tracks.selectAudio(track) }
        }
        actions.selectSubtitle = { id in
            tracks.selectSubtitle(
                id == PlayerTrackOption.offID ? nil : tracks.subtitleTracks.first { $0.id == id }
            )
        }
        actions.setSubtitleStyle = { tracks.setSubtitleStyle($0) }
        actions.togglePlayPause = onPlayPause
        return actions
    }

    /// The Style editor (or one of its screens) is up: as in VOD, the panel
    /// pins to the top and the transport steps aside so the subtitles show.
    private var styleEditing: Bool {
        openMenu == .subtitles && subtitleScreen.isStyleFamily
    }

    #if os(tvOS)
    @ViewBuilder
    private func optionsPanel(_ kind: LiveChannelTrackMenuKind) -> some View {
        PlayerOptionsPanel(
            category: kind.category, model: trackOptions, palette: palette, actions: trackActions,
            subtitleScreen: $subtitleScreen, heightCache: $panelHeights, focus: $panelFocus,
            close: closeMenu, backRequest: panelBackRequest,
            maximumHeight: max(
                0,
                availableSize.height - Self.horizontalMargin
                    - (styleEditing ? Self.horizontalMargin : menuBottomInset)
            ),
            // A live channel draws one subtitle line.
            offersDualSubtitles: false
        )
        .id(kind)
        .plozzFocusSection()
    }
    #endif

    // MARK: Badges

    /// VOD's rule (`PlayerControlsModel.hasSelectableAudio`): Audio only when
    /// there's more than one track to choose between.
    private var showsAudio: Bool { tracks.audioTracks.count > 1 }

    /// Subtitles once the stream offers any, as VOD.
    private var showsSubtitles: Bool { !tracks.subtitleTracks.isEmpty }

    /// VOD's track-control badges, plus the live-only actions.
    private var badges: some View {
        HStack(spacing: 20) {
            if canGoLive {
                badge(
                    LibraryChannelPlaybackCopy.returnToCurrentTitle(isScheduledChannel: plozzChannelID != nil),
                    systemImage: plozzChannelID != nil ? "clock.arrow.circlepath" : "dot.radiowaves.left.and.right",
                    control: .goLive, prominent: true, action: onGoLive
                )
                .accessibilityIdentifier("live-channel-go-live")
            }
            if showsAudio {
                badge(
                    LiveChannelTrackMenuKind.audio.title, systemImage: LiveChannelTrackMenuKind.audio.icon,
                    control: .audio, prominent: openMenu == .audio
                ) { toggleMenu(.audio) }
                    .accessibilityIdentifier("live-channel-audio")
            }
            if showsSubtitles {
                badge(
                    LiveChannelTrackMenuKind.subtitles.title, systemImage: LiveChannelTrackMenuKind.subtitles.icon,
                    control: .subtitles, prominent: openMenu == .subtitles
                ) { toggleMenu(.subtitles) }
                    .accessibilityIdentifier("live-channel-subtitles")
            }
            if let onMultiview {
                badge("Multiview", systemImage: "rectangle.split.2x1", control: .multiview, action: onMultiview)
                    .accessibilityIdentifier("live-channel-multiview")
            }
        }
        .opacity(cardOpen ? 0 : 1)
        .plozzFocusSection()
        // GLOBAL, so the reading includes the cluster's parking offset.
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { top in
            // Frozen while the card is up: nothing can open a menu then, and
            // republishing through the reveal would rewrite state every frame.
            if !cardOpen { badgesTop = top }
        }
    }

    private func badge(
        _ title: LocalizedStringResource, systemImage: String, control: LiveChannelControl,
        prominent: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label { Text(title) } icon: { Image(systemName: systemImage) }
                .labelStyle(.iconOnly)
        }
        .playerGlassButton(prominent: prominent)
        .focused($focus, equals: control)
        .disabled(openMenu != nil || cardOpen)
    }

    /// The open track menu, resting just above the badges that opened it.
    ///
    /// Its own layer rather than an overlay on the badges: an overlay is sized
    /// and placed from the badges' box, and a menu taller than that box ended
    /// up hanging down over the timeline.
    @ViewBuilder
    private var menuLayer: some View {
        if let openMenu {
            if menuHangsBelowBadges {
                VStack(spacing: 0) {
                    LiveChannelTrackPanel(kind: openMenu, model: tracks, focus: $focus, onSelect: closeMenu)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, Self.horizontalMargin)
                .padding(.top, menuTopInset)
                .padding(.bottom, Self.horizontalMargin)
                .transition(.scale(scale: 0.9, anchor: .topTrailing).combined(with: .opacity))
            } else {
                #if os(tvOS)
                VStack(spacing: 0) {
                    // Style pins to the TOP, as VOD's does, so its height changes
                    // extend downward; every other menu rests above its buttons.
                    if !styleEditing { Spacer(minLength: 0) }
                    optionsPanel(openMenu)
                    if styleEditing { Spacer(minLength: 0) }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, Self.horizontalMargin)
                .padding(.top, Self.horizontalMargin)
                .padding(.bottom, styleEditing ? Self.horizontalMargin : menuBottomInset)
                .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
                #else
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    LiveChannelTrackPanel(kind: openMenu, model: tracks, focus: $focus, onSelect: closeMenu)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, Self.horizontalMargin)
                .padding(.top, Self.horizontalMargin)
                .padding(.bottom, menuBottomInset)
                .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
                #endif
            }
        }
    }

    /// Touch, stood up: the badges are in the top bar, so their menu drops
    /// down from them rather than rising.
    private var menuHangsBelowBadges: Bool { isTouchPortrait }

    private var menuTopInset: CGFloat {
        guard badgesBottom > layerTop, badgesBottom > 0 else { return 80 }
        return badgesBottom - layerTop + Self.panelLift
    }

    private var menuBottomInset: CGFloat {
        guard layerBottom > badgesTop, badgesTop > 0 else { return 320 }
        return layerBottom - badgesTop + Self.panelLift
    }

    // MARK: Timeline

    @ViewBuilder
    private var timelineRow: some View {
        #if os(tvOS)
        Button(action: onPlayPause) { timeline }
            .buttonStyle(LiveChannelTimelineButtonStyle { focused in
                if focused { leftTabRow() }
            })
            .focusEffectDisabled()
            .focused($focus, equals: .timeline)
            .disabled(openMenu != nil)
            .accessibilityIdentifier("live-channel-timeline")
            .accessibilityLabel(Text(status))
        #else
        VStack(spacing: 14) {
            timeline
            HStack(spacing: 28) {
                Button(action: onPrevious) {
                    Label("Previous Channel", systemImage: "backward.end.fill").labelStyle(.iconOnly)
                }
                .buttonStyle(PlayerGlassCircleButtonStyle(diameter: 48))
                if canPause || phase == .paused {
                    Button(action: onPlayPause) {
                        if phase == .paused {
                            Label("Play", systemImage: "play.fill").labelStyle(.iconOnly)
                        } else {
                            Label("Pause", systemImage: "pause.fill").labelStyle(.iconOnly)
                        }
                    }
                    .buttonStyle(PlayerGlassCircleButtonStyle(diameter: 56))
                }
                Button(action: onNext) {
                    Label("Next Channel", systemImage: "forward.end.fill").labelStyle(.iconOnly)
                }
                .buttonStyle(PlayerGlassCircleButtonStyle(diameter: 48))
            }
            .font(.title3.weight(.semibold))
        }
        #endif
    }

    private var timeline: some View {
        LiveChannelTimeline(
            program: program,
            behindLiveSeconds: behindLiveSeconds,
            isAtLiveEdge: isAtLiveEdge,
            isPaused: phase == .paused,
            holdsFocusedShape: cardOpen
        )
    }

    // MARK: Tabs

    /// VOD's tab row: the card tabs switch the card on focus, like a segmented
    /// control; Guide opens the guide.
    private var tabRow: some View {
        HStack(spacing: 20) {
            ForEach(availableTabs, id: \.self) { tab in
                Button { toggleCard(tab) } label: {
                    // The label reports the tab's own native focus, so the card
                    // follows focus without waiting for a Select press.
                    FocusReporting { focused in
                        if focused {
                            tabFocused(tab)
                            focusedPill = tab
                            tabFocusedAt = .now
                        } else if focusedPill == tab {
                            focusedPill = nil
                            // Gone into the card (the guide grid reports
                            // nothing), not along the row or onto the strip.
                            DispatchQueue.main.async {
                                if focusedPill == nil, focus != .cardExit { tabFocusedAt = nil }
                            }
                        }
                    } content: {
                        Text(tab.title)
                    }
                }
                    // Applied as a style, as VOD's tab row does, so it reads the
                    // player's environment: with glass off for performance the
                    // tabs frost along with every panel and card.
                    .buttonStyle(PlayerTabButtonStyle(
                        focused: focusedPill == tab, selected: cardOpen && cardTab == tab
                    ))
                    .focused($focus, equals: .cardTab(tab))
                    .disabled(!isFocusable(.cardTab(tab)))
                    .accessibilityIdentifier(tab.identifier)
            }
            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Rides as an overlay so it adds no layout of its own.
        .overlay(alignment: .top) { cardExitGuide }
        .plozzFocusSection()
        // Only presses made ON the row reach here — the card is a sibling —
        // but the press that moved focus onto a pill can arrive after that
        // focus, so the pill must have settled before Up counts.
        .plozzMoveCommand { direction in
            guard direction == .up, cardOpen, let tabFocusedAt,
                  Date.now.timeIntervalSince(tabFocusedAt) > 0.3 else { return }
            exitCard()
        }
    }

    /// Something for Up to land on above the open card's tab row.
    ///
    /// With the card up everything above the row steps aside — faded and
    /// disabled — so tvOS had nowhere to move and Up did nothing; only Menu
    /// got back. Focus landing here closes the card and returns to the
    /// timeline (see `focusChanged`). VOD's `infoExitGuide`, same reasoning:
    /// act on where focus lands, not on the press.
    @ViewBuilder
    private var cardExitGuide: some View {
        #if os(tvOS)
        if cardExitGuideActive {
            // A button reporting its own native focus, like the pills: the
            // shared focus state alone never registered the landing.
            Button(action: exitCard) {
                // Not `Color.clear`: UIKit won't focus a fully transparent view.
                Color.black.opacity(0.001)
                    .frame(height: 8)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(LiveChannelTimelineButtonStyle { focused in
                if focused { exitCard() }
            })
            .focusEffectDisabled()
            .focused($focus, equals: .cardExit)
            .offset(y: -26)
        }
        #endif
    }

    /// Only while focus is on the pill row, so Up from inside the card stops
    /// on a pill first.
    private var cardExitGuideActive: Bool {
        cardOpen && openMenu == nil && tabFocusedAt != nil
    }

    /// With the card closed only the tab it last showed is in the focus order,
    /// so Down from the timeline has exactly one place to land — VOD's
    /// `entryFocusTarget`, made structural. Open, the whole row is reachable.
    /// Touch has no focus order to narrow.
    private func isFocusable(_ control: LiveChannelControl) -> Bool {
        guard openMenu == nil else { return false }
        #if os(tvOS)
        return cardOpen || control == .cardTab(cardTab)
        #else
        return true
        #endif
    }

    @ViewBuilder
    private var card: some View {
        Group {
            switch cardTab {
            case .info:
                LiveChannelInfoCard(
                    title: title, logoURL: logoURL, plozzChannelID: plozzChannelID, program: program,
                    compact: isTouchPortrait,
                    diagnosticsEnabled: diagnosticsEnabled, toggleDiagnostics: toggleDiagnostics,
                    focus: $focus
                )
            case .onNow:
                LiveChannelOnNowPanel(
                    items: onNowItems, currentChannelID: channelID,
                    focus: $focus, isCardOpen: cardOpen, select: selectOnNow
                )
            case .guide:
                if let guideContent {
                    guideCard(guideContent)
                }
            }
        }
        .frame(height: cardHeight)
        .colorScheme(.dark)
    }

    /// The EPG grid in the Info card's container — the same panel surface,
    /// padding and corner as every other card, so the Guide reads as one of
    /// them rather than a grid laid straight over the picture.
    private func guideCard(_ content: (LiveChannelGuideEmbedding) -> AnyView) -> some View {
        guideGrid(content)
            .padding(metrics.contentPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Concentric with the panel: its radius less the padding inside it.
            .clipShape(RoundedRectangle(
                cornerRadius: max(0, metrics.panelCornerRadius - metrics.contentPadding), style: .continuous
            ))
            .modifier(PanelGlassBackground(cornerRadius: metrics.panelCornerRadius))
    }

    @ViewBuilder
    private func guideGrid(_ content: (LiveChannelGuideEmbedding) -> AnyView) -> some View {
        let grid = content(LiveChannelGuideEmbedding(
            back: { focus = .cardTab(.guide) },
            didTune: {
                closeCard()
                focus = .timeline
            },
            focusesPlayingChannel: guideGrabsFocus
        ))
        // A fresh grid when the Guide button asks for focus.
        .id(guideGrabsFocus)
        #if os(iOS)
        if isTouchPortrait {
            grid
        } else {
            // Across a wide screen the grid alone draws its roomy layout at a
            // height that shows barely a row; beside an info column it keeps
            // the phone's compact shape, which scrolls comfortably.
            HStack(spacing: 12) {
                LiveChannelGuideInfoColumn(
                    title: title, logoURL: logoURL, plozzChannelID: plozzChannelID, program: program
                )
                .frame(width: (availableSize.width * 0.36).rounded())
                grid
            }
        }
        #else
        // The grid runs on below the card; fade it out rather than cut it off.
        grid.mask {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.8),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
        #endif
    }

    // MARK: Behaviour

    private func focusChanged(_ control: LiveChannelControl?) {
        switch control {
        case .cardTab(let tab):
            tabFocused(tab)
        case .timeline, .audio, .subtitles, .goLive, .multiview, .openLibraryTitle:
            // Leaving the tab row upward is leaving the card, as in VOD.
            if cardOpen { closeCard() }
        case .cardExit:
            exitCard()
        case .onNowItem, .trackRow, .playbackInfo:
            // Into the card: Up from here belongs to the pill first.
            tabFocusedAt = nil
        default:
            break
        }
    }

    /// Focus alone opens the card, or switches it when it is already up.
    ///
    /// Driven from the tab's own native focus (its label reports it)
    /// as well as the shared focus state: the state is written by the parent
    /// view, and arriving here through it alone left the card closed until
    /// Select was pressed.
    private func tabFocused(_ tab: LiveChannelCardTab) {
        if !cardOpen {
            openCard(tab)
        } else if tab != cardTab {
            // A content swap under an open card, never a second reveal — but
            // the Guide card is taller, so its height change travels.
            withAnimation(revealClock) { select(tab) }
        }
    }

    /// Native focus on anything other than the tab row takes the card down.
    private func leftTabRow() {
        if cardOpen { closeCard() }
    }

    private func select(_ tab: LiveChannelCardTab) {
        if tab != .guide { guideGrabsFocus = false }
        if tab == .onNow { onNowItems = loadOnNow() }
        cardTab = tab
    }

    private func openCard(_ tab: LiveChannelCardTab) {
        select(tab)
        withAnimation(revealClock) { cardOpen = true }
    }

    private func closeCard() {
        guideGrabsFocus = false
        tabFocusedAt = nil
        withAnimation(revealClock) { cardOpen = false }
    }

    /// Up out of the pill row: the card goes and the timeline comes back.
    private func exitCard() {
        guard cardOpen else { return }
        closeCard()
        #if os(tvOS)
        focus = .timeline
        #endif
    }

    private func toggleCard(_ tab: LiveChannelCardTab) {
        if cardOpen, cardTab == tab {
            closeCard()
            #if os(tvOS)
            focus = .timeline
            #endif
        } else if cardOpen {
            select(tab)
        } else {
            openCard(tab)
        }
    }

    private func selectOnNow(_ item: LiveChannelOnNowItem) {
        closeCard()
        #if os(tvOS)
        focus = .timeline
        #endif
        guard item.channelID != channelID else { return }
        onTuneChannel?(item.channelID)
    }

    private func toggleMenu(_ kind: LiveChannelTrackMenuKind) {
        if openMenu == kind {
            closeMenu()
            return
        }
        menuReturnFocus = focus ?? kind.control
        subtitleScreen = .tracks
        openMenu = kind
        // After tvOS's own default-focus pass over the new rows — see
        // `PlayerControls.restoreFocus`.
        #if os(tvOS)
        let target = PlayerOptionsPanel.preferredFocus(
            for: kind.category, subtitleScreen: .tracks, model: trackOptions
        )
        DispatchQueue.main.async { panelFocus = target }
        #else
        let row = LiveChannelTrackPanel.selectedRow(kind: kind, model: tracks)
        DispatchQueue.main.async { focus = .trackRow(row) }
        #endif
    }

    private func closeMenu() {
        let returnFocus = menuReturnFocus
        openMenu = nil
        menuReturnFocus = nil
        subtitleScreen = .tracks
        DispatchQueue.main.async { focus = returnFocus }
    }

    private func handleExit() {
        if openMenu == .subtitles, subtitleScreen != .tracks {
            // Back out of a Subtitles screen to the track list first, as VOD.
            panelBackRequest &+= 1
        } else if openMenu != nil {
            closeMenu()
        } else if cardOpen {
            closeCard()
            focus = .timeline
        } else {
            onClose()
        }
    }
}

#if os(iOS)
// MARK: - Touch layout

/// The iPhone / iPad arrangement: the VOD touch player's shape
/// (`PlozziOSPlayerControlsOverlay`) with the live transport's parts.
///
/// Close at the top left with the host's PiP / AirPlay / Stop row beside it;
/// channel down · play / pause · channel up centred between the top bar and the
/// transport, where a thumb reaches; and at the foot, bottom-up, the card, the
/// tab row, the timeline and the title with its badges. A card replaces the
/// title and timeline rather than parking beneath them — tvOS parks the whole
/// cluster by one offset, which needs a known, roomy screen, and a phone on its
/// side has barely enough height for the card alone. Taps drive everything: a
/// tap on the video puts away an open menu, then an open card, then the
/// controls themselves.
extension LiveChannelOverlay {
    /// Leaves the top row level with the host's presentation controls.
    static let touchTopBarInset: CGFloat = 8
    /// The close button's width plus the row's spacing: where the host starts
    /// its presentation controls so they sit beside it.
    static let touchPresentationLeadingInset: CGFloat = horizontalMargin + 44 + 12

    /// A stood-up phone, or an iPad window as narrow as one.
    var isCompactWidth: Bool { availableSize.width > 0 && availableSize.width < 520 }

    var touchMetrics: PlayerCardMetrics {
        .liveTouch(forWidth: availableSize.width, height: availableSize.height)
    }

    /// The guide gets what the top bar and tab row leave, so a phone on its
    /// side still shows a few rows and a tall screen doesn't get a wall of grid.
    var touchGuideHeight: CGFloat {
        let chrome: CGFloat = 44 + Self.touchTopBarInset + 12 // top bar
            + 48 + Self.stackSpacing + Self.bottomMargin // tab row
        return min(max(availableSize.height - chrome - 16, 160), 520).rounded()
    }

    var touchLayout: some View {
        ZStack(alignment: .top) {
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture(perform: backgroundTapped)
            touchScrim
            ZStack(alignment: .top) {
                // Measured as a sibling so it is the same box the menu layer is
                // laid out in (VOD transport rule 1).
                Color.clear
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        layerTop = frame.minY
                        layerBottom = frame.maxY
                        availableSize = frame.size
                    }
                    .allowsHitTesting(false)
                // Stood up, the video is a band across the middle with room
                // all round, so the buttons sit on it, as VOD's do. On its
                // side there's no such room: they take the gap between the top
                // bar and the transport so they can't land on the title.
                if isTouchPortrait, !cardOpen, openMenu == nil {
                    centerTransport
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                }
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    if !isTouchPortrait, !cardOpen, openMenu == nil {
                        centerTransport
                            .transition(.opacity)
                    }
                    Spacer(minLength: 0)
                    touchBottomCluster
                }
                menuLayer
            }
            .modifier(WindowSafeAreaPadding())
        }
        .environment(\.playerCardMetrics, touchMetrics)
    }

    private var touchScrim: some View {
        LinearGradient(
            colors: [.black.opacity(0.65), .clear, .black.opacity(cardOpen ? 0.9 : 0.82)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func backgroundTapped() {
        if openMenu != nil {
            closeMenu()
        } else if cardOpen {
            closeCard()
        } else {
            onDismissControls()
        }
    }

    // MARK: Centre

    /// VOD's skip · play · skip, as channel down · play / pause · channel up.
    private var centerTransport: some View {
        HStack(spacing: 28) {
            Button(action: onPrevious) {
                Label("Previous Channel", systemImage: "backward.end.fill")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 24))
            }
            .buttonStyle(PlayerGlassCircleButtonStyle(diameter: 64))
            .accessibilityIdentifier("live-channel-previous")

            playPauseButton

            Button(action: onNext) {
                Label("Next Channel", systemImage: "forward.end.fill")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 24))
            }
            .buttonStyle(PlayerGlassCircleButtonStyle(diameter: 64))
            .accessibilityIdentifier("live-channel-next")
        }
        .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
    }

    /// Stands in for the host's activity panel while the controls are up, so
    /// a tune in progress doesn't stack a spinner card over these buttons.
    private var playPauseButton: some View {
        Button(action: onPlayPause) {
            Group {
                if isBusy {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                        .accessibilityLabel(Text(phase.activityLabel))
                } else if phase == .paused {
                    Label("Play", systemImage: "play.fill")
                } else {
                    Label("Pause", systemImage: "pause.fill")
                }
            }
            .labelStyle(.iconOnly)
            .font(.system(size: 32))
        }
        .buttonStyle(PlayerGlassCircleButtonStyle(diameter: 76))
        // A stream with no time-shift can't pause; the button stays put so the
        // row doesn't reflow, but says so.
        .disabled(isBusy || !(canPause || phase == .paused))
        .opacity(isBusy || canPause || phase == .paused ? 1 : 0.45)
        .accessibilityIdentifier("live-channel-play-pause")
    }

    private var isBusy: Bool {
        switch phase {
        case .loading, .buffering, .seeking, .reconnecting: true
        default: false
        }
    }

    // MARK: Bottom

    private var touchBottomCluster: some View {
        VStack(alignment: .leading, spacing: Self.stackSpacing) {
            if !cardOpen {
                Group {
                    if isTouchPortrait {
                        // The track badges are up in the top bar; only the
                        // live-edge and library shortcuts stay by the title.
                        HStack(alignment: .center, spacing: 12) {
                            touchTitleBlock
                            touchGoLiveBadge
                            libraryButton
                        }
                    } else if isCompactWidth {
                        VStack(alignment: .leading, spacing: 14) {
                            touchTitleBlock
                            touchBadges
                        }
                    } else {
                        HStack(alignment: .bottom, spacing: 16) {
                            touchTitleBlock
                            touchBadges
                                .layoutPriority(1)
                        }
                    }
                }
                .transition(.opacity)
                timeline
                    .accessibilityIdentifier("live-channel-timeline")
                    .accessibilityElement(children: .combine)
                    .transition(.opacity)
            }
            touchTabRow
            if cardOpen {
                card
                    // Grows upward out of the tabs, as VOD's touch card does.
                    .transition(.scale(scale: 0.94, anchor: .bottom).combined(with: .opacity))
            }
        }
        .reportSubtitleControlsFrame { tracks.subtitles.controlsLayout.frame = $0 }
        .padding(.horizontal, Self.horizontalMargin)
        .padding(.bottom, Self.bottomMargin)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// VOD's touch title block with the channel in front: logo, then the
    /// status pill and channel over the programme.
    private var touchTitleBlock: some View {
        HStack(spacing: 12) {
            ChannelLogoArtwork(
                name: title, logoURL: logoURL, size: CGSize(width: 56, height: 34),
                cornerRadius: 6, plozzChannelID: plozzChannelID
            )
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    LiveChannelStatusPill(status: status, isLive: isAtLiveEdge && phase == .playing)
                    if program != nil {
                        Text(title)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                }
                Text(program?.title ?? title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Hidden under an open track menu when it rises over it; stood up the
        // menu hangs from the top bar instead and leaves the title alone.
        .opacity(openMenu == nil || menuHangsBelowBadges ? 1 : 0)
        .animation(.easeInOut(duration: 0.28), value: openMenu == nil)
    }

    /// The same actions as the tvOS badges, as VOD's touch glass circles.
    private var touchBadges: some View {
        HStack(spacing: 12) {
            touchGoLiveBadge
            touchTrackBadges
        }
    }

    @ViewBuilder
    private var touchGoLiveBadge: some View {
        if canGoLive {
            touchBadge(
                LibraryChannelPlaybackCopy.returnToCurrentTitle(isScheduledChannel: plozzChannelID != nil),
                systemImage: plozzChannelID != nil ? "clock.arrow.circlepath" : "dot.radiowaves.left.and.right",
                prominent: true, action: onGoLive
            )
            .accessibilityIdentifier("live-channel-go-live")
        }
    }

    /// Audio · Subtitles · Multiview: beside the title on its side, in the top
    /// bar stood up.
    private var touchTrackBadges: some View {
        HStack(spacing: 12) {
            if showsAudio {
                touchBadge(
                    LiveChannelTrackMenuKind.audio.title, systemImage: LiveChannelTrackMenuKind.audio.icon,
                    prominent: openMenu == .audio
                ) { toggleMenu(.audio) }
                    .accessibilityIdentifier("live-channel-audio")
            }
            if showsSubtitles {
                touchBadge(
                    LiveChannelTrackMenuKind.subtitles.title, systemImage: LiveChannelTrackMenuKind.subtitles.icon,
                    prominent: openMenu == .subtitles
                ) { toggleMenu(.subtitles) }
                    .accessibilityIdentifier("live-channel-subtitles")
            }
            if let onMultiview {
                touchBadge("Multiview", systemImage: "rectangle.split.2x1", action: onMultiview)
                    .accessibilityIdentifier("live-channel-multiview")
            }
        }
        // GLOBAL, so the menu layer can rest the open menu just above (or,
        // in the top bar, just below) them.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            badgesTop = frame.minY
            badgesBottom = frame.maxY
        }
    }

    private func touchBadge(
        _ title: LocalizedStringResource, systemImage: String,
        prominent: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label { Text(title) } icon: { Image(systemName: systemImage) }
                .labelStyle(.iconOnly)
                .font(.title3)
        }
        .buttonStyle(PlayerGlassCircleButtonStyle(diameter: 44))
        .overlay {
            if prominent {
                Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }

    /// VOD's touch tab row: tapping a tab opens its card, tapping it again
    /// closes it. Scrolls sideways when four tabs don't fit a narrow phone.
    private var touchTabRow: some View {
        ViewThatFits(in: .horizontal) {
            touchTabs
            ScrollView(.horizontal) { touchTabs }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
        }
    }

    private var touchTabs: some View {
        HStack(spacing: 12) {
            ForEach(availableTabs, id: \.self) { tab in
                Button { toggleCard(tab) } label: { Text(tab.title) }
                    .buttonStyle(PlayerTabButtonStyle(focused: false, selected: cardOpen && cardTab == tab))
                    // The whole pill takes the tap; see `PlayerTouchCardStrip.tab`.
                    .contentShape(Capsule(style: .continuous))
                    .disabled(openMenu != nil)
                    .accessibilityIdentifier(tab.identifier)
                    .accessibilityAddTraits(cardOpen && cardTab == tab ? .isSelected : [])
            }
        }
    }
}

/// Keeps touch controls clear of the Dynamic Island, notch and home indicator.
///
/// The Live TV page lays the expanded player out over the whole window by frame
/// and position rather than as a full-screen presentation, so SwiftUI's own
/// safe area doesn't reach it and the controls landed under the island. This
/// pads by the window's insets instead. It deliberately does NOT measure its
/// own frame to work out the overlap: feeding a measured frame back into the
/// padding re-ran layout every frame and locked up the main thread. An expanded
/// player always covers the window, so the window's insets are the answer;
/// anywhere else pass `isEnabled: false`, which keeps the modifier (and so the
/// view's identity) in place while padding by nothing.
struct WindowSafeAreaPadding: ViewModifier {
    var isEnabled = true

    @Environment(\.layoutDirection) private var layoutDirection
    @State private var window = WindowSafeArea()

    func body(content: Content) -> some View {
        let insets = isEnabled ? window.insets : .zero
        let rtl = layoutDirection == .rightToLeft
        content
            .padding(EdgeInsets(
                top: insets.top, leading: rtl ? insets.right : insets.left,
                bottom: insets.bottom, trailing: rtl ? insets.left : insets.right
            ))
            .ignoresSafeArea()
            // Zero-sized: a full-size UIKit view here sat above the controls in
            // the host's presentation layer and swallowed every tap.
            .background(WindowSafeAreaReader { window = $0 }.frame(width: 0, height: 0).allowsHitTesting(false))
    }
}

struct WindowSafeArea: Equatable {
    var insets: UIEdgeInsets = .zero
    var size: CGSize = .zero
}

private struct WindowSafeAreaReader: UIViewRepresentable {
    let onChange: (WindowSafeArea) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    /// Reads the WINDOW's insets, not its own, so it can be zero-sized; it
    /// follows rotation and window resizing through the scene's geometry,
    /// which a zero-sized view's own layout never would.
    final class ReaderView: UIView {
        var onChange: ((WindowSafeArea) -> Void)?
        private var reported: WindowSafeArea?
        private var sceneObservation: NSKeyValueObservation?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            sceneObservation = window?.windowScene?.observe(\.effectiveGeometry, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.report() }
            }
            report()
        }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }

        private func report() {
            guard let window else { return }
            let value = WindowSafeArea(insets: window.safeAreaInsets, size: window.bounds.size)
            guard value != reported else { return }
            reported = value
            // Never during SwiftUI's own update pass.
            DispatchQueue.main.async { [weak self] in self?.onChange?(value) }
        }
    }
}
#endif

// MARK: - Programme artwork

/// A programme's art in a fixed 16:9 box, fitted rather than cropped so a
/// poster or a square still sits in the same place as a wide still; the
/// channel's logo stands in when the guide has no art.
struct LiveChannelProgramArtwork: View {
    let artworkURL: URL?
    let channelName: String // l10n:content — provider-supplied channel name
    let logoURL: URL?
    let plozzChannelID: String?
    let size: CGSize
    var cornerRadius: CGFloat = 12

    var body: some View {
        ZStack {
            if let artworkURL {
                Color.white.opacity(0.08)
                FallbackAsyncImage(references: [.remote(artworkURL)]) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    logo
                }
            } else {
                logo
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }

    /// With no programme art, the channel's logo tile is the art: its own
    /// backing plate across the whole frame, the logo as large as that allows.
    private var logo: some View {
        ChannelLogoArtwork(
            name: channelName, logoURL: logoURL, size: size,
            cornerRadius: cornerRadius, plozzChannelID: plozzChannelID
        )
    }
}

// MARK: - Info

/// VOD's Info card for the programme on air: art, title, episode line, timing
/// and synopsis.
private struct LiveChannelInfoCard: View {
    let title: String // l10n:content — provider-supplied channel name
    let logoURL: URL?
    let plozzChannelID: String?
    let program: LiveChannelProgramInfo?
    /// A stood-up phone: the art stays but shrinks, and the synopsis goes so
    /// the title and timing have room to wrap instead.
    var compact = false
    let diagnosticsEnabled: Bool
    let toggleDiagnostics: () -> Void
    @FocusState.Binding var focus: LiveChannelControl?

    @Environment(\.playerCardMetrics) private var metrics

    private var artHeight: CGFloat {
        (compact ? metrics.contentHeight * 0.8 : metrics.contentHeight).rounded()
    }

    var body: some View {
        HStack(alignment: .top, spacing: metrics.columnSpacing) {
            if metrics.showsThumbnail {
                LiveChannelProgramArtwork(
                    artworkURL: program?.artworkURL, channelName: title, logoURL: logoURL,
                    plozzChannelID: plozzChannelID,
                    size: CGSize(width: (artHeight * 16 / 9).rounded(), height: artHeight),
                    cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius
                )
            }
            VStack(alignment: .leading, spacing: compact ? 4 : 8) {
                Text(program?.title ?? title)
                    .font(metrics.titleFont)
                    .lineLimit(compact ? 2 : 1)
                if let subtitle = program?.subtitle {
                    Text(subtitle)
                        .font(metrics.captionFont)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                if let program {
                    LiveChannelProgramTiming(program: program)
                        .font(metrics.captionFont)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(compact ? 2 : 1)
                    if !compact, let description = program.description {
                        Text(description)
                            .font(metrics.bodyFont)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(metrics.overviewLineLimit)
                    }
                } else {
                    Text("No guide information for this channel.")
                        .font(metrics.bodyFont)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: metrics.textColumnMaxWidth, maxHeight: .infinity, alignment: .topLeading)
            Spacer(minLength: 0)
        }
        .padding(metrics.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // VOD's Playback Info spot, bottom-right, in a row that spans the whole
        // card and is its own focus section: a lone button over at the right
        // sits under none of the tabs, so Down from Info found nothing.
        .overlay(alignment: .bottom) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                playbackInfoButton
            }
            .padding(metrics.contentPadding)
            .plozzFocusSection()
        }
        .modifier(PanelGlassBackground(cornerRadius: metrics.panelCornerRadius))
    }
}

extension LiveChannelInfoCard {
    /// VOD's Playback Info toggle (see `InfoPanelView`): the icon alone at rest,
    /// its title revealed by the capsule growing around it on focus.
    fileprivate var playbackInfoButton: some View {
        let isFocused = focus == .playbackInfo
        return Button(action: toggleDiagnostics) {
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                if isFocused {
                    Text("Playback Info").fixedSize().transition(.identity)
                }
            }
            .font(metrics.actionFont)
            .lineLimit(1)
            .animation(.easeOut(duration: 0.2), value: isFocused)
        }
        .buttonStyle(InfoActionButtonStyle(
            focused: isFocused,
            prominent: diagnosticsEnabled,
            hPadding: metrics.actionHPadding,
            vPadding: metrics.actionVPadding
        ))
        .focused($focus, equals: .playbackInfo)
        .accessibilityIdentifier("live-channel-playback-info")
    }
}

/// "9:00 – 10:00 PM · 1 hr · 32 min left", as one `Text` so it can wrap.
private struct LiveChannelProgramTiming: View {
    let program: LiveChannelProgramInfo

    @Environment(\.locale) private var locale

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            text(now: context.date)
                .monospacedDigit()
        }
    }

    private func text(now: Date) -> Text {
        let clock = Date.FormatStyle.dateTime.hour().minute().locale(locale)
        let units = Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes], width: .abbreviated)
            .locale(locale)
        let remaining = program.end.timeIntervalSince(now)
        let span = Text(verbatim: "\(program.start.formatted(clock)) – \(program.end.formatted(clock)) · "
            + Duration.seconds(program.duration).formatted(units))
        guard now >= program.start, remaining > 60 else { return span }
        return span + Text(verbatim: " · ") + Text(
            "\(Duration.seconds(remaining).formatted(units)) left",
            comment: "Time remaining in the live programme. The argument is a duration such as '32 min'."
        )
    }
}

#if os(iOS)
/// The Guide card's left column on a wide touch screen: what is playing, so
/// the grid beside it can take the phone's compact shape and stay navigable.
private struct LiveChannelGuideInfoColumn: View {
    let title: String // l10n:content — provider-supplied channel name
    let logoURL: URL?
    let plozzChannelID: String?
    let program: LiveChannelProgramInfo?

    @Environment(\.playerCardMetrics) private var metrics

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - metrics.contentPadding * 2)
            let artHeight = min(width * 9 / 16, geometry.size.height * 0.42).rounded()
            VStack(alignment: .leading, spacing: 6) {
                LiveChannelProgramArtwork(
                    artworkURL: program?.artworkURL, channelName: title, logoURL: logoURL,
                    plozzChannelID: plozzChannelID,
                    size: CGSize(width: (artHeight * 16 / 9).rounded(), height: artHeight),
                    cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius
                )
                .padding(.bottom, 4)
                Text(program?.title ?? title)
                    .font(metrics.titleFont)
                    .lineLimit(2)
                if program != nil {
                    Text(title)
                        .font(metrics.captionFont)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                if let program {
                    LiveChannelProgramTiming(program: program)
                        .font(metrics.captionFont)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                    if let description = program.description {
                        Text(description)
                            .font(metrics.bodyFont)
                            .foregroundStyle(.white.opacity(0.85))
                            // Whatever height is left, truncated rather than clipped.
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                } else {
                    Text("No guide information for this channel.")
                        .font(metrics.bodyFont)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .foregroundStyle(.white)
            .padding(metrics.contentPadding)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .clipped()
        .modifier(PanelGlassBackground(cornerRadius: metrics.panelCornerRadius))
    }
}
#endif

// MARK: - Timeline

/// The live stand-in for VOD's scrub bar: the same track surface, fill and
/// playhead, measuring the programme instead of a file.
///
/// The faint fill is what has aired so far (VOD's buffered fill); the bright
/// fill and playhead are what is on screen, which trails it while paused or
/// time-shifted. The label riding the playhead is the clock time of the picture
/// on screen. Without guide data the bar is simply full at the live edge.
private struct LiveChannelTimeline: View {
    let program: LiveChannelProgramInfo?
    let behindLiveSeconds: TimeInterval
    let isAtLiveEdge: Bool
    let isPaused: Bool
    /// The card is up: keep the bar in its focused shape while it travels
    /// (see `ScrubBar`), whatever holds focus.
    let holdsFocusedShape: Bool

    @Environment(\.locale) private var locale
    /// The timeline's own button's focus: a `Button` label sees it natively.
    @Environment(\.isFocused) private var isFocused
    @State private var currentLabelWidth: CGFloat = 0

    private var focused: Bool { isFocused || holdsFocusedShape }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        let onScreen = now.addingTimeInterval(-behindLiveSeconds)
        let aired = program?.progress(at: now) ?? 1
        let playing = program?.progress(at: onScreen) ?? 1
        return VStack(spacing: Self.rowSpacing) {
            bar(aired: aired, playing: playing)
                .frame(height: Self.barRowHeight)
            labels(playing: playing, onScreen: onScreen)
                .frame(height: Self.labelRowHeight)
        }
    }

    // Touch has no focused shape to make room for, and VOD's touch bar is a
    // slim line with small times, so the phone gets the compact row.
    #if os(tvOS)
    private static let rowSpacing: CGFloat = 8
    private static let barRowHeight: CGFloat = 44
    private static let labelRowHeight: CGFloat = 30
    private static let restingBarHeight: CGFloat = 12
    private static let restingKnobHeight: CGFloat = 12
    private static let pauseGlyphSize: CGFloat = 24
    private static let pauseGlyphOffset: CGFloat = 40
    private static let timeFont: Font = .callout.weight(.semibold)
    #else
    private static let rowSpacing: CGFloat = 2
    private static let barRowHeight: CGFloat = 18
    private static let labelRowHeight: CGFloat = 20
    private static let restingBarHeight: CGFloat = 6
    private static let restingKnobHeight: CGFloat = 14
    private static let pauseGlyphSize: CGFloat = 16
    private static let pauseGlyphOffset: CGFloat = 24
    private static let timeFont: Font = .caption.weight(.semibold)
    #endif

    private func bar(aired: Double, playing: Double) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let knobX = width * CGFloat(playing)
            let barHeight: CGFloat = focused ? 20 : Self.restingBarHeight
            let knobWidth: CGFloat = focused ? 8 : 4
            let knobHeight: CGFloat = focused ? 32 : Self.restingKnobHeight
            ZStack(alignment: .leading) {
                PlayerScrubTrackSurface(height: barHeight)
                Capsule()
                    .fill(.white.opacity(0.14))
                    .frame(width: width * CGFloat(aired), height: barHeight)
                UnevenRoundedRectangle(
                    topLeadingRadius: barHeight / 2, bottomLeadingRadius: barHeight / 2,
                    bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous
                )
                .fill(.white.opacity(focused ? 0.62 : 0.32))
                .frame(width: knobX, height: barHeight)
                RoundedRectangle(cornerRadius: focused ? knobWidth / 2 : 0, style: .continuous)
                    .fill(.white)
                    .frame(width: knobWidth, height: knobHeight)
                    .offset(x: knobX - knobWidth / 2)
                    .shadow(radius: 4)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .animation(.easeOut(duration: 0.2), value: focused)
        }
    }

    /// VOD's timeline labels: the current label rides the playhead and the ends
    /// give way to it rather than colliding.
    private func labels(playing: Double, onScreen: Date) -> some View {
        let start = program.map { clock($0.start) }
        let end = program.map { clock($0.end) }
        let startWidth = start.map(PlayerControls.measuredTimeWidth) ?? 0
        let endWidth = end.map(PlayerControls.measuredTimeWidth) ?? 0
        return GeometryReader { geometry in
            let width = geometry.size.width
            let midY = geometry.size.height / 2
            let half = currentLabelWidth / 2
            // The pause glyph hangs off the label's trailing edge; keep it on screen.
            let trailingReach = half + (isPaused ? Self.pauseGlyphOffset + Self.pauseGlyphSize * 0.6 : 0)
            let centerX = min(max(width * CGFloat(playing), half), max(half, width - trailingReach))
            let gap: CGFloat = 16
            let startHidden = centerX - half - gap <= startWidth
            let endHidden = centerX + trailingReach + gap >= width - endWidth

            if let start {
                timeText(start, opacity: 0.7)
                    .opacity(startHidden ? 0 : 1)
                    .frame(width: width, alignment: .leading)
                    .position(x: width / 2, y: midY)
            }
            if let end {
                timeText(end, opacity: 0.7)
                    .opacity(endHidden ? 0 : 1)
                    .frame(width: width, alignment: .trailing)
                    .position(x: width / 2, y: midY)
            }
            timeText(clock(onScreen), opacity: 1)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { currentLabelWidth = $0 }
                .overlay(alignment: .trailing) {
                    if isPaused {
                        Image(systemName: "pause.circle.fill")
                            .font(.system(size: Self.pauseGlyphSize))
                            .foregroundStyle(.white)
                            .offset(x: Self.pauseGlyphOffset)
                    }
                }
                .position(x: centerX, y: midY)
        }
        .animation(.easeOut(duration: 0.15), value: playing)
    }

    private func clock(_ date: Date) -> String { // l10n:content — locale-formatted time
        date.formatted(.dateTime.hour().minute().locale(locale))
    }

    private func timeText(_ text: String, opacity: Double) -> some View {
        Text(verbatim: text)
            .monospacedDigit()
            .font(Self.timeFont)
            .foregroundStyle(.white.opacity(opacity))
            .fixedSize()
            .shadow(radius: 3)
    }
}

/// The timeline is the whole control; focus shows as the bar's own focused
/// shape, exactly like the scrub bar, rather than a system halo around it.
private struct LiveChannelTimelineButtonStyle: ButtonStyle {
    let focusChanged: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        FocusReporting(focusChanged: focusChanged) { configuration.label.contentShape(Rectangle()) }
    }
}

/// Calls back whenever the enclosing focusable's native focus changes.
private struct FocusReporting<Content: View>: View {
    let focusChanged: (Bool) -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        content().onChange(of: isFocused, initial: true) { _, focused in focusChanged(focused) }
    }
}

/// The status beside the channel logo, as Apple's players draw it: a red LIVE
/// pill at the live edge, grey once behind it (or paused).
private struct LiveChannelStatusPill: View {
    let status: LocalizedStringResource
    let isLive: Bool

    var body: some View {
        Text(status)
            .font(.caption2.weight(.heavy))
            .tracking(0.6)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isLive ? Color(uiColor: .systemRed) : Color.gray.opacity(0.75))
            )
            .animation(.easeInOut(duration: 0.2), value: isLive)
    }
}

// MARK: - Track menus

enum LiveChannelTrackMenuKind: Hashable {
    case audio, subtitles

    var title: LocalizedStringResource {
        switch self {
        case .audio:
            LocalizedStringResource(
                "player.category.audio", defaultValue: "Audio",
                comment: "Tab in the in-player options panel listing audio tracks."
            )
        case .subtitles:
            LocalizedStringResource(
                "player.category.subtitles", defaultValue: "Subtitles",
                comment: "Tab in the in-player options panel listing subtitle tracks."
            )
        }
    }

    var icon: String {
        switch self {
        case .audio: "waveform"
        case .subtitles: "captions.bubble"
        }
    }

    var control: LiveChannelControl {
        switch self {
        case .audio: .audio
        case .subtitles: .subtitles
        }
    }

    /// The VOD options panel's menu for this kind.
    var category: PlayerControls.Category {
        switch self {
        case .audio: .audio
        case .subtitles: .subtitles
        }
    }
}

/// VOD's floating options panel — the same glass, header and menu rows — for
/// the two track lists a live channel offers.
private struct LiveChannelTrackPanel: View {
    let kind: LiveChannelTrackMenuKind
    let model: LiveChannelPlayerModel
    @FocusState.Binding var focus: LiveChannelControl?
    let onSelect: () -> Void

    @Environment(\.themePalette) private var palette

    private struct Row: Identifiable {
        let id: Int
        let title: Text
        let isSelected: Bool
        let select: () -> Void
    }

    static func selectedRow(kind: LiveChannelTrackMenuKind, model: LiveChannelPlayerModel) -> Int {
        switch kind {
        case .audio:
            model.audioTracks.firstIndex { $0.id == model.selectedAudioID } ?? 0
        case .subtitles:
            model.subtitleTracks.firstIndex { $0.id == model.selectedSubtitleID }.map { $0 + 1 } ?? 0
        }
    }

    private var rows: [Row] {
        switch kind {
        case .audio:
            // Always one row, so the menu has somewhere for focus to land even
            // when the stream carries a single, unlabelled audio track.
            guard !model.audioTracks.isEmpty else {
                return [Row(
                    id: 0,
                    title: Text("Default audio", comment: "Audio menu row shown when the live stream has one unnamed audio track."),
                    isSelected: true
                ) {}]
            }
            return model.audioTracks.enumerated().map { index, track in
                Row(id: index, title: Text(verbatim: track.displayTitle), isSelected: model.selectedAudioID == track.id) {
                    model.selectAudio(track)
                }
            }
        case .subtitles:
            let off = Row(
                id: 0, title: Text("Off", comment: "Subtitle menu row that turns subtitles off."),
                isSelected: model.selectedSubtitleID == nil
            ) { model.selectSubtitle(nil) }
            return [off] + model.subtitleTracks.enumerated().map { index, track in
                Row(id: index + 1, title: Text(verbatim: track.displayTitle), isSelected: model.selectedSubtitleID == track.id) {
                    model.selectSubtitle(track)
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(kind.title)
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.top, 18)
            let rows = rows
            #if os(tvOS)
            if rows.count > Self.rowsBeforeScrolling {
                ScrollView { rowStack(rows) }
                    .frame(height: Self.scrollingHeight)
            } else {
                rowStack(rows)
            }
            #else
            // A phone on its side has well under seven rows of room above the
            // badges, so scroll whenever the rows don't fit the space given.
            ViewThatFits(in: .vertical) {
                rowStack(rows)
                ScrollView { rowStack(rows) }
            }
            #endif
        }
        .padding(.bottom, 14)
        .padding(.horizontal, 14)
        .frame(width: Self.width, alignment: .leading)
        .modifier(PanelGlassBackground())
        .colorScheme(.dark)
        .plozzFocusSection()
    }

    private func rowStack(_ rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows) { row in
                Button {
                    row.select()
                    onSelect()
                } label: {
                    HStack(spacing: 10) {
                        row.title
                            .font(.body)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if row.isSelected {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .playerMenuRowMark(isSelected: true, accent: palette.accent)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlayerMenuRowButtonStyle())
                .focusEffectDisabled()
                .focused($focus, equals: .trackRow(row.id))
            }
        }
    }

    #if os(tvOS)
    private static let rowsBeforeScrolling = 7
    private static let width: CGFloat = 520
    private static let scrollingHeight: CGFloat = 440
    #else
    private static let width: CGFloat = 320
    #endif
}

// MARK: - On Now

/// The On Now card: what else is airing, laid out like the Cast tab — a row of
/// cards floating over the video, each the programme's art and its title.
private struct LiveChannelOnNowPanel: View {
    let items: [LiveChannelOnNowItem]
    let currentChannelID: String
    @FocusState.Binding var focus: LiveChannelControl?
    let isCardOpen: Bool
    let select: (LiveChannelOnNowItem) -> Void

    @Environment(\.playerCardMetrics) private var metrics
    @Environment(\.plozzMetrics) private var cardMetrics

    var body: some View {
        if items.isEmpty {
            Text("Nothing else is on right now.")
                .font(metrics.bodyFont)
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { PlayerOverVideoSurface(cornerRadius: metrics.panelCornerRadius) }
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                row(now: context.date)
            }
        }
    }

    private func row(now: Date) -> some View {
        // One shape for the whole row: a second line is reserved only when some
        // card has one, so a lineup without guide data gets taller art instead.
        let reservesDetailLine = items.contains { LiveChannelOnNowCard.detail(for: $0, now: now) != nil }
        return ScrollView(.horizontal, showsIndicators: false) {
            // Not lazy, for the reason the cast row isn't: a bounded row, and
            // focus must be able to target any card.
            HStack(spacing: metrics.columnSpacing) {
                ForEach(items) { item in
                    Button { select(item) } label: {
                        LiveChannelOnNowCard(
                            item: item, isCurrent: item.channelID == currentChannelID, now: now,
                            reservesDetailLine: reservesDetailLine
                        )
                    }
                    .buttonStyle(LiveChannelCardButtonStyle(cornerRadius: cardMetrics.landscapeCardCornerRadius))
                    .disabled(!isCardOpen)
                    .focused($focus, equals: .onNowItem(item.id))
                    .accessibilityIdentifier("live-channel-on-now-\(item.channelID)")
                }
            }
            // As the Cast row: flush with the panel's leading edge, and no
            // vertical inset, so each card is the full height of the Info card
            // it stands in for.
            .padding(.trailing, metrics.contentPadding)
        }
        .scrollClipDisabled()
    }
}

/// `PlayerOverVideoCardStyle` driven by the card's own native focus.
private struct LiveChannelCardButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct CardBody: View {
        let configuration: ButtonStyle.Configuration
        let cornerRadius: CGFloat
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            // The Cast cards' lift: small cards in a row barely register the
            // gentler default.
            PlayerOverVideoCardStyle(focused: isFocused, cornerRadius: cornerRadius, focusScale: 1.10)
                .makeBody(configuration: configuration)
        }
    }
}

private struct LiveChannelOnNowCard: View {
    let item: LiveChannelOnNowItem
    let isCurrent: Bool
    let now: Date
    /// Whether the row keeps room for a second line under the title.
    let reservesDetailLine: Bool

    @Environment(\.playerCardMetrics) private var metrics
    /// The app's media-card rule, as Home's landscape cards and the Up Next card
    /// follow it: art inset by `cardInset` on every side with a concentric outer
    /// corner, and the caption held further in so it clears that corner.
    @Environment(\.plozzMetrics) private var cardMetrics
    @Environment(\.isFocused) private var focused

    #if os(tvOS)
    private static let progressHeight: CGFloat = 6
    #else
    private static let progressHeight: CGFloat = 4
    #endif

    private var inset: CGFloat { cardMetrics.cardInset }
    private var captionInset: CGFloat { cardMetrics.landscapeCaptionInset }

    /// Everything under the art, so the art takes exactly what is left of the
    /// card's fixed height.
    private var textHeight: CGFloat {
        guard reservesDetailLine else { return (metrics.castNameSize * 1.25).rounded(.up) }
        return ((metrics.castNameSize + metrics.castRoleSize) * 1.25).rounded(.up) + 3
    }

    /// The card's full height less the art's inset above it, the caption below,
    /// and the caption's own inset from the bottom corners.
    private var artHeight: CGFloat {
        let chrome = inset + cardMetrics.landscapeCaptionTopSpacing + textHeight + inset + captionInset
        return max(40, (metrics.cardHeight - chrome).rounded())
    }

    private var artCornerRadius: CGFloat { PlozzTheme.Metrics.mediumMediaCornerRadius }

    private var artWidth: CGFloat { (artHeight * 16 / 9).rounded() }

    /// The programme leads and the channel it's on follows, as the guide lists
    /// them. A channel with no guide data, or whose guide only repeats its own
    /// name, is named once.
    private var headline: String { item.program?.title ?? item.channelName }

    /// The line under the title: the channel when a programme leads, else the
    /// programme's episode line or time left; nil when there's nothing to add.
    static func detail(for item: LiveChannelOnNowItem, now: Date) -> Text? {
        guard let program = item.program else { return nil }
        if program.title.caseInsensitiveCompare(item.channelName) != .orderedSame {
            return Text(verbatim: item.channelName)
        }
        if let subtitle = program.subtitle { return Text(verbatim: subtitle) }
        let remaining = program.end.timeIntervalSince(now)
        guard now >= program.start, remaining > 60 else { return nil }
        let units = Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes], width: .abbreviated)
        return Text(
            "\(Duration.seconds(remaining).formatted(units)) left",
            comment: "Time remaining in the live programme. The argument is a duration such as '32 min'."
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            artwork
                .overlay { progressOverlay }
                .overlay(alignment: .topLeading) { watchingBadge }
            VStack(alignment: .leading, spacing: 3) {
                MarqueeText(text: headline, font: metrics.castNameFont, isFocused: focused)
                    .foregroundStyle(.white)
                if let detail = Self.detail(for: item, now: now) {
                    detail
                        .font(metrics.castRoleFont)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, captionInset)
            .padding(.top, cardMetrics.landscapeCaptionTopSpacing)
        }
        .padding([.top, .horizontal], inset)
        .padding(.bottom, inset + captionInset)
        .frame(width: artWidth + inset * 2, height: metrics.cardHeight, alignment: .topLeading)
    }

    /// The channel being watched, marked on its art rather than taking a line
    /// of the caption.
    @ViewBuilder
    private var watchingBadge: some View {
        if isCurrent {
            Label {
                Text("Watching")
            } icon: {
                Image(systemName: "play.fill")
            }
            .font(metrics.castRoleFont.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            // A capsule: the corner radius clamps to half its height.
            .modifier(PanelGlassBackground(cornerRadius: 999))
            // Concentric with the art's corner.
            .padding(max(8, artCornerRadius / 2))
        }
    }

    /// The programme's progress across the bottom of its art, as a VOD
    /// poster's watch progress: the same scrim, the same white capsule.
    @ViewBuilder
    private var progressOverlay: some View {
        if let program = item.program {
            // Concentric with the art's rounded corner, as `PosterCardView`.
            let inset = max(artCornerRadius - Self.progressHeight / 2, 8)
            let fraction = CGFloat(program.progress(at: now))
            ZStack(alignment: .bottom) {
                MediaArtworkChromeScrim(top: false, bottom: true)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(PlozzMediaChrome.track(isFocused: focused))
                        Capsule(style: .continuous)
                            .fill(PlozzMediaChrome.foreground(isFocused: focused))
                            .frame(width: max(Self.progressHeight, geometry.size.width * fraction))
                            .shadow(color: .black.opacity(0.35), radius: Self.progressHeight * 0.25)
                    }
                }
                .frame(height: Self.progressHeight)
                .padding(.horizontal, inset)
                .padding(.bottom, inset)
            }
            .clipShape(RoundedRectangle(cornerRadius: artCornerRadius, style: .continuous))
            .allowsHitTesting(false)
        }
    }

    private var artwork: some View {
        LiveChannelProgramArtwork(
            artworkURL: item.program?.artworkURL, channelName: item.channelName, logoURL: item.logoURL,
            plozzChannelID: item.plozzChannelID, size: CGSize(width: artWidth, height: artHeight),
            cornerRadius: artCornerRadius
        )
    }
}
#endif
