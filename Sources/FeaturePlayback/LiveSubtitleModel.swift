#if canImport(SwiftUI)
import SwiftUI
import AVFoundation
import CoreGraphics
import CoreModels
import CoreNetworking

/// The live bridge between parsed subtitle cues and the owned
/// ``SubtitleOverlayView`` during real playback.
///
/// It holds the active ``SubtitleCueTimeline`` for the primary (and optional
/// secondary/dual) track plus the resolved ``SubtitleStyle``, and exposes the
/// currently-on-screen cues as observable state. A display-link in the player
/// container calls ``tick(_:)`` every frame with the engine clock; the timelines
/// recompute the active window cheaply (O(log n + k)) and this model only
/// publishes a new cue array when a cue boundary is crossed or a live payload
/// changes, so SwiftUI can idle while an unchanged line is held.
///
/// This is the runtime counterpart to the design's "engines emit cues, Plozz
/// draws them" inversion: the model is fed by whatever produced the cues (a
/// provider sidecar parsed by ``SubtitleCueParser`` today, an AetherEngine cue
/// stream later) and is completely independent of the playback engine.
@MainActor
@Observable
public final class LiveSubtitleModel {
    /// Cues on screen for the primary track right now (already time-filtered).
    public private(set) var primary: [SubtitleCue] = []
    /// Cues on screen for an optional secondary (dual-subtitle) track.
    public private(set) var secondary: [SubtitleCue] = []
    /// `true` while a secondary (dual) subtitle track is actively selected — a
    /// sidecar timeline or an engine live-feed. The overlay reserves the second
    /// dual-subtitle lane only while this holds, so a *persisted* `style.secondary`
    /// (dual appearance the viewer configured in an earlier session) can't reserve
    /// a phantom empty lane — and shift the primary line — on a later
    /// single-subtitle playback.
    public private(set) var hasSecondaryTrack: Bool = false
    /// The resolved appearance the overlay renders with.
    public var style: SubtitleStyle = .default
    /// Whether the current video frame is HDR, so the overlay can clamp luminance.
    public var isHDR: Bool = false
    /// On-screen rect of the video image (for bitmap cues / precise placement);
    /// `nil` fills the container, which is correct for text dialogue.
    public var videoRect: CGRect?
    public var activePictureRect: CGRect?
    /// Unstretched picture aspect when the video plane is scaled nonuniformly.
    public var sourceVideoAspectRatio: Double?
    public let controlsLayout = SubtitleControlsLayout()

    @ObservationIgnored private var primaryTimeline: SubtitleCueTimeline?
    @ObservationIgnored private var secondaryTimeline: SubtitleCueTimeline?
    @ObservationIgnored private var storedOffset: Double = 0
    /// `true` when an engine pushes its own already-windowed active cues
    /// (AetherEngine/Plozzigen) instead of us driving a sidecar timeline. In this
    /// mode there is no `SubtitleCueTimeline` and ``tick(_:)`` time-filters the
    /// pushed buffer — the engine emits the decoded *read-ahead* cue set (not just
    /// the on-screen line), so the model selects the cues active at the playhead.
    @ObservationIgnored private var isLiveFeed = false
    @ObservationIgnored private var liveFeedPermitsTimingOffsets = true
    /// The full decoded cue buffer most recently pushed by a live engine feed.
    @ObservationIgnored private var liveCues: [SubtitleCue] = []
    /// Live-feed state for the SECONDARY (dual) channel, mirroring the primary
    /// live feed above. Lets an engine that decodes a second subtitle stream
    /// (AetherEngine/Plozzigen) push its cues for the dual line — the path that
    /// makes dual subtitles work for embedded tracks with no sidecar URL.
    @ObservationIgnored private var isSecondaryLiveFeed = false
    @ObservationIgnored private var secondaryLiveCues: [SubtitleCue] = []
    /// Last clock value seen by ``tick(_:)``, so a fresh ``updateLiveCues(_:)``
    /// push can re-seat against the current playhead between ticks.
    @ObservationIgnored private var lastTickTime: Double = 0

    public init() {}

    /// `true` when a primary (or secondary) cue stream is loaded, or an engine is
    /// live-feeding cues, so the host can decide whether the overlay needs driving.
    public var hasContent: Bool {
        primaryTimeline != nil || secondaryTimeline != nil || isLiveFeed || isSecondaryLiveFeed
    }

    /// Whether the overlay owns the primary subtitle. Native presentation
    /// events can be drawn here without promising seek-safe timing offsets.
    public var rendersPrimary: Bool {
        primaryTimeline != nil || isLiveFeed
    }

    // HDR white-point multiplication is a color operation, not opacity. Leave
    // those frames on the existing overlay rather than dimming their alpha.
    var permitsScheduledASSArtwork: Bool {
        isLiveFeed && (!isHDR || style.hdrLuminanceScale == 1)
    }
    public var supportsPrimaryTimingOffset: Bool {
        primaryTimeline != nil || (isLiveFeed && liveFeedPermitsTimingOffsets)
    }

    /// Global sync offset in seconds (positive = show subtitles later). Applied to
    /// both tracks and forces the next ``tick(_:)`` to recompute.
    public var offset: Double {
        get { storedOffset }
        set {
            storedOffset = newValue
            primaryTimeline?.offset = newValue
            secondaryTimeline?.offset = newValue
        }
    }

    /// Loads (or, with `nil`, clears) the primary cue stream. The on-screen set is
    /// reset to empty until the next ``tick(_:)`` seats the active cues.
    public func loadPrimary(_ stream: SubtitleCueStream?) {
        isLiveFeed = false
        if let stream {
            primaryTimeline = SubtitleCueTimeline(stream: stream, offset: storedOffset)
        } else {
            primaryTimeline = nil
        }
        primary = []
    }

    /// Switches the model into **live-feed** mode: drops any sidecar timeline and
    /// lets an engine push its decoded cue buffer via ``updateLiveCues(_:)``, which
    /// ``tick(_:)`` then time-filters against the playhead. Used by Plozzigen
    /// (AetherEngine), which decodes subtitles itself.
    public func beginLiveFeed(permitsTimingOffsets: Bool = true) {
        isLiveFeed = true
        liveFeedPermitsTimingOffsets = permitsTimingOffsets
        primaryTimeline = nil
        liveCues = []
        primary = []
        // NOTE: deliberately does NOT touch the secondary channel. A primary
        // track change routes through here, and the dual line (sidecar timeline
        // OR its own engine live feed) must survive that switch. Full resets go
        // through `clear()`.
    }

    /// Replaces the live cue buffer from an engine feed and re-seats the on-screen
    /// set against the current playhead. No-op unless ``beginLiveFeed()`` is
    /// active, so a stray late callback can't draw over a sidecar timeline or a
    /// cleared overlay.
    public func updateLiveCues(_ cues: [SubtitleCue]) {
        guard isLiveFeed else { return }
        liveCues = cues
        recomputeLiveActive(at: lastTickTime)
    }

    /// Seats the live cues visible at `time` (engine playhead), republishing
    /// `primary` only when the active set changes.
    private func recomputeLiveActive(at time: Double) {
        let active = liveCues.active(at: time, offset: liveFeedPermitsTimingOffsets ? storedOffset : 0)
        if active != primary {
            primary = active
        }
    }

    /// Loads (or clears) the secondary/dual cue stream. Switches the secondary
    /// channel out of engine-live mode: a parsed sidecar timeline takes over.
    public func loadSecondary(_ stream: SubtitleCueStream?) {
        isSecondaryLiveFeed = false
        secondaryLiveCues = []
        if let stream {
            secondaryTimeline = SubtitleCueTimeline(stream: stream, offset: storedOffset)
        } else {
            secondaryTimeline = nil
        }
        hasSecondaryTrack = stream != nil
        secondary = []
    }

    /// Switches the SECONDARY (dual) channel into engine live-feed mode: drops any
    /// sidecar timeline and lets an engine push its decoded second-stream cues via
    /// ``updateSecondaryLiveCues(_:)``. This is how dual subtitles work for
    /// embedded tracks (Plex direct-play) that have no fetchable sidecar URL —
    /// AetherEngine/Plozzigen demuxes and decodes the second track itself.
    public func beginSecondaryLiveFeed() {
        isSecondaryLiveFeed = true
        secondaryTimeline = nil
        secondaryLiveCues = []
        hasSecondaryTrack = true
        secondary = []
    }

    /// Replaces the secondary live cue buffer from an engine feed and re-seats the
    /// on-screen set. No-op unless ``beginSecondaryLiveFeed()`` is active.
    public func updateSecondaryLiveCues(_ cues: [SubtitleCue]) {
        guard isSecondaryLiveFeed else { return }
        secondaryLiveCues = cues
        recomputeSecondaryLiveActive(at: lastTickTime)
    }

    /// Seats the secondary live cues visible at `time`, republishing `secondary`
    /// only when the active set changes.
    private func recomputeSecondaryLiveActive(at time: Double) {
        let active = secondaryLiveCues.active(at: time, offset: storedOffset)
        if active != secondary {
            secondary = active
        }
    }

    /// Drops all cue streams and clears the screen.
    public func clear() {
        isLiveFeed = false
        isSecondaryLiveFeed = false
        hasSecondaryTrack = false
        primaryTimeline = nil
        secondaryTimeline = nil
        liveCues = []
        secondaryLiveCues = []
        primary = []
        secondary = []
    }

    /// Advance to playback `time` (seconds). Republishes the active cues for a
    /// track only when its on-screen set changes, so a 60 Hz call is cheap.
    public func tick(_ time: Double) {
        lastTickTime = time
        if isLiveFeed {
            // Live feed drives the PRIMARY only (the engine decodes it). Fall
            // through so the secondary sidecar timeline below still advances.
            recomputeLiveActive(at: time)
        } else if let p = primaryTimeline, p.update(to: time) {
            primary = p.active
        }
        // The secondary/dual line is either its own engine live feed (embedded
        // track decoded by the engine) or a sidecar timeline — independent of the
        // primary's source. Seat whichever is active every tick, including while
        // the primary is a live feed, or the second line never shows.
        if isSecondaryLiveFeed {
            recomputeSecondaryLiveActive(at: time)
        } else if let s = secondaryTimeline, s.update(to: time) {
            secondary = s.active
        }
    }
}

/// Thin SwiftUI wrapper that observes a ``LiveSubtitleModel`` and feeds the pure
/// ``SubtitleOverlayView``. Hosted above the engine's video surface (below the
/// transport controls) in the player container.
struct LiveSubtitleOverlay: View {
    let model: LiveSubtitleModel
    let controls: PlayerControlsModel
    var scheduledArtwork: ScheduledASSArtworkView? = nil

    var body: some View {
        let style = SystemCaptionStyle.shared.resolved(model.style)
        SubtitleOverlayView(
            primary: model.primary,
            secondary: model.secondary,
            secondaryActive: model.hasSecondaryTrack,
            style: style,
            isHDR: model.isHDR,
            videoRect: model.videoRect,
            activePictureRect: model.activePictureRect,
            sourceVideoAspectRatio: model.sourceVideoAspectRatio,
            controlsFrames: controls.subtitleLayout.frames
        )
        .background {
            if let scheduledArtwork {
                GeometryReader { geo in
                    ScheduledASSArtworkSurface(view: scheduledArtwork, layout: .init(
                        style: style, videoRect: model.videoRect, activePictureRect: model.activePictureRect,
                        sourceAspectRatio: model.sourceVideoAspectRatio.map { CGFloat($0) },
                        controls: SubtitleOverlayGeometry.localControls(
                            controls.subtitleLayout.frames, style: style, origin: geo.frame(in: .global).origin
                        )
                    ))
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .ignoresSafeArea()
    }
}

private struct ScheduledASSArtworkSurface: UIViewRepresentable {
    let view: ScheduledASSArtworkView
    let layout: SubtitleOverlayGeometry.BitmapLayout

    func makeUIView(context: Context) -> ScheduledASSArtworkView {
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: ScheduledASSArtworkView, context: Context) {
        uiView.bitmapLayout = layout
    }
}

/// SwiftUI supplies geometry, not frame timing. A prerendered group is visible
/// precisely on its half-open interval on the native player's item timeline.
final class ScheduledASSArtworkView: UIView, ScheduledASSArtworkSink {
    private struct Frame {
        let start: Double
        let group: CALayer
        let images: [SubtitleImage]
    }
    private var timeline: AVSynchronizedLayer?
    private var frames: [Frame] = []
    // One active frame, a short preroll, and a little history for the compositor.
    // Bound retention even if the native item clock is stopped or invalid.
    private static let maximumFrames = 64

    var bitmapLayout: SubtitleOverlayGeometry.BitmapLayout? {
        didSet {
            guard oldValue != bitmapLayout else { return }
            alpha = CGFloat(bitmapLayout?.style.opacity ?? 1)
            setNeedsLayout()
        }
    }

    func display(_ cues: [CoreModels.SubtitleCue], at itemTime: Double, item: AVPlayerItem) {
        guard itemTime.isFinite else { reset(); return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if timeline?.playerItem !== item {
            reset()
            let timeline = AVSynchronizedLayer(playerItem: item)
            timeline.frame = bounds
            layer.addSublayer(timeline)
            self.timeline = timeline
        }
        let start = max(AVCoreAnimationBeginTimeAtZero, itemTime)
        // A correction at an already queued deadline supersedes that tail.
        while let last = frames.last, last.start >= start {
            frames.removeLast().group.removeFromSuperlayer()
        }
        pruneElapsedFrames()
        if frames.count == Self.maximumFrames {
            // Coalesce the furthest prefetched change, not the visible frame.
            frames.removeLast().group.removeFromSuperlayer()
        }
        if let previous = frames.last { setVisibility(of: previous, until: start) }
        let group = CALayer()
        group.frame = bounds
        group.opacity = 0
        let images = cues.compactMap { cue -> SubtitleImage? in
            guard case .image(let image) = cue.body else { return nil }
            let region = CALayer()
            region.contents = image.cgImage
            group.addSublayer(region)
            return image
        }
        let frame = Frame(start: start, group: group, images: images)
        layoutRegions(of: frame)
        timeline?.addSublayer(group)
        setVisibility(of: frame, until: nil)
        frames.append(frame)
    }

    private func setVisibility(of frame: Frame, until end: Double?) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 1
        animation.beginTime = frame.start
        animation.duration = end.map { $0 - frame.start } ?? 1
        animation.fillMode = end == nil ? .forwards : .removed
        animation.isRemovedOnCompletion = false
        frame.group.add(animation, forKey: "interval")
    }

    func pruneElapsedFrames() {
        guard frames.count > 1, let now = timeline?.playerItem?.currentTime().seconds, now.isFinite else { return }
        while frames.count > 1, frames[1].start < now - 0.5 {
            frames.removeFirst().group.removeFromSuperlayer()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let timeline else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        timeline.frame = bounds
        for frame in frames {
            frame.group.frame = bounds
            layoutRegions(of: frame)
        }
        CATransaction.commit()
    }

    private func layoutRegions(of frame: Frame) {
        guard let bitmapLayout else { return }
        let rects = bitmapLayout.frames(for: frame.images, in: bounds)
        for (region, rect) in zip(frame.group.sublayers ?? [], rects) { region.frame = rect }
    }

    func reset() {
        timeline?.removeFromSuperlayer()
        timeline?.playerItem = nil
        timeline = nil
        frames.removeAll()
    }
}
#endif
