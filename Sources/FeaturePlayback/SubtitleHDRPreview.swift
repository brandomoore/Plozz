#if canImport(UIKit) && canImport(AVFoundation)
import AVFoundation
import CoreNetworking
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class SubtitleHDRPreview {
    enum State: Equatable {
        case idle, loading, ready
        case failed(Failure)
    }

    enum Failure: Equatable {
        case missingAsset, playback, displayOwned, displayCriteria, startupTimedOut

        var message: LocalizedStringResource {
            switch self {
            case .missingAsset: "The HDR preview scene is unavailable."
            case .playback: "The HDR preview scene could not be played."
            case .displayOwned: "Stop the other video before starting an HDR preview."
            case .displayCriteria: "HDR display matching could not be prepared."
            case .startupTimedOut: "The HDR preview did not become ready."
            }
        }
    }

    static var assetURL: URL? {
        Bundle.module.url(forResource: "SubtitleHDRPreview", withExtension: "mp4")
    }

    private(set) var state: State = .idle
    @ObservationIgnored private let assetURLProvider: @MainActor () -> URL?
    @ObservationIgnored private var player: AVQueuePlayer?
    @ObservationIgnored private var looper: AVPlayerLooper?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var failureObserver: NSObjectProtocol?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var wantsAnimation = true
    @ObservationIgnored private var criteriaRequested = false
    @ObservationIgnored private var surface: SubtitleHDRVideoView?
    @ObservationIgnored private var startupTimeout: Task<Void, Never>?
    #if os(tvOS)
    @ObservationIgnored private let displayCriteria = NativeDisplayCriteriaController(requiresUnownedTarget: true)
    #endif

    init(assetURL: @escaping @MainActor () -> URL? = { SubtitleHDRPreview.assetURL }) {
        assetURLProvider = assetURL
        #if os(tvOS)
        displayCriteria.onOwnershipConflict = { [weak self] in self?.fail(.displayOwned) }
        displayCriteria.onCriteriaFailure = { [weak self] in self?.fail(.displayCriteria) }
        displayCriteria.onCriteriaRequested = { [weak self] in
            self?.criteriaRequested = true
            self?.updateReadyState()
        }
        #endif
    }

    deinit {
        startupTimeout?.cancel()
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        #if os(tvOS)
        let criteria = displayCriteria
        Task { @MainActor in criteria.stop() }
        #endif
    }

    func start(animate: Bool) {
        wantsAnimation = animate
        if player != nil {
            applyTransport()
            return
        }
        guard let url = assetURLProvider() else {
            fail(.missingAsset)
            return
        }
        generation += 1
        let stamp = generation
        state = .loading
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.automaticallyWaitsToMinimizeStalling = false
        self.player = player
        startupTimeout = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(15))
            } catch is CancellationError {
                return
            } catch {
                PlozzLog.playback.error("HDR preview startup timer failed.")
                return
            }
            guard let self, self.generation == stamp, self.state == .loading else { return }
            self.fail(.startupTimedOut)
        }
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.appliesPerFrameHDRDisplayMetadata = true
        let looper = AVPlayerLooper(player: player, templateItem: item)
        self.looper = looper
        surface?.playerLayer.player = player
        observations.append(player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.generation == stamp else { return }
                self.observeCurrentItem()
            }
        })
        observations.append(looper.observe(\.status, options: [.initial, .new]) { [weak self] looper, _ in
            guard looper.status == .failed else { return }
            Task { @MainActor in
                guard let self, self.generation == stamp else { return }
                self.fail(.playback)
            }
        })
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.generation == stamp,
                      let failed = notification.object as? AVPlayerItem,
                      failed === self.player?.currentItem else { return }
                self.fail(.playback)
            }
        }
        #if os(tvOS)
        displayCriteria.attach(to: surface?.window)
        displayCriteria.configure(asset: asset, fallback: nil)
        #else
        criteriaRequested = true
        #endif
        applyTransport()
        PlozzLog.playback.debug("Started local HDR10 subtitle preview")
    }

    func stop() {
        releaseResources()
        state = .idle
    }

    func makeSurface() -> SubtitleHDRVideoView {
        if let surface { return surface }
        let surface = SubtitleHDRVideoView()
        surface.owner = self
        surface.playerLayer.player = player
        self.surface = surface
        return surface
    }

    func surfaceWindowChanged(_ window: UIWindow?) {
        #if os(tvOS)
        displayCriteria.attach(to: window)
        #endif
        updateReadyState()
    }

    func surfaceFrameChanged() { updateReadyState() }

    private func observeCurrentItem() {
        itemObservation = nil
        guard let item = player?.currentItem else { return }
        let stamp = generation
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
            Task { @MainActor in
                guard let self, self.generation == stamp, item === self.player?.currentItem else { return }
                if item?.status == .failed { self.fail(.playback) }
                else { self.updateReadyState() }
            }
        }
    }

    private func updateReadyState() {
        guard player != nil else { return }
        if criteriaRequested, player?.currentItem?.status == .readyToPlay,
           surface?.playerLayer.isReadyForDisplay == true {
            if state != .ready { state = .ready }
            startupTimeout?.cancel()
            startupTimeout = nil
        }
        applyTransport()
    }

    private func applyTransport() {
        // A paused preview still needs its first decoded frame.
        if wantsAnimation || surface?.playerLayer.isReadyForDisplay != true {
            player?.play()
        } else {
            player?.pause()
        }
    }

    private func fail(_ failure: Failure) {
        releaseResources()
        state = .failed(failure)
        PlozzLog.playback.error("HDR subtitle preview failed: \(String(describing: failure))")
    }

    private func releaseResources() {
        generation += 1
        startupTimeout?.cancel()
        startupTimeout = nil
        observations.removeAll()
        itemObservation = nil
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
            self.failureObserver = nil
        }
        looper?.disableLooping()
        looper = nil
        player?.pause()
        player?.removeAllItems()
        surface?.playerLayer.player = nil
        player = nil
        criteriaRequested = false
        #if os(tvOS)
        displayCriteria.stop()
        #endif
    }
}

@MainActor
final class SubtitleHDRVideoView: UIView {
    weak var owner: SubtitleHDRPreview?
    private var readiness: NSKeyValueObservation?
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    init() {
        super.init(frame: .zero)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    private func configureView() {
        isUserInteractionEnabled = false
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspectFill
        readiness = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.owner?.surfaceFrameChanged() }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        owner?.surfaceWindowChanged(window)
    }
}

struct SubtitleHDRVideoSurface: UIViewRepresentable {
    let preview: SubtitleHDRPreview
    func makeUIView(context: Context) -> SubtitleHDRVideoView { preview.makeSurface() }
    func updateUIView(_ view: SubtitleHDRVideoView, context: Context) {}
}
#endif
