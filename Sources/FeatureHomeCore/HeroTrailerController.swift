#if canImport(AVFoundation)
import AVFoundation
import CoreImage
import CoreModels
import CoreNetworking
import Foundation
import Observation
#if canImport(UIKit)
import UIKit
import SwiftUI
#endif

/// A fast, shared hero-trailer source already resolved to a directly playable URL.
/// Home intentionally accepts only local/server-resolved sources here — never
/// a YouTube id that would require the slow/heavy on-device extraction path.
public struct HeroTrailerSource: Sendable, Equatable {
    public let ownerItemID: String
    public let trailerItemID: String
    public let url: URL
    public let duration: TimeInterval

    public init(
        ownerItemID: String,
        trailerItemID: String,
        url: URL,
        duration: TimeInterval
    ) {
        self.ownerItemID = ownerItemID
        self.trailerItemID = trailerItemID
        self.url = url
        self.duration = duration
    }
}

public typealias HeroTrailerResolving = @Sendable (MediaItem) async -> HeroTrailerSource?

public enum HeroTrailerSurfaceRole: Sendable, Equatable {
    case home
    case detail
    case featured
}

/// Shared, app-level owner of the **hero trailer** — one muted (by default)
/// `AVPlayer` whose video layer is rendered by both the Home hero carousel and
/// the detail-page hero. Hoisting it above both surfaces (like
/// ``ThemeMusicController``) is what lets a trailer that started in the Home hero
/// keep playing when the user opens the detail page: only the foreground metadata
/// swaps; the same player keeps rolling behind it.
///
/// Deliberately bounded for memory safety (the Apple TV per-process ceiling is
/// unforgiving): exactly ONE `AVPlayer`, one in-flight item, torn down on stop.
/// The Home carousel only ever feeds it a **fast** (local / server-resolved)
/// trailer URL — never an on-device YouTube extraction — so it never spins up the
/// heavy JavaScriptCore path on the rotating hero.
@MainActor
@Observable
public final class HeroTrailerController {
    /// The item id whose trailer is currently loaded/playing (`nil` when idle).
    public var currentItemID: String? { playbackIdentity?.itemID }
    private var playbackIdentity: (itemID: String, detailItemID: String?)?
    /// Whether a trailer item is actively playing (has begun, not ended/stopped).
    public private(set) var isPlaying = false
    public private(set) var isReady = false
    public private(set) var isPaused = false
    #if canImport(UIKit)
    private var backgroundObserver: (any NSObjectProtocol)?
    #endif
    /// The live (session) mute state of the trailer. Initialized from the active
    /// surface's mute *default* when a trailer starts, but the in-hero mute button
    /// flips THIS (a transient session override) — it never rewrites the saved
    /// default, so muting/unmuting a playing trailer doesn't change the setting.
    public private(set) var isMuted = true
    public private(set) var pauseStartedAt: Date?
    public private(set) var activeSurfaceRole: HeroTrailerSurfaceRole?
    public private(set) var featuredOwnerID: UUID?
    public var isFeaturedReserved: Bool { featuredOwnerID != nil }
    /// The resolved trailer duration in seconds once known (`0` until ready).
    /// Drives the hero's dwell length so the progress bar spans the full trailer.
    public private(set) var duration: TimeInterval = 0
    /// One frozen frame captured immediately before Home pushes detail. It masks
    /// the few-frame gap while the shared player moves between AVPlayerLayers.
    /// Bounded to exactly one image and replaced on every handoff.
    public private(set) var handoffImage: UIImage?

    /// The underlying player, exposed only so a ``HeroTrailerVideoLayer`` can
    /// attach an `AVPlayerLayer`. Engine-agnostic callers must not depend on it.
    public let player = AVPlayer()
    #if canImport(UIKit)
    /// Move the decoded surface, not the player between competing display layers.
    @ObservationIgnored fileprivate let surfaceView = HeroTrailerPlayerSurfaceView()
    @ObservationIgnored private weak var homeHost: HeroTrailerVideoLayer.HostView?
    @ObservationIgnored private weak var detailHost: HeroTrailerVideoLayer.HostView?
    @ObservationIgnored private weak var featuredHost: HeroTrailerVideoLayer.HostView?
    #endif

    /// Fired on the main actor when the current trailer plays through to its end,
    /// so the hero can advance to the next item. Reset per load.
    private var endHandlerOwnerID: String?
    private var endHandler: (@MainActor () -> Void)?

    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var hasStartedPlayback = false
    private var autoplayWhenReady = false
    private var requestedPaused = false
    @ObservationIgnored private var suspendedHeroPause: Bool?
    private var playbackOwners = Set<UUID>()
    public var isPlaybackSuppressed: Bool { !playbackOwners.isEmpty }
    private var captionSelectionTask: Task<Void, Never>?
    @ObservationIgnored private var videoOutput: AVPlayerItemVideoOutput?
    @ObservationIgnored private let imageContext = CIContext(options: nil)

    public init() {
        // Never let the trailer claim the Now-Playing transport or interrupt
        // music; it's ambient. Muting is applied per play() call.
        player.actionAtItemEnd = .pause
        player.appliesMediaSelectionCriteriaAutomatically = false
        #if canImport(UIKit)
        surfaceView.playerLayer.player = player
        observeAppLifecycle()
        #endif
    }

    #if canImport(UIKit)
    /// Stop an ambient trailer once the app is no longer on screen.
    ///
    /// Nothing did this: leaving the app left the hero's trailer streaming and
    /// decoding, which measured as the single largest remaining draw — the app's
    /// steady CPU swung between roughly 1% and 18% purely on whether a trailer
    /// was running. It is decoration for a screen nobody is looking at, so it
    /// should not survive leaving that screen.
    ///
    /// Deliberately `didEnterBackground` rather than `willResignActive`: the
    /// latter also fires for a pulled-down notification shade or the app
    /// switcher, where the hero is still on screen and stopping would read as a
    /// glitch.
    private func observeAppLifecycle() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying || self.currentItemID != nil || self.isFeaturedReserved else {
                    return
                }
                self.stop()
            }
        }
    }
    #endif

    /// Reads the source's actual AVFoundation duration before the hero timeline
    /// starts. Using the real stream duration keeps the wall-clock gauge and
    /// end-of-item advance on the same clock.
    public static func resolvedDuration(of url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    /// Whether this controller is already presenting `itemID` (so a hero→detail
    /// hand-off for the same title can keep playing rather than reload).
    public func isShowing(_ itemID: String) -> Bool {
        currentItemID != nil && (currentItemID == itemID || playbackIdentity?.detailItemID == itemID)
    }

    /// Marks the frontmost renderer. Touch surfaces use this to keep a Home →
    /// detail handoff alive while still stopping playback when Home truly leaves.
    public func claimSurface(_ role: HeroTrailerSurfaceRole, itemID: String) {
        guard !isFeaturedReserved || role == .featured else { return }
        guard currentItemID == nil || isShowing(itemID) else { return }
        if activeSurfaceRole != role {
            HandoffDiagnostics.emit("trailer CLAIM role=\(role) item=\(HandoffDiagnostics.correlationID(itemID))")
        }
        activeSurfaceRole = role
        #if canImport(UIKit)
        moveSurfaceToActiveHost()
        #endif
    }

    public func isClaimed(by role: HeroTrailerSurfaceRole, itemID: String) -> Bool {
        activeSurfaceRole == role && isShowing(itemID)
    }

    /// Transfer before pushing detail, so Home's disappearance cannot tear down
    /// the shared item regardless of SwiftUI lifecycle callback ordering.
    public func handoffToDetail(itemID: String, destinationItemID: String? = nil) {
        guard isShowing(itemID), !isFeaturedReserved else { return }
        // The router supplies the exact source selected for this detail page.
        // Keep Home's identity too; the same title can have different server IDs.
        playbackIdentity?.detailItemID = destinationItemID
        HandoffDiagnostics.emit("trailer HANDOFF item=\(HandoffDiagnostics.correlationID(itemID)) destination=\(HandoffDiagnostics.correlationID(destinationItemID))")
        claimSurface(.detail, itemID: itemID)
        endHandlerOwnerID = nil
        endHandler = nil
        setPaused(false)
        startPrepared()
    }

    public func releaseSurface(_ role: HeroTrailerSurfaceRole) {
        guard activeSurfaceRole == role else { return }
        activeSurfaceRole = nil
    }

    /// Installs the current frontmost surface's end handler. Ownership prevents
    /// a hidden Home carousel from clearing/replacing the detail page's handler.
    public func setEndHandler(
        ownerID: String,
        _ handler: @escaping @MainActor () -> Void
    ) {
        guard !isFeaturedReserved else { return }
        endHandlerOwnerID = ownerID
        endHandler = handler
    }

    public func clearEndHandler(ownerID: String) {
        guard endHandlerOwnerID == ownerID else { return }
        endHandlerOwnerID = nil
        endHandler = nil
    }

    /// Loads and plays `resolvedURL` as the trailer for `itemID`. No-op (keeps
    /// playing) if the same item is already showing. `muted` follows the profile's
    /// trailer-audio preference.
    public func play(itemID: String, resolvedURL: URL, muted: Bool, featuredOwner: UUID? = nil) {
        guard !isPlaybackSuppressed, featuredOwnerID == featuredOwner else { return }
        prepare(itemID: itemID, resolvedURL: resolvedURL, muted: muted, featuredOwner: featuredOwner)
        autoplayWhenReady = true
        beginPlaybackIfReady()
    }

    /// Queues and preloads a trailer without starting it. Home uses this to make
    /// the item ready behind the still image, then starts one exact 3s+duration
    /// timeline only after readiness is known.
    public func prepare(itemID: String, resolvedURL: URL, muted: Bool, featuredOwner: UUID? = nil) {
        guard !isPlaybackSuppressed, featuredOwnerID == featuredOwner else { return }
        if currentItemID == itemID, player.currentItem != nil {
            player.isMuted = muted
            isMuted = muted
            return
        }

        stopPlayback(resetItem: false)
        activateSession()

        let item = AVPlayerItem(url: resolvedURL)
        let output = AVPlayerItemVideoOutput(
            pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_32BGRA)
            ]
        )
        item.add(output)
        videoOutput = output
        player.isMuted = muted
        isMuted = muted
        hasStartedPlayback = false
        autoplayWhenReady = false
        requestedPaused = isPaused
        isReady = false
        duration = 0
        observeEnd(of: item)
        observeStatus(of: item)
        player.replaceCurrentItem(with: item)
        disableCaptions(on: item)

        playbackIdentity = (itemID, nil)
        HandoffDiagnostics.emit("trailer QUEUED item=\(HandoffDiagnostics.correlationID(itemID)) owner=\(HandoffDiagnostics.correlationID(endHandlerOwnerID))")
        PlozzLog.app.info("Hero trailer: queued item=\(itemID) muted=\(muted) url=\(PlozzLog.redact(url: resolvedURL))")
    }

    /// Starts a previously prepared item (or arms it to start when ready).
    public func startPrepared(featuredOwner: UUID? = nil) {
        guard !isPlaybackSuppressed, featuredOwnerID == featuredOwner else { return }
        autoplayWhenReady = true
        beginPlaybackIfReady()
    }

    /// Applies a live mute change (e.g. the user flips the muted toggle) without
    /// reloading.
    public func setMuted(_ muted: Bool, featuredOwner: UUID? = nil) {
        guard featuredOwnerID == featuredOwner else { return }
        player.isMuted = muted
        isMuted = muted
    }

    /// Flip the live (session) mute — what the in-hero mute button calls. Transient:
    /// it does NOT touch the persisted mute default.
    public func toggleMuted() {
        setMuted(!isMuted)
    }

    /// Captures the currently displayed video frame for a seamless layer handoff.
    /// A missing frame never authorizes artwork over an active trailer.
    public func captureHandoffFrame() async {
        let capturedItem = player.currentItem
        let itemTime = player.currentTime()
        if let image = decodedFrame() {
            handoffImage = image
            return
        }

        // Decode concurrently with navigation; ignore a frame from a player item
        // that was replaced while the generator was working.
        guard let asset = capturedItem?.asset else {
            handoffImage = nil
            return
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(
            seconds: 0.05,
            preferredTimescale: 600
        )
        generator.requestedTimeToleranceAfter = CMTime(
            seconds: 0.05,
            preferredTimescale: 600
        )
        do {
            let generated = try await generator.image(at: itemTime)
            guard player.currentItem === capturedItem else { return }
            handoffImage = UIImage(cgImage: generated.image)
        } catch {
            guard player.currentItem === capturedItem else { return }
            PlozzLog.app.debug("Hero trailer handoff frame unavailable: \(String(describing: error))")
            handoffImage = nil
        }
    }

    private func decodedFrame() -> UIImage? {
        guard let videoOutput,
              let buffer = videoOutput.copyPixelBuffer(
                forItemTime: player.currentTime(), itemTimeForDisplay: nil
              ) else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        return imageContext.createCGImage(image, from: image.extent).map { UIImage(cgImage: $0) }
    }

    /// Freezes/resumes the ambient trailer in lockstep with the hero's
    /// auto-advance pause so the wall-clock progress gauge and picture never
    /// drift apart during remote interaction or recede.
    public func setPaused(
        _ paused: Bool,
        surfaceRole: HeroTrailerSurfaceRole? = nil,
        featuredOwner: UUID? = nil
    ) {
        if isFeaturedReserved, featuredOwner == nil {
            suspendedHeroPause = paused
            return
        }
        guard featuredOwnerID == featuredOwner else { return }
        if let surfaceRole, let activeSurfaceRole, surfaceRole != activeSurfaceRole { return }
        requestedPaused = paused
        applyPauseState()
    }

    /// A full player owns this hold until its media I/O has stopped. Surface
    /// timers, scrolling, and late trailer resolution cannot override it.
    public func suspendForPlayback(owner: UUID) {
        guard playbackOwners.insert(owner).inserted else { return }
        applyPauseState()
    }

    public func resumeAfterPlayback(owner: UUID) {
        guard playbackOwners.remove(owner) != nil else { return }
        applyPauseState()
    }

    private func applyPauseState() {
        let paused = requestedPaused || isPlaybackSuppressed
        if paused {
            if !isPaused { pauseStartedAt = .now }
            isPaused = true
        } else {
            isPaused = false
            pauseStartedAt = nil
        }
        guard currentItemID != nil else { return }
        if paused {
            player.pause()
        } else if hasStartedPlayback {
            player.play()
        }
    }

    /// Stops playback and releases the item. Called on navigate-away / advance /
    /// mode-off so the single player never lingers.
    public func stop() {
        featuredOwnerID = nil
        suspendedHeroPause = nil
        guard isPlaying || currentItemID != nil else { return }
        HandoffDiagnostics.emit("trailer STOP item=\(HandoffDiagnostics.correlationID(currentItemID)) owner=\(HandoffDiagnostics.correlationID(endHandlerOwnerID))")
        stopPlayback(resetItem: true)
        PlozzLog.app.info("Hero trailer: stopped")
    }

    /// Home cleanup cannot stop a trailer transferred to detail or a focused card.
    public func stopHero(ifShowing itemID: String? = nil) {
        guard !isFeaturedReserved, activeSurfaceRole != .detail else { return }
        if let itemID, !isShowing(itemID) { return }
        stop()
    }

    public func reserveFeaturedSurface(owner: UUID) -> Bool {
        guard !isPlaybackSuppressed, activeSurfaceRole != .detail else { return false }
        if featuredOwnerID == owner { return true }
        let heroPause = suspendedHeroPause ?? requestedPaused
        stop()
        endHandlerOwnerID = nil
        endHandler = nil
        featuredOwnerID = owner
        suspendedHeroPause = heroPause
        setPaused(false, featuredOwner: owner)
        return true
    }

    public func releaseFeaturedSurface(owner: UUID) {
        guard featuredOwnerID == owner else { return }
        let heroPause = suspendedHeroPause ?? false
        stop()
        setPaused(heroPause)
    }

    /// Stops only if the currently-loaded item is `itemID` (a scoped teardown so a
    /// stale view's disappear can't stop a trailer that already advanced).
    public func stop(ifShowing itemID: String, ownedBy ownerID: String? = nil) {
        guard isShowing(itemID) else { return }
        if let ownerID, ownerID != endHandlerOwnerID { return }
        stop()
    }

    #if canImport(UIKit)
    fileprivate func registerHost(_ host: HeroTrailerVideoLayer.HostView, role: HeroTrailerSurfaceRole) {
        guard host.window != nil else { return }
        switch role {
        case .home: homeHost = host
        case .detail: detailHost = host
        case .featured: featuredHost = host
        }
        moveSurfaceToActiveHost()
    }

    private func moveSurfaceToActiveHost() {
        let host: HeroTrailerVideoLayer.HostView?
        switch activeSurfaceRole {
        case .home: host = homeHost
        case .detail: host = detailHost
        case .featured: host = featuredHost
        case nil: host = nil
        }
        // Keep the outgoing picture until the receiving host actually mounts.
        guard let host, host.window != nil, host.controller === self,
              host.role == activeSurfaceRole, surfaceView.superview !== host else { return }
        let frame = decodedFrame() ?? handoffImage
        (surfaceView.superview as? HeroTrailerVideoLayer.HostView)?.holdFrame(frame)
        host.holdFrame(frame)
        HandoffDiagnostics.emit("trailer RENDER role=\(String(describing: activeSurfaceRole)) item=\(HandoffDiagnostics.correlationID(currentItemID))")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaceView.removeFromSuperview()
        host.addSubview(surfaceView)
        surfaceView.frame = host.bounds
        surfaceView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        CATransaction.commit()
    }
    #endif

    private func stopPlayback(resetItem: Bool) {
        hasStartedPlayback = false
        player.pause()
        captionSelectionTask?.cancel()
        captionSelectionTask = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        if resetItem {
            player.replaceCurrentItem(with: nil)
            videoOutput = nil
            handoffImage = nil
            isPlaying = false
            isReady = false
            requestedPaused = false
            isPaused = isPlaybackSuppressed
            pauseStartedAt = isPaused ? (pauseStartedAt ?? .now) : nil
            playbackIdentity = nil
            activeSurfaceRole = nil
            duration = 0
        }
    }

    private func disableCaptions(on item: AVPlayerItem) {
        captionSelectionTask = Task { @MainActor [weak self, weak item] in
            guard let item,
                  let group = try? await item.asset.loadMediaSelectionGroup(
                    for: .legible
                  ),
                  !Task.isCancelled,
                  self?.player.currentItem === item else {
                return
            }
            item.select(nil, in: group)
        }
    }

    private func beginPlaybackIfReady() {
        guard autoplayWhenReady, isReady, !requestedPaused, !isPlaybackSuppressed, !hasStartedPlayback else { return }
        hasStartedPlayback = true
        isPlaying = true
        player.seek(to: .zero)
        player.play()
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = false
                self.endHandler?()
            }
        }
    }

    private func observeStatus(of item: AVPlayerItem) {
        statusObservation?.invalidate()
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                switch item.status {
                case .readyToPlay:
                    let seconds = item.duration.seconds
                    if seconds.isFinite, seconds > 0 { self.duration = seconds }
                    self.isReady = true
                    self.beginPlaybackIfReady()
                case .failed:
                    let detail = item.error.map(String.init(describing:)) ?? "unknown"
                    PlozzLog.app.error("Hero trailer: failed error=\(detail)")
                    self.stop()
                default:
                    break
                }
            }
        }
    }

    private func activateSession() {
        #if !os(macOS)
        do {
            let session = AVAudioSession.sharedInstance()
            // Mix so a muted trailer never disturbs other audio; a sound-on trailer
            // still coexists (and theme music is blocked separately at the app level).
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            PlozzLog.app.error("Hero trailer: audio session activation failed error=\(String(describing: error))")
        }
        #endif
    }
}

#if canImport(UIKit)
fileprivate final class HeroTrailerPlayerSurfaceView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspectFill
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { nil }
}

/// Hosts the single persistent video layer only when this surface owns playback.
public struct HeroTrailerVideoLayer: UIViewRepresentable {
    private let controller: HeroTrailerController
    private let role: HeroTrailerSurfaceRole

    public init(
        controller: HeroTrailerController,
        role: HeroTrailerSurfaceRole
    ) {
        self.controller = controller
        self.role = role
    }

    public func makeUIView(context: Context) -> HostView {
        let host = HostView()
        attach(to: host)
        return host
    }

    public func updateUIView(_ uiView: HostView, context: Context) {
        attach(to: uiView)
    }

    private func attach(to host: HostView) {
        host.controller = controller
        host.role = role
        controller.registerHost(host, role: role)
    }

    public final class HostView: UIView {
        fileprivate weak var controller: HeroTrailerController?
        fileprivate var role: HeroTrailerSurfaceRole = .home
        private let heldFrame = UIImageView()

        public override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            heldFrame.contentMode = .scaleAspectFill
            heldFrame.clipsToBounds = true
            addSubview(heldFrame)
        }

        required init?(coder: NSCoder) { nil }

        fileprivate func holdFrame(_ image: UIImage?) {
            heldFrame.image = image
        }

        public override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { controller?.registerHost(self, role: role) }
        }

        public override func layoutSubviews() {
            super.layoutSubviews()
            subviews.forEach { $0.frame = bounds }
        }
    }
}
#endif
#endif
