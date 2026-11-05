#if os(tvOS)
import AVFoundation
import CoreModels
import CoreNetworking
import CoreUI
import SwiftUI
import UIKit

/// Plozz's regular transport UI over an already-playing ambient trailer.
/// The caller retains the player, item and video surface; no provider session,
/// display-mode switch or watch-progress reporting is started here.
public final class BorrowedTrailerPlayer: UIViewController {
    let engine: BorrowedTrailerEngine
    private let input: PlayerInputViewController

    public init(
        player: AVPlayer, surface: UIView, title: String, // l10n:content - provider-supplied media title
        settings: PlaybackSettings = .default, palette: ThemePalette = .dark,
        onDismiss: @escaping () -> Void
    ) {
        let engine = BorrowedTrailerEngine(player: player, surface: surface)
        self.engine = engine
        let model = engine.controls
        model.title = title
        model.infoCard.headline = title
        model.duration = engine.duration
        model.currentSeconds = engine.currentTime
        model.controlsVisible = true
        model.engineCapabilities = engine.capabilities
        model.skipGesture.backwardInterval = settings.skipBackwardInterval
        model.skipGesture.forwardInterval = settings.skipForwardInterval
        model.skipGesture.seekWithoutPausing = settings.seekWithoutPausing
        let actions = PlayerActions(
            seek: { engine.seeks.requestSeek(to: $0) },
            togglePlayPause: { engine.togglePlayPause() },
            setPlaybackSpeed: { engine.setPlaybackSpeed($0) },
            restart: { engine.seeks.requestSeek(to: 0) },
            dismiss: onDismiss
        )
        input = PlayerInputViewController(engine: engine, model: model, actions: actions)
        super.init(nibName: nil, bundle: nil)
        input.attachVideoSurface()
        input.attachControls(themePalette: ThemePaletteBox(
            makeControls: { model, actions, exit in
                AnyView(PlayerControls(model: model, palette: palette, actions: actions, onExitToSurface: exit))
            },
            makeSkipButton: { _, _, _, _ in AnyView(EmptyView()) },
            makeUpNextCard: { _, _, _, _ in AnyView(EmptyView()) }
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.accessibilityIdentifier = "trailer-fullscreen-player"
        addChild(input)
        input.view.frame = view.bounds
        input.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(input.view)
        input.didMove(toParent: self)
    }

    public override var preferredFocusEnvironments: [UIFocusEnvironment] { [input] }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        engine.stop()
    }
}

@MainActor
final class BorrowedTrailerEngine: VideoEngine, SeekScrubCoordinatorHost {
    let player: AVPlayer
    private let item: AVPlayerItem?
    let surface: UIView
    let controls = PlayerControlsModel()
    lazy var seeks = SeekScrubCoordinator(host: self, controls: controls)
    private(set) var seekDidStop = false
    var seekEngine: any VideoEngine { self }
    private var isActive: Bool { !seekDidStop && item != nil && player.currentItem === item }
    var seekIntendsPlayback: Bool { !controls.intendsPause && isActive }
    var status: VideoEngineStatus { isActive ? .ready : .idle }
    var isPaused: Bool { player.rate == 0 && player.timeControlStatus != .waitingToPlayAtSpecifiedRate }
    var preventsDisplaySleep: Bool { isActive && player.timeControlStatus == .playing }
    var hasPresentedVideoFrame: Bool { isActive && (surface.layer as? AVPlayerLayer)?.isReadyForDisplay == true }
    var currentTime: TimeInterval { isActive ? finite(player.currentTime().seconds) : 0 }
    var duration: TimeInterval { isActive ? finite(item?.duration.seconds ?? 0) : 0 }
    var furthestObservedPosition: TimeInterval { currentTime }
    var bufferedPosition: TimeInterval {
        player.currentItem?.loadedTimeRanges.map { finite(CMTimeRangeGetEnd($0.timeRangeValue).seconds) }.max() ?? 0
    }
    var videoAspectRatio: Double? {
        guard let size = player.currentItem?.presentationSize, size.height > 0 else { return nil }
        return Double(size.width / size.height)
    }
    var capabilities: PlayerEngineCapabilities { [.playbackSpeed, .videoZoom] }
    var audioTracks: [MediaTrack] { [] }
    var subtitleTracks: [MediaTrack] { [] }
    var onProgress: (@MainActor () -> Void)?
    var onFailure: (@MainActor (AppError) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onTracksChanged: (@MainActor () -> Void)?
    var onProbedSourceFactsChanged: (@MainActor (EngineProbedSourceFacts) -> Void)?
    var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?

    init(player: AVPlayer, surface: UIView) {
        self.player = player
        self.item = player.currentItem
        self.surface = surface
    }

    func load(request: PlaybackRequest, startPosition: TimeInterval) async {
        preconditionFailure("Borrowed trailer playback must never replace its owner's item.")
    }
    func makeVideoOutputView() -> UIView { surface }
    func play() {
        guard isActive else { return }
        player.playImmediately(atRate: Float(controls.playbackSpeed))
    }
    func pause() {
        guard isActive else { return }
        player.pause()
    }
    func seekApplyPaused(_ paused: Bool) {
        guard isActive else { return }
        controls.intendsPause = paused
        controls.isPaused = paused
        if paused { pause() } else { play() }
    }
    func togglePlayPause() {
        guard isActive else { return }
        if duration > 0, currentTime >= duration - 0.1 {
            controls.intendsPause = false
            seeks.requestSeek(to: 0)
        } else {
            seekApplyPaused(!controls.intendsPause)
        }
    }
    func seek(to seconds: TimeInterval) async {
        guard isActive, seconds.isFinite else { return }
        let completed = await player.seek(
            to: CMTime(seconds: max(0, min(seconds, duration)), preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        )
        if !completed, !seekDidStop, !Task.isCancelled {
            PlozzLog.playback.error("Borrowed trailer seek was interrupted")
        }
    }
    func stop() {
        guard !seekDidStop else { return }
        seekDidStop = true
        seeks.cancelAll()
        if controls.isSeeking, player.currentItem === item { item?.cancelPendingSeeks() }
    }
    func setPlaybackSpeed(_ rate: Double) {
        guard isActive, rate.isFinite else { return }
        controls.playbackSpeed = min(max(rate, 0.25), maximumPlaybackSpeed)
        if seekIntendsPlayback { play() }
    }
    func setAudioDelay(_ seconds: TimeInterval) {}
    func setSubtitleDelay(_ seconds: TimeInterval) {}
    func setDialogEnhanceEnabled(_ enabled: Bool) {}
    func selectAudioTrack(_ track: MediaTrack?) {}
    func selectSubtitleTrack(_ track: MediaTrack?) {}
    private func finite(_ value: Double) -> Double { value.isFinite ? max(0, value) : 0 }
}
#endif
