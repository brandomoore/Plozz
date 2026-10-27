#if canImport(SwiftUI) && canImport(UIKit)
import AVFoundation
import CoreModels
import CoreNetworking
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
    var plozzChannelMood: LibraryChannelArtworkMood? = nil
    let channelID: String
    let input: LiveChannelInput
    let program: LiveChannelProgramInfo?
    /// The guide's programmes before `program`, for a rewind window reaching past its start.
    let earlierPrograms: [LiveChannelProgramInfo]
    let libraryItem: LibraryChannelItem?
    let openLibraryItem: ((LibraryChannelItem) -> Void)?
    let phase: LiveChannelPlaybackPhase
    let isAtLiveEdge: Bool
    let behindLiveSeconds: TimeInterval
    let canPause: Bool
    let canGoLive: Bool
    /// How far back the stream's own window reaches, when it can be seeked through.
    let seekWindowSeconds: TimeInterval?
    /// Step through the window by a signed number of seconds (remote left/right).
    let onSeekBy: (TimeInterval) -> Void
    /// Land a set distance behind live (a drag along the touch timeline).
    let onSeekBehindLive: (TimeInterval) -> Void
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
    var hasTouchGestureSurface = false
    var touchBackgroundTapRevision = 0
    var touchTimelineOnly = false
    var onTouchScrubbingChanged: (Bool) -> Void = { _ in }
    var onExpandPreview: (() -> Void)?
    var onCollapsePreview: (() -> Void)?
    var previewStatus: LocalizedStringResource?

    @Environment(\.playerCardMetrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.themePalette) private var palette
    @Environment(\.locale) private var locale
    @State private var openMenu: LiveChannelTrackMenuKind?
    @State private var menuReturnFocus: LiveChannelControl?
    /// The VOD player's options panel, fed the channel's tracks: its model, the
    /// Subtitles screen it shows, its remembered heights, the Menu press that
    /// steps it back, and the focus inside it.
    @State private var trackOptions = PlayerControlsModel()
    @State private var subtitleScreen: PlayerControls.SubtitleScreen = .tracks
    @State private var playbackScreen: PlayerControls.PlaybackScreen = .options
    @State private var audioScreen: PlayerControls.AudioScreen = .options
    #if os(iOS)
    private enum MobileSheet: String, Identifiable {
        case zoom, subtitles, audioSync
        var id: Self { self }
    }
    @State private var mobileMenu = PlayerMenuPresentation()
    @State private var mobileSheet: MobileSheet?
    #endif
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
    /// Touch: the overlay's own box, which sizes the cards (see `touchMetrics`).
    @State private var availableSize: CGSize = .zero
    /// A swipe or drag through the rewind window: where it would land, drawn on
    /// the timeline before anything seeks.
    @State private var scrub = LiveChannelTimelineScrub()
    @State private var scrubBehind: TimeInterval?
    /// A swipe's tail can arrive as a move command; it is not a 10 s step.
    @State private var scrubEndedAt: Date?
    /// The scrub preview above the playhead, and the position still to fetch
    /// while one fetch is under way (newest wins).
    @State private var scrubThumbnail: CGImage?
    @State private var scrubThumbnailWanted: TimeInterval?
    @State private var scrubThumbnailTask: Task<Void, Never>?
    /// A finger is on the remote's touch surface: its move commands are the
    /// swipe, which drags the playhead, never a 10 s step.
    @State private var scrubPanActive = false
    /// tvOS: a scrub left pending by a lifted finger, as Apple's player does:
    /// Select confirms it, and running out of time or Back cancels it.
    @State private var scrubConfirmTask: Task<Void, Never>?
    @State private var scrubPending = false
    /// The timeline's own native focus, from its button style. `focus` can lag
    /// it (the shared state follows the pills; see `tabFocused`).
    @State private var timelineFocused = false
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    @State private var touchViewportSize: CGSize = .zero
    #endif

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
            .onChange(of: scrubBehind) { _, behind in scrubMoved(behind) }
            #if os(iOS)
            .onChange(of: scrubBehind != nil) { _, scrubbing in
                if scrubbing { openMenu = nil }
                onTouchScrubbingChanged(scrubbing)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    resetScrub()
                    mobileMenu.reset()
                }
            }
            #endif
            // A finger held still is still scrubbing: keep the transport up
            // until it lifts, which is what confirms the position.
            .task(id: scrubBehind != nil) {
                guard scrubBehind != nil else { return }
                while !Task.isCancelled, scrubBehind != nil {
                    onControlActivity()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        .environment(\.channelLogoPreservesSourceCorners, true)
        .playerPlatformAppearance()
        .animation(.easeInOut(duration: 0.2), value: openMenu)
        .animation(.easeInOut(duration: 0.3), value: styleEditing)
        .onChange(of: trackOptionsSource, initial: true) { _, source in syncTrackOptions(source) }
        .onChange(of: locale.identifier) { syncTrackOptions(trackOptionsSource) }
        .onChange(of: focus) { _, control in focusChanged(control) }
        .onChange(of: openMenu != nil || cardOpen || mobileOptionsBusy) { _, pinned in
            onTracksPresentationChange(pinned)
        }
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
            case .playback: toggleMenu(.playback)
            }
        }
        .onChange(of: channelID) { _, _ in
            resetScrub()
            invalidateMobileMenu()
        }
        .onChange(of: input) { _, _ in
            resetScrub()
            invalidateMobileMenu()
        }
        .onChange(of: seekWindowSeconds == nil) { _, unavailable in
            if unavailable { resetScrub() }
        }
        .onDisappear {
            invalidateMobileMenu()
            resetScrub()
            onTracksPresentationChange(false)
            #if os(iOS)
            onTouchScrubbingChanged(false)
            #endif
        }
        #if os(iOS)
        .task(id: mobileMenu.destination) { presentMobileDestination() }
        .onChange(of: phase) { _, phase in
            if phase == .loading { invalidateMobileMenu() }
        }
        .onChange(of: PlayerMoreMenu.hasOptions(trackOptions, availability: mobileMenuAvailability)) { _, available in
            if !available { mobileMenu.reset() }
        }
        .plozzSheet(item: $mobileSheet) { sheet in
            switch sheet {
            case .zoom: PlayerZoomSettingsSheet(model: tracks.videoZoom)
            case .subtitles: LiveSubtitleSettingsSheet(tracks: tracks, controls: trackOptions)
            case .audioSync: LiveAudioSyncSheet(tracks: tracks, controls: trackOptions)
            }
        }
        #endif
        #if os(tvOS)
        .observingSystemPlaybackAudio(trackOptions.systemAudio, isVisible: true)
        .onExitCommand(perform: handleExit)
        .background(TVFocusActivityObserver(onActivity: onControlActivity))
        #endif
    }

    private var mobileOptionsBusy: Bool {
        #if os(iOS)
        mobileMenu.isBusy || mobileSheet != nil
        #else
        false
        #endif
    }

    private func invalidateMobileMenu() {
        #if os(iOS)
        mobileMenu.reset()
        mobileSheet = nil
        #endif
    }

    @ViewBuilder
    private var layout: some View {
        #if os(iOS)
        if let onExpandPreview {
            inlinePreviewLayout(expand: onExpandPreview)
        } else {
            touchLayout
        }
        #else
        ZStack(alignment: .top) {
            // Measured as a sibling so it is the same box the menu layer is laid
            // out in (VOD transport rule 1).
            Color.clear
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
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
    private static let horizontalMargin: CGFloat = 0
    private static let bottomMargin: CGFloat = 0
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
            .reportSubtitleControlsFrame(
                in: tracks.subtitles.controlsLayout, region: .topControls, isVisible: !touchChromeHidden
            )
            #endif
            Spacer(minLength: 0)
            #if os(iOS)
            if !isTouchPortrait {
                libraryButton
                    .reportSubtitleControlsFrame(
                        in: tracks.subtitles.controlsLayout, region: .topControls, isVisible: !touchChromeHidden
                    )
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
        // Level with the host's PiP / AirPlay row, which is laid out
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
                    .reportSubtitleControlsFrame(
                        in: tracks.subtitles.controlsLayout, region: .timeline, isVisible: !cardOpen && !styleEditing
                    )
                    // Steps aside for the card, in place, so nothing reflows.
                    .opacity(cardOpen ? 0 : 1)
                    .allowsHitTesting(!cardOpen)
                tabRow
            }
            .reportSubtitleControlsFrame(
                in: tracks.subtitles.controlsLayout, region: .transport, isVisible: !cardOpen && !styleEditing
            )
            card
                .reportSubtitleControlsFrame(
                    in: tracks.subtitles.controlsLayout, region: .card, isVisible: cardOpen && !styleEditing
                )
                .padding(.top, Self.cardGap - Self.stackSpacing)
                .padding(.bottom, Self.cardBottomPad)
                .offset(y: cardOpen ? 0 : Self.cardCatchUp)
                .disabled(!cardOpen)
        }
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
                .reportSubtitleControlsFrame(
                    in: tracks.subtitles.controlsLayout, region: .title,
                    isVisible: !cardOpen && !styleEditing
                )
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
                    cornerRadius: 8, plozzChannelID: plozzChannelID, plozzChannelMood: plozzChannelMood
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
            tracks: source.audio, selectedID: source.selectedAudio, preferred: [], locale: locale
        )
        trackOptions.subtitleOptions = TrackMenuBuilder.subtitleOptions(
            tracks: source.subtitles, selectedID: source.selectedSubtitle, preferred: [], detectedLanguages: [:], locale: locale
        )
        trackOptions.subtitleStyle = source.style
        trackOptions.subtitlesRenderHDR = source.isHDR
        trackOptions.engineCapabilities = source.capabilities
        #if os(iOS)
        trackOptions.subtitleDelayAdjustable = tracks.subtitles.supportsPrimaryTimingOffset
        trackOptions.subtitleDelaySeconds = tracks.subtitles.offset
        trackOptions.secondarySubtitleImagePrimaryFormat = TrackMenuBuilder.imagePrimaryFormat(
            selectedPrimaryID: source.selectedSubtitle, engineTracks: source.subtitles, providerTracks: []
        )
        #endif
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
            offersDualSubtitles: false,
            playbackScreen: $playbackScreen, videoZoom: tracks.videoZoom,
            offersPlaybackSpeed: false, audioScreen: $audioScreen
        )
        .reportSubtitleControlsFrame(in: tracks.subtitles.controlsLayout, region: .menu, isVisible: !styleEditing)
        .id(kind)
        .plozzFocusSection()
    }
    #endif

    // MARK: Badges

    private var showsAudio: Bool {
        #if os(tvOS)
        Self.showsAudio(trackCount: tracks.audioTracks.count, systemAudio: trackOptions.systemAudio)
        #else
        !tracks.audioTracks.isEmpty
        #endif
    }

    #if os(tvOS)
    static func showsAudio(trackCount: Int, systemAudio: SystemPlaybackAudio) -> Bool {
        trackCount > 1 || !systemAudio.availableSettings.isEmpty
    }
    #endif

    /// Subtitles once the stream offers any, as VOD.
    private var showsSubtitles: Bool { !tracks.subtitleTracks.isEmpty }
    private var showsZoom: Bool {
        tracks.engine.capabilities.contains(.videoZoom) && !tracks.continuesExternally
    }

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
            if showsZoom {
                badge(
                    LiveChannelTrackMenuKind.playback.title, systemImage: LiveChannelTrackMenuKind.playback.icon,
                    control: .playback, prominent: openMenu == .playback
                ) { toggleMenu(.playback) }
                    .accessibilityIdentifier("live-channel-playback")
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
                badge("Multiview", systemImage: "rectangle.split.2x2", control: .multiview, action: onMultiview)
                    .accessibilityIdentifier("live-channel-multiview")
            }
        }
        .reportSubtitleControlsFrame(
            in: tracks.subtitles.controlsLayout, region: .trackControls, isVisible: !cardOpen && !styleEditing
        )
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
        PlayerControlButton(title, systemImage: systemImage, prominent: prominent, action: action)
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
                    .reportSubtitleControlsFrame(in: tracks.subtitles.controlsLayout, region: .menu)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, Self.horizontalMargin)
            .padding(.top, Self.horizontalMargin)
            .padding(.bottom, menuBottomInset)
            .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
            #endif
        }
    }

    private var menuBottomInset: CGFloat {
        guard layerBottom > badgesTop, badgesTop > 0 else { return 320 }
        return layerBottom - badgesTop + Self.panelLift
    }

    // MARK: Timeline

    @ViewBuilder
    private var timelineRow: some View {
        #if os(tvOS)
        Button(action: timelineSelected) { timeline }
            .buttonStyle(LiveChannelTimelineButtonStyle { focused in
                timelineFocused = focused
                if focused { leftTabRow() } else { resetScrub() }
            })
            .background(timelineScrubPan)
            // VOD's left/right skip, through the stream's own rewind window.
            .onMoveCommand { direction in
                guard let window = seekWindowSeconds, !scrubPanActive,
                      scrubEndedAt.map({ Date().timeIntervalSince($0) > 0.5 }) ?? true else { return }
                // A click while a scrub waits moves the pending position, as VOD's skip does mid-scrub.
                if scrubPending, let pending = scrubBehind {
                    let step = direction == .left ? Self.seekStep : direction == .right ? -Self.seekStep : 0
                    guard step != 0 else { return }
                    scrubBehind = min(max(pending + step, 0), window)
                    awaitScrubConfirmation()
                    return
                }
                guard scrubBehind == nil else { return }
                switch direction {
                case .left: onSeekBy(-Self.seekStep)
                case .right: onSeekBy(Self.seekStep)
                default: break
                }
            }
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
            earlierPrograms: earlierPrograms,
            seekWindowSeconds: seekWindowSeconds,
            behindLiveSeconds: behindLiveSeconds,
            isAtLiveEdge: isAtLiveEdge,
            isPaused: phase == .paused,
            holdsFocusedShape: cardOpen,
            scrubBehind: $scrubBehind,
            scrubThumbnail: scrubThumbnail,
            showsScrubThumbnail: tracks.offersScrubThumbnails,
            previewAvailableSize: timelinePreviewSize,
            seekToBehindLive: seekWindowSeconds == nil ? nil : onSeekBehindLive
        )
    }

    private var timelinePreviewSize: CGSize {
        #if os(iOS)
        touchViewportSize
        #else
        availableSize
        #endif
    }

    #if os(tvOS)
    /// The remote's touch surface scrubs while the timeline holds focus.
    private var timelineScrubPan: some View {
        LiveChannelTimelineScrubPan(
            isEnabled: timelineFocused && seekWindowSeconds != nil && openMenu == nil && !cardOpen,
            began: {
                scrubPanActive = true
                scrubConfirmTask?.cancel()
                scrubConfirmTask = nil
                // A swipe after a lift carries on from the pending position.
                scrub.begin(behindLive: scrubBehind ?? behindLiveSeconds)
            },
            changed: { translation, speed in
                guard scrubPanActive, let window = seekWindowSeconds else { return }
                scrub.change(
                    translationX: Double(translation.x), translationY: Double(translation.y),
                    speed: speed, windowSeconds: window
                )
                // Undecided or vertical leaves any pending position where it is.
                if let behind = scrub.behindLive {
                    onControlActivity()
                    scrubBehind = behind
                }
            },
            ended: { committed in
                scrubPanActive = false
                let landing = committed ? scrub.end() : nil
                if !committed { scrub.cancel() }
                if landing != nil || scrubBehind != nil { scrubEndedAt = Date() }
                // Lifting is not a choice on the remote: hold the position for
                // Select to confirm.
                if let landing {
                    scrubBehind = landing
                    scrubPending = true
                    awaitScrubConfirmation()
                } else if scrubPending {
                    awaitScrubConfirmation()
                } else {
                    scrubBehind = nil
                }
            }
        )
    }
    #endif

    /// One remote press through the rewind window.
    static let seekStep: TimeInterval = 10

    /// How long a lifted scrub waits for Select before playback carries on.
    static let scrubConfirmTimeout: Duration = .seconds(5)

    private func awaitScrubConfirmation() {
        scrubConfirmTask?.cancel()
        scrubConfirmTask = Task { @MainActor in
            try? await Task.sleep(for: Self.scrubConfirmTimeout)
            guard !Task.isCancelled else { return }
            cancelPendingScrub()
        }
    }

    /// Select on the timeline: confirms a scrub (pending, or still under the
    /// finger), else plays/pauses.
    private func timelineSelected() {
        let landing = scrubPanActive ? scrub.end() ?? scrubBehind : scrubPending ? scrubBehind : nil
        guard let landing else {
            onPlayPause()
            return
        }
        scrubConfirmTask?.cancel()
        scrubConfirmTask = nil
        scrubPanActive = false
        scrub.cancel()
        scrubPending = false
        scrubBehind = nil
        scrubEndedAt = Date()
        onSeekBehindLive(landing)
    }

    /// Back, or the timeout: forget the scrub; playback never moved.
    @discardableResult
    private func cancelPendingScrub() -> Bool {
        guard scrubPending else { return false }
        scrubConfirmTask?.cancel()
        scrubConfirmTask = nil
        scrubPending = false
        scrubBehind = nil
        return true
    }

    private func resetScrub() {
        scrubConfirmTask?.cancel()
        scrubConfirmTask = nil
        scrubThumbnailTask?.cancel()
        scrubThumbnailTask = nil
        scrubThumbnailWanted = nil
        scrubThumbnail = nil
        scrubPending = false
        scrubPanActive = false
        scrub.cancel()
        scrubBehind = nil
    }

    /// Fetches the preview for where the scrub is now. A fetch in flight runs
    /// to completion (its segment is cached for the way back) and the next one
    /// starts from wherever the scrub has moved to by then.
    private func scrubMoved(_ behind: TimeInterval?) {
        guard let behind else {
            scrubThumbnailTask?.cancel()
            scrubThumbnailTask = nil
            scrubThumbnail = nil
            scrubThumbnailWanted = nil
            return
        }
        scrubThumbnailWanted = behind
        guard tracks.offersScrubThumbnails, scrubThumbnailTask == nil else { return }
        scrubThumbnailTask = Task { @MainActor in
            while !Task.isCancelled, let target = scrubThumbnailWanted {
                scrubThumbnailWanted = nil
                let image = await tracks.scrubThumbnail(behindLive: target, maxWidth: Self.scrubThumbnailPixels)
                guard !Task.isCancelled else { return }
                if scrubBehind != nil, let image { scrubThumbnail = image }
            }
            guard !Task.isCancelled else { return }
            scrubThumbnailTask = nil
        }
    }

    /// The preview variant's own width (`LiveHLSScrubThumbnails`): sharp in
    /// the box without upscaling the frame first.
    static let scrubThumbnailPixels = 640

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
                    .reportSubtitleControlsFrame(
                        in: tracks.subtitles.controlsLayout, region: .tab(tab.identifier), isVisible: !styleEditing
                    )
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
                    title: title, logoURL: logoURL, plozzChannelID: plozzChannelID,
                    plozzChannelMood: plozzChannelMood, program: program,
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
            .modifier(PanelGlassBackground(cornerRadius: metrics.panelCornerRadius, mediaGlass: true))
            #if os(iOS)
            .contentShape(Rectangle())
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("live-channel-guide-panel")
            #endif
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
        grid
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
        playbackScreen = .options
        audioScreen = .options
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
        #if os(tvOS)
        let returnFocus: LiveChannelControl? = menuReturnFocus == .audio && !showsAudio ? .timeline : menuReturnFocus
        #else
        let returnFocus = menuReturnFocus
        #endif
        openMenu = nil
        menuReturnFocus = nil
        subtitleScreen = .tracks
        playbackScreen = .options
        audioScreen = .options
        DispatchQueue.main.async { focus = returnFocus }
    }

    private func handleExit() {
        if cancelPendingScrub() { return }
        if (openMenu == .subtitles && subtitleScreen != .tracks)
            || (openMenu == .playback && playbackScreen != .options)
            || (openMenu == .audio && audioScreen != .options) {
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
/// Close at the top left with the host's PiP / AirPlay row beside it;
/// channel down · play / pause · channel up centred between the top bar and the
/// transport, where a thumb reaches; and at the foot, bottom-up, the card, the
/// tab row, the timeline and the title with its badges. A card replaces the
/// title and timeline rather than parking beneath them — tvOS parks the whole
/// cluster by one offset, which needs a known, roomy screen, and a phone on its
/// side has barely enough height for the card alone. Taps drive everything: a
/// tap on the video puts away an open menu, then an open card, then the
/// controls themselves.
extension LiveChannelOverlay {
    private var touchChromeHidden: Bool { touchTimelineOnly || scrubBehind != nil }

    /// Leaves the top row level with the host's presentation controls.
    static let touchTopBarInset: CGFloat = 0
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
            if !hasTouchGestureSurface {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture(perform: backgroundTapped)
            }
            touchScrim
            ZStack(alignment: .top) {
                // Measured as a sibling so it is the same box the menu layer is
                // laid out in (VOD transport rule 1).
                Color.clear
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        layerBottom = frame.maxY
                        availableSize = frame.size
                    }
                    .allowsHitTesting(false)
                VStack(spacing: 0) {
                    topBar
                        .playerTouchChromeHidden(touchChromeHidden)
                    Spacer(minLength: 0)
                    touchBottomCluster
                }
                menuLayer
            }
            .modifier(PlayerTouchChromePadding())
            if !cardOpen, openMenu == nil {
                centerTransport
                    .reportSubtitleControlsFrame(
                        in: tracks.subtitles.controlsLayout, region: .centerTransport, isVisible: !touchChromeHidden
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .playerTouchChromeHidden(touchChromeHidden)
                    .transition(.opacity)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { touchViewportSize = $0 }
        .environment(\.playerCardMetrics, touchMetrics)
        .onChange(of: touchBackgroundTapRevision) { _, _ in backgroundTapped() }
    }

    private func inlinePreviewLayout(expand: @escaping () -> Void) -> some View {
        ZStack {
            if !hasTouchGestureSurface {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: backgroundTapped)
            }
            if let previewStatus {
                Text(previewStatus)
                    .font(.subheadline)
            } else {
                centerTransport
                    .reportSubtitleControlsFrame(
                        in: tracks.subtitles.controlsLayout, region: .centerTransport, isVisible: true
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(spacing: 12) {
                    Text(program?.title ?? title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    touchGoLiveBadge
                    touchBadge(
                        "Full Screen", systemImage: "arrow.up.left.and.arrow.down.right",
                        action: expand
                    )
                    .accessibilityIdentifier("live-channel-fullscreen")
                }
                .reportSubtitleControlsFrame(
                    in: tracks.subtitles.controlsLayout, region: .title, isVisible: true
                )
            }
            .padding(12)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { touchViewportSize = $0 }
        .onChange(of: touchBackgroundTapRevision) { _, _ in backgroundTapped() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("live-channel-preview-controls")
    }

    private var touchScrim: some View {
        LinearGradient(
            colors: [
                .black.opacity(touchTimelineOnly ? 0 : 0.65),
                .black.opacity(touchTimelineOnly ? 0 : 0.35),
                .black.opacity(touchTimelineOnly ? 0.45 : (cardOpen ? 0.9 : 0.82))
            ],
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
        HStack(spacing: compactTransport ? 20 : PlayerTouchLayout.transportSpacing(in: touchViewportSize)) {
            Button(action: onPrevious) {
                Label("Previous Channel", systemImage: "backward.end.fill")
                    .labelStyle(.iconOnly)
                    .font(.system(size: compactTransport ? 24 : 34))
            }
            .buttonStyle(PlayerGlassCircleButtonStyle(diameter: compactTransport ? 44 : PlayerTouchLayout.skipDiameter))
            .accessibilityIdentifier("live-channel-previous")

            playPauseButton

            Button(action: onNext) {
                Label("Next Channel", systemImage: "forward.end.fill")
                    .labelStyle(.iconOnly)
                    .font(.system(size: compactTransport ? 24 : 34))
            }
            .buttonStyle(PlayerGlassCircleButtonStyle(diameter: compactTransport ? 44 : PlayerTouchLayout.skipDiameter))
            .accessibilityIdentifier("live-channel-next")
        }
        .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
    }

    private var compactTransport: Bool {
        onExpandPreview != nil || PlayerTouchLayout.usesCompactTransport(in: touchViewportSize)
    }

    private var playPauseDiameter: CGFloat {
        guard onExpandPreview != nil else { return compactTransport ? 44 : PlayerTouchLayout.playDiameter }
        // Keep the centered primary control clear of the 44 pt footer and its 12 pt inset.
        return min(64, max(44, touchViewportSize.height - 2 * (44 + 12)))
    }

    /// Stands in for the host's activity panel while the controls are up, so
    /// a tune in progress doesn't stack a spinner card over these buttons.
    private var playPauseButton: some View {
        Button(action: onPlayPause) {
            Group {
                if isBusy {
                    ProgressView()
                        .controlSize(.large)
                        .tint(Color.primary)
                        .accessibilityLabel(Text(phase.activityLabel))
                } else if phase == .paused {
                    Label("Play", systemImage: "play.fill")
                } else {
                    Label("Pause", systemImage: "pause.fill")
                }
            }
            .labelStyle(.iconOnly)
            .font(.system(size: onExpandPreview != nil ? playPauseDiameter / 2 : (compactTransport ? 24 : 44)))
        }
        .buttonStyle(PlayerGlassCircleButtonStyle(diameter: playPauseDiameter))
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
        VStack(alignment: .leading, spacing: 0) {
            if !cardOpen {
                Group {
                    if isTouchPortrait {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .center, spacing: 12) {
                                touchTitleBlock
                                touchGoLiveBadge
                                libraryButton
                            }
                            touchTrackBadges()
                                .reportSubtitleControlsFrame(
                                    in: tracks.subtitles.controlsLayout, region: .trackControls,
                                    isVisible: !touchChromeHidden
                                )
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    } else {
                        HStack(alignment: .bottom, spacing: 16) {
                            touchTitleBlock
                            touchBadges
                                .layoutPriority(1)
                        }
                    }
                }
                .playerTouchChromeHidden(touchChromeHidden)
                .transition(.opacity)
                timeline
                    .frame(height: PlayerTouchLayout.timelineRowHeight)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("live-channel-timeline")
                    .reportSubtitleControlsFrame(in: tracks.subtitles.controlsLayout, region: .timeline)
                    .transition(.opacity)
            }
            HStack(spacing: 12) {
                touchTabRow
                if let onCollapsePreview {
                    Spacer(minLength: 0)
                    touchBadge(
                        "Exit Full Screen", systemImage: "arrow.down.right.and.arrow.up.left",
                        action: onCollapsePreview
                    )
                    .accessibilityIdentifier("live-channel-exit-fullscreen")
                }
            }
                .playerTouchChromeHidden(touchChromeHidden)
            if cardOpen {
                card
                    .reportSubtitleControlsFrame(in: tracks.subtitles.controlsLayout, region: .card)
                    .padding(.top, PlayerTouchLayout.cardSpacing)
                    // Grows upward out of the tabs, as VOD's touch card does.
                    .transition(.scale(scale: 0.94, anchor: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, Self.horizontalMargin)
        .padding(.bottom, Self.bottomMargin)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var touchTitleBlock: some View {
        let compact = PlayerTouchLayout.usesCompactTitle(in: touchViewportSize)
        return VStack(alignment: .leading, spacing: 4) {
            if program != nil, !compact {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .accessibilityIdentifier("live-channel-name")
                    touchPositionBadge
                }
            }
            HStack(spacing: 8) {
                Text(program?.title ?? title)
                    .font(compact ? .headline : .title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityIdentifier("live-channel-program-title")
                if program == nil || compact {
                    touchPositionBadge
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("live-channel-title-block")
        .reportSubtitleControlsFrame(
            in: tracks.subtitles.controlsLayout, region: .title,
            isVisible: !cardOpen && !touchChromeHidden
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(openMenu == nil ? 1 : 0)
        .animation(.easeInOut(duration: 0.28), value: openMenu == nil)
    }

    private var touchPositionBadge: some View {
        let playing = LiveChannelPlaybackPhase.playing
        let scheduled = plozzChannelID != nil
        let showsPosition = phase == .playing || (phase == .paused && !isAtLiveEdge)
        return ZStack(alignment: .leading) {
            // Reserve both localized widths so changing position or hiding the badge cannot move the header.
            ForEach([true, false], id: \.self) { atLiveEdge in
                LiveChannelStatusPill(
                    status: playing.statusLabel(isAtLiveEdge: atLiveEdge, isScheduledChannel: scheduled),
                    isLive: false, compact: true
                )
                .hidden()
            }
            LiveChannelStatusPill(
                status: playing.statusLabel(isAtLiveEdge: isAtLiveEdge, isScheduledChannel: scheduled),
                isLive: isAtLiveEdge, compact: true
            )
            .accessibilityIdentifier("live-channel-position")
            .playerTouchChromeHidden(!showsPosition)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// The same actions as the tvOS badges, as VOD's touch glass circles.
    private var touchBadges: some View {
        touchTrackBadges(includesGoLive: true)
        .reportSubtitleControlsFrame(
            in: tracks.subtitles.controlsLayout, region: .trackControls, isVisible: !touchChromeHidden
        )
    }

    @ViewBuilder
    private var touchGoLiveBadge: some View {
        if canGoLive {
            touchBadge(
                LibraryChannelPlaybackCopy.returnToCurrentTitle(isScheduledChannel: plozzChannelID != nil),
                systemImage: plozzChannelID != nil ? "clock.arrow.circlepath" : "dot.radiowaves.left.and.right",
                action: onGoLive
            )
            .accessibilityIdentifier("live-channel-go-live")
            .reportSubtitleControlsFrame(
                in: tracks.subtitles.controlsLayout, region: .trackControls, isVisible: !touchChromeHidden
            )
        }
    }

    /// Track actions stay above the timeline, below the title in portrait.
    private func touchTrackBadges(includesGoLive: Bool = false) -> some View {
        PlayerGlassControlGroup {
            if includesGoLive { touchGoLiveBadge }
            PlayerMoreMenuButton(
                model: trackOptions, availability: mobileMenuAvailability, presentation: mobileMenu,
                layout: .init(size: touchViewportSize),
                accessibilityIdentifier: "live-channel-playback-options", actions: mobileMenuActions
            )
        }
        // GLOBAL, so the menu layer can rest the open menu just above them.
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { top in
            badgesTop = top
        }
    }

    private var mobileMenuAvailability: PlayerMoreMenuAvailability {
        .init(video: showsZoom, videoModel: tracks.videoZoom, multiview: onMultiview != nil)
    }

    private var mobileMenuActions: PlayerMoreMenuActions {
        let generation = mobileMenu.generation
        var actions = PlayerMoreMenuActions()
        actions.isCurrent = {
            mobileMenu.generation == generation && tracks.matchesSource(channelID: channelID, input: input)
        }
        actions.selectAudio = { id in
            guard let track = tracks.audioTracks.first(where: { $0.id == id }) else {
                PlozzLog.playback.debug("Ignoring obsolete live audio menu selection.")
                return
            }
            tracks.selectAudio(track)
            onControlActivity()
        }
        actions.selectSubtitle = { id in
            if id == PlayerTrackOption.offID {
                tracks.selectSubtitle(nil)
            } else if let track = tracks.subtitleTracks.first(where: { $0.id == id }) {
                tracks.selectSubtitle(track)
            } else {
                PlozzLog.playback.debug("Ignoring obsolete live subtitle menu selection.")
                return
            }
            onControlActivity()
        }
        actions.setDialogueEnhancement = { enabled in
            tracks.engine.setDialogEnhanceEnabled(enabled)
            trackOptions.dialogEnhanceEnabled = enabled
            onControlActivity()
        }
        return actions
    }

    private func presentMobileDestination() {
        guard let destination = mobileMenu.takeDestination() else { return }
        guard scenePhase == .active, tracks.matchesSource(channelID: channelID, input: input) else {
            mobileMenu.reset()
            return
        }
        switch destination {
        case .zoom: mobileSheet = .zoom
        case .subtitleAdvanced: mobileSheet = .subtitles
        case .audioSync: mobileSheet = .audioSync
        case .multiview:
            if let onMultiview { onMultiview() }
            else { PlozzLog.playback.debug("Ignoring unavailable live multiview menu selection.") }
        case .subtitleSearch, .speed, .quality, .versions, .timestamps:
            PlozzLog.playback.error("Live menu requested an unavailable destination.")
        }
    }

    private func touchBadge(
        _ title: LocalizedStringResource, systemImage: String,
        selected: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label { Text(title) } icon: { Image(systemName: systemImage) }
                .labelStyle(.iconOnly)
                .font(.title3)
        }
        .buttonStyle(PlayerGlassCircleButtonStyle(diameter: 44))
        .accessibilityAddTraits(selected ? .isSelected : [])
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
        HStack(spacing: 8) {
            ForEach(availableTabs, id: \.self) { tab in
                Button { toggleCard(tab) } label: { Text(tab.title) }
                    .playerTouchTab(selected: cardOpen && cardTab == tab)
                    // The whole pill takes the tap; see `PlayerTouchCardStrip.tab`.
                    .contentShape(Capsule(style: .continuous))
                    .disabled(openMenu != nil)
                    .accessibilityIdentifier(tab.identifier)
                    .accessibilityAddTraits(cardOpen && cardTab == tab ? .isSelected : [])
                    .reportSubtitleControlsFrame(in: tracks.subtitles.controlsLayout, region: .tab(tab.identifier))
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
    var minimumInset: CGFloat = 0
    var minimumHorizontalInset: CGFloat = 0

    @Environment(\.layoutDirection) private var layoutDirection
    @State private var window = WindowSafeArea()

    func body(content: Content) -> some View {
        let insets = isEnabled ? window.insets : .zero
        let minimum = isEnabled ? minimumInset : 0
        let horizontal = isEnabled ? minimumHorizontalInset : 0
        let rtl = layoutDirection == .rightToLeft
        content
            .padding(EdgeInsets(
                top: max(minimum, insets.top), leading: max(horizontal, rtl ? insets.right : insets.left),
                bottom: max(minimum, insets.bottom), trailing: max(horizontal, rtl ? insets.left : insets.right)
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
    var plozzChannelMood: LibraryChannelArtworkMood? = nil
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
            cornerRadius: cornerRadius, plozzChannelID: plozzChannelID, plozzChannelMood: plozzChannelMood
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
    var plozzChannelMood: LibraryChannelArtworkMood? = nil
    let program: LiveChannelProgramInfo?
    /// A stood-up phone: the art stays but shrinks, and the synopsis goes so
    /// the title and timing have room to wrap instead.
    var compact = false
    let diagnosticsEnabled: Bool
    let toggleDiagnostics: () -> Void
    @FocusState.Binding var focus: LiveChannelControl?

    @Environment(\.playerCardMetrics) private var metrics
    @Environment(\.playerControlForeground) private var foreground

    private var artHeight: CGFloat {
        (compact ? metrics.contentHeight * 0.8 : metrics.contentHeight).rounded()
    }

    var body: some View {
        HStack(alignment: .top, spacing: metrics.columnSpacing) {
            if metrics.showsThumbnail {
                LiveChannelProgramArtwork(
                    artworkURL: program?.artworkURL, channelName: title, logoURL: logoURL,
                    plozzChannelID: plozzChannelID,
                    plozzChannelMood: plozzChannelMood,
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
                        .foregroundStyle(foreground.opacity(0.75))
                        .lineLimit(1)
                }
                if let program {
                    LiveChannelProgramTiming(program: program)
                        .font(metrics.captionFont)
                        .foregroundStyle(foreground.opacity(0.6))
                        .lineLimit(compact ? 2 : 1)
                    if !compact, let description = program.description {
                        Text(description)
                            .font(metrics.bodyFont)
                            .foregroundStyle(foreground.opacity(0.85))
                            .lineLimit(metrics.overviewLineLimit)
                    }
                } else {
                    Text("No guide information for this channel.")
                        .font(metrics.bodyFont)
                        .foregroundStyle(foreground.opacity(0.6))
                }
            }
            .foregroundStyle(foreground)
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
        .modifier(PanelGlassBackground(cornerRadius: metrics.panelCornerRadius, mediaGlass: true))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("live-channel-info-panel")
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
        #if os(iOS)
        .playerTouchPanelAction()
        .accessibilityAddTraits(diagnosticsEnabled ? .isSelected : [])
        #else
        .buttonStyle(InfoActionButtonStyle(
            focused: isFocused,
            prominent: diagnosticsEnabled,
            hPadding: metrics.actionHPadding,
            vPadding: metrics.actionVPadding
        ))
        #endif
        .accessibilityLabel("Playback Info")
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

// MARK: - Timeline

/// The live stand-in for VOD's scrub bar, measuring the programme instead of a
/// file. Mobile uses fill-only progress; tvOS retains its playhead.
///
/// The faint fill is what has aired so far (VOD's buffered fill); the bright
/// fill (and tvOS playhead) is what is on screen, which trails it while paused or
/// time-shifted. The label riding the playhead is the clock time of the picture
/// on screen. Without guide data the bar is simply full at the live edge.
private struct LiveChannelTimeline: View {
    let program: LiveChannelProgramInfo?
    /// Programmes before `program`, for a rewind window that reaches past its start.
    let earlierPrograms: [LiveChannelProgramInfo]
    /// How far back the stream can be rewound; nil without a usable window.
    let seekWindowSeconds: TimeInterval?
    let behindLiveSeconds: TimeInterval
    let isAtLiveEdge: Bool
    let isPaused: Bool
    /// The card is up: keep the bar in its focused shape while it travels
    /// (see `ScrubBar`), whatever holds focus.
    let holdsFocusedShape: Bool
    /// A swipe or drag in progress: where it would land, in seconds behind live.
    @Binding var scrubBehind: TimeInterval?
    /// The frame there, when one has loaded.
    var scrubThumbnail: CGImage?
    /// Scrubbing shows the preview box at once, as VOD does, filled when a frame lands.
    var showsScrubThumbnail = false
    var previewAvailableSize: CGSize = .zero
    /// Touch: a drag along the bar seeks through the window.
    var seekToBehindLive: ((TimeInterval) -> Void)?

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
        // A scrub shows where it would land, as VOD's playhead follows the finger.
        let behind = scrubBehind ?? behindLiveSeconds
        let onScreen = now.addingTimeInterval(-behind)
        let layout = LiveChannelTimelineLayout(
            now: now, program: program, earlierPrograms: earlierPrograms,
            seekWindowSeconds: seekWindowSeconds, behindLiveSeconds: behind
        )
        #if os(iOS)
        let samples = PlayerClockTimes.clockWidthSamples(locale: locale)
        return HStack(spacing: 4) {
            touchTime(
                clock(onScreen), samples: samples, alignment: .leading,
                label: "Current time", identifier: "live-timeline-current-time"
            )
            bar(layout)
                .frame(height: 44)
                .contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Playback position")
                .accessibilityValue(Text(verbatim: clock(onScreen)))
                .accessibilityIdentifier("live-channel-timeline-scrubber")
                .modifier(LiveChannelTimelineDrag(
                    layout: layout, now: now, windowSeconds: seekWindowSeconds,
                    preview: $scrubBehind, seek: seekToBehindLive
                ))
            touchTime(
                program == nil ? "--:--" : clock(layout.end), samples: samples, alignment: .trailing,
                label: "Estimated end time", identifier: "live-timeline-end-time"
            )
        }
        #else
        return VStack(spacing: Self.rowSpacing) {
            bar(layout)
                .frame(height: Self.barRowHeight)
            labels(layout, onScreen: onScreen)
                .frame(height: Self.labelRowHeight)
        }
        // The bar and its time row together: about VOD's 44pt touch target,
        // where the bar alone is too thin to catch without aiming.
        .modifier(LiveChannelTimelineDrag(
            layout: layout, now: now, windowSeconds: seekWindowSeconds,
            preview: $scrubBehind, seek: seekToBehindLive
        ))
        #endif
    }

    #if os(iOS)
    private func touchTime(
        _ text: String, samples: [String], alignment: Alignment,
        label: LocalizedStringResource, identifier: String
    ) -> some View {
        ZStack {
            ForEach(samples, id: \.self) { Text(verbatim: $0).hidden() }
        }
        .overlay(alignment: alignment) {
            Text(verbatim: text)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .font(.caption.monospacedDigit())
        .fixedSize()
        .frame(minWidth: 44, minHeight: 44, alignment: alignment)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(verbatim: text))
        .accessibilityIdentifier(identifier)
    }
    #endif

    // Touch has no focused shape to make room for, and VOD's touch bar is a
    // slim line with small times, so the phone gets the compact row.
    #if os(tvOS)
    private static let rowSpacing: CGFloat = 8
    private static let barRowHeight: CGFloat = 44
    private static let labelRowHeight: CGFloat = 30
    private static let restingBarHeight: CGFloat = 12
    private static let restingKnobHeight: CGFloat = 12
    private static let scrubbingKnobWidth: CGFloat = 8
    private static let scrubbingKnobHeight: CGFloat = 40
    private static let pauseGlyphSize: CGFloat = 24
    private static let pauseGlyphOffset: CGFloat = 40
    private static let timeFont: Font = .callout.weight(.semibold)
    #else
    private static let rowSpacing: CGFloat = 2
    private static let barRowHeight: CGFloat = 18
    private static let labelRowHeight: CGFloat = 20
    private static let restingBarHeight: CGFloat = 8
    private static let pauseGlyphSize: CGFloat = 16
    private static let pauseGlyphOffset: CGFloat = 24
    private static let timeFont: Font = .caption.weight(.semibold)
    #endif

    /// With a rewind window the faint fill is the window itself (VOD's buffered
    /// fill: what can be reached), and the bright fill runs from its start to
    /// the picture on screen. Without one only the faint aired span shows.
    /// Programme boundaries split the bar into sections.
    private func bar(_ layout: LiveChannelTimelineLayout) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let knobX = width * CGFloat(layout.playing)
            // Scrubbing takes VOD's touched shape on touch (`PlayerTouchScrubBar`)
            // and its focused shape with a lifted knob on the remote.
            let scrubbing = scrubBehind != nil
            let barHeight: CGFloat = focused || scrubbing ? 20 : Self.restingBarHeight
            #if os(tvOS)
            let fillStart = width * CGFloat(layout.seekableStart ?? 0)
            let knobWidth: CGFloat = scrubbing ? Self.scrubbingKnobWidth : focused ? 8 : 4
            let knobHeight: CGFloat = scrubbing ? Self.scrubbingKnobHeight
                : focused ? 32 : Self.restingKnobHeight
            #endif
            ZStack(alignment: .leading) {
                #if os(iOS)
                LiveChannelTouchTrack(
                    layout: layout, width: width, height: barHeight, focused: focused, scrubbing: scrubbing
                )
                #else
                ZStack(alignment: .leading) {
                    PlayerScrubTrackSurface(height: barHeight)
                    Rectangle()
                        .fill(Color.white.opacity(layout.seekableStart == nil ? 0.14 : 0.24))
                        .frame(width: max(0, width * CGFloat(layout.aired) - fillStart), height: barHeight)
                        .offset(x: fillStart)
                    // The bright fill means "you can go here": without a rewind
                    // window only the faint aired span shows.
                    if layout.seekableStart != nil {
                        Rectangle()
                            .fill(Color.white.opacity(scrubbing ? 0.9 : focused ? 0.62 : 0.32))
                            .frame(width: max(0, knobX - fillStart), height: barHeight)
                            .offset(x: fillStart)
                    }
                }
                .mask {
                    LiveChannelProgrammeTrack(
                        ranges: layout.maskRanges, height: barHeight, restingHeight: Self.restingBarHeight
                    )
                    .equatable()
                }
                #endif
                if scrubbing, showsScrubThumbnail {
                    LiveChannelScrubThumbnail(
                        image: scrubThumbnail, knobX: knobX, barWidth: width,
                        availableSize: previewAvailableSize
                    )
                        .transition(.opacity)
                }
                #if os(tvOS)
                RoundedRectangle(cornerRadius: focused || scrubbing ? knobWidth / 2 : 0, style: .continuous)
                    .fill(Color.white)
                    .frame(width: knobWidth, height: knobHeight)
                    .offset(x: knobX - knobWidth / 2)
                    .shadow(radius: 4)
                #endif
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .animation(.easeOut(duration: 0.2), value: focused)
        }
    }

    /// VOD's timeline labels: the current label rides the playhead and the ends
    /// give way to it rather than colliding.
    private func labels(_ layout: LiveChannelTimelineLayout, onScreen: Date) -> some View {
        let playing = layout.playing
        let start = program == nil && seekWindowSeconds == nil ? nil : clock(layout.start)
        let end = program.map { _ in clock(layout.end) }
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

#if os(iOS)
struct LiveChannelTouchTrack: View {
    let layout: LiveChannelTimelineLayout
    let width: CGFloat
    let height: CGFloat
    let focused: Bool
    let scrubbing: Bool
    var body: some View {
        let fillStart = width * CGFloat(layout.seekableStart ?? 0)
        ZStack(alignment: .leading) {
            PlayerScrubTrackSurface(height: height)
            Rectangle()
                .fill(Color.white.opacity(layout.seekableStart == nil ? 0.14 : 0.24))
                .frame(width: max(0, width * CGFloat(layout.aired) - fillStart), height: height)
                .offset(x: fillStart)
            if layout.seekableStart != nil {
                Rectangle()
                    .fill(Color.white.opacity(scrubbing ? 0.9 : focused ? 0.62 : 0.32))
                    .frame(width: max(0, width * CGFloat(layout.playing) - fillStart), height: height)
                    .offset(x: fillStart)
            }
        }
        .mask {
            LiveChannelProgrammeTrack(ranges: layout.maskRanges, height: height, minimumSectionWidth: 20)
                .equatable()
        }
        .frame(width: width, height: height)
    }
}
#endif

/// The scrub preview floating above the playhead, in VOD's frame (`ScrubBar`):
/// glass-bordered on 26, kept on the bar's span, centred on the playhead.
private struct LiveChannelScrubThumbnail: View {
    /// nil until the first frame lands: the box shows empty, as VOD's does.
    let image: CGImage?
    let knobX: CGFloat
    let barWidth: CGFloat
    var availableSize: CGSize = .zero
    @Environment(\.plozzReduceTransparency) private var reduceTransparency

    #if os(tvOS)
    private static let width: CGFloat = 483
    private static let border: CGFloat = 12
    private static let corner: CGFloat = 18
    private static let lift: CGFloat = 34
    #else
    private static let width: CGFloat = 200
    private static let border: CGFloat = 6
    private static let corner: CGFloat = 10
    private static let lift: CGFloat = 22
    #endif

    var body: some View {
        #if os(iOS)
        let size = PlayerTouchLayout.scrubPreviewSize(availableSize: availableSize)
        PlayerTouchScrubPreview(image: image, availableSize: availableSize)
            .position(
                x: min(max(knobX, size.width / 2), max(size.width / 2, barWidth - size.width / 2)),
                y: -(Self.lift + size.height / 2)
            )
        #else
        let aspect = image.map { $0.height > 0 ? CGFloat($0.width) / CGFloat($0.height) : 16.0 / 9.0 } ?? 16.0 / 9.0
        let height = Self.width / aspect
        let visualWidth = Self.width + 2 * Self.border
        let half = visualWidth / 2
        let x = min(max(knobX, half), max(half, barWidth - half))
        let content = ZStack {
            Rectangle().fill(.black.opacity(0.55))
            if let image {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: Self.width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        Group {
            if #available(iOS 26.0, tvOS 26.0, *), !reduceTransparency {
                content
                    .padding(Self.border)
                    .background {
                        PlayerNativeGlassSurface(RoundedRectangle(
                            cornerRadius: Self.corner + Self.border, style: .continuous
                        ))
                    }
            } else {
                content.overlay(
                    RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                        .stroke(.white.opacity(0.85), lineWidth: Self.border)
                )
            }
        }
        .position(x: x, y: -(Self.lift + height / 2))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        #endif
    }
}

/// Touch: dragging along the timeline seeks through the window, landing where
/// the finger lifts. Reaching past the live edge lands on it.
private struct LiveChannelTimelineDrag: ViewModifier {
    let layout: LiveChannelTimelineLayout
    let now: Date
    let windowSeconds: TimeInterval?
    @Binding var preview: TimeInterval?
    let seek: ((TimeInterval) -> Void)?
    @GestureState private var isDragging = false

    func body(content: Content) -> some View {
        #if os(iOS)
        if let seek {
            content.overlay {
                GeometryReader { geometry in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .updating($isDragging) { _, active, _ in active = true }
                            .onChanged { value in
                                preview = behind(at: value.location.x, width: geometry.size.width)
                            }
                            .onEnded { value in
                                let landing = behind(at: value.location.x, width: geometry.size.width)
                                preview = nil
                                guard let landing else { return }
                                seek(landing)
                                TouchFeedback.shared.emit(.selection)
                            })
                }
            }
            .onChange(of: isDragging) { _, active in
                if !active { preview = nil }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }

    /// Seconds behind live under the finger: the layout's clock at that point,
    /// kept inside the window (the bar can show earlier, unreachable programmes).
    private func behind(at x: CGFloat, width: CGFloat) -> TimeInterval? {
        guard width > 0 else { return nil }
        let fraction = min(max(x / width, 0), 1)
        let span = layout.end.timeIntervalSince(layout.start)
        let target = layout.start.addingTimeInterval(span * Double(fraction))
        let behind = max(0, now.timeIntervalSince(target))
        return windowSeconds.map { min(behind, $0) } ?? behind
    }
}

/// The timeline's track cut into one rounded section per programme, the way
/// `PlayerSkipMarkerTrack` cuts VOD's bar at skip markers.
private struct LiveChannelProgrammeTrack: View, Equatable {
    let ranges: [Range<Double>]
    let height: CGFloat
    var minimumSectionWidth: CGFloat = 0
    var restingHeight: CGFloat? = nil

    var body: some View {
        Canvas { context, size in
            let mask = SkipMarkerTrackLayout.maskPath(
                ranges: ranges, size: size, minimumSectionWidth: minimumSectionWidth,
                restingHeight: restingHeight
            )
            context.fill(mask, with: .color(.white))
        }
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
    var compact = false

    var body: some View {
        Text(status)
            .font(.caption2.weight(.heavy))
            .tracking(0.6)
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 6 : 10)
            .padding(.vertical, compact ? 2 : 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isLive ? Color(uiColor: .systemRed) : Color.gray.opacity(0.75))
            )
            .animation(.easeInOut(duration: 0.2), value: isLive)
    }
}

// MARK: - Track menus

enum LiveChannelTrackMenuKind: Hashable {
    case audio, subtitles, playback

    var title: LocalizedStringResource {
        switch self {
        case .playback: "Playback"
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
        case .playback: "slider.horizontal.3"
        case .audio: "waveform"
        case .subtitles: "captions.bubble"
        }
    }

    var control: LiveChannelControl {
        switch self {
        case .playback: .playback
        case .audio: .audio
        case .subtitles: .subtitles
        }
    }

    /// The VOD options panel's menu for this kind.
    var category: PlayerControls.Category {
        switch self {
        case .playback: .playback
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
        case .playback: model.videoZoom.settings.mode.rawValue
        case .audio:
            model.audioTracks.firstIndex { $0.id == model.selectedAudioID } ?? 0
        case .subtitles:
            model.subtitleTracks.firstIndex { $0.id == model.selectedSubtitleID }.map { $0 + 1 } ?? 0
        }
    }

    private var rows: [Row] {
        switch kind {
        case .playback:
            return PlayerVideoZoom.Mode.allCases.map { mode in
                Row(id: mode.rawValue, title: Text(mode.menuTitle), isSelected: model.videoZoom.settings.mode == mode) {
                    model.videoZoom.settings.mode = mode
                }
            }
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
                .foregroundStyle(Color.primary)
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
struct LiveChannelOnNowPanel: View {
    let items: [LiveChannelOnNowItem]
    let currentChannelID: String
    @FocusState.Binding var focus: LiveChannelControl?
    let isCardOpen: Bool
    let select: (LiveChannelOnNowItem) -> Void

    @Environment(\.playerCardMetrics) private var metrics
    @Environment(\.playerControlForeground) private var foreground

    var body: some View {
        if items.isEmpty {
            Text("Nothing else is on right now.")
                .font(metrics.bodyFont)
                .foregroundStyle(foreground.opacity(0.7))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { PlayerOverVideoSurface(cornerRadius: metrics.panelCornerRadius, mediaGlass: true) }
                .accessibilityIdentifier("live-channel-on-now-empty")
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
                    .buttonStyle(LiveChannelCardButtonStyle(cornerRadius: metrics.panelCornerRadius))
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
            PlayerOverVideoCardStyle(focused: isFocused, cornerRadius: cornerRadius, focusScale: 1.10, mediaGlass: true)
                .makeBody(configuration: configuration)
        }
    }
}

struct LiveChannelOnNowCard: View {
    let item: LiveChannelOnNowItem
    let isCurrent: Bool
    let now: Date
    /// Whether the row keeps room for a second line under the title.
    let reservesDetailLine: Bool

    @Environment(\.playerCardMetrics) private var metrics
    @Environment(\.playerControlForeground) private var foreground
    @Environment(\.isFocused) private var focused

    private static let spacing: CGFloat = 10
    #if os(tvOS)
    private static let progressHeight: CGFloat = 6
    #else
    private static let progressHeight: CGFloat = 4
    #endif

    private var inset: CGFloat { metrics.contentPadding }

    /// Everything under the art, so the art takes exactly what is left of the
    /// card's fixed height.
    private var textHeight: CGFloat {
        guard reservesDetailLine else { return (metrics.castNameSize * 1.25).rounded(.up) }
        return ((metrics.castNameSize + metrics.castRoleSize) * 1.25).rounded(.up) + 3
    }

    /// Player insets and corners stay independent of browsing-card density.
    private var artHeight: CGFloat {
        max(40, (metrics.cardHeight - inset * 2 - textHeight - Self.spacing).rounded())
    }

    private var artCornerRadius: CGFloat { max(8, metrics.panelCornerRadius - inset) }

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
        VStack(alignment: .leading, spacing: Self.spacing) {
            artwork
                .overlay { progressOverlay }
                .overlay(alignment: .topLeading) { watchingBadge }
            VStack(alignment: .leading, spacing: 3) {
                MarqueeText(text: headline, font: metrics.castNameFont, isFocused: focused)
                    .foregroundStyle(foreground)
                if let detail = Self.detail(for: item, now: now) {
                    detail
                        .font(metrics.castRoleFont)
                        .foregroundStyle(foreground.opacity(0.6))
                        .lineLimit(1)
                }
            }
        }
        .padding(inset)
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
            .foregroundStyle(Color.primary)
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
            plozzChannelID: item.plozzChannelID, plozzChannelMood: item.plozzChannelMood,
            size: CGSize(width: artWidth, height: artHeight),
            cornerRadius: artCornerRadius
        )
    }
}
#endif
