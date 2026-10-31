#if os(iOS)
import CoreGraphics
import CoreModels
import CoreNetworking
import FeaturePlayback
import AVKit
import SwiftUI
import CoreUI

private enum PlozziOSPlayerSheet: String, Identifiable {
    case speed
    case zoom
    case subtitleAdvanced
    case subtitleSearch
    case audioSync
    case quality
    case timestamps

    var id: Self { self }
}

struct PlozziOSPlayerControlsOverlay: View {
    let viewModel: PlayerViewModel
    let keyboardActions: PlozziOSPlayerKeyboardActions
    let hasVersions: Bool
    let versionsPresented: Bool
    let onShowVersions: () -> Void
    let onClose: () -> Void

    @State private var controlsVisible = true
    @State private var scrubPreviewCoordinator: ScrubPreviewCoordinator?
    @State private var presentedSheet: PlozziOSPlayerSheet?
    @State private var timestampBrowser: PlayerCommunityTimestampsModel?
    @Environment(\.communityPlaybackTimestampSource) private var timestampSource
    @State private var menuPresentation = PlayerMenuPresentation()
    /// Whether the Info / Cast card is expanded. Owned here rather than inside
    /// the strip because dismissing it is this view's job: the tap that closes
    /// it lands on the video, above the card, which the strip does not cover.
    @State private var isCardOpen = false
    /// Whole turns the skip glyphs have made — one per press, signed by
    /// direction. A running total rather than a flag, so pressing again
    /// mid-spin adds a turn instead of restarting the one in flight.
    @State private var backwardSpins = 0
    @State private var forwardSpins = 0
    @State private var autoHideTask: Task<Void, Never>?
    @State private var touchGestures = PlayerTouchGestureState()
    @State private var availableSize: CGSize = .zero
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var pictureInPicture = PlozziOSPictureInPictureController()

    private var isScrubbing: Bool { viewModel.controls.isScrubbing }
    private var nativeMenuPresented: Bool { menuPresentation.isBusy }
    private var menuSourceID: [String?] {
        let item = viewModel.currentPlaybackItem
        return [item?.sourceAccountID, item?.id, item?.selectedVersionID]
    }
    private var scrubSeconds: TimeInterval { viewModel.controls.scrubSeconds }

    var body: some View {
        ZStack {
            PlayerTouchGestureSurface(
                state: touchGestures,
                shortcutsEnabled: touchShortcutsEnabled,
                levelsEnabled: keyboardShortcutsEnabled && viewModel.volumeBrightnessGesturesEnabled,
                isActive: !isPlayingElsewhere && scenePhase == .active,
                canSeek: viewModel.controls.duration.isFinite && viewModel.controls.duration > 0,
                canBoost: !viewModel.controls.intendsPause
                    && viewModel.controls.engineCapabilities.contains(.playbackSpeed),
                canZoom: viewModel.controls.engineCapabilities.contains(.videoZoom),
                onTap: backgroundTapped,
                onSkip: touchSkip,
                onBoostChanged: touchBoostChanged,
                onZoom: { fillsScreen in
                    viewModel.controls.videoZoom.settings.mode = fillsScreen ? .fill : .fit
                },
                onGestureStarted: beginTouchInteraction
            )
            .ignoresSafeArea()

            if isPlayingElsewhere {
                PlozziOSExternalPlaybackPlaceholder(
                    routeName: viewModel.externalPlaybackRouteName,
                    isPictureInPicture: pictureInPicture.isActive
                )
            }

            if controlsVisible || touchGestures.skip != nil {
                LinearGradient(
                    colors: [
                        .black.opacity(controlsVisible ? 0.65 : 0),
                        .black.opacity(controlsVisible ? 0.35 : 0),
                        .black.opacity(controlsVisible ? 0.82 : 0.45),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }

            if controlsVisible || touchGestures.skip != nil || showsUpNext {
                VStack(spacing: 0) {
                    if controlsVisible && !isScrubbing {
                        PlozziOSPlayerTopBar(
                            subtitleLayout: viewModel.controls.subtitleLayout,
                            pictureInPictureAvailable: pictureInPicture.isAvailable,
                            onTogglePictureInPicture: {
                                pictureInPicture.toggle()
                                noteInteraction()
                            },
                            onClose: onClose
                        )
                    }
                    Spacer(minLength: 0)
                    PlozziOSPlayerTransport(
                        viewModel: viewModel,
                        showsTransport: controlsVisible || touchGestures.skip != nil,
                        showsUpNext: showsUpNext,
                        playbackControls: primaryPlaybackControls(compact: true),
                        timelineOnly: !controlsVisible || isScrubbing,
                        displayedSeconds: isScrubbing
                            ? scrubSeconds
                            : (touchGestures.skip?.target ?? viewModel.controls.currentSeconds),
                        isScrubbing: isScrubbing,
                        scrubPreviewImage: scrubPreviewCoordinator?.image,
                        showsScrubPreview: scrubPreviewCoordinator?.isAvailable == true,
                        pictureInPictureAvailable: pictureInPicture.isAvailable,
                        onTogglePictureInPicture: {
                            pictureInPicture.toggle()
                            noteInteraction()
                        },
                        onScrubChanged: { value in
                            viewModel.controls.scrubSeconds = value
                            scrubPreviewCoordinator?.update(for: value)
                            noteInteraction()
                        },
                        onScrubEditingChanged: { editing in
                            guard editing || isScrubbing else { return }
                            viewModel.controls.isScrubbing = editing
                            if editing {
                                controlsVisible = true
                                viewModel.controls.scrubSeconds = viewModel.controls.currentSeconds
                                cancelTouchInteraction()
                                cancelAutoHide()
                            } else {
                                viewModel.requestSeek(to: scrubSeconds)
                                scrubPreviewCoordinator?.clear()
                                scheduleAutoHide()
                            }
                        },
                        onSkipBackward: {
                            seek(by: -viewModel.controls.skipGesture.backwardInterval.seconds)
                        },
                        onPlayPause: {
                            viewModel.togglePlayPause()
                            noteInteraction()
                        },
                        onSkipForward: {
                            seek(by: viewModel.controls.skipGesture.forwardInterval.seconds)
                        },
                        supportsVideoZoom: !isPlayingElsewhere
                            && viewModel.controls.engineCapabilities.contains(.videoZoom),
                        hasTimestamps: timestampSource != nil && viewModel.canBrowseCommunityTimestamps,
                        hasVersions: hasVersions,
                        menuPresentation: menuPresentation,
                        isCardOpen: $isCardOpen,
                        onInteraction: noteInteraction,
                        availableSize: availableSize
                    )
                }
                .modifier(PlayerTouchChromePadding())
            }

            if controlsVisible && !isScrubbing && !isCardOpen && !showsUpNext {
                primaryPlaybackControls(compact: PlayerTouchLayout.usesCompactTransport(in: availableSize))
                    .reportSubtitleControlsFrame(in: viewModel.controls.subtitleLayout, region: .centerTransport)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if !isScrubbing {
                PlayerTouchGestureFeedbackView(state: touchGestures)
            }

            if viewModel.controls.skipButtonVisible, !touchGestures.isActive, !isScrubbing {
                Button {
                    let canSkip = viewModel.controls.activeSkipSegment != nil
                    viewModel.skipActiveSegment()
                    if canSkip { TouchFeedback.shared.emit(.impact) }
                    noteInteraction()
                } label: {
                    Text(skipTitle)
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(24)
            }

        }
        .onGeometryChange(for: CGSize.self) {
            $0.size
        } action: {
            availableSize = $0
        }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .onChange(of: controlsVisible) { _, visible in
            if !visible { viewModel.controls.timelineClock.isEnabled = false }
        }
        .onChange(of: isCardOpen) { _, _ in cardOpenChanged() }
        .onChange(of: menuSourceID) {
            menuPresentation.reset()
            presentedSheet = nil
        }
        .onChange(of: menuPresentation.isBusy) { _, busy in
            if busy { cancelAutoHide() } else { scheduleAutoHide() }
        }
        .task(id: menuPresentation.destination) { presentMenuDestination() }
        .onAppear { scheduleAutoHide() }
        .onAppear { configureScrubPreview() }
        .onAppear { attachPictureInPicture() }
        // The presenting layer does not exist until the native path has loaded,
        // and an engine hand-off can replace it mid-session, so re-read it
        // whenever playback becomes ready rather than once at appear.
        .onChange(of: viewModel.phase) { _, phase in
            attachPictureInPicture()
            if phase != .ready {
                menuPresentation.reset()
                presentedSheet = nil
            }
        }
        // No AirPlay equivalent yet, and not for want of trying: the engine
        // declares its native subtitle renditions in the master playlist, but the
        // wireless AirPlay path serves the media playlist so AVPlayer will not
        // reject a DV/HDR master on an SDR receiver. A media playlist carries no
        // EXT-X-MEDIA tags, so there is no legible track to select and the call
        // changes nothing. Tracked upstream as AetherEngine#227.
        .onDisappear { pictureInPicture.detach() }
        .onDisappear {
            menuPresentation.reset()
            keyboardActions.clear()
            cancelAutoHide()
            cancelTouchInteraction()
            scrubPreviewCoordinator?.clear()
            viewModel.controls.isScrubbing = false
            viewModel.controls.timelineClock.isEnabled = false
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                menuPresentation.reset()
                cancelAutoHide()
                cancelTouchInteraction()
                viewModel.controls.isScrubbing = false
                scrubPreviewCoordinator?.clear()
            } else {
                scheduleAutoHide()
            }
        }
        .onChange(of: touchShortcutsEnabled) { _, enabled in
            if !enabled { cancelTouchInteraction() }
        }
        .onChange(of: keyboardShortcutsEnabled, initial: true) { _, _ in updateKeyboardActions() }
        .onChange(of: canSeekWithKeyboard) { _, _ in updateKeyboardActions() }
        .onChange(of: viewModel.temporarySpeedBoostRate) { _, rate in
            touchGestures.showBoost(rate: rate)
        }
        .onChange(of: viewModel.scrubPreview) {
            configureScrubPreview()
        }
        .onChange(of: viewModel.controls.intendsPause) { _, paused in
            if paused {
                cancelTouchInteraction()
                controlsVisible = true
                cancelAutoHide()
            } else {
                scheduleAutoHide()
            }
        }
        .onChange(of: viewModel.controls.diagnosticsEnabled) { _, enabled in
            if enabled { cancelAutoHide() } else { scheduleAutoHide() }
        }
        .onChange(of: versionsPresented) { _, presented in
            if presented { cancelAutoHide() } else { scheduleAutoHide() }
        }
        .plozzSheet(item: $presentedSheet, onDismiss: scheduleAutoHide) { sheet in
            switch sheet {
            case .speed:
                PlozziOSPlaybackSpeedSheet(viewModel: viewModel)
            case .zoom:
                PlayerZoomSettingsSheet(model: viewModel.controls.videoZoom)
            case .subtitleAdvanced:
                PlozziOSSubtitleOptionsSheet(viewModel: viewModel, mode: .advanced)
            case .subtitleSearch:
                PlozziOSSubtitleOptionsSheet(viewModel: viewModel, mode: .search)
            case .audioSync:
                PlozziOSAudioSyncSheet(viewModel: viewModel)
            case .quality:
                PlozziOSStreamingQualitySheet(viewModel: viewModel)
            case .timestamps:
                if let timestampBrowser { PlayerCommunityTimestampsView(model: timestampBrowser) }
            }
        }
        .ignoresSafeArea()
    }

    private func presentMenuDestination() {
        guard let destination = menuPresentation.takeDestination() else { return }
        guard scenePhase == .active else {
            menuPresentation.reset()
            return
        }
        cancelAutoHide()
        switch destination {
        case .subtitleAdvanced: presentedSheet = .subtitleAdvanced
        case .subtitleSearch: presentedSheet = .subtitleSearch
        case .audioSync: presentedSheet = .audioSync
        case .speed: presentedSheet = .speed
        case .zoom: presentedSheet = .zoom
        case .quality: presentedSheet = .quality
        case .versions: onShowVersions()
        case .timestamps:
            guard let timestampSource, viewModel.canBrowseCommunityTimestamps else {
                PlozzLog.playback.debug("Ignoring unavailable community timestamps menu selection.")
                scheduleAutoHide()
                return
            }
            timestampBrowser = viewModel.makeCommunityTimestampBrowser(source: timestampSource)
            presentedSheet = .timestamps
        case .multiview:
            PlozzLog.playback.error("VOD menu requested unavailable multiview destination.")
        }
    }

    private func primaryPlaybackControls(compact: Bool) -> some View {
        HStack(spacing: compact ? 20 : PlayerTouchLayout.transportSpacing(in: availableSize)) {
            Button {
                seek(by: -viewModel.controls.skipGesture.backwardInterval.seconds)
                backwardSpins -= 1
            } label: {
                PlozziOSSkipGlyph(
                    seconds: viewModel.controls.skipGesture.backwardInterval.rawValue,
                    direction: .backward, size: compact ? 24 : 34, turns: backwardSpins
                )
            }
            .buttonStyle(PlayerGlassCircleButtonStyle(diameter: compact ? 44 : PlayerTouchLayout.skipDiameter))
            .accessibilityLabel("Skip backward")

            Button {
                viewModel.togglePlayPause()
                noteInteraction()
            } label: {
                Image(systemName: viewModel.controls.intendsPause ? "play.fill" : "pause.fill")
                    .font(.system(size: compact ? 24 : 44))
            }
            .buttonStyle(PlayerGlassCircleButtonStyle(diameter: compact ? 44 : PlayerTouchLayout.playDiameter))
            .accessibilityLabel(viewModel.controls.intendsPause ? "Play" : "Pause")

            Button {
                seek(by: viewModel.controls.skipGesture.forwardInterval.seconds)
                forwardSpins += 1
            } label: {
                PlozziOSSkipGlyph(
                    seconds: viewModel.controls.skipGesture.forwardInterval.rawValue,
                    direction: .forward, size: compact ? 24 : 34, turns: forwardSpins
                )
            }
            .buttonStyle(PlayerGlassCircleButtonStyle(diameter: compact ? 44 : PlayerTouchLayout.skipDiameter))
            .accessibilityLabel("Skip forward")
        }
        .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
    }

    private var skipTitle: LocalizedStringResource {
        viewModel.controls.activeSkipSegment?.kind.skipActionLabel ?? "Skip"
    }

    private var showsUpNext: Bool {
        viewModel.controls.upNextCard.isPresenting && viewModel.controls.upNextCard.info != nil
            && !isCardOpen && !nativeMenuPresented && presentedSheet == nil
            && !versionsPresented && !isScrubbing && !isPlayingElsewhere
    }

    private func toggleControls() {
        guard !nativeMenuPresented else { return }
        controlsVisible.toggle()
        if controlsVisible {
            scheduleAutoHide()
        } else {
            cancelAutoHide()
        }

    }

    private var keyboardShortcutsEnabled: Bool {
        !isPlayingElsewhere && presentedSheet == nil && !nativeMenuPresented
            && !versionsPresented && !isCardOpen && !isScrubbing
            && scenePhase == .active
    }

    private var touchShortcutsEnabled: Bool {
        keyboardShortcutsEnabled && !viewModel.controls.upNextCard.isPresenting
    }

    private var canSeekWithKeyboard: Bool {
        viewModel.controls.duration.isFinite && viewModel.controls.duration > 0
    }

    private func updateKeyboardActions() {
        keyboardActions.isEnabled = keyboardShortcutsEnabled
        keyboardActions.canSeek = canSeekWithKeyboard
        keyboardActions.skip = keyboardSkip
        keyboardActions.playPause = {
            guard keyboardShortcutsEnabled else { return }
            viewModel.togglePlayPause()
            noteInteraction()
        }
    }

    private func backgroundTapped() {
        guard !isScrubbing else { return }
        touchGestures.clearSkip()
        if isCardOpen {
            isCardOpen = false
            noteInteraction()
        } else {
            toggleControls()
        }
    }

    private func beginTouchInteraction() {
        cancelAutoHide()
        controlsVisible = false
    }

    private func touchSkip(_ direction: PlayerTouchSkipDirection) {
        guard touchShortcutsEnabled else { return }
        if skipWithFeedback(direction, origin: "touchSkip") {
            TouchFeedback.shared.emit(.selection)
        }
    }

    private func keyboardSkip(_ direction: PlayerTouchSkipDirection) {
        guard keyboardShortcutsEnabled else { return }
        skipWithFeedback(direction, origin: "keyboardSkip")
    }

    @discardableResult
    private func skipWithFeedback(_ direction: PlayerTouchSkipDirection, origin: String) -> Bool {
        let duration = viewModel.controls.duration
        guard duration.isFinite, duration > 0 else { return false }
        let interval = direction == .forward
            ? viewModel.controls.skipGesture.forwardInterval.seconds
            : -viewModel.controls.skipGesture.backwardInterval.seconds
        guard let target = touchGestures.seek(
            by: interval,
            from: viewModel.controls.pendingSeekTarget ?? viewModel.controls.currentSeconds,
            within: 0...max(0, duration - 1)
        ) else { return false }
        beginTouchInteraction()
        viewModel.requestSeek(to: target, origin: origin)
        return true
    }

    private func touchBoostChanged(_ held: Bool) {
        if held {
            guard touchShortcutsEnabled, let rate = viewModel.beginTemporarySpeedBoost() else { return }
            beginTouchInteraction()
            touchGestures.showBoost(rate: rate)
        } else {
            viewModel.endTemporarySpeedBoost()
            touchGestures.showBoost(rate: nil)
        }
    }

    private func cancelTouchInteraction() {
        viewModel.endTemporarySpeedBoost()
        touchGestures.cancel()
    }

    private func seek(by interval: TimeInterval) {
        guard viewModel.controls.duration.isFinite, viewModel.controls.duration > 0 else { return }
        let start = viewModel.controls.pendingSeekTarget ?? viewModel.controls.currentSeconds
        let target = min(
            max(start + interval, 0),
            viewModel.controls.duration
        )
        guard target != start else { return }
        viewModel.requestSeek(to: target)
        TouchFeedback.shared.emit(.impact)
        noteInteraction()
    }

    /// Re-arms or suspends auto-hide when the card opens or closes.
    private func cardOpenChanged() {
        if isCardOpen {
            cancelAutoHide()
        } else {
            scheduleAutoHide()
        }
    }

    private func noteInteraction() {
        controlsVisible = true
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        cancelAutoHide()
        #if DEBUG
        // A file-driven capture run supplies no touch to reveal the transport, and
        // it fades a few seconds after playback starts — so a shot that waits for
        // the scene to settle catches bare video with no chrome. When the capture
        // rig asks, auto-hide is suspended and the bar the run set up stays up to
        // be photographed. Inert in any run the rig did not seed.
        if PlozziOSScreenshotSeed.holdsPlayerControls { return }
        #endif
        // An open Info / Cast card counts as being in use, like an open sheet.
        // Reading a synopsis or scrolling a cast row involves long stretches
        // with no taps, and the timer cannot tell that from abandonment — so it
        // took the card away mid-read. It resumes when the card closes.
        guard !viewModel.controls.intendsPause,
              presentedSheet == nil,
              !versionsPresented,
              !nativeMenuPresented,
              !viewModel.controls.diagnosticsEnabled,
              !isScrubbing,
              !isCardOpen,
              !touchGestures.isActive
        else {
            return
        }

        // Auto-hide exists to get the chrome out of the way of the video. With
        // the video on a TV or in a PiP window there is nothing to reveal, and
        // hiding leaves the user staring at a placeholder with no way to pause
        // without tapping first.
        guard !isPlayingElsewhere else { return }
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            controlsVisible = false
        }
    }

    private func cancelAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    /// True while the frames are presenting somewhere other than this screen.
    private var isPlayingElsewhere: Bool {
        pictureInPicture.isActive || viewModel.externalPlaybackRouteName != nil
    }

    private func attachPictureInPicture() {
        guard let engine = viewModel.pictureInPictureEngine else { return }
        pictureInPicture.attach(engine: engine)
        pictureInPicture.onRestoreUI = { @MainActor in
            // Nothing to rebuild today: the player stays mounted behind the PiP
            // window. The handler still has to run so AVKit completes the
            // restore rather than leaving the window half-dismissed.
        }
    }

    private func configureScrubPreview() {
        scrubPreviewCoordinator?.clear()
        scrubPreviewCoordinator = viewModel.makeScrubPreviewCoordinator()
        scrubPreviewCoordinator?.prefetch()
    }
}

/// The system AirPlay route picker.
///
/// Nothing else is needed to AirPlay a locally-remuxed stream: AetherEngine
/// watches `isExternalPlaybackActive` on its own AVPlayer and, when a wireless
/// receiver picks up, reloads at the current position with the device's LAN IP
/// swapped in for 127.0.0.1 and the MEDIA playlist forced, because the Apple TV
/// cannot fetch segments from the phone's loopback and rejects a DV/HDR master
/// playlist on an SDR receiver. That makes this true AirPlay video rather than
/// screen mirroring. A wired HDMI display is deliberately left on the loopback.
/// Shown when the video has moved off this screen.
///
/// The local surface goes black in both cases, because the frames are being
/// presented somewhere else: a Picture in Picture window, or an AirPlay
/// receiver. A black rectangle with floating subtitles over it reads as a
/// failure, so say plainly where the video went.
private struct PlozziOSExternalPlaybackPlaceholder: View {
    let routeName: String?
    let isPictureInPicture: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: isPictureInPicture ? "pip" : "airplayvideo")
                .font(.system(size: 52, weight: .light))
            Text(title)
                .font(.title3.weight(.semibold))
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .plozzForeground(.secondary)
            }
        }
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Opaque on purpose. The shared player keeps rendering its subtitle
        // overlay against a black surface, and those cues are meaningless here
        // while the frames they belong to are on another screen, so this covers
        // them rather than letting them float over an empty rectangle.
        .background(Color.black)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var title: LocalizedStringResource {
        if isPictureInPicture { return "Playing in Picture in Picture" }
        if let routeName { return "Playing on \(routeName)" }
        return "Playing on AirPlay"
    }

    private var detail: LocalizedStringResource? {
        isPictureInPicture ? "Tap the window to bring playback back here." : nil
    }
}

private struct PlozziOSAirPlayRouteButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        // Surfaces Apple TV class receivers ahead of audio-only routes.
        view.prioritizesVideoDevices = true
        view.tintColor = context.environment.playerControlTint
        view.activeTintColor = view.tintColor
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = context.environment.playerControlTint
        uiView.activeTintColor = uiView.tintColor
    }
}

/// Close, AirPlay and Picture in Picture — all leading.
///
/// The title moved out of here to sit above the scrub bar, matching tvOS, where
/// the name of what you are watching belongs with the timeline rather than in a
/// corner. Route and PiP join it on the left because they are the same class of
/// thing: WHERE this is playing, not what.
private struct PlozziOSPlayerTopBar: View {
    let subtitleLayout: SubtitleControlsLayout
    let pictureInPictureAvailable: Bool
    let onTogglePictureInPicture: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.headline)
            }
            .buttonStyle(PlayerGlassCircleButtonStyle(diameter: 44))
            .accessibilityLabel("Close player")
            .reportSubtitleControlsFrame(in: subtitleLayout, region: .topControls)

            PlayerGlassControlGroup {
                PlozziOSAirPlayRouteButton()
                    .frame(width: 44, height: 44)
                    .accessibilityLabel(Text(verbatim: "AirPlay"))

                if pictureInPictureAvailable {
                    Button(action: onTogglePictureInPicture) {
                        Image(systemName: "pip.enter")
                            .font(.headline)
                    }
                    .buttonStyle(PlayerGlassCircleButtonStyle(diameter: 44))
                    .accessibilityLabel("Picture in Picture")
                }
            }
            .reportSubtitleControlsFrame(in: subtitleLayout, region: .topControls)

            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private extension View {
    /// Gives a transport glyph a real 44pt touch target.
    ///
    /// The sizing has to live on the button's LABEL. Applied to the `Button`
    /// itself, `.frame(minWidth: 44, minHeight: 44)` only enlarges the layout
    /// slot the button is centred in; the button stays as big as its label, which
    /// for these glyphs is around 20pt. The overlay puts a full-screen tap layer
    /// behind the controls to toggle them, so every tap that landed in the gap
    /// between the glyph and its 44pt slot fell through to that layer: pressing
    /// play or skip read as tapping off the controls and dismissed them, and the
    /// buttons appeared to do nothing. `contentShape` makes the padded area part
    /// of the label rather than empty space the tap passes through.
    func playerTransportGlyph(font: Font = .title3) -> some View {
        self
            .font(font)
            .foregroundStyle(.white)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

struct PlozziOSPlayerTransport<PlaybackControls: View>: View {
    let viewModel: PlayerViewModel
    let showsTransport: Bool
    let showsUpNext: Bool
    let playbackControls: PlaybackControls
    let timelineOnly: Bool
    let displayedSeconds: TimeInterval
    let isScrubbing: Bool
    let scrubPreviewImage: CGImage?
    let showsScrubPreview: Bool
    let pictureInPictureAvailable: Bool
    let onTogglePictureInPicture: () -> Void
    let onScrubChanged: (TimeInterval) -> Void
    let onScrubEditingChanged: (Bool) -> Void
    let onSkipBackward: () -> Void
    let onPlayPause: () -> Void
    let onSkipForward: () -> Void
    let supportsVideoZoom: Bool
    let hasTimestamps: Bool
    let hasVersions: Bool
    let menuPresentation: PlayerMenuPresentation
    @Binding var isCardOpen: Bool
    let onInteraction: () -> Void
    /// The full player bounds, not this bottom cluster's intrinsic size.
    let availableSize: CGSize

    var body: some View {
        VStack(alignment: .trailing, spacing: 16) {
            if showsUpNext, let info = viewModel.controls.upNextCard.info {
                Group {
                    if showsTransport && !timelineOnly {
                        playbackControls
                    } else {
                        playbackControls.hidden()
                    }
                }
                .reportSubtitleControlsFrame(
                    in: viewModel.controls.subtitleLayout, region: .transport,
                    isVisible: showsTransport && !timelineOnly
                )
                .frame(maxWidth: .infinity)

                PlozziOSUpNextCard(
                    info: info,
                    artworkPolicy: viewModel.controls.artworkPolicy,
                    countdownRemaining: viewModel.controls.upNextCard.advanceAtSeconds.map {
                        max($0 - viewModel.controls.currentSeconds, 0)
                    },
                    countdownDuration: viewModel.controls.automaticUpNextDelay,
                    onPlay: { viewModel.playEpisode(info.episode) },
                    onDismiss: { viewModel.dismissUpNextCard() }
                )
                .reportSubtitleControlsFrame(in: viewModel.controls.subtitleLayout, region: .card)
            }

            if showsTransport {
                transportControls
            } else {
                transportControls.hidden()
            }
        }
        .frame(maxWidth: .infinity, alignment: .bottom)
    }

    private var transportControls: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 16) {
                // Episode line ABOVE the title, matching `titleBlock` on tvOS:
                // "S1, E2 · Episode Title" reads as a qualifier of the series
                // name, so it belongs above the thing it qualifies. This had the
                // two the other way round.
                VStack(alignment: .leading, spacing: 1) {
                    if !viewModel.controls.subtitle.isEmpty, !PlayerTouchLayout.usesCompactTitle(in: availableSize) {
                        Text(viewModel.controls.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                    Text(viewModel.controls.title)
                        .font(PlayerTouchLayout.usesCompactTitle(in: availableSize) ? .headline : .title3.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .reportSubtitleControlsFrame(
                    in: viewModel.controls.subtitleLayout, region: .title,
                    isVisible: !isCardOpen && !timelineOnly
                )

                Spacer(minLength: 12)

                trackControls
                    .reportSubtitleControlsFrame(
                        in: viewModel.controls.subtitleLayout, region: .trackControls,
                        isVisible: !isCardOpen && !timelineOnly
                    )
            }
            .foregroundStyle(.white)
            .playerTouchChromeHidden(isCardOpen || timelineOnly || !showsTransport)

            PlozziOSPlayerTimeline(
                model: viewModel.controls, displayedSeconds: displayedSeconds, isScrubbing: isScrubbing,
                onScrubChanged: onScrubChanged, onScrubEditingChanged: onScrubEditingChanged,
                onInteraction: onInteraction
            )
            .frame(height: PlayerTouchLayout.timelineRowHeight)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("player-timeline")
            .reportSubtitleControlsFrame(
                in: viewModel.controls.subtitleLayout, region: .timeline,
                isVisible: !isCardOpen && showsTransport
            )
            .opacity(isCardOpen ? 0 : 1)
            .allowsHitTesting(!isCardOpen && showsTransport)
            .accessibilityHidden(isCardOpen || !showsTransport)
            .overlay(alignment: .bottom) {
                if isScrubbing, showsScrubPreview {
                    PlayerTouchScrubPreview(image: scrubPreviewImage, availableSize: availableSize)
                        .padding(.bottom, PlayerTouchLayout.timelineRowHeight + 12)
                }
            }

            // Info / Cast tabs sit BELOW the scrubber, matching tvOS, and the
            // card grows upward out of them.
            PlayerTouchCardStrip(
                model: viewModel.controls,
                availableSize: availableSize,
                isCardOpen: $isCardOpen,
                player: viewModel,
                onRestart: { viewModel.requestSeek(to: 0, origin: "restart") },
                onNextEpisode: { viewModel.playNextEpisode() },
                onPreviousEpisode: {
                    if let previous = viewModel.previousEpisode {
                        viewModel.playEpisode(previous)
                    }
                }
            )
            .playerTouchChromeHidden(timelineOnly)

            // Deliberately no .font / .foregroundStyle / .buttonStyle here. Those
            // travel through the environment into a Menu's POPUP content, not just
            // its label, so the menu's rows rendered white-on-light with the plain
            // button style until UIKit re-applied its own styling: the flash on
            // open. Each glyph now carries its own styling instead.
        }
        .reportSubtitleControlsFrame(
            in: viewModel.controls.subtitleLayout, region: .transport, isVisible: !isCardOpen && !timelineOnly
        )
    }

    /// One named-options menu leaves the title room in portrait.
    @ViewBuilder
    private var trackControls: some View {
        // Opacity alone leaves native glass children exposed to accessibility.
        if isCardOpen || timelineOnly || !showsTransport {
            trackControlGroup.hidden()
        } else {
            trackControlGroup
        }
    }

    private var trackControlGroup: some View {
        let item = viewModel.currentPlaybackItem
        return PlayerGlassControlGroup {
            PlayerMoreMenuButton(
                model: viewModel.controls,
                availability: .init(
                    maximumSpeed: viewModel.maximumPlaybackSpeed, video: supportsVideoZoom,
                    quality: viewModel.streamingQualityAvailable, versions: hasVersions, timestamps: hasTimestamps
                ),
                presentation: menuPresentation,
                layout: .init(size: availableSize),
                actions: menuActions(for: item)
            )
        }
        .accessibilityIdentifier("player-track-controls")
    }

    private func menuActions(for item: MediaItem?) -> PlayerMoreMenuActions {
        var actions = PlayerMoreMenuActions()
        actions.isCurrent = {
            viewModel.currentPlaybackItem?.id == item?.id
                && viewModel.currentPlaybackItem?.sourceAccountID == item?.sourceAccountID
                && viewModel.currentPlaybackItem?.selectedVersionID == item?.selectedVersionID
        }
        actions.selectAudio = { viewModel.selectAudioOption(id: $0); onInteraction() }
        actions.selectSubtitle = { viewModel.selectSubtitleOption(id: $0); onInteraction() }
        actions.setDialogueEnhancement = { viewModel.setDialogEnhanceEnabled($0); onInteraction() }
        actions.setSpeed = { viewModel.setPlaybackSpeed($0); onInteraction() }
        return actions
    }

}

struct PlozziOSPlayerTimeline: View {
    let model: PlayerControlsModel
    let displayedSeconds: TimeInterval
    let isScrubbing: Bool
    let onScrubChanged: (TimeInterval) -> Void
    let onScrubEditingChanged: (Bool) -> Void
    let onInteraction: () -> Void

    var body: some View {
        PlayerClockTimeline(model: model, enabled: model.timelineClock.isEnabled) { clock in
            let visibleClock = isScrubbing ? nil : clock
            let durationTime = playbackTime(model.duration)
            HStack(spacing: 4) {
                timeButton(
                    Text(verbatim: visibleClock?.current ?? playbackTime(displayedSeconds)),
                    layoutText: Text(verbatim: durationTime),
                    samples: (clock?.currentWidthSamples ?? []).map { Text(verbatim: $0) },
                    label: visibleClock != nil ? "Current time" : "Elapsed time",
                    identifier: "player-timeline-current-time", alignment: .leading
                )
                PlayerTouchScrubBar(
                    currentSeconds: displayedSeconds, duration: model.duration,
                    bufferedFraction: model.bufferedFraction, segments: model.skipSegments.segments,
                    onScrub: onScrubChanged, onScrubbingChanged: onScrubEditingChanged
                )
                .accessibilityLabel("Playback position")
                .accessibilityIdentifier("player-timeline-scrubber")
                timeButton(
                    visibleClock.map { $0.end.map { Text($0) } ?? Text(verbatim: "--:--") }
                        ?? Text(verbatim: "-\(playbackTime(max(model.duration - displayedSeconds, 0)))"),
                    layoutText: Text(verbatim: "-\(durationTime)"),
                    samples: (clock?.endWidthSamples ?? []).map { Text($0) },
                    label: visibleClock != nil ? "Estimated end time" : "Remaining time",
                    identifier: "player-timeline-end-time", alignment: .trailing
                )
            }
        }
    }

    private func timeButton(
        _ text: Text, layoutText: Text, samples: [Text], label: LocalizedStringResource, identifier: String,
        alignment: Alignment
    ) -> some View {
        Button {
            guard !isScrubbing else { return }
            model.timelineClock.isEnabled.toggle()
            onInteraction()
        } label: {
            ZStack {
                layoutText.hidden()
                ForEach(samples.indices, id: \.self) { index in
                    samples[index].hidden()
                }
            }
            .accessibilityHidden(true)
            .overlay(alignment: alignment) {
                text
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .font(.caption.monospacedDigit())
            .fixedSize()
            .frame(minWidth: 44, minHeight: 44, alignment: alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!isScrubbing)
        .accessibilityRespondsToUserInteraction(!isScrubbing)
        .accessibilityLabel(Text(label))
        .accessibilityValue(text)
        .accessibilityHint("Switch between playback and clock times")
        .accessibilityIdentifier(identifier)
    }

    func playbackTime(_ seconds: TimeInterval) -> String {
        let rounded = seconds.rounded()
        let duration = model.duration.rounded()
        guard seconds.isFinite, seconds >= 0, rounded < Double(Int.max),
              duration.isFinite, duration >= 0, duration < Double(Int.max) else { return "--:--" }
        let total = Int(rounded)
        let hours = total / 3_600
        let durationHours = Int(duration) / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        if durationHours > 0 || hours > 0 {
            return String(format: "%0*ld:%02ld:%02ld", String(durationHours).count, hours, minutes, remainder)
        }
        return String(format: "%02ld:%02ld", minutes, remainder)
    }
}


/// The skip-back / skip-forward glyph: a ring that spins one full turn per
/// press, with the interval stationary inside it.
///
/// Composed rather than using `gobackward.10` and friends, for two reasons. The
/// composite symbols bake the number into the artwork, so rotating one rotates
/// the number with it — and Apple only ships numbered variants for 5, 10, 15,
/// 30, 45, 60, 75 and 90. Interpolating the raw value into a symbol name, which
/// is what this used to do, produced `gobackward.1` for a one-second interval:
/// not a symbol, so the button rendered as nothing at all. Drawing the ring and
/// the number separately supports every interval by construction.
private struct PlozziOSSkipGlyph: View {
    enum Direction { case backward, forward }

    let seconds: Int
    let direction: Direction
    let size: CGFloat
    /// Signed whole turns. The rotation follows the skip: back winds
    /// anticlockwise, forward clockwise.
    let turns: Int

    /// Where the circle's centre sits inside the glyph's bounding box.
    ///
    /// Not the box's centre, and that is the whole difficulty: the arrowhead
    /// protrudes above the circle, so the box is taller than the circle by that
    /// protrusion and its top edge is the arrowhead's tip. The circle's centre
    /// therefore sits half the protrusion BELOW the box's centre — and rotating
    /// about the box's centre swung the ring through a small arc rather than
    /// turning it in place, which is the bob. Fitting the glyph to a square frame
    /// fixed the text-metrics half of this; the asymmetry is the other half, and
    /// no amount of framing removes it.
    private static let ringCentre = UnitPoint(x: 0.5, y: 0.54)

    var body: some View {
        ZStack {
            // Sized as an IMAGE, not as text.
            //
            // A symbol laid out with `.font` gets text metrics — the box it
            // occupies includes descender space the glyph does not use, so its
            // centre sits below the ring's. Rotating about that point swung the
            // ring through a small arc instead of spinning it in place, which
            // read as the arrow bobbing up and down. Resizing to a square frame
            // makes the glyph's own bounds the frame, so its centre and the
            // rotation anchor are the same point.
            Image(systemName: direction == .backward ? "gobackward" : "goforward")
                .resizable()
                .scaledToFit()
                .fontWeight(.regular)
                .frame(width: size, height: size)
                .rotationEffect(.degrees(Double(turns) * 360), anchor: Self.ringCentre)
                // Keyed to the running total, so a press mid-spin extends the
                // turn rather than snapping back and starting over.
                .animation(.easeInOut(duration: 0.45), value: turns)

            // Deliberately outside the rotation. The ring is the thing that
            // moves; a number that spun with it would be unreadable at exactly
            // the moment it is being checked.
            Text(verbatim: "\(seconds)")
                // Proportional to the ring, matching how Apple's own composite
                // glyphs scale their numerals.
                .font(.system(size: size * 0.42, weight: .semibold))
                // The ring is not vertically symmetric — its opening and
                // arrowhead sit at the top — so the space the numeral occupies
                // is centred a little below the circle's own centre.
                .offset(y: size * 0.06)
        }
    }
}

private struct PlozziOSSubtitleOptionsSheet: View {
    enum Mode { case advanced, search }
    @Environment(\.dismiss) private var dismiss
    let viewModel: PlayerViewModel
    let mode: Mode

    var body: some View {
        NavigationStack {
            Form {
                if mode == .advanced {
                    secondaryTracks
                    PlozziOSPlaybackSyncControls(viewModel: viewModel, includesAudio: false)
                    appearance
                } else {
                    remoteSearch
                }
            }
            .navigationTitle(Text(mode == .search ? LocalizedStringResource("Search for Subtitles") : "Subtitles"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .accessibilityIdentifier(mode == .search ? "player-subtitle-search-sheet" : "player-subtitle-advanced-sheet")
        .task {
            if mode == .search, viewModel.controls.subtitleDownload.canSearch,
               case .idle = viewModel.controls.subtitleDownload.state {
                viewModel.searchRemoteSubtitles()
            }
        }
    }

    @ViewBuilder
    private var secondaryTracks: some View {
        if let format = viewModel.controls.secondarySubtitleImagePrimaryFormat {
            Section("Second Track") {
                Text("Unavailable with \(format) image subtitles.")
                    .plozzForeground(.secondary)
            }
        } else if !viewModel.controls.secondarySubtitleOptions.isEmpty {
            Section("Second Track") {
                ForEach(viewModel.controls.secondarySubtitleOptions) { option in
                    Button {
                        viewModel.selectSecondarySubtitleOption(id: option.id)
                    } label: {
                        HStack {
                            option.title
                            Spacer()
                            if option.isSelected {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                if let statusText = secondaryStatusText {
                    Text(statusText)
                        .font(.caption)
                        .plozzForeground(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var appearance: some View {
        if viewModel.controls.subtitleStyleAdjustable {
            Section("Appearance") {
                if let format =
                    viewModel.controls.secondarySubtitleImagePrimaryFormat {
                    Label(
                        "\(format) subtitles are rendered as images and can’t be restyled.",
                        systemImage: "photo"
                    )
                    .plozzForeground(.secondary)
                } else {
                    NavigationLink {
                        MobileSubtitleStyleEditor(viewModel: .init(player: viewModel))
                    } label: {
                        LabeledContent {
                            viewModel.controls.subtitleStyle.fontDisplayName
                        } label: {
                            Text("Style")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var remoteSearch: some View {
        if viewModel.controls.subtitleDownload.canSearch {
            Section("Find More") {
                switch viewModel.controls.subtitleDownload.state {
                case .idle:
                    searchButton
                case .searching:
                    HStack {
                        ProgressView()
                        Text("Searching…")
                    }
                case let .results(results):
                    ForEach(results) { subtitle in
                        Button {
                            viewModel.downloadAndLoadRemoteSubtitle(subtitle)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(subtitle.name)
                                HStack(spacing: 8) {
                                    Text(remoteSubtitleDetails(subtitle))
                                        .font(.caption)
                                        .plozzForeground(.secondary)
                                    SubtitleFileMatchBadge(isHashMatch: subtitle.isHashMatch)
                                }
                            }
                        }
                    }
                    searchButton
                case .empty:
                    Text("No matching subtitles were found.")
                        .plozzForeground(.secondary)
                    searchButton
                case .downloading:
                    HStack {
                        ProgressView()
                        Text("Adding subtitle…")
                    }
                case .added:
                    Label("Subtitle added", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    searchButton
                case .failed:
                    Text("Subtitle search failed.")
                        .foregroundStyle(.red)
                    searchButton
                case .unavailable(let message):
                    Text(message).foregroundStyle(.red)
                    searchButton
                }
            }
        }
    }

    private var searchButton: some View {
        Button("Search for Subtitles", systemImage: "magnifyingglass") {
            viewModel.searchRemoteSubtitles()
        }
    }

    private var secondaryStatusText: LocalizedStringResource? {
        switch viewModel.controls.secondarySubtitleStatus {
        case .idle:
            return nil
        case .loading:
            return LocalizedStringResource("Loading second subtitle…")
        case let .loaded(cueCount):
            guard cueCount == 0 else { return nil }
            return LocalizedStringResource("The selected track contains no cues.")
        case .unavailable:
            return LocalizedStringResource("The selected second subtitle could not be loaded.")
        }
    }

    private func remoteSubtitleDetails(_ subtitle: RemoteSubtitle) -> String {
        [
            subtitle.language?.uppercased(),
            subtitle.format?.uppercased(),
            subtitle.providerName,
            subtitle.isForced ? "Forced" : nil,
            subtitle.isHearingImpaired ? "SDH" : nil
        ]
        .compactMap { $0 }
        .joined(separator: " • ")
    }
}

private struct PlozziOSPlaybackSpeedSheet: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: PlayerViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Fine Control") {
                    Slider(
                        value: Binding(
                            get: { viewModel.controls.playbackSpeed },
                            set: { viewModel.setPlaybackSpeed($0) }
                        ),
                        in: 0.25...max(0.25, viewModel.maximumPlaybackSpeed),
                        step: 0.05
                    )
                    Text(
                        viewModel.controls.playbackSpeed,
                        format: .number.precision(.fractionLength(2))
                    )
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
                }

                Section("Presets") {
                    ForEach(PlayerMoreMenu.speedPresets.filter { $0 <= viewModel.maximumPlaybackSpeed }, id: \.self) { rate in
                        Button {
                            viewModel.setPlaybackSpeed(rate)
                        } label: {
                            HStack {
                                Text(verbatim: "\(rate.formatted(.number))×")
                                Spacer()
                                if abs(viewModel.controls.playbackSpeed - rate) < 0.01 {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Playback Speed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct PlozziOSPlaybackSyncControls: View {
    let viewModel: PlayerViewModel
    var includesAudio = true
    var includesSubtitles = true

    var body: some View {
        Group {
            if includesAudio, viewModel.controls.engineCapabilities.contains(.audioDelay) {
                Section("Audio Delay") {
                    Slider(
                        value: Binding(
                            get: { viewModel.controls.audioDelaySeconds },
                            set: { viewModel.setAudioDelay($0) }
                        ),
                        in: -2...2,
                        step: 0.05
                    )
                    .accessibilityLabel("Audio Delay")
                    .accessibilityIdentifier("player-audio-delay")
                    Text(
                        viewModel.controls.audioDelaySeconds,
                        format: .number.precision(.fractionLength(2))
                    )
                    .plozzForeground(.secondary)
                }
            }

            if includesSubtitles, viewModel.controls.subtitleDelayAdjustable {
                Section("Subtitle Delay") {
                    Slider(
                        value: Binding(
                            get: { viewModel.controls.subtitleDelaySeconds },
                            set: { viewModel.setSubtitleDelay($0) }
                        ),
                        in: -2...2,
                        step: 0.05
                    )
                    .accessibilityLabel("Subtitle Delay")
                    .accessibilityIdentifier("player-subtitle-delay")
                    Text(
                        viewModel.controls.subtitleDelaySeconds,
                        format: .number.precision(.fractionLength(2))
                    )
                    .plozzForeground(.secondary)
                }
            }
        }
    }
}

private struct PlozziOSAudioSyncSheet: View {
    let viewModel: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                PlozziOSPlaybackSyncControls(viewModel: viewModel, includesSubtitles: false)
            }
            .navigationTitle("Audio Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct PlozziOSUpNextCard: View {
    let info: UpNextInfo
    let artworkPolicy: ArtworkPresentationPolicy
    let countdownRemaining: TimeInterval?
    let countdownDuration: TimeInterval
    let onPlay: () -> Void
    let onDismiss: () -> Void
    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var artworkHeight = 60.0

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onPlay) {
                HStack(spacing: 12) {
                    if !dynamicTypeSize.isAccessibilitySize {
                        thumbnail
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        info.eyebrow
                            .font(.caption.weight(.heavy))
                            .tracking(1)
                            .textCase(.uppercase)
                            .foregroundStyle(Color.primary.opacity(0.65))
                        info.showName
                            .font(.headline)
                            .lineLimit(2)
                        if let metaLine = info.metaLine {
                            Text(metaLine)
                                .font(.caption)
                                .foregroundStyle(Color.primary.opacity(0.75))
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let countdownRemaining, countdownRemaining > 0.05 {
                        countdown(remaining: countdownRemaining)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding([.leading, .vertical], metrics.cardInset)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("player-up-next")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss Up Next")
            .padding(.trailing, metrics.cardInset)
        }
        .frame(maxWidth: 460)
        .foregroundStyle(Color.primary)
        .playerPanelBackground(cornerRadius: metrics.landscapeCardCornerRadius)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player-up-next-card")
    }

    private var thumbnail: some View {
        let source = EpisodeArtworkSource(
            item: info.episode, spoilerSettings: info.spoilerSettings, policy: artworkPolicy
        )
        return Color.clear
            .frame(width: artworkHeight * 16 / 9)
            .frame(minHeight: artworkHeight, maxHeight: .infinity)
            .overlay {
                FallbackAsyncImage(
                    references: source.references, variant: .landscapeCard,
                    artworkPolicy: source.policy,
                    asyncFallbackURL: source.fallbackURL, pinIdentity: source.pinIdentity
                ) {
                    ZStack {
                        Rectangle().fill(Color.primary.opacity(0.08))
                        Image(systemName: "play.rectangle.fill")
                            .foregroundStyle(Color.primary.opacity(0.35))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: metrics.landscapeArtworkCornerRadius))
            .blur(radius: info.blurThumbnail ? 18 : 0)
            .clipShape(RoundedRectangle(cornerRadius: metrics.landscapeArtworkCornerRadius))
            .accessibilityHidden(true)
    }

    private func countdown(remaining: TimeInterval) -> some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: min(max(remaining / max(countdownDuration, 1), 0), 1))
                .stroke(Color.primary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(Int(ceil(remaining)), format: .number)
                .font(.caption.monospacedDigit().bold())
        }
        .frame(width: 32, height: 32)
    }
}
#endif
