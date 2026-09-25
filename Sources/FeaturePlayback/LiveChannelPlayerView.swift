#if canImport(SwiftUI) && canImport(AVFoundation) && canImport(UIKit)
import AVFoundation
import CoreModels
import CoreUI
import Observation
import SwiftUI
import UIKit

struct LiveChannelSessionReporting {
    let id: UUID
    let update: @MainActor (LiveTVPlaybackUpdate) -> Void
    let failed: @MainActor () -> Void
}

/// Playback host for live channels.
///
/// The host deliberately bypasses `PlayerViewModel`: live channels have no
/// VOD watch history, resume point, duration, or scrobbling lifecycle. The
/// caller owns any server-specific live session. Video still runs through Plozz's production
/// AetherEngine adapter and its existing video surface.
public struct LiveChannelPlayerView: View {
    private let channelID: String
    private let title: String // l10n:content — provider-supplied channel name
    private let input: LiveChannelInput
    private let logoURL: URL?
    private let makeEngine: @MainActor () throws -> any LiveChannelEngine
    private let onPreviousChannel: () -> Void
    private let onNextChannel: () -> Void
    private let isFavorite: Bool
    private let canToggleFavorite: Bool
    private let onToggleFavorite: () -> Void
    private let isExpanded: Bool
    private let usesNativeFullscreen: Bool
    private let isActive: Bool
    private let onReturnToGuide: (() -> Void)?
    private let playPauseRequest: Int
    private let onPlaybackStarted: () -> Void
    private let reportingID: UUID?
    private let onPlaybackUpdate: @MainActor (LiveTVPlaybackUpdate) -> Void
    private let onPlaybackFailed: @MainActor () -> Void
    private let onVideoAspectRatioChange: @MainActor (Double?) -> Void
    private let preparingChannelName: String?
    private let onMultiview: (() -> Void)?
    private let outputGroup: LiveChannelOutputGroup?
    private let outputID: UUID?
    private let isAudible: Bool
    private let countsAsWatching: Bool
    private let isMultiview: Bool
    private let trackPreferences: LiveChannelTrackPreferences?
    private let networkBlock: LiveTVNetworkBlock?
    private let presentationControls: (@MainActor (LiveChannelPresentationContext) -> AnyView)?
    private let onExternalContinuationChanged: @MainActor (Bool) -> Void
    private let onRestoreUI: @MainActor () async -> Bool
    private let isAuthorized: Bool
    private let onStopPlayback: @MainActor () -> Void
    private let onOpenLibraryItem: ((LibraryChannelItem) -> Void)?
    private let program: LiveChannelProgramInfo?
    private let loadOnNow: @MainActor () -> [LiveChannelOnNowItem]
    private let onTuneChannel: ((String) -> Void)?
    private let guideOverlay: ((LiveChannelGuideEmbedding) -> AnyView)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(GlassPerformanceModel.self) private var glassPerformance: GlassPerformanceModel?
    @State private var model: LiveChannelPlayerModel?
    @State private var sourceTask: Task<Void, Never>?
    @State private var fullscreenPresented = false
    @State private var fullscreenOwnsSurface = false
    @State private var returnsToGuideAfterFullscreen = false
    @State private var engineInitializationFailed = false
    @State private var controlsVisible = true
    @State private var tracksArePresented = false
    @State private var autoHideRevision = 0
    @State private var hudInactivity = PlaybackControlsInactivity()
    @State private var focusRevision = 0
    @State private var playbackStartPolicy = LiveChannelPlaybackStartPolicy<LiveChannelSource>()
    /// The Guide card is up, and its grid owns focus through its own state.
    @State private var guidePresented = false
    /// Set by the remote's Guide button for the transport to act on.
    @State private var pendingGuideOpen = false
    /// The VOD player's Playback Info diagnostics, toggled from the Info card.
    @State private var diagnosticsEnabled = false
    @State private var diagnosticsSampler = PlaybackDiagnosticsSampler()
    /// Whether this channel is holding the app's panels on their frosted, cheaper
    /// surface, as a demanding VOD title does (`PlayerView`).
    @State private var suspendedGlass = false
    @State private var suspendedGlassWasHDR = false
    @FocusState private var focusedControl: LiveChannelControl?

    private var plozzChannelID: String? {
        if case .libraryChannel = input { return channelID }
        return nil
    }

    private var allowsDisplayMatching: Bool {
        #if os(tvOS)
        isExpanded || isMultiview
        #else
        true
        #endif
    }

    public init(
        channelID: String,
        title: String, // l10n:content — provider-supplied channel name
        input: LiveChannelInput,
        logoURL: URL?,
        makeEngine: @escaping @MainActor () throws -> any LiveChannelEngine,
        onPreviousChannel: @escaping () -> Void,
        onNextChannel: @escaping () -> Void,
        isFavorite: Bool,
        canToggleFavorite: Bool,
        onToggleFavorite: @escaping () -> Void,
        isExpanded: Bool = true,
        usesNativeFullscreen: Bool = false,
        isActive: Bool = true,
        onReturnToGuide: (() -> Void)? = nil,
        playPauseRequest: Int = 0,
        onPlaybackStarted: @escaping () -> Void = {},
        reportingID: UUID? = nil,
        onPlaybackUpdate: @escaping @MainActor (LiveTVPlaybackUpdate) -> Void = { _ in },
        onPlaybackFailed: @escaping @MainActor () -> Void = {},
        onVideoAspectRatioChange: @escaping @MainActor (Double?) -> Void = { _ in },
        preparingChannelName: String? = nil,
        onMultiview: (() -> Void)? = nil,
        outputGroup: LiveChannelOutputGroup? = nil,
        outputID: UUID? = nil,
        isAudible: Bool = true,
        countsAsWatching: Bool = false,
        isMultiview: Bool = false,
        trackPreferences: LiveChannelTrackPreferences? = nil,
        networkBlock: LiveTVNetworkBlock? = nil,
        isAuthorized: Bool = true,
        presentationControls: (@MainActor (LiveChannelPresentationContext) -> AnyView)? = nil,
        onExternalContinuationChanged: @escaping @MainActor (Bool) -> Void = { _ in },
        onRestoreUI: @escaping @MainActor () async -> Bool = { false },
        onStopPlayback: @escaping @MainActor () -> Void = {},
        onOpenLibraryItem: ((LibraryChannelItem) -> Void)? = nil,
        program: LiveChannelProgramInfo? = nil,
        loadOnNow: @escaping @MainActor () -> [LiveChannelOnNowItem] = { [] },
        onTuneChannel: ((String) -> Void)? = nil,
        guideOverlay: ((LiveChannelGuideEmbedding) -> AnyView)? = nil
    ) {
        self.channelID = channelID
        self.title = title
        self.input = input
        self.logoURL = logoURL
        self.makeEngine = makeEngine
        self.onPreviousChannel = onPreviousChannel
        self.onNextChannel = onNextChannel
        self.isFavorite = isFavorite
        self.canToggleFavorite = canToggleFavorite
        self.onToggleFavorite = onToggleFavorite
        self.isExpanded = isExpanded
        self.usesNativeFullscreen = usesNativeFullscreen
        self.isActive = isActive
        self.onReturnToGuide = onReturnToGuide
        self.playPauseRequest = playPauseRequest
        self.onPlaybackStarted = onPlaybackStarted
        self.reportingID = reportingID
        self.onPlaybackUpdate = onPlaybackUpdate
        self.onPlaybackFailed = onPlaybackFailed
        self.onVideoAspectRatioChange = onVideoAspectRatioChange
        self.preparingChannelName = preparingChannelName
        self.onMultiview = onMultiview
        self.outputGroup = outputGroup
        self.outputID = outputID
        self.isAudible = isAudible
        self.countsAsWatching = countsAsWatching
        self.isMultiview = isMultiview
        self.trackPreferences = trackPreferences
        self.networkBlock = networkBlock
        self.isAuthorized = isAuthorized
        self.presentationControls = presentationControls
        self.onExternalContinuationChanged = onExternalContinuationChanged
        self.onRestoreUI = onRestoreUI
        self.onStopPlayback = onStopPlayback
        self.onOpenLibraryItem = onOpenLibraryItem
        self.program = program
        self.loadOnNow = loadOnNow
        self.onTuneChannel = onTuneChannel
        self.guideOverlay = guideOverlay
    }

    public init(
        channelID: String,
        title: String, // l10n:content — provider-supplied channel name
        streamURL: URL,
        logoURL: URL?,
        httpHeaders: [String: String] = [:],
        makeEngine: @escaping @MainActor () throws -> any LiveChannelEngine,
        onPreviousChannel: @escaping () -> Void,
        onNextChannel: @escaping () -> Void,
        isFavorite: Bool,
        canToggleFavorite: Bool,
        onToggleFavorite: @escaping () -> Void,
        isExpanded: Bool = true,
        usesNativeFullscreen: Bool = false,
        isActive: Bool = true,
        onReturnToGuide: (() -> Void)? = nil,
        playPauseRequest: Int = 0,
        onPlaybackStarted: @escaping () -> Void = {},
        reportingID: UUID? = nil,
        onPlaybackUpdate: @escaping @MainActor (LiveTVPlaybackUpdate) -> Void = { _ in },
        onPlaybackFailed: @escaping @MainActor () -> Void = {},
        onVideoAspectRatioChange: @escaping @MainActor (Double?) -> Void = { _ in },
        preparingChannelName: String? = nil,
        onMultiview: (() -> Void)? = nil,
        outputGroup: LiveChannelOutputGroup? = nil,
        outputID: UUID? = nil,
        isAudible: Bool = true,
        countsAsWatching: Bool = false,
        isMultiview: Bool = false,
        trackPreferences: LiveChannelTrackPreferences? = nil,
        networkBlock: LiveTVNetworkBlock? = nil,
        isAuthorized: Bool = true,
        presentationControls: (@MainActor (LiveChannelPresentationContext) -> AnyView)? = nil,
        onExternalContinuationChanged: @escaping @MainActor (Bool) -> Void = { _ in },
        onRestoreUI: @escaping @MainActor () async -> Bool = { false },
        onStopPlayback: @escaping @MainActor () -> Void = {},
        onOpenLibraryItem: ((LibraryChannelItem) -> Void)? = nil,
        program: LiveChannelProgramInfo? = nil,
        loadOnNow: @escaping @MainActor () -> [LiveChannelOnNowItem] = { [] },
        onTuneChannel: ((String) -> Void)? = nil,
        guideOverlay: ((LiveChannelGuideEmbedding) -> AnyView)? = nil
    ) {
        self.init(
            channelID: channelID, title: title,
            input: .stream(url: streamURL, httpHeaders: httpHeaders), logoURL: logoURL,
            makeEngine: makeEngine, onPreviousChannel: onPreviousChannel, onNextChannel: onNextChannel,
            isFavorite: isFavorite, canToggleFavorite: canToggleFavorite, onToggleFavorite: onToggleFavorite,
            isExpanded: isExpanded, usesNativeFullscreen: usesNativeFullscreen, isActive: isActive,
            onReturnToGuide: onReturnToGuide, playPauseRequest: playPauseRequest,
            onPlaybackStarted: onPlaybackStarted, reportingID: reportingID,
            onPlaybackUpdate: onPlaybackUpdate, onPlaybackFailed: onPlaybackFailed,
            onVideoAspectRatioChange: onVideoAspectRatioChange,
            preparingChannelName: preparingChannelName, onMultiview: onMultiview,
            outputGroup: outputGroup, outputID: outputID, isAudible: isAudible,
            countsAsWatching: countsAsWatching, isMultiview: isMultiview, trackPreferences: trackPreferences,
            networkBlock: networkBlock, isAuthorized: isAuthorized, presentationControls: presentationControls,
            onExternalContinuationChanged: onExternalContinuationChanged,
            onRestoreUI: onRestoreUI, onStopPlayback: onStopPlayback,
            onOpenLibraryItem: onOpenLibraryItem, program: program, loadOnNow: loadOnNow,
            onTuneChannel: onTuneChannel, guideOverlay: guideOverlay
        )
    }

    private var playerSurface: some View {
        ZStack {
            Color.black
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

            if let model {
                let sourceMatches = model.matchesSource(
                    channelID: channelID,
                    input: input
                )
                VideoSurfaceContainer(engine: model.engine)
                    .ignoresSafeArea()

                if sourceMatches, model.networkBlock == nil, !model.continuesExternally {
                    LiveChannelSubtitleSurface(model: model)
                        .allowsHitTesting(false)
                }

                #if os(tvOS)
                if isExpanded, diagnosticsEnabled, sourceMatches, model.hasPresentedFrame {
                    PlaybackDiagnosticsOverlay(diagnostics: diagnosticsSampler.latest)
                        .allowsHitTesting(false)
                        .ignoresSafeArea()
                        .transition(.opacity)
                }
                #endif

                if !sourceMatches || !model.hasPresentedFrame || (!isExpanded && model.interruption != nil) {
                    Rectangle()
                        .fill(.black)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                if let networkBlock = model.networkBlock {
                    LiveChannelNetworkStatus(block: networkBlock)
                } else if isExpanded {
                    if !controlsVisible {
                        LiveChannelRevealSurface(
                            focus: $focusedControl,
                            onReveal: revealControls
                        )
                        .transition(.identity)
                    }

                    if controlsVisible,
                       !sourceMatches || model.interruption == nil {
                        LiveChannelOverlay(
                            title: title,
                            logoURL: logoURL,
                            plozzChannelID: plozzChannelID,
                            channelID: channelID,
                            input: input,
                            program: program,
                            libraryItem: sourceMatches ? model.engine.currentLibraryItem : nil,
                            openLibraryItem: onOpenLibraryItem,
                            phase: sourceMatches ? model.phase : .loading,
                            isAtLiveEdge: sourceMatches ? model.isAtLiveEdge : true,
                            behindLiveSeconds: sourceMatches ? model.behindLiveSeconds : 0,
                            canPause: sourceMatches && model.canPause,
                            canGoLive: sourceMatches && model.canGoLive,
                            focus: $focusedControl,
                            onClose: dismissPlayer,
                            onPrevious: channelPrevious,
                            onPlayPause: togglePlayPause,
                            onGoLive: goLive,
                            onNext: channelNext,
                            onMultiview: model.engine.supportsConcurrentPlayback ? onMultiview : nil,
                            guideContent: guideOverlay,
                            pendingGuideOpen: pendingGuideOpen,
                            consumeGuideOpen: { pendingGuideOpen = false },
                            onGuideCardChange: { guidePresented = $0 },
                            loadOnNow: loadOnNow,
                            onTuneChannel: onTuneChannel.map { tune in { (id: String) in noteInteraction(); tune(id) } },
                            tracks: model,
                            diagnosticsEnabled: diagnosticsEnabled,
                            toggleDiagnostics: { diagnosticsEnabled.toggle() },
                            onTracksPresentationChange: { tracksArePresented = $0 },
                            onControlActivity: noteControlNavigation,
                            onDismissControls: dismissControls
                        )
                        .onAppear(perform: focusPlaybackControlIfNeeded)
                        .transition(.opacity)
                    }

                    if sourceMatches, let interruption = model.interruption {
                        LiveChannelInterruptionView(
                            interruption: interruption,
                            canRetry: model.canRetry,
                            focus: $focusedControl,
                            onRetry: retry,
                            onClose: dismissPlayer
                        )
                    } else if !sourceMatches || model.showsActivityIndicator, !overlayShowsActivity {
                        LiveChannelActivityView(
                            phase: sourceMatches ? model.phase : .loading
                        )
                            .allowsHitTesting(false)
                    }
                } else if sourceMatches, let interruption = model.interruption {
                    LiveChannelCompactStatusView(
                        icon: interruption.icon,
                        title: interruption.title
                    )
                } else if !model.hasPresentedFrame, model.phase == .paused {
                    LiveChannelCompactStatusView(icon: "pause.fill", title: "Paused")
                } else if !sourceMatches || model.showsActivityIndicator {
                    LiveChannelCompactStatusView(
                        icon: nil,
                        title: sourceMatches
                            ? model.phase.activityLabel
                            : LiveChannelPlaybackPhase.loading.activityLabel,
                        showsProgress: true
                    )
                }
                if let presentationControls {
                    presentationControls(.init(
                        engine: model.engine,
                        sessionID: reportingID,
                        permitsExternalPresentation: permitsExternalPresentation
                            && networkBlock == nil && (isExpanded || model.continuesExternally),
                        isVisible: isActive && scenePhase == .active,
                        showsControls: controlsVisible && isExpanded,
                        intendsPlayback: model.intendsPlayback,
                        hasSelectedSubtitle: model.selectedSubtitleID != nil,
                        continuationChanged: { [weak model] in model?.setExternalContinuation($0) },
                        restoreUI: onRestoreUI,
                        registerInvalidation: { [weak model] in model?.onPresentationInvalidated = $0 },
                        stopPlayback: {
                            stopPlayback()
                            onStopPlayback()
                        }
                    ))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    #if os(iOS)
                    // Beside the overlay's close button, as VOD's top bar.
                    .padding(.top, LiveChannelOverlay.touchTopBarInset)
                    .padding(.leading, LiveChannelOverlay.touchPresentationLeadingInset)
                    .modifier(WindowSafeAreaPadding(isEnabled: isExpanded))
                    #else
                    .padding(.top, 112)
                    .padding(.horizontal, 16)
                    #endif
                }
            } else if engineInitializationFailed {
                if isExpanded {
                    LiveChannelInterruptionView(
                        interruption: .failure(
                            .engine(.unknown("engine initialization")),
                            retryLimitReached: false
                        ),
                        canRetry: false,
                        focus: $focusedControl,
                        onRetry: {},
                        onClose: dismissPlayer
                    )
                } else {
                    LiveChannelCompactStatusView(
                        icon: "exclamationmark.triangle.fill",
                        title: "Preview unavailable"
                    )
                }
            } else {
                if isExpanded {
                    LiveChannelStartupView(
                        focus: $focusedControl,
                        onClose: dismissPlayer
                    )
                    .onAppear { focusAfterPresentation(.close) }
                } else {
                    LiveChannelCompactStatusView(
                        icon: nil,
                        title: "Connecting",
                        showsProgress: true
                    )
                }
            }
            if let preparingChannelName {
                LiveChannelCompactStatusView(
                    icon: nil, title: "Opening \(preparingChannelName)", showsProgress: true
                )
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: controlsVisible)
        #if os(tvOS)
        .onReceive(NotificationCenter.default.publisher(for: LiveTVGuideButton.pressed)) { _ in
            guard isExpanded, isActive, guideOverlay != nil else { return }
            openGuide()
        }
        .background(LiveChannelRemotePresses(
            isEnabled: isExpanded && isActive,
            channelUp: channelNext,
            channelDown: channelPrevious
        ))
        .onExitCommand {
            guard isExpanded else { return }
            dismissPlayer()
        }
        .onPlayPauseCommand {
            guard isExpanded else { return }
            togglePlayPause()
        }
        #endif
        .task(id: autoHideRevision) {
            let startedAt = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                guard isExpanded, controlsVisible, !tracksArePresented, !guidePresented,
                      model?.phase == .playing else { return }
                let remaining = hudInactivity.remainingDelay(
                    startedAt: startedAt,
                    now: ProcessInfo.processInfo.systemUptime
                )
                if remaining == 0 {
                    hideControls()
                    return
                }
                do {
                    try await Task.sleep(for: .seconds(remaining))
                } catch {
                    return
                }
            }
        }
    }

    public var body: some View {
        ZStack {
            Color.black
            if !fullscreenOwnsSurface {
                playerSurface
            }
        }
        .fullScreenCover(isPresented: $fullscreenPresented, onDismiss: fullscreenDidDismiss) {
            playerSurface
                .ignoresSafeArea()
        }
        .onChange(of: wantsNativeFullscreen, initial: true) { _, presented in
            returnsToGuideAfterFullscreen = presented
            updateFullscreenPresentation(presented)
        }
        .modifier(LiveChannelActivityObserver(
            isActive: isActive,
            isAuthorized: isAuthorized,
            scenePhase: scenePhase,
            networkBlock: networkBlock,
            currentModel: { model },
            fullscreenOwnsSurface: { fullscreenOwnsSurface },
            updateSource: updateSource,
            stopPlayback: stopPlayback
        ))
        .onChange(of: focusedControl) { _, newValue in
            guard let newValue, newValue != .surface else { return }
            noteInteraction()
        }
        .onChange(of: playbackFocusAvailability) { _, _ in
            focusPlaybackControlIfNeeded()
        }
        .onChange(of: playbackStartedSource) { _, _ in
            reportPlaybackStartedIfNeeded()
        }
        .onChange(of: model?.phase) { _, phase in
            playbackPhaseChanged(phase)
        }
        .onChange(of: model?.engine.videoAspectRatio, initial: true) { _, ratio in
            onVideoAspectRatioChange(ratio)
        }
        .onChange(of: tracksArePresented) { _, _ in autoHideRevision &+= 1 }
        .onChange(of: diagnosticsEnabled) { _, enabled in updateDiagnosticsSampling(enabled) }
        .onChange(of: GlassDemandKey(
            expanded: isExpanded, presentedFrame: model?.hasPresentedFrame ?? false, reportingID: reportingID
        )) { _, _ in updateGlassSuspension() }
        .onDisappear(perform: releaseGlassSuspension)
        .onChange(of: reportingID) { _, _ in updateDiagnosticsSampling(diagnosticsEnabled) }
        #if os(iOS)
        .sheet(isPresented: $diagnosticsEnabled) {
            NavigationStack {
                PlaybackDiagnosticsOverlay(diagnostics: diagnosticsSampler.latest, presentation: .mobile)
                    .navigationTitle("Playback Diagnostics")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { diagnosticsEnabled = false }
                        }
                    }
            }
        }
        #endif
        .onChange(of: isExpanded) { _, expanded in
            expansionChanged(expanded)
        }
        .onChange(of: playPauseRequest) { _, _ in
            guard !isExpanded else { return }
            model?.togglePlayPause()
        }
        .onChange(of: source, initial: true) { _, _ in updateSource() }
        .onChange(of: reportingID) { _, _ in
            updateSource()
            onVideoAspectRatioChange(model?.engine.videoAspectRatio)
        }
        .onChange(of: isAudible) { _, audible in model?.setAudible(audible) }
        .onChange(of: allowsDisplayMatching) { _, allowed in model?.setDisplayMatchingAllowed(allowed) }
        .onChange(of: countsAsWatching) { _, watching in
            model?.setWatching(watching)
            reportPlaybackStartedIfNeeded()
        }
        .onChange(of: permitsExternalPresentation) { _, allowed in
            model?.setPermitsExternalPresentation(allowed)
        }
    }

    private func playbackPhaseChanged(_ phase: LiveChannelPlaybackPhase?) {
        autoHideRevision &+= 1
        guard let phase else { return }
        if phase != .playing { controlsVisible = true }
        if isExpanded, phase.isInterrupted { focusInterruptionAction() }
    }

    private func expansionChanged(_ expanded: Bool) {
        autoHideRevision &+= 1
        focusRevision &+= 1
        if expanded {
            controlsVisible = true
            reportPlaybackStartedIfNeeded()
            if model == nil {
                focusAfterPresentation(.close)
            } else if sourceMatchesCurrentModel, model?.phase.isInterrupted == true {
                focusInterruptionAction()
            } else {
                focusPlaybackControlIfNeeded()
            }
        } else {
            playbackStartPolicy.resetViewing()
            guidePresented = false
            pendingGuideOpen = false
            focusedControl = nil
        }
    }

    private struct LiveChannelActivityObserver: ViewModifier {
        let isActive: Bool
        let isAuthorized: Bool
        let scenePhase: ScenePhase
        let networkBlock: LiveTVNetworkBlock?
        let currentModel: () -> LiveChannelPlayerModel?
        let fullscreenOwnsSurface: () -> Bool
        let updateSource: () -> Void
        let stopPlayback: () -> Void

        func body(content: Content) -> some View {
            content
                .onChange(of: isActive) { _, active in
                    if active {
                        updateSource()
                        currentModel()?.setVisible(true)
                    } else {
                        currentModel()?.setVisible(false)
                        if currentModel()?.continuesExternally != true { stopPlayback() }
                    }
                }
                .onChange(of: scenePhase) { _, phase in currentModel()?.handleScenePhase(phase) }
                .onChange(of: networkBlock) { _, block in currentModel()?.setNetworkBlock(block) }
                .onChange(of: isAuthorized) { _, authorized in
                    if !authorized { stopPlayback() }
                }
                .onDisappear {
                    // Fullscreen obscures its inline owner without retiring it.
                    guard !isActive || !fullscreenOwnsSurface() else { return }
                    currentModel()?.setVisible(false)
                    if currentModel()?.continuesExternally != true { stopPlayback() }
                }
        }
    }

    private var wantsNativeFullscreen: Bool {
        #if os(tvOS)
        usesNativeFullscreen && isExpanded && isActive
        #else
        false
        #endif
    }

    private func updateFullscreenPresentation(_ presented: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if presented { fullscreenOwnsSurface = true }
            fullscreenPresented = presented
        }
    }

    private func fullscreenDidDismiss() {
        fullscreenOwnsSurface = false
        // SwiftUI may retain the dismissal closure from presentation time.
        // Read current state rather than its captured isActive/isExpanded inputs.
        if returnsToGuideAfterFullscreen {
            returnsToGuideAfterFullscreen = false
            returnFromPlayer()
        }
    }

    private func updateSource() {
        guard isActive, isAuthorized else { return }
        model?.onExternalContinuationChanged = onExternalContinuationChanged
        model?.setPermitsExternalPresentation(permitsExternalPresentation)
        if sourceMatchesCurrentModel, model?.sessionReportingID == reportingID {
            model?.setSessionReporting(sessionReporting)
            return
        }
        playbackStartPolicy.resetViewing()
        sourceTask?.cancel()
        if let model {
            sourceTask = Task {
                guard !Task.isCancelled else { return }
                await model.changeSource(
                    channelID: channelID, input: input,
                    reporting: sessionReporting
                )
            }
            return
        }

        engineInitializationFailed = false
        let engine: any LiveChannelEngine
        do {
            engine = try makeEngine()
        } catch {
            LiveChannelDiagnostics().event(.initializationFailure, attempt: 0)
            engineInitializationFailed = true
            focusAfterPresentation(.close)
            if reportingID != nil { onPlaybackFailed() }
            return
        }
        let playerModel = LiveChannelPlayerModel(
            engine: engine, channelID: channelID, input: input,
            outputGroup: outputGroup, outputID: outputID ?? UUID(), isAudible: isAudible,
            allowsDisplayMatching: allowsDisplayMatching,
            trackPreferences: trackPreferences
        )
        model = playerModel
        playerModel.onExternalContinuationChanged = onExternalContinuationChanged
        playerModel.setPermitsExternalPresentation(permitsExternalPresentation)
        playerModel.setNetworkBlock(networkBlock)
        playerModel.setWatching(countsAsWatching)
        playerModel.setSessionReporting(sessionReporting)
        playerModel.handleScenePhase(scenePhase)
        sourceTask = Task {
            guard !Task.isCancelled else { return }
            await playerModel.start()
        }
    }

    private func stopPlayback() {
        sourceTask?.cancel()
        sourceTask = nil
        diagnosticsEnabled = false
        diagnosticsSampler.stop()
        releaseGlassSuspension()
        model?.stop()
        model = nil
    }

    private var source: LiveChannelSource {
        LiveChannelSource(
            channelID: channelID,
            input: input
        )
    }

    private var permitsExternalPresentation: Bool { !isMultiview && isAuthorized }

    private var sessionReporting: LiveChannelSessionReporting? {
        reportingID.map {
            LiveChannelSessionReporting(id: $0, update: onPlaybackUpdate, failed: onPlaybackFailed)
        }
    }

    private var sourceMatchesCurrentModel: Bool {
        model?.matchesSource(
            channelID: channelID,
            input: input
        ) == true
    }

    private var playbackFocusAvailability: LiveChannelPlaybackFocusPolicy.Availability {
        // The guide owns focus while it is up.
        guard isExpanded, controlsVisible, !guidePresented, let model else {
            return .hidden
        }
        let sourceMatches = sourceMatchesCurrentModel
        guard !sourceMatches || model.interruption == nil else {
            return .hidden
        }
        return .init(
            isPresented: true,
            canPlayPause: sourceMatches && model.canPause,
            canGoLive: sourceMatches && model.canGoLive,
            canToggleFavorite: canToggleFavorite,
            canMultiview: onMultiview != nil && model.engine.supportsConcurrentPlayback,
            canOpenLibraryTitle: sourceMatches && onOpenLibraryItem != nil && model.engine.currentLibraryItem != nil
        )
    }

    private var playbackStartedSource: LiveChannelSource? {
        guard let model else { return nil }
        return LiveChannelPlaybackStartPolicy<LiveChannelSource>.eligibleSource(
            source,
            sourceMatches: sourceMatchesCurrentModel,
            isExpanded: countsAsWatching,
            phase: model.phase,
            hasPresentedFrame: model.hasPresentedFrame
        )
    }

    private func noteInteraction() {
        guard isExpanded else { return }
        hudInactivity.recordInteraction(at: ProcessInfo.processInfo.systemUptime)
        controlsVisible = true
        autoHideRevision &+= 1
    }

    private func noteControlNavigation() {
        guard controlsVisible else { return }
        noteInteraction()
    }

    private func revealControls() {
        noteInteraction()
        focusPlaybackControlIfNeeded()
    }

    /// On touch the play / pause button turns into the spinner while the
    /// transport is up and no card or menu covers it; the centred panel would
    /// sit on top of it.
    private var overlayShowsActivity: Bool {
        #if os(iOS)
        controlsVisible && !tracksArePresented
        #else
        false
        #endif
    }

    /// A tap on the bare video, as VOD's touch player: whatever the phase.
    private func dismissControls() {
        guard isExpanded else { return }
        focusedControl = nil
        controlsVisible = false
    }

    private func hideControls() {
        guard isExpanded, model?.phase == .playing else { return }
        focusedControl = nil
        controlsVisible = false
        focusAfterPresentation(.surface)
    }

    private func focusAfterPresentation(_ control: LiveChannelControl) {
        #if os(tvOS)
        guard isExpanded else { return }
        focusRevision &+= 1
        let revision = focusRevision
        Task { @MainActor in
            await Task.yield()
            guard isExpanded, revision == focusRevision else { return }
            focusedControl = control
        }
        #endif
    }

    private func focusPlaybackControlIfNeeded() {
        #if os(tvOS)
        let availability = playbackFocusAvailability
        guard availability.isPresented,
              !availability.contains(focusedControl) else {
            return
        }
        focusRevision &+= 1
        let revision = focusRevision
        Task { @MainActor in
            await Task.yield()
            let latestAvailability = playbackFocusAvailability
            guard isExpanded,
                  revision == focusRevision,
                  latestAvailability.isPresented,
                  !latestAvailability.contains(focusedControl) else {
                return
            }
            focusedControl = latestAvailability.preferredControl
        }
        #endif
    }

    private func focusInterruptionAction() {
        focusAfterPresentation(
            LiveChannelPlaybackFocusPolicy.interruptionControl(
                canRetry: model?.canRetry == true
            )
        )
    }

    private func reportPlaybackStartedIfNeeded() {
        guard playbackStartPolicy.consume(playbackStartedSource) else { return }
        onPlaybackStarted()
    }

    /// Suspends glass while a demanding channel plays full screen, as the VOD
    /// player does for a demanding title (`PlayerView.updateGlassSuspension`):
    /// the controls, cards and panels drawn over it then take the frosted
    /// surface. Judged from what the engine probed, since a live stream has no
    /// provider metadata. A preview or Multiview tile draws no panels over it.
    private func updateGlassSuspension() {
        guard isExpanded, let model, model.hasPresentedFrame else {
            releaseGlassSuspension()
            return
        }
        let facts = model.engine.probedSourceFacts
        let demand = GlassPerformanceBudget.demand(
            for: nil, resolvedRange: facts?.range, probedWidth: facts?.videoWidth
        )
        guard demand.isDemanding != suspendedGlass else { return }
        if demand.isDemanding {
            glassPerformance?.beginDemandingPlayback(isHDR: demand.isHDR)
            suspendedGlassWasHDR = demand.isHDR
        } else {
            glassPerformance?.endDemandingPlayback(isHDR: suspendedGlassWasHDR)
            suspendedGlassWasHDR = false
        }
        suspendedGlass = demand.isDemanding
    }

    private func releaseGlassSuspension() {
        guard suspendedGlass else { return }
        suspendedGlass = false
        glassPerformance?.endDemandingPlayback(isHDR: suspendedGlassWasHDR)
        suspendedGlassWasHDR = false
    }

    /// Samples the playing channel for Playback Info, as the VOD player does,
    /// only while it's showing: the sampler polls every second.
    private func updateDiagnosticsSampling(_ enabled: Bool) {
        guard enabled, let model else {
            diagnosticsSampler.stop()
            return
        }
        let engine = model.engine
        let mode: PlaybackDiagnostics.PlaybackMode = switch engine.liveSnapshot.route {
        case .nativeHLS: .directPlay
        case .localHLS, .software: .plozzigen
        case .none, .audio: .unknown
        }
        let streamURL: URL? = if case .stream(let url, _) = input { url } else { nil }
        diagnosticsSampler.start(
            player: engine.nowPlayingPlayer,
            mode: mode,
            engineName: engine.displayName,
            streamURL: streamURL,
            engineTelemetry: { engine.liveTelemetry },
            probedFacts: { engine.probedSourceFacts }
        )
    }

    private func togglePlayPause() {
        guard let model else { return }
        noteInteraction()
        model.togglePlayPause()
    }

    private func goLive() {
        guard let model else { return }
        noteInteraction()
        Task { await model.goLive() }
    }

    private func retry() {
        guard let model, model.canRetry else { return }
        noteInteraction()
        Task { await model.retry() }
    }

    private func channelPrevious() {
        noteInteraction()
        onPreviousChannel()
    }

    private func channelNext() {
        noteInteraction()
        onNextChannel()
    }

    /// The remote's Guide button: bring the controls up on the Guide card.
    private func openGuide() {
        noteInteraction()
        pendingGuideOpen = true
    }

    private func dismissPlayer() {
        if fullscreenOwnsSurface {
            updateFullscreenPresentation(false)
        } else {
            returnFromPlayer()
        }
    }

    private func returnFromPlayer() {
        if let onReturnToGuide {
            playbackStartPolicy.resetViewing()
            onReturnToGuide()
            return
        }
        stopPlayback()
        dismiss()
    }
}

private struct LiveChannelSource: Equatable {
    let channelID: String
    let input: LiveChannelInput
}

struct LiveChannelPlaybackStartPolicy<Source: Equatable> {
    private var reportedSource: Source?

    static func eligibleSource(
        _ source: Source,
        sourceMatches: Bool,
        isExpanded: Bool,
        phase: LiveChannelPlaybackPhase,
        hasPresentedFrame: Bool
    ) -> Source? {
        guard sourceMatches,
              isExpanded,
              phase == .playing,
              hasPresentedFrame else {
            return nil
        }
        return source
    }

    mutating func consume(_ eligibleSource: Source?) -> Bool {
        guard let eligibleSource, eligibleSource != reportedSource else {
            return false
        }
        reportedSource = eligibleSource
        return true
    }

    mutating func resetViewing() {
        reportedSource = nil
    }
}

/// What the glass-suspension decision depends on, as one value to observe.
private struct GlassDemandKey: Equatable {
    let expanded: Bool
    let presentedFrame: Bool
    let reportingID: UUID?
}

enum LiveChannelControl: Hashable {
    case surface
    case close
    case previous
    case playPause
    case goLive
    case next
    case favorite
    case retry
    case multiview
    case openLibraryTitle
    /// The transport's hub, as the scrub bar is for VOD.
    case timeline
    case audio
    case subtitles
    case cardTab(LiveChannelCardTab)
    /// Invisible strip above the open card's tab row. Focusing it IS the
    /// "leave the card" gesture, as VOD's `infoExit`.
    case cardExit
    case onNowItem(String)
    case trackRow(Int)
    /// The Info card's Playback Info toggle.
    case playbackInfo
}

struct LiveChannelFavoriteControlState: Equatable {
    let isFavorite: Bool
    let canToggle: Bool

    var title: LocalizedStringResource {
        isFavorite ? "Remove from Favorites" : "Add to Favorites"
    }

    var systemImage: String {
        isFavorite ? "star.fill" : "star"
    }
}

enum LiveChannelPlaybackFocusPolicy {
    struct Availability: Equatable {
        let isPresented: Bool
        let canPlayPause: Bool
        let canGoLive: Bool
        let canToggleFavorite: Bool
        var canMultiview = false
        var canOpenLibraryTitle = false

        static let hidden = Availability(
            isPresented: false,
            canPlayPause: false,
            canGoLive: false,
            canToggleFavorite: false
        )

        /// The timeline, whatever else is available: like VOD's scrub bar it is
        /// always present, and every other control is one press from it.
        var preferredControl: LiveChannelControl { .timeline }

        func contains(_ control: LiveChannelControl?) -> Bool {
            guard isPresented, let control else { return false }
            switch control {
            case .previous, .next, .timeline, .audio, .subtitles, .cardTab, .cardExit,
                 .onNowItem, .trackRow, .playbackInfo:
                return true
            case .playPause:
                return canPlayPause
            case .goLive:
                return canGoLive
            case .favorite:
                return canToggleFavorite
            case .multiview:
                return canMultiview
            case .openLibraryTitle:
                return canOpenLibraryTitle
            case .surface, .close, .retry:
                return false
            }
        }
    }

    static func interruptionControl(canRetry: Bool) -> LiveChannelControl {
        canRetry ? .retry : .close
    }
}

private struct LiveChannelRevealSurface: View {
    @FocusState.Binding var focus: LiveChannelControl?
    let onReveal: () -> Void

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(perform: onReveal)
            #if os(tvOS)
            .focusable(true)
            .focused($focus, equals: .surface)
            .focusEffectDisabled()
            .onMoveCommand { _ in onReveal() }
            #endif
            .accessibilityIdentifier("live-channel-reveal-surface")
    }
}

private struct LiveChannelActivityView: View {
    let phase: LiveChannelPlaybackPhase

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text(phase.activityLabel)
                .font(.headline)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .modifier(PanelGlassBackground(cornerRadius: PlozzTheme.Metrics.playerPanelCornerRadius))
        .accessibilityElement(children: .combine)
    }
}

private struct LiveChannelCompactStatusView: View {
    let icon: String?
    let title: LocalizedStringResource
    var showsProgress = false

    var body: some View {
        HStack(spacing: 10) {
            if showsProgress {
                ProgressView()
                    .tint(.white)
            } else if let icon {
                Image(systemName: icon)
            }
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // A capsule: the corner radius clamps to half the height.
        .modifier(PanelGlassBackground(cornerRadius: 999))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

private struct LiveChannelStartupView: View {
    @FocusState.Binding var focus: LiveChannelControl?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text(LiveChannelPlaybackPhase.loading.activityLabel)
                .font(.headline)
                .foregroundStyle(.white)
            Button("Close", action: onClose)
                .focused($focus, equals: .close)
                .buttonStyle(InfoActionButtonStyle(prominent: false))
        }
        .padding(36)
        .modifier(PanelGlassBackground(cornerRadius: PlozzTheme.Metrics.playerPanelCornerRadius))
    }
}

private struct LiveChannelInterruptionView: View {
    let interruption: LiveChannelInterruption
    let canRetry: Bool
    @FocusState.Binding var focus: LiveChannelControl?
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: interruption.icon)
                .font(.largeTitle)
                .foregroundStyle(.white.opacity(0.9))
            Text(interruption.title)
                .font(.title2.bold())
            Text(interruption.message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            HStack(spacing: 16) {
                if canRetry {
                    Button("Try Again", action: onRetry)
                        .focused($focus, equals: .retry)
                        .buttonStyle(InfoActionButtonStyle(prominent: true))
                }
                Button("Close", action: onClose)
                    .focused($focus, equals: .close)
                    .buttonStyle(InfoActionButtonStyle(prominent: false))
            }
        }
        .foregroundStyle(.white)
        .padding(36)
        .modifier(PanelGlassBackground(cornerRadius: PlozzTheme.Metrics.playerPanelCornerRadius))
        .padding(40)
    }
}

@MainActor
@Observable
private final class LiveChannelPlayerPlaybackState {
    var phase: LiveChannelPlaybackPhase = .loading
    var hasPresentedFrame = false
    var seekableWindow: LiveSeekableWindow?
    var isAtLiveEdge = true
    var behindLiveSeconds: TimeInterval = 0
    var manualRetryCount = 0
    var isLoading = false
    var userPaused = false
    var isRecoveringProgramme = false
}

@MainActor
@Observable
private final class LiveChannelPlayerTrackState {
    private(set) var audioTracks: [MediaTrack] = []
    private(set) var subtitleTracks: [MediaTrack] = []
    private(set) var selectedAudioID: Int?
    private(set) var selectedSubtitleID: Int?
    let subtitles = LiveSubtitleModel()
    private let preferences: LiveChannelTrackPreferences
    private var selectedAudioForSource: Int?
    private var selectedSubtitleForSource: Int?
    private var didApplySubtitlePreference = false
    /// Whether the engine has actually been told the preferred subtitle. Kept
    /// apart from `didApplySubtitlePreference` (the choice is made) because a
    /// selection sent while the channel is still loading can be dropped by the
    /// engine — the menu then showed subtitles on with nothing drawn until the
    /// viewer selected them again.
    private var hasSentSubtitlePreference = false

    init(preferences: LiveChannelTrackPreferences) {
        self.preferences = preferences
        subtitles.style = preferences.subtitleStyle
    }

    var engineSubtitleStyle: SubtitleStyle { preferences.engineSubtitleStyle }

    func selectAudio(_ track: MediaTrack, engine: any LiveChannelEngine) {
        guard audioTracks.contains(track) else { return }
        selectedAudioForSource = track.id
        selectedAudioID = track.id
        if let language = track.language { preferences.audioLanguage = language }
        engine.selectAudioTrack(track)
    }

    func selectSubtitle(_ track: MediaTrack?, engine: any LiveChannelEngine) {
        if let track, !subtitleTracks.contains(track) { return }
        selectedSubtitleForSource = track?.id
        selectedSubtitleID = track?.id
        didApplySubtitlePreference = true
        hasSentSubtitlePreference = true
        if let track {
            preferences.subtitleMode = .all
            if let language = track.language { preferences.subtitleLanguage = language }
            subtitles.beginLiveFeed()
        } else {
            preferences.subtitleMode = .off
            subtitles.clear()
        }
        engine.selectSubtitleTrack(track)
    }

    /// - Parameter isReady: the channel has loaded and presented a frame, so a
    ///   subtitle selection sent now will be honoured.
    func refresh(engine: any LiveChannelEngine, isReady: Bool = true) {
        let audio = engine.audioTracks
        let captions = engine.subtitleTracks
        if audio != audioTracks { audioTracks = audio }
        if captions != subtitleTracks { subtitleTracks = captions }
        let wanted = selectedAudioForSource.flatMap { id in audio.first { $0.id == id } }
            ?? audio.first { LanguageMatch.matches($0.language, preferences.audioLanguage) }
        if let wanted, selectedAudioForSource != wanted.id {
            selectedAudioForSource = wanted.id
            if engine.currentAudioTrackID != wanted.id { engine.selectAudioTrack(wanted) }
        }
        selectedAudioID = engine.currentAudioTrackID ?? selectedAudioForSource
            ?? audio.first(where: \.isDefault)?.id
        guard !captions.isEmpty else { return }
        if !didApplySubtitlePreference {
            let chosen = captions.defaultSubtitleSelection(
                mode: preferences.subtitleMode,
                preferredLanguage: preferences.subtitleLanguage
            )
            didApplySubtitlePreference = true
            selectedSubtitleForSource = chosen?.id
            selectedSubtitleID = chosen?.id
        }
        // Sent once the channel can act on it — on or off, so an engine that
        // auto-selected a default rendition is also told when the viewer
        // wants subtitles off.
        guard isReady, !hasSentSubtitlePreference else { return }
        hasSentSubtitlePreference = true
        let chosen = selectedSubtitleForSource.flatMap { id in captions.first { $0.id == id } }
        if chosen != nil { subtitles.beginLiveFeed() } else { subtitles.clear() }
        engine.selectSubtitleTrack(chosen)
    }

    func resetProgramme() {
        audioTracks = []
        subtitleTracks = []
        selectedAudioForSource = nil
        selectedAudioID = nil
        selectedSubtitleForSource = nil
        selectedSubtitleID = nil
        didApplySubtitlePreference = false
        hasSentSubtitlePreference = false
        subtitles.clear()
    }
}

@MainActor
@Observable
final class LiveChannelPlayerModel {
    let engine: any LiveChannelEngine
    private let outputGroup: LiveChannelOutputGroup?
    private var outputPolicy: LiveChannelOutputPolicy
    private let outputID: UUID
    private let playbackState = LiveChannelPlayerPlaybackState()
    private let trackState: LiveChannelPlayerTrackState

    private(set) var phase: LiveChannelPlaybackPhase {
        get { playbackState.phase }
        set { playbackState.phase = newValue }
    }
    private(set) var hasPresentedFrame: Bool {
        get { playbackState.hasPresentedFrame }
        set { playbackState.hasPresentedFrame = newValue }
    }
    private(set) var seekableWindow: LiveSeekableWindow? {
        get { playbackState.seekableWindow }
        set {
            playbackState.seekableWindow = newValue
            // No window, no delay to measure: whatever was playing is gone.
            if newValue == nil { playbackState.behindLiveSeconds = 0 }
        }
    }
    /// How far playback trails the live edge, for the transport's timeline.
    private(set) var behindLiveSeconds: TimeInterval {
        get { playbackState.behindLiveSeconds }
        set { playbackState.behindLiveSeconds = newValue }
    }
    private(set) var isAtLiveEdge: Bool {
        get { playbackState.isAtLiveEdge }
        set { playbackState.isAtLiveEdge = newValue }
    }
    private(set) var manualRetryCount: Int {
        get { playbackState.manualRetryCount }
        set { playbackState.manualRetryCount = newValue }
    }
    private var isLoading: Bool {
        get { playbackState.isLoading }
        set { playbackState.isLoading = newValue }
    }
    private var userPaused: Bool {
        get { playbackState.userPaused }
        set { playbackState.userPaused = newValue }
    }
    private var isRecoveringProgramme: Bool {
        get { playbackState.isRecoveringProgramme }
        set { playbackState.isRecoveringProgramme = newValue }
    }
    var audioTracks: [MediaTrack] { trackState.audioTracks }
    var subtitleTracks: [MediaTrack] { trackState.subtitleTracks }
    var selectedAudioID: Int? { trackState.selectedAudioID }
    var selectedSubtitleID: Int? { trackState.selectedSubtitleID }
    var subtitles: LiveSubtitleModel { trackState.subtitles }

    private(set) var networkBlock: LiveTVNetworkBlock?
    private(set) var continuesExternally = false
    private var isVisible = true
    private var sceneIsActive = true
    private var presentationRequestedContinuation = false
    private var permitsExternalPresentation = true
    @ObservationIgnored var onExternalContinuationChanged: (@MainActor (Bool) -> Void)?
    @ObservationIgnored var onPresentationInvalidated: (@MainActor () -> Void)?

    private struct Source: Equatable {
        let channelID: String
        let input: LiveChannelInput
    }

    private var source: Source
    private let uptime: @MainActor () -> TimeInterval
    private let idleSleepGuard = LiveChannelWakeLease()
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    private var attemptStartedAt: TimeInterval = 0
    private var firstFrameTimingStartedAt: TimeInterval = 0
    private var bufferingStartedAt: TimeInterval?
    @ObservationIgnored private var diagnostics = LiveChannelDiagnostics()
    @ObservationIgnored private var retuneBudget = LiveChannelRetuneBudget()
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var foregroundTask: Task<Void, Never>?
    private var recoveryGeneration = 0
    private var attemptGeneration = 0
    private var attemptCount = 0
    private var isSuspended = false
    private var needsForegroundLoad = false
    private var pendingSourceReset = false
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var sessionReporting: LiveChannelSessionReporting?
    @ObservationIgnored private var reportedSessionStart = false
    @ObservationIgnored private var reportedSessionFailure = false
    @ObservationIgnored private var lastSessionReport: TimeInterval?
    @ObservationIgnored private var lastSessionState: LiveTVPlaybackUpdate.State?

    private static let startupTimeout: TimeInterval = 30
    private static let bufferingTimeout: TimeInterval = 60
    private static let maximumManualRetries = 2

    var sessionReportingID: UUID? { sessionReporting?.id }
    var intendsPlayback: Bool { !userPaused && hasPresentedFrame && !phase.isInterrupted }

    init(
        engine: any LiveChannelEngine,
        channelID: String = "",
        input: LiveChannelInput,
        uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        outputGroup: LiveChannelOutputGroup? = nil,
        outputID: UUID = UUID(),
        isAudible: Bool = true,
        allowsDisplayMatching: Bool = true,
        trackPreferences: LiveChannelTrackPreferences? = nil
    ) {
        self.engine = engine
        self.outputGroup = outputGroup
        self.outputID = outputID
        outputPolicy = LiveChannelOutputPolicy(
            isAudible: isAudible, suppressesDisplayMatching: !allowsDisplayMatching
        )
        self.trackState = LiveChannelPlayerTrackState(preferences: trackPreferences ?? LiveChannelTrackPreferences())
        source = Source(
            channelID: channelID,
            input: input
        )
        self.uptime = uptime
        if let outputGroup {
            outputGroup.register(
                engine, id: outputID, audible: isAudible, allowsDisplayMatching: allowsDisplayMatching
            )
        } else {
            engine.configureLiveOutput(outputPolicy)
        }
    }

    convenience init(
        engine: any LiveChannelEngine,
        channelID: String = "",
        streamURL: URL,
        httpHeaders: [String: String] = [:],
        uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        outputGroup: LiveChannelOutputGroup? = nil,
        outputID: UUID = UUID(),
        isAudible: Bool = true,
        allowsDisplayMatching: Bool = true,
        trackPreferences: LiveChannelTrackPreferences? = nil
    ) {
        self.init(
            engine: engine, channelID: channelID, input: .stream(url: streamURL, httpHeaders: httpHeaders),
            uptime: uptime, outputGroup: outputGroup, outputID: outputID, isAudible: isAudible,
            allowsDisplayMatching: allowsDisplayMatching,
            trackPreferences: trackPreferences
        )
    }

    deinit {
        monitorTask?.cancel()
        recoveryTask?.cancel()
        foregroundTask?.cancel()
        guard !stopped else { return }
        let engine = engine
        let group = outputGroup
        let id = outputID
        let invalidatePresentation = onPresentationInvalidated
        Task { @MainActor in
            invalidatePresentation?()
            group?.unregister(id, engine: engine)
            engine.setWatching(false)
            engine.stop()
        }
    }

    func setAudible(_ audible: Bool) {
        guard !stopped else { return }
        outputPolicy.isAudible = audible
        if let outputGroup { outputGroup.setAudible(audible, id: outputID, engine: engine) }
        else { engine.configureLiveOutput(outputPolicy) }
    }

    func setDisplayMatchingAllowed(_ allowed: Bool) {
        guard !stopped else { return }
        outputPolicy.suppressesDisplayMatching = !allowed
        if let outputGroup {
            outputGroup.setDisplayMatchingAllowed(allowed, id: outputID, engine: engine)
        } else {
            engine.configureLiveOutput(outputPolicy)
        }
    }

    func setWatching(_ watching: Bool) {
        engine.setWatching(watching && !stopped)
    }

    func setPermitsExternalPresentation(_ allowed: Bool) {
        permitsExternalPresentation = allowed
        if !allowed { presentationRequestedContinuation = false }
        refreshExternalContinuation()
    }

    var canPause: Bool {
        // Resuming a deliberately paused replacement must not require the
        // first frame or seekable range that playback itself will produce.
        networkBlock == nil && !phase.isInterrupted && (userPaused || phase == .paused
            || (hasPresentedFrame && supportsTimeShift))
    }

    var canGoLive: Bool {
        canPause && hasPresentedFrame && supportsTimeShift && !isAtLiveEdge
    }

    private var supportsTimeShift: Bool {
        // Scheduled channels retain a broadcast cursor, not a native DVR range.
        if case .libraryChannel = source.input { return true }
        return seekableWindow?.supportsTimeShift == true
    }

    var canRetry: Bool {
        if case .failed(.input(.unsupportedSource)) = phase { return false }
        return networkBlock == nil && phase.isInterrupted && manualRetryCount < Self.maximumManualRetries
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        refreshExternalContinuation()
        if !visible, !continuesExternally { stop() }
    }

    func setExternalContinuation(_ continuing: Bool) {
        guard !stopped, permitsExternalPresentation || !continuing else { return }
        presentationRequestedContinuation = continuing
        refreshExternalContinuation()
        if continuesExternally, isSuspended, !userPaused {
            isSuspended = false
            engine.play()
        }
    }

    private func refreshExternalContinuation() {
        #if os(iOS)
        let actual = (engine as? any PictureInPicturePresentingEngine)?
            .continuesPlaybackInBackground == true
        #else
        let actual = false
        #endif
        let next = !stopped && permitsExternalPresentation && networkBlock == nil
            && (presentationRequestedContinuation || actual)
        guard next != continuesExternally else { return }
        continuesExternally = next
        onExternalContinuationChanged?(next)
        if !next, !isVisible {
            stop()
        } else if !next, !sceneIsActive {
            handleScenePhase(.background)
        }
    }

    func setNetworkBlock(_ block: LiveTVNetworkBlock?) {
        guard block != networkBlock else { return }
        networkBlock = block
        guard !stopped else { return }
        if block != nil {
            onPresentationInvalidated?()
            presentationRequestedContinuation = false
            refreshExternalContinuation()
            guard !stopped else { return }
            attemptGeneration &+= 1
            cancelRecovery()
            foregroundTask?.cancel()
            foregroundTask = nil
            isLoading = false
            needsForegroundLoad = true
            engine.stop()
            hasPresentedFrame = false
            subtitles.clear()
            phase = .paused
            idleSleepGuard.allowSleep()
        } else if isVisible, sceneIsActive, !userPaused {
            isSuspended = false
            resumeActivePlayback()
        }
    }

    func selectAudio(_ track: MediaTrack) {
        guard networkBlock == nil else { return }
        trackState.selectAudio(track, engine: engine)
    }

    func selectSubtitle(_ track: MediaTrack?) {
        trackState.selectSubtitle(track, engine: engine)
    }

    private func refreshTracks() {
        trackState.refresh(engine: engine, isReady: !isLoading && hasPresentedFrame)
    }

    func matchesSource(
        channelID: String,
        input: LiveChannelInput
    ) -> Bool {
        source == Source(
            channelID: channelID,
            input: input
        )
    }

    func matchesSource(channelID: String, streamURL: URL, httpHeaders: [String: String]) -> Bool {
        matchesSource(channelID: channelID, input: .stream(url: streamURL, httpHeaders: httpHeaders))
    }

    fileprivate var interruption: LiveChannelInterruption? {
        switch phase {
        case .failed(let failure):
            return .failure(
                failure, retryLimitReached: !canRetry,
                libraryItemKind: engine.currentLibraryItem?.kind
            )
        case .ended:
            return .ended(retryLimitReached: !canRetry)
        case .loading, .buffering, .seeking, .reconnecting, .playing, .paused:
            return nil
        }
    }

    var showsActivityIndicator: Bool {
        phase == .loading || phase == .buffering || phase == .seeking || phase == .reconnecting
    }

    func start() async {
        stopped = false
        startMonitor()
        guard !isSuspended, networkBlock == nil else {
            needsForegroundLoad = true
            return
        }
        await loadAttempt()
    }

    func changeSource(
        channelID: String,
        input: LiveChannelInput,
        reporting: LiveChannelSessionReporting? = nil
    ) async {
        let nextSource = Source(
            channelID: channelID,
            input: input
        )
        guard !stopped else { return }
        let changed = nextSource != source || sessionReporting?.id != reporting?.id
        setSessionReporting(reporting, reset: changed)
        guard changed else { return }

        source = nextSource
        resetProgrammeTracks()
        isRecoveringProgramme = false
        attemptGeneration += 1
        cancelRecovery()
        foregroundTask?.cancel()
        foregroundTask = nil
        retuneBudget = LiveChannelRetuneBudget()
        pendingSourceReset = false
        manualRetryCount = 0
        attemptCount = 0
        isLoading = false
        phase = .loading
        hasPresentedFrame = false
        seekableWindow = nil
        isAtLiveEdge = true
        attemptStartedAt = uptime()
        bufferingStartedAt = nil
        needsForegroundLoad = isSuspended
        idleSleepGuard.allowSleep()

        guard !isSuspended, networkBlock == nil else {
            engine.pause()
            return
        }
        await loadAttempt()
    }

    func changeSource(
        channelID: String,
        streamURL: URL,
        httpHeaders: [String: String] = [:],
        reporting: LiveChannelSessionReporting? = nil
    ) async {
        await changeSource(
            channelID: channelID, input: .stream(url: streamURL, httpHeaders: httpHeaders), reporting: reporting
        )
    }

    func setSessionReporting(_ reporting: LiveChannelSessionReporting?, reset: Bool = false) {
        let changed = sessionReporting?.id != reporting?.id
        if reset || sessionReporting?.id != reporting?.id {
            reportedSessionStart = false
            reportedSessionFailure = false
            lastSessionReport = nil
            lastSessionState = nil
        }
        sessionReporting = reporting
        if changed, reporting != nil, continuesExternally {
            onExternalContinuationChanged?(true)
        }
    }

    func retry() async {
        guard canRetry else { return }
        cancelRecovery()
        manualRetryCount += 1
        diagnostics.event(.retry, attempt: attemptCount + 1)
        pendingSourceReset = false
        userPaused = false
        await loadAttempt()
    }

    func togglePlayPause() {
        guard !phase.isInterrupted else { return }
        if userPaused || phase == .paused {
            userPaused = false
            diagnostics.event(.resume, attempt: attemptCount)
            guard !isSuspended else { return }
            resumeActivePlayback()
        } else {
            guard canPause else { return }
            userPaused = true
            diagnostics.event(.pause, attempt: attemptCount)
            if !isLoading { cancelRecovery() }
            engine.pause()
            phase = .paused
            bufferingStartedAt = nil
            idleSleepGuard.allowSleep()
        }
    }

    func goLive() async {
        guard canGoLive, !isSuspended, !isLoading else { return }
        let generation = attemptGeneration
        userPaused = false
        diagnostics.event(.seek, attempt: attemptCount)
        phase = .seeking
        bufferingStartedAt = uptime()
        await engine.seekToLiveEdge()
        guard generation == attemptGeneration else { return }
        diagnostics.event(.seekCompleted, attempt: attemptCount)
        guard !stopped, !isSuspended, !phase.isInterrupted, !userPaused else { return }
        engine.play()
        refreshFromEngine()
    }

    func handleScenePhase(_ scenePhase: ScenePhase) {
        sceneIsActive = scenePhase == .active
        refreshExternalContinuation()
        guard !stopped else { return }
        if continuesExternally {
            isSuspended = false
            idleSleepGuard.allowSleep()
            return
        }
        switch scenePhase {
        case .active:
            guard isSuspended, !stopped else { return }
            diagnostics.event(.foreground, attempt: attemptCount)
            isSuspended = false
            guard !userPaused, !phase.isInterrupted || isRecoveringProgramme else { return }
            resumeActivePlayback()
        case .inactive, .background:
            guard !stopped else { return }
            if !isSuspended {
                diagnostics.event(.suspend, attempt: attemptCount)
            }
            isSuspended = true
            if !isLoading || scenePhase == .background { cancelRecovery() }
            engine.pause()
            if scenePhase == .background {
                // Pausing alone leaves native HLS fetching manifests/segments.
                needsForegroundLoad = true
                attemptGeneration += 1
                isLoading = false
                foregroundTask?.cancel()
                foregroundTask = nil
                engine.stop()
            }
            idleSleepGuard.allowSleep()
        @unknown default:
            isSuspended = true
            diagnostics.event(.suspend, attempt: attemptCount)
            cancelRecovery()
            engine.pause()
            idleSleepGuard.allowSleep()
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        isRecoveringProgramme = false
        onPresentationInvalidated?()
        onPresentationInvalidated = nil
        presentationRequestedContinuation = false
        if continuesExternally {
            continuesExternally = false
            onExternalContinuationChanged?(false)
        }
        onExternalContinuationChanged = nil
        setSessionReporting(nil)
        attemptGeneration += 1
        diagnostics.event(.stop, attempt: attemptCount)
        cancelRecovery()
        foregroundTask?.cancel()
        foregroundTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        engine.onFailure = nil
        engine.onEnded = nil
        engine.onLiveSourceReset = nil
        engine.onProgrammeChanged = nil
        engine.onTracksChanged = nil
        engine.onSubtitleCues = nil
        subtitles.clear()
        outputGroup?.unregister(outputID, engine: engine)
        engine.setWatching(false)
        engine.stop()
        idleSleepGuard.allowSleep()
    }

    private func loadAttempt() async {
        guard !stopped, !isSuspended, networkBlock == nil else {
            needsForegroundLoad = true
            return
        }
        attemptGeneration += 1
        let generation = attemptGeneration
        let source = source
        attemptCount += 1
        installEngineCallbacks(for: generation)
        diagnostics.event(.load, attempt: attemptCount)
        isLoading = true
        phase = .loading
        hasPresentedFrame = false
        seekableWindow = nil
        isAtLiveEdge = true
        attemptStartedAt = uptime()
        firstFrameTimingStartedAt = attemptStartedAt
        bufferingStartedAt = nil
        needsForegroundLoad = false
        do {
            try await engine.loadChannel(source.input)
        } catch is CancellationError {
            return
        } catch {
            guard generation == attemptGeneration, !stopped, networkBlock == nil else { return }
            isLoading = false
            if showRecoverableProgrammeIssue() { return }
            if let error = error as? LiveChannelInputError {
                fail(.input(error), generation: generation)
            } else if let error = error as? LibraryChannelError {
                fail(.library(error), generation: generation)
            } else {
                fail(.engine(error as? AppError ?? .invalidResponse), generation: generation)
            }
            return
        }
        guard generation == attemptGeneration, !stopped, !phase.isInterrupted else { return }
        isLoading = false
        if isSuspended || userPaused {
            engine.pause()
        }
        refreshTracks()
        refreshFromEngine()
        if pendingSourceReset { requestRetune() }
    }

    private func installEngineCallbacks(for generation: Int) {
        engine.onFailure = { [weak self] error in
            self?.fail(.engine(error), generation: generation)
        }
        engine.onEnded = { [weak self] in
            self?.streamEnded(generation: generation)
        }
        engine.onLiveSourceReset = { [weak self] in
            self?.sourceNeedsRetune(generation: generation)
        }
        engine.onProgrammeChanged = { [weak self] in
            guard let self, !self.stopped, self.networkBlock == nil, self.attemptGeneration == generation else { return }
            self.resetProgrammeTracks()
            self.isRecoveringProgramme = false
            self.hasPresentedFrame = false
            self.seekableWindow = nil
            self.manualRetryCount = 0
            self.attemptStartedAt = self.uptime()
            self.firstFrameTimingStartedAt = self.attemptStartedAt
            self.bufferingStartedAt = nil
            self.phase = self.userPaused ? .paused : .loading
        }
        engine.onTracksChanged = { [weak self] in
            guard let self, !self.stopped, self.attemptGeneration == generation else { return }
            self.refreshTracks()
        }
        engine.onSubtitleCues = { [weak self] cues in
            guard let self, !self.stopped, self.attemptGeneration == generation else { return }
            self.subtitles.updateLiveCues(cues)
        }
        // Remote-HLS channels are drawn by the engine's AVPlayer, not the
        // overlay, so hand it the look "Use native subtitles" asks for.
        engine.updateSubtitleStyle(trackState.engineSubtitleStyle)
    }

    private func startMonitor() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                self.refreshFromEngine()
            }
        }
    }

    func refreshFromEngine() {
        refreshExternalContinuation()
        guard networkBlock == nil else { return }
        guard !stopped, !phase.isInterrupted || isRecoveringProgramme else {
            idleSleepGuard.allowSleep()
            return
        }
        guard !isSuspended else {
            idleSleepGuard.allowSleep()
            return
        }
        if showRecoverableProgrammeIssue() { return }
        if isRecoveringProgramme {
            isRecoveringProgramme = false
            phase = .loading
        }

        let snapshot = engine.liveSnapshot
        subtitles.tick(snapshot.position)
        diagnostics.sample(snapshot, uptime: uptime(), attempt: attemptCount)
        if isLoading {
            phase = .loading
            if !userPaused, !isScheduledSource {
                enforceStartupTimeout()
            }
            idleSleepGuard.allowSleep()
            return
        }
        if snapshot.phase == .failed {
            if case .failed(let error) = engine.status {
                fail(.engine(error))
            } else {
                fail(.engine(.invalidResponse))
            }
            return
        }
        if snapshot.phase == .ended {
            streamEnded()
            return
        }
        seekableWindow = snapshot.seekableRange.flatMap {
            LiveSeekableWindow(ranges: [(start: $0.lowerBound, duration: $0.upperBound - $0.lowerBound)])
        }
        if let behind = snapshot.behindLiveSeconds, behind.isFinite {
            isAtLiveEdge = behind <= 3
            behindLiveSeconds = isAtLiveEdge ? 0 : max(0, behind)
        } else {
            isAtLiveEdge = seekableWindow?.isAtLiveEdge(currentTime: snapshot.position) ?? true
            behindLiveSeconds = isAtLiveEdge ? 0
                : max(0, (seekableWindow?.upperBound ?? snapshot.position) - snapshot.position)
        }
        let hadPresentedFrame = hasPresentedFrame
        hasPresentedFrame = hasPresentedFrame || snapshot.firstFrameReady
        if !hadPresentedFrame, hasPresentedFrame {
            // The first moment a subtitle selection is sure to be honoured.
            refreshTracks()
            diagnostics.tuneToFirstFrame(
                attempt: attemptCount,
                startedAt: firstFrameTimingStartedAt,
                firstFrameAt: uptime()
            )
        }
        if userPaused {
            phase = .paused
        } else if pendingSourceReset || recoveryTask != nil {
            phase = .reconnecting
        } else if !hasPresentedFrame {
            phase = .loading
        } else {
            switch snapshot.phase {
            case .idle, .loading: phase = .loading
            case .playing: phase = snapshot.firstFrameReady ? .playing : .buffering
            case .paused: phase = .paused
            case .seeking: phase = .seeking
            case .rebuffering: phase = .buffering
            case .stalled(let reconnecting): phase = reconnecting ? .reconnecting : .buffering
            case .ended, .failed: break
            }
        }
        if showsActivityIndicator {
            if bufferingStartedAt == nil { bufferingStartedAt = uptime() }
        } else {
            bufferingStartedAt = nil
        }
        if !userPaused, phase != .paused, !isScheduledSource {
            if hasPresentedFrame {
                enforceBufferingTimeout()
            } else {
                enforceStartupTimeout()
            }
        }
        idleSleepGuard.keepAwake(phase == .playing && isVisible && sceneIsActive && !continuesExternally)
        reportSessionActivity(position: snapshot.position)
    }

    private var isScheduledSource: Bool {
        if case .libraryChannel = source.input { return true }
        return false
    }

    private func resetProgrammeTracks() {
        trackState.resetProgramme()
    }

    private func showRecoverableProgrammeIssue() -> Bool {
        guard isScheduledSource, let issue = engine.recoverableProgrammeIssue else { return false }
        if phase != .failed(.library(issue)) { subtitles.clear() }
        isRecoveringProgramme = true
        isLoading = false
        phase = .failed(.library(issue))
        hasPresentedFrame = false
        seekableWindow = nil
        bufferingStartedAt = nil
        idleSleepGuard.allowSleep()
        return true
    }

    private func reportSessionActivity(position: TimeInterval) {
        guard let sessionReporting, hasPresentedFrame, !phase.isInterrupted, !isSuspended, !stopped else { return }
        let state: LiveTVPlaybackUpdate.State = phase == .paused ? .paused : .playing
        let now = uptime()
        if !reportedSessionStart {
            reportedSessionStart = true
            lastSessionReport = now
            lastSessionState = .playing
            sessionReporting.update(.init(state: .started, positionSeconds: position))
        } else if lastSessionState != state || now - (lastSessionReport ?? now) >= 15 {
            lastSessionReport = now
            lastSessionState = state
            sessionReporting.update(.init(state: state, positionSeconds: position))
        }
    }

    private func reportSessionFailure() {
        guard let sessionReporting, !reportedSessionFailure else { return }
        reportedSessionFailure = true
        sessionReporting.failed()
    }

    private func resumeActivePlayback() {
        attemptStartedAt = uptime()
        bufferingStartedAt = nil
        if needsForegroundLoad {
            guard foregroundTask == nil else { return }
            foregroundTask = Task { [weak self] in
                guard let self else { return }
                await self.loadAttempt()
                guard !Task.isCancelled else { return }
                self.foregroundTask = nil
            }
        } else if pendingSourceReset {
            requestRetune()
        } else {
            engine.play()
            refreshFromEngine()
        }
    }

    private func sourceNeedsRetune(generation: Int? = nil) {
        guard generation.map({ $0 == attemptGeneration }) ?? true,
              !stopped, !phase.isInterrupted else { return }
        if !pendingSourceReset {
            diagnostics.event(.sourceReset, attempt: attemptCount)
            pendingSourceReset = true
        }
        requestRetune()
    }

    @discardableResult
    func requestRetune() -> Task<Void, Never>? {
        guard pendingSourceReset, !stopped, !phase.isInterrupted,
              !isSuspended, !userPaused, !isLoading else { return nil }
        if let recoveryTask { return recoveryTask }
        guard !retuneBudget.isExhausted else {
            fail(.recoveryExhausted)
            return nil
        }
        phase = .reconnecting
        let recovery = recoveryGeneration
        let delay = retuneBudget.delayBeforeNextAttempt(uptime: uptime())
        let task = Task { [weak self] in
            do {
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            } catch is CancellationError {
                return
            } catch {
                self?.fail(.engine(.unknown("recovery scheduling")))
                return
            }
            guard let self, !Task.isCancelled,
                  self.recoveryGeneration == recovery, !self.stopped,
                  !self.isSuspended, !self.userPaused else { return }
            self.retuneBudget.recordAttempt(uptime: self.uptime())
            self.pendingSourceReset = false
            self.diagnostics.event(.retune, attempt: self.attemptCount + 1)
            await self.loadAttempt()
            guard self.recoveryGeneration == recovery else { return }
            self.recoveryTask = nil
            self.refreshFromEngine()
            if self.pendingSourceReset { self.requestRetune() }
        }
        recoveryTask = task
        return task
    }

    private func cancelRecovery() {
        recoveryGeneration += 1
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    private func enforceStartupTimeout() {
        guard uptime() - attemptStartedAt >= Self.startupTimeout else { return }
        fail(.startupTimedOut)
    }

    private func enforceBufferingTimeout() {
        guard showsActivityIndicator,
              let bufferingStartedAt,
              uptime() - bufferingStartedAt >= Self.bufferingTimeout else {
            return
        }
        fail(.bufferingTimedOut)
    }

    private func fail(
        _ failure: LiveChannelPlaybackFailure,
        generation: Int? = nil
    ) {
        guard generation.map({ $0 == attemptGeneration }) ?? true,
              !stopped, !phase.isInterrupted || isRecoveringProgramme else { return }
        if showRecoverableProgrammeIssue() { return }
        switch failure {
        case .input, .library:
            diagnostics.event(.failure, attempt: attemptCount)
        case .engine(let error):
            diagnostics.event(.failure, attempt: attemptCount, error: error)
        case .startupTimedOut:
            diagnostics.event(.startupTimeout, attempt: attemptCount)
        case .bufferingTimedOut:
            diagnostics.event(.stallTimeout, attempt: attemptCount)
        case .recoveryExhausted:
            diagnostics.event(.retuneExhausted, attempt: attemptCount)
        }
        phase = .failed(failure)
        isRecoveringProgramme = false
        attemptGeneration += 1
        isLoading = false
        cancelRecovery()
        foregroundTask?.cancel()
        foregroundTask = nil
        engine.stop()
        idleSleepGuard.allowSleep()
        reportSessionFailure()
    }

    private func streamEnded(generation: Int? = nil) {
        guard generation.map({ $0 == attemptGeneration }) ?? true,
              !stopped, !phase.isInterrupted || isRecoveringProgramme else { return }
        isRecoveringProgramme = false
        diagnostics.event(.ended, attempt: attemptCount)
        phase = .ended
        attemptGeneration += 1
        isLoading = false
        cancelRecovery()
        foregroundTask?.cancel()
        foregroundTask = nil
        engine.stop()
        idleSleepGuard.allowSleep()
        reportSessionFailure()
    }
}

enum LiveChannelPlaybackPhase: Equatable {
    case loading
    case buffering
    case seeking
    case reconnecting
    case playing
    case paused
    case failed(LiveChannelPlaybackFailure)
    case ended

    var isInterrupted: Bool {
        switch self {
        case .failed, .ended:
            return true
        case .loading, .buffering, .seeking, .reconnecting, .playing, .paused:
            return false
        }
    }

    func statusLabel(isAtLiveEdge: Bool, isScheduledChannel: Bool = false) -> LocalizedStringResource {
        switch self {
        case .loading:
            return "CONNECTING"
        case .buffering:
            return "BUFFERING"
        case .seeking:
            return "SEEKING"
        case .reconnecting:
            return "RECONNECTING"
        case .playing:
            if isScheduledChannel { return isAtLiveEdge ? "ON NOW" : "DELAYED" }
            return isAtLiveEdge ? "LIVE" : "BEHIND LIVE"
        case .paused:
            return "PAUSED"
        case .failed:
            return "PLAYBACK ERROR"
        case .ended:
            return "PLAYBACK ENDED"
        }
    }

    func statusColor(isAtLiveEdge: Bool) -> Color {
        switch self {
        case .playing where isAtLiveEdge:
            return .green
        case .failed, .ended:
            return .red
        case .paused:
            return .yellow
        case .loading, .buffering, .seeking, .reconnecting, .playing:
            return .white.opacity(0.82)
        }
    }

    var activityLabel: LocalizedStringResource {
        switch self {
        case .seeking: "Seeking…"
        case .reconnecting: "Reconnecting…"
        case .buffering: "Buffering…"
        default: "Loading channel…"
        }
    }
}

enum LiveChannelPlaybackFailure: Equatable {
    case startupTimedOut
    case bufferingTimedOut
    case recoveryExhausted
    case engine(AppError)
    case input(LiveChannelInputError)
    case library(LibraryChannelError)

    static func engineMessage(_ error: AppError) -> LocalizedStringResource {
        switch error {
        case .notFound:
            "The channel provider could not find this stream. Its playlist link may be outdated, or the feed may be temporarily off air."
        case .unauthorized, .invalidCredentials:
            "The channel provider refused access to this stream. It may require authorization or be unavailable in your region."
        case .serverUnreachable:
            "Plozz could not reach the channel's streaming server. Check your internet connection or try again later."
        case .rateLimited:
            "The channel provider is limiting requests. Wait before trying again."
        case .invalidResponse:
            "The channel's playlist or video data could not be opened. Its link may be outdated or the feed may be temporarily unavailable."
        case .decoding:
            "The player could not decode this channel's audio or video. Try another stream version or channel."
        case .cancelled:
            "Opening this channel was cancelled."
        default:
            "Plozz could not start playback. Retry or choose another channel."
        }
    }
}

enum LibraryChannelPlaybackCopy {
    static func returnToCurrentTitle(isScheduledChannel: Bool) -> LocalizedStringResource {
        isScheduledChannel ? "Jump to now" : "Go Live"
    }

    static func failureTitle(for kind: MediaItemKind?) -> LocalizedStringResource {
        switch kind {
        case .movie: "Couldn't play this movie"
        case .episode: "Couldn't play this episode"
        default: "Couldn't play this program"
        }
    }
}

private struct LiveChannelInterruption {
    let icon: String
    let title: LocalizedStringResource
    let message: LocalizedStringResource

    static func failure(
        _ failure: LiveChannelPlaybackFailure,
        retryLimitReached: Bool,
        libraryItemKind: MediaItemKind? = nil
    ) -> LiveChannelInterruption {
        let base: LiveChannelInterruption
        switch failure {
        case .input(let error):
            base = LiveChannelInterruption(
                icon: "exclamationmark.triangle.fill",
                title: "Channel Unavailable",
                message: error.message
            )
        case .library(let error):
            base = LiveChannelInterruption(
                icon: "exclamationmark.triangle.fill",
                title: LibraryChannelPlaybackCopy.failureTitle(for: libraryItemKind),
                message: error.message
            )
        case .startupTimedOut:
            base = LiveChannelInterruption(
                icon: "exclamationmark.triangle.fill",
                title: "Playback timed out",
                message: "The channel did not present video in time."
            )
        case .bufferingTimedOut:
            base = LiveChannelInterruption(
                icon: "wifi.exclamationmark",
                title: "Playback stalled",
                message: "The channel stopped delivering playable video."
            )
        case .engine(let error):
            base = LiveChannelInterruption(
                icon: "exclamationmark.triangle.fill",
                title: "Unable to Play Channel",
                message: LiveChannelPlaybackFailure.engineMessage(error)
            )
        case .recoveryExhausted:
            base = LiveChannelInterruption(
                icon: "wifi.exclamationmark",
                title: "Unable to Reconnect",
                message: "This channel keeps disconnecting. Try again or choose another channel."
            )
        }
        return retryLimitReached ? base.withRetryLimitMessage() : base
    }

    static func ended(retryLimitReached: Bool) -> LiveChannelInterruption {
        let base = LiveChannelInterruption(
            icon: "stop.circle.fill",
            title: "Playback ended",
            message: "The channel stopped playing."
        )
        return retryLimitReached ? base.withRetryLimitMessage() : base
    }

    private func withRetryLimitMessage() -> LiveChannelInterruption {
        LiveChannelInterruption(
            icon: icon,
            title: title,
            message: "This channel could not be restarted. Return to the channel list and try again later."
        )
    }
}
#endif
