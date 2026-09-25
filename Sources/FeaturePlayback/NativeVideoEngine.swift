#if canImport(AVFoundation)
import Foundation
import AVFoundation
import Observation
import CoreModels
import CoreNetworking
#if canImport(UIKit)
import UIKit
#endif
#if os(tvOS)
import AVKit
#endif

/// `AVPlayer`-backed implementation of `VideoEngine`.
///
/// This type contains all of the playback mechanics that `PlayerViewModel` used
/// to own directly — `AVURLAsset`/`AVPlayerItem` construction, caption styling,
/// resume seeking, the periodic time observer + report cadence, the
/// `AVAudioSession` configuration + route-change handling, default subtitle
/// selection, and the transcode-fallback *detection* hook — moved essentially
/// verbatim. The orchestration around it (resolving a `PlaybackRequest`,
/// reporting progress, deciding to re-resolve with a server transcode,
/// downloading subtitles) stays in `PlayerViewModel`, which drives this engine
/// through the `VideoEngine` protocol.
@MainActor
@Observable
public final class NativeVideoEngine: VideoEngine {
    // MARK: Observable state

    public private(set) var status: VideoEngineStatus = .idle
    public private(set) var isPaused: Bool = false

    /// Keep the display awake only while the player is genuinely advancing
    /// frames. `timeControlStatus == .playing` is `false` when paused, ended, or
    /// stalled waiting to buffer, so the screensaver/sleep is allowed in exactly
    /// those cases — matching the cross-engine policy.
    public var preventsDisplaySleep: Bool {
        player?.timeControlStatus == .playing
    }

    public var hasPresentedVideoFrame: Bool {
        #if canImport(UIKit)
        status == .ready && videoOutputView?.playerLayer.isReadyForDisplay == true
        #else
        false
        #endif
    }

    public var currentTime: TimeInterval {
        guard let seconds = player?.currentTime().seconds, seconds.isFinite else { return 0 }
        return max(0, seconds)
    }

    public var duration: TimeInterval {
        guard let seconds = player?.currentItem?.duration.seconds, seconds.isFinite else { return 0 }
        return max(0, seconds)
    }

    public private(set) var furthestObservedPosition: TimeInterval = 0

    /// Furthest buffered position across the item's loaded ranges, for the scrub
    /// bar's buffer fill. `0` when unknown.
    public var bufferedPosition: TimeInterval {
        guard let ranges = player?.currentItem?.loadedTimeRanges else { return 0 }
        var end: TimeInterval = 0
        for value in ranges {
            let range = value.timeRangeValue
            let rangeEnd = (range.start + range.duration).seconds
            if rangeEnd.isFinite { end = max(end, rangeEnd) }
        }
        return end
    }

    public var audioTracks: [MediaTrack] { request?.audioTracks ?? [] }
    public var subtitleTracks: [MediaTrack] { request?.subtitleTracks ?? [] }

    // MARK: Orchestration callbacks

    public var onProgress: (@MainActor () -> Void)?
    public var onFailure: (@MainActor (AppError) -> Void)?
    public var onEnded: (@MainActor () -> Void)?
    /// Native tracks are known synchronously and AVPlayer draws its own
    /// subtitles (legible group) / Plozz draws sidecar cues via the VM, so the
    /// native engine never fires either of these. Declared to satisfy the
    /// protocol.
    public var onTracksChanged: (@MainActor () -> Void)?
    public var onProbedSourceFactsChanged: (@MainActor (EngineProbedSourceFacts) -> Void)?
    public var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    public var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?

    // MARK: Configuration

    /// Subtitle appearance. The engine applies these style rules when building
    /// the player item, and re-applies them live via ``updateSubtitleStyle(_:)``
    /// when the viewer edits the look mid-playback.
    private var style: SubtitleStyle

    // MARK: Private playback state

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var backgroundAudioEnabled = false
    @ObservationIgnored private var request: PlaybackRequest?
    @ObservationIgnored private let authenticatedHTTPResolver:
        (any AuthenticatedHTTPResourceResolving)?
    @ObservationIgnored private let streamingPlaylistClient: (any HTTPClient)?
    @ObservationIgnored private let startsMuted: Bool
    @ObservationIgnored private var timeObserver: (owner: AVPlayer, token: Any)?
    /// Fences reentrant async loads. A newer load or stop invalidates every older
    /// continuation before it can publish or start a stale player.
    @ObservationIgnored private var loadGeneration: UInt = 0
    @ObservationIgnored private let reportInterval: TimeInterval = 10
    @ObservationIgnored private var lastReportedSecond: Int = -1
    @ObservationIgnored private var fallbackMonitorTask: Task<Void, Never>?
    @ObservationIgnored private var lifecycleDiagnostics: NativePlaybackLifecycleDiagnostics?
    @ObservationIgnored private var startupResume: NativeStartupResume?
    /// Detects an item that decodes audio but renders **no video frames** (e.g.
    /// HEVC AVPlayer can't display) so we can swap to the on-device engine.
    @ObservationIgnored private var missingVideoProbeTask: Task<Void, Never>?
    /// Inspects the real container video format the moment it loads (concurrently
    /// with playback start) so a known AVPlayer-hostile codec can swap instantly
    /// instead of waiting out the no-frames probe.
    @ObservationIgnored private var formatInspectTask: Task<Void, Never>?
    private var convertedVideoFormat: NativePlaybackFailure.VideoFormat?
    @ObservationIgnored private var audioSessionConfigured = false
    /// Retains the resource-loader delegate that serves injected subtitle
    /// playlists; `AVAssetResourceLoader` holds it only weakly.
    @ObservationIgnored private var subtitleLoader: SubtitleInjectingResourceLoader?
    /// Off-critical-path default-subtitle pick. Runs concurrently with playback
    /// startup so resolving the asset's `AVMediaSelectionGroup` never extends the
    /// time-to-first-frame; cancelled on teardown so a stale selection never
    /// applies to a replaced player item.
    @ObservationIgnored private var defaultSubtitleSelectionTask: Task<Void, Never>?
    /// The text track the view model asked AVPlayer to draw itself (embedded, or
    /// "Use native subtitles"), or `nil` for none. Kept across item rebuilds so a
    /// transcode-fallback reload restores it instead of disabling the draw.
    @ObservationIgnored private var requestedLegibleTrack: MediaTrack?
    /// Off-critical-path preferred-audio-language pick (per-series memory /
    /// prefer-original-language). AVPlayer otherwise just plays the asset's default
    /// audio track, so without this the audio half of those features no-ops on the
    /// native engine. Cancelled on teardown so a stale selection never applies to a
    /// replaced player item.
    @ObservationIgnored private var preferredAudioSelectionTask: Task<Void, Never>?
    #if !os(macOS)
    @ObservationIgnored private var routeChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var endOfPlaybackObserver: NSObjectProtocol?
    #endif
    #if canImport(UIKit)
    /// A single, stable `AVPlayerLayer`-backed surface fed by whichever
    /// `AVPlayer` is live, so a transcode-fallback swap re-points the existing
    /// surface instead of forcing the SwiftUI layer to rebuild it.
    @ObservationIgnored private var videoOutputView: PlayerLayerView?
    #endif
    #if os(tvOS)
    @ObservationIgnored private let displayCriteria = NativeDisplayCriteriaController()
    #endif

    public init(
        style: SubtitleStyle = .default,
        authenticatedHTTPResolver: (any AuthenticatedHTTPResourceResolving)? = nil,
        streamingPlaylistClient: (any HTTPClient)? = nil,
        startsMuted: Bool = false
    ) {
        self.style = style
        self.authenticatedHTTPResolver = authenticatedHTTPResolver
        self.streamingPlaylistClient = streamingPlaylistClient
        self.startsMuted = startsMuted
        PlaybackInstrumentation.increment(.nativeEngine)
    }

    deinit {
        PlaybackInstrumentation.decrement(.nativeEngine)
    }

    public let displayName = "AVPlayer"

    /// The live `AVPlayer`, exposed for the AVFoundation-specific diagnostics
    /// sampler. Engine-agnostic callers must not depend on this; a future
    /// non-AVFoundation engine simply wouldn't offer it (diagnostics is
    /// best-effort and non-fatal).
    public var underlyingPlayer: AVPlayer? { player }
    public var nowPlayingPlayer: AVPlayer? { player }
    public var needsBackgroundReload: Bool { false }

    public func setBackgroundAudioEnabled(_ enabled: Bool) {
        #if os(iOS)
        backgroundAudioEnabled = enabled
        player?.audiovisualBackgroundPlaybackPolicy = enabled ? .continuesIfPossible : .automatic
        #endif
    }

    public var videoAspectRatio: Double? {
        if let size = player?.currentItem?.presentationSize,
           size.width > 0,
           size.height > 0 {
            return Double(abs(size.width / size.height))
        }
        guard let video = request?.sourceMetadata?.video,
              let width = video.width,
              let height = video.height,
              width > 0,
              height > 0 else {
            return nil
        }
        return Double(width) / Double(height)
    }

    // MARK: - Lifecycle

    public func load(request: PlaybackRequest, startPosition: TimeInterval) async {
        guard !Task.isCancelled else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        status = .loading
        configureAudioSession()
        // Tear down any previous player (e.g. a failed direct-play attempt being
        // retried under a transcode) without reporting a stop.
        teardownPlayer()
        #if os(tvOS)
        displayCriteria.invalidatePendingLoad()
        #endif

        self.request = request
        let streamURL: URL?
        if case .some(.authenticatedHTTP(let locator)) = request.playbackSource {
            do {
                streamURL = try await authenticatedHTTPResolver?.resolve(locator)
            } catch {
                guard generation == loadGeneration, !Task.isCancelled else { return }
                let appError = (error as? AppError) ?? .unknown("")
                status = .failed(appError)
                onFailure?(appError)
                return
            }
        } else {
            streamURL = request.streamURL ?? request.playbackSource?.publicURL
        }
        guard generation == loadGeneration, !Task.isCancelled else { return }
        guard var streamURL else {
            let error = AppError.unknown("Native playback requires a URL source")
            status = .failed(error)
            onFailure?(error)
            return
        }

        if request.streamingOptions != nil, request.isTranscoding, request.isManifestStream {
            do {
                let mediaURL = try await StreamingMediaPlaylist.resolve(streamURL, using: streamingPlaylistClient)
                guard generation == loadGeneration, !Task.isCancelled else { return }
                if let mediaURL {
                    streamURL = mediaURL
                    HandoffDiagnostics.emit("native STREAM_PLAYLIST single-rendition-media=true")
                } else {
                    HandoffDiagnostics.emit("native STREAM_PLAYLIST original-manifest=true")
                }
            } catch {
                guard generation == loadGeneration, !Task.isCancelled else { return }
                // Inspection is optional; let AVPlayer report the original
                // stream's authoritative transport/format failure if it persists.
                PlozzLog.playback.error("Could not inspect the converted HLS playlist; retaining the original manifest.")
            }
            guard generation == loadGeneration, !Task.isCancelled else { return }
        }

        let injectableSubtitles = await resolveInjectableSubtitles(for: request)
        guard generation == loadGeneration, !Task.isCancelled else { return }
        let asset: AVURLAsset
        var item: AVPlayerItem
        if let audioURL = request.externalAudioURL {
            PlaybackTrace.note("trailer mux: extAudio present video=\(Self.itagOf(streamURL)) audio=\(Self.itagOf(audioURL))")
            // Adaptive trailer: a video-only stream paired with a separate
            // audio-only stream (the only way YouTube serves 1080p). AVPlayer can't
            // take two bare URLs, and googlevideo's adaptive tracks are fragmented
            // MP4 that AVPlayer won't play wrapped in a plain HLS segment — so mux
            // them with an AVMutableComposition (a video track + an audio track),
            // which AVFoundation reads natively and keeps in sync. If that fails,
            // fall back to the plain video URL, whose failed (silent) decode
            // re-resolves through the engine's transcode fallback to the
            // progressive muxed (audible ~360p) stream.
            let muxItem = await makeTrailerMuxItem(videoURL: streamURL, audioURL: audioURL)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            if let muxItem {
                item = muxItem
                asset = AVURLAsset(url: streamURL)
            } else {
                asset = makeAsset(for: request, streamURL: streamURL, injectableSubtitles: injectableSubtitles)
                item = AVPlayerItem(asset: asset)
            }
        } else {
            PlaybackTrace.note("trailer/native load: no extAudio (progressive) url=\(Self.itagOf(streamURL))")
            asset = makeAsset(
                for: request,
                streamURL: streamURL,
                injectableSubtitles: injectableSubtitles
            )
            item = AVPlayerItem(asset: asset)
        }
        // Apply in-app subtitle styling overrides if the user set any.
        item.textStyleRules = style.textStyleRules()
        // Drive the tvOS display into the right dynamic range (true Dolby
        // Vision / HDR10 / HLG) for this source before playback begins.
        configureDynamicRange(for: request, item: item)

        let player = AVPlayer(playerItem: item)
        player.isMuted = startsMuted
        #if os(iOS)
        player.audiovisualBackgroundPlaybackPolicy = backgroundAudioEnabled ? .continuesIfPossible : .automatic
        #endif
        player.allowsExternalPlayback = true
        self.player = player
        if HandoffDiagnostics.isEnabled {
            lifecycleDiagnostics = NativePlaybackLifecycleDiagnostics(player: player, request: request)
        }
        #if canImport(UIKit)
        videoOutputView?.player = player
        #endif

        let inspectsConvertedFormat = request.isTranscoding && request.streamingOptions != nil
        if inspectsConvertedFormat { inspectVideoFormat(asset: asset, item: item, request: request) }
        furthestObservedPosition = max(furthestObservedPosition, startPosition)
        if startPosition > 1 {
            let result = await resumePlayback(
                player: player, item: item, to: startPosition, generation: generation
            )
            guard generation == loadGeneration, !Task.isCancelled else { return }
            switch result {
            case .ready: break
            case .cancelled:
                status = .failed(.cancelled)
                return
            case .failed:
                PlozzLog.playback.error("Native startup seek did not reach the requested position.")
                let error = currentPlayerError()
                status = .failed(error)
                onFailure?(error)
                return
            }
            guard generation == loadGeneration, !Task.isCancelled else {
                player.pause()
                return
            }
        }
        guard generation == loadGeneration, !Task.isCancelled else { return }
        if item.status == .failed {
            let error = currentPlayerError()
            status = .failed(error)
            onFailure?(error)
            return
        }

        // Watch for a direct-play item that can't actually be decoded so we can
        // transparently re-resolve via a server transcode.
        monitorForTranscodeFallback(item: item)

        // Watch for an item that plays audio but renders no video (e.g. an HEVC
        // stream AVPlayer can't display) so we can swap to the on-device engine.
        monitorForMissingVideo(item: item, request: request)

        // Auto-notify when this item plays through to its natural end so the
        // owner can react (e.g. dismiss a finished trailer).
        observeEndOfPlayback(item: item)

        // Inspect the *real* container video format as soon as it loads (in
        // parallel — adds no startup delay) so a known AVPlayer-hostile codec can
        // swap to the on-device engine near-instantly, before the no-frames probe.
        if !inspectsConvertedFormat { inspectVideoFormat(asset: asset, item: item, request: request) }

        installTimeObserver(on: player)
        status = .ready
        isPaused = false
        player.playImmediately(atRate: Float(currentPlaybackRate))

        // Plozz owns subtitle SELECTION and DRAWING through its SDR overlay (see
        // PlayerViewModel.applyInitialSubtitleSelectionIfReady). The native engine
        // must therefore NOT enable any AVPlayer legible option — otherwise
        // AVPlayer would paint the asset's default/forced/autoselect subtitle into
        // the (HDR) video signal in parallel with the overlay: a double-draw that
        // also defeats HDR-safe rendering. Disable the legible group on load so
        // the overlay stays the single source of truth. Detached from load()'s
        // critical path because resolving the asset's `AVMediaSelectionGroup`
        // involves extra I/O the first video frame must not wait on. Cancelled in
        // `teardownPlayer` so it never applies to a replaced player item.
        // The one exception is a track the view model explicitly handed to
        // AVPlayer (still present in this request), which is re-applied instead.
        if let requested = requestedLegibleTrack,
           !request.subtitleTracks.contains(where: { $0.id == requested.id }) {
            requestedLegibleTrack = nil
        }
        applyLegibleSelection(for: item)

        // Apply the resolved audio-language preference (per-series memory /
        // prefer-original-language) the same off-critical-path way. AVPlayer has no
        // load-time language option, so we select the best-matching audible track
        // once its `AVMediaSelectionGroup` resolves. Empty preference => leave the
        // asset's default audio untouched (the no-feature common case). The viewer's
        // later manual pick (`selectAudioTrack`) still overrides this freely.
        preferredAudioSelectionTask?.cancel()
        let preferredAudioLanguages = request.preferredAudioLanguages
        if !preferredAudioLanguages.isEmpty {
            preferredAudioSelectionTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.applyPreferredAudioSelection(
                    for: item,
                    preferredLanguages: preferredAudioLanguages
                )
            }
        }
    }

    // MARK: - Dynamic range / Dolby Vision display switch

    /// Classifies the source's dynamic range and, on tvOS, requests the matching
    /// display mode so the Apple TV negotiates true Dolby Vision / HDR10 / HLG
    /// (or returns to SDR) with the panel. Per-frame metadata stays enabled even
    /// when the provider omitted or misclassified HDR; AVFoundation applies only
    /// metadata actually present in the stream.
    private func configureDynamicRange(for request: PlaybackRequest, item: AVPlayerItem) {
        item.appliesPerFrameHDRDisplayMetadata = true
        #if os(tvOS)
        displayCriteria.configure(
            asset: item.asset,
            fallback: nativeBootstrapDisplayCriteria(metadata: request.sourceMetadata))
        #endif
    }

    #if os(tvOS)
    /// The bound surface identifies the display. A detached or not-yet-loaded
    /// native surface must not clear another engine's display request.
    private func applyDisplayCriteria() {
        let window = videoOutputView?.window
        displayCriteria.attach(to: window.flatMap { Self.windowHasDisplayManager($0) ? $0 : nil })
    }

    /// Clears any forced display mode so the TV isn't stranded in HDR/DoVi after
    /// playback stops.
    private func clearDisplayCriteria() {
        displayCriteria.stop()
    }

    /// Safety net: the `avDisplayManager` accessor comes from AVKit's
    /// `UIWindow (AVAdditions)` category. If that framework somehow isn't linked,
    /// the selector is unrecognized and calling it would crash — so verify it's
    /// present first and degrade to a no-op (no display switch) instead.
    private static func windowHasDisplayManager(_ window: UIWindow) -> Bool {
        window.responds(to: Selector(("avDisplayManager")))
    }
    #endif

    // MARK: - Asset construction

    /// Builds the asset to play. When the server is direct-playing the original
    /// file (not transcoding) and the item has text subtitles the player would
    /// otherwise never see, wrap the stream in a synthesized HLS playlist that
    /// adds those subtitles as selectable renditions. Otherwise play the stream
    /// URL directly (transcoded HLS already carries subtitles in its manifest).
    private func makeAsset(
        for request: PlaybackRequest,
        streamURL: URL,
        injectableSubtitles: [InjectableSubtitle]
    ) -> AVURLAsset {
        subtitleLoader = nil
        guard !request.isManifestStream else {
            return AVURLAsset(url: streamURL)
        }
        guard !injectableSubtitles.isEmpty,
              let duration = request.item.runtime,
              duration > 0 else {
            return AVURLAsset(url: streamURL)
        }
        let composer = SubtitleHLSComposer(
            videoURL: streamURL,
            durationSeconds: duration,
            subtitles: injectableSubtitles
        )
        let loader = SubtitleInjectingResourceLoader(composer: composer)
        subtitleLoader = loader
        return loader.makeAsset()
    }

    /// Builds an `AVURLAsset` that pairs a **video-only** trailer stream with a
    /// **separate audio-only** stream via a synthesized HLS master, so AVPlayer
    /// muxes and syncs them itself (see ``TrailerAudioMuxComposer``). This unlocks
    /// higher-quality (e.g. 1080p H.264) YouTube trailers, which are only offered
    /// as adaptive video+audio tracks.
    ///
    /// The `EXTINF` needs the real media duration, which an online trailer item
    /// doesn't carry — so read it directly from the video-only asset first (a
    /// small metadata fetch: googlevideo fMP4 is faststart, so only the moov is
    /// touched). Returns `nil` if the duration can't be read, so the caller falls
    /// back to a plain asset rather than authoring a broken playlist.
    /// Builds an `AVPlayerItem` that muxes a **video-only** trailer stream with a
    /// **separate audio-only** stream using an `AVMutableComposition` (one video
    /// track + one audio track), so AVPlayer plays higher-quality (e.g. 1080p
    /// H.264) YouTube trailers — which are only offered as adaptive video+audio
    /// tracks — natively and in sync.
    ///
    /// Why a composition and not an HLS wrap: googlevideo's adaptive tracks are
    /// *fragmented* MP4; wrapping the whole file as one plain HLS segment (no
    /// `EXT-X-MAP` init segment) makes AVPlayer stall and fail to decode. As bare
    /// `AVURLAsset`s the same fMP4 reads natively, and a composition is the
    /// standard way to pair a picture track with a separate sound track.
    ///
    /// Returns `nil` if either track can't be loaded/composed, so the caller falls
    /// back to the progressive (audible) stream rather than a broken item.
    private func makeTrailerMuxItem(videoURL: URL, audioURL: URL) async -> AVPlayerItem? {
        subtitleLoader = nil

        let start = Date()
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        do {
            // Load both assets' tracks concurrently — the unavoidable metadata
            // (moov) fetch. Durations come from the track ranges / URL below, not
            // the (doubled) asset duration, so we don't load `.duration` here.
            async let videoTracksLoad = videoAsset.loadTracks(withMediaType: .video)
            async let audioTracksLoad = audioAsset.loadTracks(withMediaType: .audio)
            let (videoTracks, audioTracks) = try await (videoTracksLoad, audioTracksLoad)

            guard let videoTrack = videoTracks.first else {
                PlaybackTrace.note("trailer mux: no video track after \(Self.ms(since: start))ms")
                return nil
            }

            // Use each track's authoritative media `timeRange` (its real sample
            // range) rather than the asset's container `duration`.
            let vTrackRange = try await videoTrack.load(.timeRange)
            let aTrackRange = try await audioTracks.first?.load(.timeRange)

            // YouTube DASH fMP4 consistently reports ~2x the real duration in its
            // moov (both the asset duration AND the track sample range are doubled
            // — phantom time padded onto the end). That leaves the scrubber reading
            // double-length and delays the natural-end auto-dismiss. The googlevideo
            // URL carries the true length in its `dur=` query param, independent of
            // the fMP4 metadata, so clamp every inserted range to it when present.
            let trueDuration = Self.googleVideoDurationSeconds(videoURL)
            let cap: CMTime = trueDuration.map { CMTime(seconds: $0, preferredTimescale: 600) }
                ?? .positiveInfinity
            let videoSpan = CMTimeMinimum(vTrackRange.duration, cap)
            PlaybackTrace.note("trailer mux durations: vTrack=\(String(format: "%.1f", vTrackRange.duration.seconds)) aTrack=\(String(format: "%.1f", (aTrackRange?.duration.seconds ?? -1))) urlDur=\(trueDuration.map { String(format: "%.1f", $0) } ?? "?") -> span=\(String(format: "%.1f", videoSpan.seconds))")

            let composition = AVMutableComposition()
            let compVideo = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
            try compVideo?.insertTimeRange(
                CMTimeRange(start: .zero, duration: videoSpan),
                of: videoTrack,
                at: .zero
            )

            if let audioTrack = audioTracks.first, let aTrackRange {
                let compAudio = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )
                // Clamp the audio to the shorter of the real ranges so a small
                // track-length mismatch can't extend the item past the picture.
                let audioSpan = CMTimeMinimum(CMTimeMinimum(aTrackRange.duration, cap), videoSpan)
                try compAudio?.insertTimeRange(
                    CMTimeRange(start: .zero, duration: audioSpan),
                    of: audioTrack,
                    at: .zero
                )
            } else {
                PlaybackTrace.note("trailer mux: no audio track (silent) after \(Self.ms(since: start))ms")
            }

            PlaybackTrace.note("trailer mux: composed in \(Self.ms(since: start))ms dur=\(String(format: "%.1f", composition.duration.seconds))s")
            return AVPlayerItem(asset: composition)
        } catch {
            PlaybackTrace.note("trailer mux: compose FAILED after \(Self.ms(since: start))ms err=\(error)")
            PlozzLog.playback.debug("Trailer mux composition failed; falling back to plain asset")
            return nil
        }
    }

    /// Milliseconds elapsed since `start`, for diagnostic timing.
    private static func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    /// The `itag` query value of a googlevideo URL (e.g. `137`), for diagnostics;
    /// `?` when absent.
    private static func itagOf(_ url: URL) -> String {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "itag" })?.value ?? "?"
    }

    /// The true media length (seconds) from a googlevideo URL's `dur=` query
    /// param, or `nil` when absent/unparseable. This is the authoritative video
    /// duration YouTube stamps on the stream URL, independent of the fMP4 moov
    /// (which YouTube DASH consistently reports at ~2x), so it's the reliable cap
    /// for the muxed composition's length.
    private static func googleVideoDurationSeconds(_ url: URL) -> Double? {
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "dur" })?.value,
              let seconds = Double(value), seconds > 0 else {
            return nil
        }
        return seconds
    }

    private func resolveInjectableSubtitles(
        for request: PlaybackRequest
    ) async -> [InjectableSubtitle] {
        guard !request.isManifestStream else { return [] }
        var result: [InjectableSubtitle] = []
        for track in request.subtitleTracks where track.kind == .subtitle {
            guard let source = track.deliverySource else { continue }
            let url: URL?
            switch source {
            case .localFile(let localURL):
                url = localURL
            case .authenticatedHTTP(let locator):
                url = try? await authenticatedHTTPResolver?.resolve(locator)
            }
            guard let url else { continue }
            result.append(
                InjectableSubtitle(
                    index: track.id,
                    name: track.displayTitle,
                    languageTag: track.language,
                    isDefault: track.isDefault,
                    isForced: track.isForced,
                    sourceURL: url
                )
            )
        }
        return result
    }

    public func play() {
        guard let player else { return }
        player.playImmediately(atRate: Float(currentPlaybackRate))
        isPaused = false
    }

    public func pause() {
        guard let player else { return }
        player.pause()
        isPaused = true
    }

    // MARK: - Tunables

    /// AVPlayer can change `rate` live with no reload, so we advertise speed.
    /// Audio/subtitle delay are not exposed by AVPlayer in a useful way (it
    /// owns the audio mix in the asset graph), so we honestly opt out instead
    /// of pretending — the menu hides those rows for this engine.
    public var capabilities: PlayerEngineCapabilities { [.playbackSpeed] }

    /// Last requested speed, so a subsequent play() doesn't snap back to 1.0
    /// (AVPlayer resets rate to 1.0 on pause and on some item transitions).
    @ObservationIgnored private var currentPlaybackRate: Double = 1.0

    public func setPlaybackSpeed(_ rate: Double) {
        let clamped = max(0.25, min(4.0, rate))
        currentPlaybackRate = clamped
        // Only push to AVPlayer when playing — pausing then re-setting `rate`
        // would silently un-pause the player.
        if let player, !isPaused {
            player.rate = Float(clamped)
        }
    }

    public func stop() {
        loadGeneration &+= 1
        fallbackMonitorTask?.cancel()
        fallbackMonitorTask = nil
        #if !os(macOS)
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
        routeChangeObserver = nil
        #endif
        teardownPlayer()
        #if os(tvOS)
        clearDisplayCriteria()
        #endif
        #if canImport(UIKit)
        videoOutputView?.player = nil
        videoOutputView = nil
        #endif
        status = .idle
    }

    // MARK: - Audio session

    /// Best-effort: configure the shared audio session for video playback so
    /// multichannel/Atmos passthrough and spatialization route correctly. Never
    /// blocks or fails playback — any error is swallowed.
    private func configureAudioSession() {
        #if !os(macOS)
        guard !audioSessionConfigured else { return }
        audioSessionConfigured = true
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            PlozzLog.playback.debug("Audio session configuration failed (non-fatal)")
        }
        observeAudioRouteChanges(session)
        #endif
    }

    #if !os(macOS)
    /// Re-asserts the active session when the audio route changes (e.g. an AVR or
    /// TV is switched mid-playback) so multichannel routing follows the new
    /// output. Best-effort and crash-safe.
    private func observeAudioRouteChanges(_ session: AVAudioSession) {
        guard routeChangeObserver == nil else { return }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                try? AVAudioSession.sharedInstance().setActive(true)
                PlozzLog.playback.debug("Audio route changed; re-activated session")
            }
        }
    }
    #endif

    // MARK: - Transcode fallback detection

    /// Polls the new player item's status; if it fails to load, notifies the
    /// owner via `onFailure` with the classified error so it can decide whether to
    /// surface it or re-resolve with a server transcode. Fires at most once per
    /// load.
    private func monitorForTranscodeFallback(item: AVPlayerItem) {
        fallbackMonitorTask?.cancel()
        let monitorStart = Date()
        fallbackMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                switch item.status {
                case .failed:
                    PlaybackTrace.note("native item FAILED after \(Self.ms(since: monitorStart))ms chain=\(NativePlaybackLifecycleDiagnostics.errorChain(item.error as NSError?))")
                    self.onFailure?(self.currentPlayerError())
                    return
                case .readyToPlay:
                    PlaybackTrace.note("native item readyToPlay in \(Self.ms(since: monitorStart))ms dur=\(String(format: "%.1f", item.duration.seconds))s")
                    return
                default:
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
        }
    }

    public var streamingOutputDynamicRange: SourceDynamicRange? { convertedVideoFormat?.dynamicRange }
    public var streamingOutputVideoCodec: DirectPlayVideoCodec? { convertedVideoFormat?.videoCodec }

    public var streamingFailure: StreamingPlaybackFailure? {
        guard let item = player?.currentItem else { return nil }
        let lastError = item.errorLog()?.events.last
        guard item.error != nil || lastError != nil else { return nil }
        let http = lastError.flatMap { (400...599).contains($0.errorStatusCode) ? $0.errorStatusCode : nil }
        let error = (item.error as NSError?) ?? lastError.map {
            NSError(domain: $0.errorDomain, code: $0.errorStatusCode)
        }
        let failure = NativePlaybackFailure.classify(
            error, httpStatus: http, convertedFormat: convertedVideoFormat,
            provider: request?.sourceProvider,
            convertingHDRSource: request?.isTranscoding == true && request?.streamingOptions != nil
                && SourceDynamicRange.providerHint(from: request?.sourceMetadata)?.isHDR == true
        )
        return failure
    }

    private func currentPlayerError() -> AppError {
        if let failure = streamingFailure {
            HandoffDiagnostics.emit(
                "native STREAM_FAILURE kind=\(failure.kind) code=\(failure.diagnosticCode ?? "unreported")"
                    + " chain=\(NativePlaybackLifecycleDiagnostics.errorChain(player?.currentItem?.error as NSError?))"
            )
        }
        if player?.currentItem?.error != nil {
            return .invalidResponse
        }
        return .unknown("")
    }

    /// Reads the actual **video and audio** codec FourCCs from the asset's track
    /// format descriptions and, if either is one AVPlayer can't handle (e.g. HEVC
    /// `hev1` → black screen, Opus → silent), swaps to the on-device engine
    /// immediately. Runs concurrently with playback start so it adds **no startup
    /// delay**: the happy path keeps playing while this resolves (typically
    /// sub-second, before the first frame paints), and a hostile codec swaps
    /// near-instantly rather than after the slower no-frames probe.
    ///
    /// This asks the container itself rather than trusting server metadata.
    /// Managed conversions retain actual codec/transfer evidence for error advice;
    /// the original-file compatibility fallback remains scoped to SDR.
    private func inspectVideoFormat(asset: AVAsset, item: AVPlayerItem, request: PlaybackRequest) {
        formatInspectTask?.cancel()
        if request.isTranscoding, request.streamingOptions != nil {
            let generation = loadGeneration
            formatInspectTask = Task { [weak self] in
                do {
                    let format = try await NativePlaybackFailure.probeConvertedFormat(
                        read: {
                            let loadedTrack = item.tracks.compactMap(\.assetTrack).first { $0.mediaType == .video }
                            let track: AVAssetTrack?
                            if let loadedTrack { track = loadedTrack }
                            else { track = try await asset.loadTracks(withMediaType: .video).first }
                            guard let track, let description = try await track.load(.formatDescriptions).first else { return nil }
                            return NativePlaybackFailure.VideoFormat(description)
                        },
                        isCurrent: { [weak self] in self?.loadGeneration == generation }
                    )
                    guard let format else { return }
                    guard let self, !Task.isCancelled, generation == self.loadGeneration else { return }
                    self.convertedVideoFormat = format
                    HandoffDiagnostics.emit("native STREAM_FORMAT codec=\(format.codec) range=\(format.dynamicRange?.rawValue ?? "unknown")")
                    if format.isHDRH264 {
                        HandoffDiagnostics.emit("native STREAM_FORMAT hdr-h264=true")
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    PlozzLog.playback.debug("Converted stream format could not be inspected; retaining generic failure classification.")
                }
            }
            return
        }
        guard HDRDisplayMode(request.sourceMetadata) == .sdr else { return }
        let expectsVideo = request.sourceMetadata?.video != nil

        formatInspectTask = Task { [weak self] in
            // Video: an AVPlayer-hostile codec (e.g. HEVC `hev1`) plays audio over
            // a black screen.
            if expectsVideo, let videoFourCC = await Self.firstCodecFourCC(of: asset, mediaType: .video) {
                guard let self, !Task.isCancelled else { return }
                PlozzLog.playback.info("Direct-play video codec FourCC: \(videoFourCC)")
                if Self.isAVPlayerHostileVideoFourCC(videoFourCC) {
                    PlozzLog.playback.info("Video FourCC \(videoFourCC) is not reliably rendered by AVPlayer; swapping to the on-device engine")
                    self.onFailure?(.invalidResponse)
                    return
                }
            }

            // Audio: a codec AVPlayer can't decode (Opus/Vorbis) plays video with
            // no sound — the no-frames probe can't catch this, so check it here.
            if let audioFourCC = await Self.firstCodecFourCC(of: asset, mediaType: .audio) {
                guard let self, !Task.isCancelled else { return }
                PlozzLog.playback.info("Direct-play audio codec FourCC: \(audioFourCC)")
                if Self.isAVPlayerHostileAudioFourCC(audioFourCC) {
                    PlozzLog.playback.info("Audio FourCC \(audioFourCC) is not decodable by AVPlayer; swapping to the on-device engine")
                    self.onFailure?(.invalidResponse)
                }
            }
        }
    }

    /// Loads the first track of `mediaType`'s codec FourCC from the container.
    private static func firstCodecFourCC(of asset: AVAsset, mediaType: AVMediaType) async -> String? {
        do {
            let tracks = try await asset.loadTracks(withMediaType: mediaType)
            guard let track = tracks.first else { return nil }
            let formats = try await track.load(.formatDescriptions)
            guard let format = formats.first else { return nil }
            return fourCCString(CMFormatDescriptionGetMediaSubType(format))
        } catch {
            return nil
        }
    }

    /// HEVC tagged `hev1` (in-band parameter sets) in an MP4-family container
    /// plays audio with a black screen on AVPlayer/VideoToolbox. `hvc1`/`avc1`
    /// are fine. (DoVi is excluded upstream via the SDR gate.)
    private static func isAVPlayerHostileVideoFourCC(_ fourCC: String) -> Bool {
        fourCC.lowercased() == "hev1"
    }

    /// Audio FourCCs AVPlayer can't decode (Opus `Opus`, Vorbis). AAC `mp4a`,
    /// AC-3 `ac-3`, E-AC-3 `ec-3`, ALAC, FLAC, LPCM etc. are all fine.
    private static func isAVPlayerHostileAudioFourCC(_ fourCC: String) -> Bool {
        let lowered = fourCC.lowercased()
        return lowered == "opus" || lowered.contains("vorbis")
    }

    private static func fourCCString(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        let scalars = bytes.map { Character(UnicodeScalar($0)) }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }


    /// and decodes audio, but **no video frame ever decodes** (e.g. an HEVC stream
    /// tagged `hev1`, or a profile VideoToolbox rejects). Because AVPlayer never
    /// errors, the normal failure path never fires — so we attach a lightweight
    /// `AVPlayerItemVideoOutput` and, if several seconds of playback advance with
    /// zero decoded frames, hand off to the on-device hybrid engine (which decodes
    /// these directly) via the standard engine-swap fallback.
    ///
    /// Scoped to **SDR** sources: HDR/Dolby Vision is the validated AVPlayer-only
    /// path (and DoVi/HDR HEVC is always `hvc1`, so it never hits this), so it's
    /// left completely untouched. The probe removes itself the moment a real frame
    /// appears, so healthy playback pays almost nothing.
    private func monitorForMissingVideo(item: AVPlayerItem, request: PlaybackRequest) {
        missingVideoProbeTask?.cancel()
        // Only meaningful when the source is expected to have video.
        guard request.sourceMetadata?.video != nil else { return }
        // Never probe HDR/Dolby Vision — protect the validated AVPlayer HDR path.
        guard HDRDisplayMode(request.sourceMetadata) == .sdr else { return }

        let output = AVPlayerItemVideoOutput(outputSettings: nil)
        item.add(output)

        missingVideoProbeTask = Task { [weak self] in
            // Require this many seconds of *advancing* playback with no video frame
            // before declaring the video undecodable (generous, to avoid tripping
            // on slow starts / buffering).
            let requiredAdvance: Double = 4
            var advanced: Double = 0
            var lastSeconds = Double.nan

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self, let player = self.player,
                      player.currentItem === item else { return }

                // A decoded frame appeared → video is fine; drop the probe.
                if output.hasNewPixelBuffer(forItemTime: player.currentTime()) {
                    item.remove(output)
                    return
                }

                // Only accrue progress while genuinely playing (ignore pause/seek/
                // buffering), so the threshold reflects real played-through time.
                guard player.timeControlStatus == .playing else { continue }
                let now = player.currentTime().seconds
                if now.isFinite, lastSeconds.isFinite, now > lastSeconds {
                    advanced += now - lastSeconds
                }
                if now.isFinite { lastSeconds = now }

                if advanced >= requiredAdvance {
                    item.remove(output)
                    PlozzLog.playback.info("AVPlayer rendered no video after \(Int(requiredAdvance))s of audio; swapping to the on-device engine")
                    self.onFailure?(.invalidResponse)
                    return
                }
            }
        }
    }

    /// Tears the current player down without touching the audio-session or
    /// route-change observers. Used both when reloading for a retry and as part
    /// of `stop()`.
    /// Observes the natural end of `item` so the owner can react (e.g. dismiss a
    /// finished trailer). `didPlayToEndTimeNotification` fires only on a clean
    /// playthrough — never on a user-initiated stop or a failure — so it's a safe
    /// auto-dismiss trigger. Scoped to this specific item; removed in
    /// `teardownPlayer`.
    private func observeEndOfPlayback(item: AVPlayerItem) {
        if let endOfPlaybackObserver {
            NotificationCenter.default.removeObserver(endOfPlaybackObserver)
        }
        endOfPlaybackObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                PlaybackTrace.note("didPlayToEnd fired curr=\(String(format: "%.1f", item.currentTime().seconds)) dur=\(String(format: "%.1f", item.duration.seconds))")
                self?.onEnded?()
            }
        }
    }

    private func teardownPlayer() {
        startupResume?.cancel()
        startupResume = nil
        lifecycleDiagnostics = nil
        fallbackMonitorTask?.cancel()
        fallbackMonitorTask = nil
        missingVideoProbeTask?.cancel()
        missingVideoProbeTask = nil
        formatInspectTask?.cancel()
        formatInspectTask = nil
        convertedVideoFormat = nil
        defaultSubtitleSelectionTask?.cancel()
        defaultSubtitleSelectionTask = nil
        preferredAudioSelectionTask?.cancel()
        preferredAudioSelectionTask = nil
        subtitleLoader = nil
        if let endOfPlaybackObserver {
            NotificationCenter.default.removeObserver(endOfPlaybackObserver)
        }
        endOfPlaybackObserver = nil
        removeTimeObserver()
        player?.pause()
        player = nil
        lastReportedSecond = -1
    }

    // MARK: - Seeking

    public func seek(to seconds: TimeInterval) async {
        await seek(to: seconds, kind: .exact)
    }

    public func seek(to seconds: TimeInterval, kind: VideoSeekKind) async {
        guard let player else { return }
        if let resume = startupResume, let item = player.currentItem,
           resume.replaceSeek(with: { [weak self] completion in
               guard let self else { completion(false); return }
               self.beginManagedSeek(player: player, item: item, to: seconds, kind: kind, completion: completion)
           }) {
            _ = await resume.waitForCompletion()
            return
        }
        await seek(player: player, to: seconds, kind: kind)
    }

    private func beginManagedSeek(
        player: AVPlayer, item: AVPlayerItem, to seconds: TimeInterval, kind: VideoSeekKind,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        let target = seekTarget(seconds, item: item)
        let time = CMTime(seconds: target, preferredTimescale: 600)
        let toleranceSeconds: TimeInterval = kind == .fast ? 5 : 1
        let tolerance = CMTime(seconds: toleranceSeconds, preferredTimescale: 600)
        let generation = loadGeneration
        HandoffDiagnostics.emit(
            "native RESUME_SEEK_BEGIN generation=\(loadGeneration) target=\(String(format: "%.2f", target)) status=\(item.status.rawValue)"
        )
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak player] finished in
            Task { @MainActor in
                let position = player?.currentTime().seconds ?? .nan
                let landed = NativeStartupResume.didLand(
                    finished: finished, position: position,
                    target: target, tolerance: toleranceSeconds
                )
                HandoffDiagnostics.emit(
                    "native RESUME_SEEK_END generation=\(generation) finished=\(finished)"
                        + " target=\(String(format: "%.2f", target)) position=\(String(format: "%.2f", position)) landed=\(landed)"
                )
                completion(landed)
            }
        }
    }

    private func resumePlayback(
        player: AVPlayer, item: AVPlayerItem, to seconds: TimeInterval, generation: UInt
    ) async -> NativeStartupResume.Result {
        let resume = NativeStartupResume(
            itemStatus: { item.status },
            isCurrent: { [weak self] in
                self?.loadGeneration == generation && self?.player === player && player.currentItem === item
            },
            beginSeek: { [weak self] completion in
                guard let self else { completion(false); return }
                self.beginManagedSeek(player: player, item: item, to: seconds, kind: .exact, completion: completion)
            },
            cancelSeek: { item.cancelPendingSeeks() }
        )
        startupResume = resume
        HandoffDiagnostics.emit("native RESUME_WAIT generation=\(generation) status=\(item.status.rawValue)")
        let result = await resume.run()
        if startupResume === resume { startupResume = nil }
        HandoffDiagnostics.emit("native RESUME_RESULT generation=\(generation) result=\(result)")
        return result
    }

    private func seek(player: AVPlayer, to seconds: TimeInterval) async {
        await seek(player: player, to: seconds, kind: .exact)
    }

    private func seek(player: AVPlayer, to seconds: TimeInterval, kind: VideoSeekKind) async {
        let target = seekTarget(seconds, item: player.currentItem)
        let time = CMTime(seconds: target, preferredTimescale: 600)
        // `.fast` widens the tolerance so AVPlayer can snap to the nearest
        // available keyframe and return immediately — the right behaviour for
        // intermediate seeks in a rapid-skip burst that will be superseded by a
        // later, exact seek. `.exact` keeps a tight 1s tolerance: exact (.zero)
        // seeks can stall or fail on transcoded HLS, so 1s is the sweet spot.
        let toleranceSeconds: Double = kind == .fast ? 5 : 1
        let tolerance = CMTime(seconds: toleranceSeconds, preferredTimescale: 600)
        if PlaybackTrace.enabled {
            let (lo, hi) = seekableBounds(item: player.currentItem)
            let clamped = abs(target - max(0, seconds)) > 0.5
            PlaybackTrace.note("NATIVE seek BEGIN req=\(String(format: "%.2f", seconds)) target=\(String(format: "%.2f", target))\(clamped ? " CLAMPED" : "") kind=\(kind) seekable=[\(String(format: "%.2f", lo)),\(String(format: "%.2f", hi))] status=\(player.currentItem?.status.rawValue ?? -9) tcs=\(player.timeControlStatus.rawValue)")
        }
        await player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
        PlaybackTrace.note("NATIVE seek END   target=\(String(format: "%.2f", target)) curr=\(String(format: "%.2f", player.currentTime().seconds)) tcs=\(player.timeControlStatus.rawValue)")
    }

    private func seekTarget(_ seconds: TimeInterval, item: AVPlayerItem?) -> TimeInterval {
        return clampToSeekableRange(seconds, item: item)
    }

    /// Clamps a target time into the item's seekable range when one is known, so
    /// a seek past the currently-available range doesn't error out.
    private func clampToSeekableRange(_ seconds: TimeInterval, item: AVPlayerItem?) -> TimeInterval {
        guard let ranges = item?.seekableTimeRanges, !ranges.isEmpty else { return max(0, seconds) }
        var lower = TimeInterval.greatestFiniteMagnitude
        var upper = 0.0
        for value in ranges {
            let range = value.timeRangeValue
            lower = min(lower, range.start.seconds)
            upper = max(upper, (range.start + range.duration).seconds)
        }
        guard upper > 0 else { return max(0, seconds) }
        return min(max(seconds, lower), upper)
    }

    /// Diagnostic: the merged [lower, upper] of the item's seekable ranges, or
    /// [0, 0] when none are known yet. Used only by `PLZSEEK` tracing.
    private func seekableBounds(item: AVPlayerItem?) -> (Double, Double) {
        guard let ranges = item?.seekableTimeRanges, !ranges.isEmpty else { return (0, 0) }
        var lower = TimeInterval.greatestFiniteMagnitude
        var upper = 0.0
        for value in ranges {
            let range = value.timeRangeValue
            lower = min(lower, range.start.seconds)
            upper = max(upper, (range.start + range.duration).seconds)
        }
        return (lower == .greatestFiniteMagnitude ? 0 : lower, upper)
    }

    // MARK: - Progress cadence

    private func installTimeObserver(on player: AVPlayer) {
        removeTimeObserver()
        let interval = CMTime(seconds: 1, preferredTimescale: 1)
        let token = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            if time.seconds.isFinite { self.furthestObservedPosition = max(0, time.seconds) }
            let seconds = Int(time.seconds)
            guard seconds != self.lastReportedSecond, seconds % Int(self.reportInterval) == 0 else { return }
            self.lastReportedSecond = seconds
            self.onProgress?()
        }
        timeObserver = (owner: player, token: token)
    }

    private func removeTimeObserver() {
        guard let timeObserver else { return }
        self.timeObserver = nil
        timeObserver.owner.removeTimeObserver(timeObserver.token)
    }

    // MARK: - Subtitle / audio track selection

    /// Applies ``requestedLegibleTrack`` to the player item's legible group —
    /// usually `nil`, so the engine never draws a subtitle itself. Plozz routes the user's default and
    /// manual subtitle choices through its own SDR overlay
    /// (`PlayerViewModel.applyInitialSubtitleSelectionIfReady` /
    /// `selectSubtitleOption`), which fetches/decodes the same track and renders
    /// it HDR-safely on top of the video. Selecting `nil` here also overrides any
    /// `default`/`autoselect`/forced characteristic the asset (or an injected HLS
    /// rendition) would otherwise honour. Best-effort: failure simply leaves
    /// AVPlayer's own selection untouched and never affects playback.
    private func applyLegibleSelection(for item: AVPlayerItem) {
        let track = requestedLegibleTrack
        defaultSubtitleSelectionTask?.cancel()
        defaultSubtitleSelectionTask = Task { @MainActor [weak self] in
            guard let self, let group = await self.legibleGroup(for: item.asset),
                  !Task.isCancelled else { return }
            item.select(track.flatMap { Self.legibleOption(for: $0, in: group) }, in: group)
        }
    }

    /// Finds the legible option AVPlayer exposes for a provider track. An
    /// injected sidecar rendition carries the track's display title as its HLS
    /// `NAME`, so match that first; otherwise fall back to canonicalised language
    /// matching (`eng` ⇄ `en`), preferring the same forced-ness.
    private static func legibleOption(
        for track: MediaTrack, in group: AVMediaSelectionGroup
    ) -> AVMediaSelectionOption? {
        if let named = group.options.first(where: { $0.displayName == track.displayTitle }) {
            return named
        }
        guard let language = track.language else { return nil }
        let candidates = AVMediaSelectionGroup.mediaSelectionOptions(
            from: group.options, filteredAndSortedAccordingToPreferredLanguages: [language]
        )
        return candidates.first {
            $0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) == track.isForced
        } ?? candidates.first
    }

    /// Selects the audible track best matching an ordered list of preferred
    /// languages (per-series memory / prefer-original-language). Uses
    /// `mediaSelectionOptions(from:filteredAndSortedAccordingToPreferredLanguages:)`
    /// so language identifiers are canonicalised — a preference of `"jpn"` matches
    /// an option tagged `"ja"`, and vice versa — and the result is ordered by the
    /// preference list. Best-effort: no match (or no audible group) leaves the
    /// asset's default audio untouched and never affects playback.
    private func applyPreferredAudioSelection(
        for item: AVPlayerItem,
        preferredLanguages: [String]
    ) async {
        guard !preferredLanguages.isEmpty,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .audible)
        else { return }
        let ranked = AVMediaSelectionGroup.mediaSelectionOptions(
            from: group.options,
            filteredAndSortedAccordingToPreferredLanguages: preferredLanguages
        )
        guard let best = ranked.first else { return }
        item.select(best, in: group)
    }

    private func legibleGroup(for asset: AVAsset) async -> AVMediaSelectionGroup? {
        try? await asset.loadMediaSelectionGroup(for: .legible)
    }

    /// Asks AVPlayer to draw `track` itself (an embedded text track, or any
    /// reachable text track under "Use native subtitles"), or to draw nothing
    /// when `nil` because the overlay owns the subtitle. Best-effort: an
    /// unmatched track leaves AVPlayer drawing nothing.
    public func selectSubtitleTrack(_ track: MediaTrack?) {
        requestedLegibleTrack = track
        guard let item = player?.currentItem else { return }
        applyLegibleSelection(for: item)
    }

    /// Re-applies subtitle styling to the *current* player item so an in-player
    /// Style edit updates an embedded text track AVFoundation draws itself (e.g. an
    /// MKV SRT on Plex direct-play, which has no sidecar the overlay could redraw).
    /// Harmless for overlay-drawn subtitles: AVFoundation's legible selection is off
    /// in that case, so it isn't rendering a track for these rules to affect.
    public func updateSubtitleStyle(_ style: SubtitleStyle) {
        self.style = style
        player?.currentItem?.textStyleRules = style.textStyleRules()
    }

    /// Best-effort manual audio selection. As with subtitles, the native picker
    /// currently owns audio switching; this rounds out the abstraction.
    public func selectAudioTrack(_ track: MediaTrack?) {
        guard let player, let item = player.currentItem else { return }
        Task { [weak self] in
            guard let self,
                  let group = try? await item.asset.loadMediaSelectionGroup(for: .audible) else { return }
            self.select(track: track, in: group, on: item)
        }
    }

    private func select(track: MediaTrack?, in group: AVMediaSelectionGroup, on item: AVPlayerItem) {
        guard let track, let language = track.language else {
            item.select(nil, in: group)
            return
        }
        let match = group.options.first { option in
            let tag = option.extendedLanguageTag ?? option.locale?.identifier
            return tag?.caseInsensitiveCompare(language) == .orderedSame
        }
        item.select(match, in: group)
    }

    // MARK: - View

    #if canImport(UIKit)
    public func makeVideoOutputView() -> UIView {
        if let existing = videoOutputView { return existing }
        let view = PlayerLayerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.player = player
        #if os(tvOS)
        // Re-apply the pending display switch once the surface has a window
        // (the criteria may have been computed in load() before attachment).
        view.onWindowChange = { [weak self] _ in
            self?.applyDisplayCriteria()
        }
        #endif
        videoOutputView = view
        return view
    }
    #endif
}

/// Startup resume is bounded by the owner's startup watchdog, not a timer that
/// seeks an unready HLS item. All continuation and seek ownership stays on main.
@MainActor
final class NativeStartupResume {
    enum Result: Equatable, Sendable {
        case ready, failed, cancelled
    }

    static func didLand(
        finished: Bool, position: TimeInterval, target: TimeInterval, tolerance: TimeInterval
    ) -> Bool {
        finished && position.isFinite && target.isFinite
            && abs(position - target) <= tolerance + 0.1
    }

    private let itemStatus: @MainActor () -> AVPlayerItem.Status
    private let isCurrent: @MainActor () -> Bool
    private var beginSeek: @MainActor (@escaping @Sendable (Bool) -> Void) -> Void
    private let cancelSeek: @MainActor () -> Void
    private let pause: @MainActor () async throws -> Void
    private var cancelled = false
    private var seekContinuation: CheckedContinuation<Bool, Never>?
    private var seekRevision: UInt = 0
    private var pendingSeekRevision: UInt?
    private var completedResult: Result?

    init(
        itemStatus: @escaping @MainActor () -> AVPlayerItem.Status,
        isCurrent: @escaping @MainActor () -> Bool,
        beginSeek: @escaping @MainActor (@escaping @Sendable (Bool) -> Void) -> Void,
        cancelSeek: @escaping @MainActor () -> Void,
        pause: @escaping @MainActor () async throws -> Void = {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    ) {
        self.itemStatus = itemStatus
        self.isCurrent = isCurrent
        self.beginSeek = beginSeek
        self.cancelSeek = cancelSeek
        self.pause = pause
    }

    func run() async -> Result {
        let result: Result = await withTaskCancellationHandler {
            while !cancelled, !Task.isCancelled, isCurrent() {
                switch itemStatus() {
                case .failed: return .failed
                case .readyToPlay:
                    let revision = seekRevision
                    let finished = await withCheckedContinuation { continuation in
                        guard !cancelled, !Task.isCancelled, isCurrent() else {
                            continuation.resume(returning: false)
                            return
                        }
                        seekContinuation = continuation
                        pendingSeekRevision = revision
                        beginSeek { [weak self] finished in
                            Task { @MainActor in self?.completeSeek(finished, revision: revision) }
                        }
                    }
                    guard !cancelled, !Task.isCancelled, isCurrent() else { return .cancelled }
                    if revision != seekRevision { continue }
                    return finished && itemStatus() == .readyToPlay ? .ready : .failed
                default:
                    do { try await pause() }
                    catch { return .cancelled }
                }
            }
            return .cancelled
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
        completedResult = result
        return result
    }

    /// A same-item transport seek replaces the startup target, not the load.
    /// Its completion remains behind readiness and the owner's cancellation.
    func replaceSeek(
        with action: @escaping @MainActor (@escaping @Sendable (Bool) -> Void) -> Void
    ) -> Bool {
        guard !cancelled, completedResult == nil, isCurrent() else { return false }
        beginSeek = action
        seekRevision &+= 1
        if let revision = pendingSeekRevision {
            cancelSeek()
            completeSeek(false, revision: revision)
        }
        return true
    }

    func waitForCompletion() async -> Result {
        while !Task.isCancelled {
            if let completedResult { return completedResult }
            do { try await Task.sleep(nanoseconds: 20_000_000) }
            catch { return .cancelled }
        }
        return .cancelled
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        guard let revision = pendingSeekRevision else { return }
        // This closure owns the old item, never the engine's mutable current item.
        cancelSeek()
        completeSeek(false, revision: revision)
    }

    private func completeSeek(_ finished: Bool, revision: UInt) {
        guard pendingSeekRevision == revision else { return }
        let continuation = seekContinuation
        seekContinuation = nil
        pendingSeekRevision = nil
        continuation?.resume(returning: finished)
    }
}

/// Observes the whole item lifetime, including failures after startup's
/// readyToPlay gate. Evidence only: notifications never stop, retry or resume.
final class NativePlaybackLifecycleDiagnostics {
    private let observations: [NSKeyValueObservation]
    private let notificationObservers: [NSObjectProtocol]

    init(
        player: AVPlayer,
        request: PlaybackRequest,
        emit: @escaping @Sendable (String) -> Void = { HandoffDiagnostics.emit($0) }
    ) {
        guard let item = player.currentItem else {
            observations = []
            notificationObservers = []
            return
        }
        let context = "load=\(UUID().uuidString) provider=\(request.sourceProvider?.rawValue ?? "unknown")"
            + " item=\(HandoffDiagnostics.correlationID(request.item.id))"
            + " session=\(HandoffDiagnostics.correlationID(request.playSessionID))"
        observations = [
            item.observe(\.status, options: [.initial, .new]) { [weak player] item, _ in
                emit(Self.line(event: "ITEM_STATUS", context: context, item: item, player: player))
            },
            player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak item] player, _ in
                guard let item else { return }
                emit(Self.line(event: "TIME_CONTROL", context: context, item: item, player: player))
            }
        ]
        notificationObservers = [
            (AVPlayerItem.playbackStalledNotification, "STALLED"),
            (AVPlayerItem.failedToPlayToEndTimeNotification, "FAILED_TO_END"),
            (AVPlayerItem.newErrorLogEntryNotification, "ERROR_LOG")
        ].map { name, event in
            NotificationCenter.default.addObserver(
                forName: name, object: item, queue: nil
            ) { [weak item, weak player] notification in
                guard let item else { return }
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                emit(Self.line(event: event, context: context, item: item, player: player, error: error))
            }
        }
    }

    deinit {
        observations.forEach { $0.invalidate() }
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private static func line( // l10n:content - structured diagnostic event, never presented as UI copy.
        event: String, context: String, item: AVPlayerItem, player: AVPlayer?, error: NSError? = nil
    ) -> String {
        let lastError = item.errorLog()?.events.last
        let observedError = error ?? (item.error as NSError?) ?? lastError.map {
            NSError(domain: $0.errorDomain, code: $0.errorStatusCode)
        }
        let failure = NativePlaybackFailure.classify(
            observedError,
            httpStatus: lastError?.errorStatusCode
        )
        let bufferedThrough = item.loadedTimeRanges.map {
            CMTimeRangeGetEnd($0.timeRangeValue).seconds
        }.filter(\.isFinite).max() ?? 0
        return "native LIFECYCLE event=\(event) \(context)"
            + " status=\(item.status.rawValue) timeControl=\(player?.timeControlStatus.rawValue ?? -1)"
            + " position=\(String(format: "%.2f", item.currentTime().seconds))"
            + " bufferEmpty=\(item.isPlaybackBufferEmpty) likelyToKeepUp=\(item.isPlaybackLikelyToKeepUp)"
            + " bufferedThrough=\(String(format: "%.2f", bufferedThrough))"
            + " waiting=\(player?.reasonForWaitingToPlay?.rawValue ?? "none")"
            + " kind=\(failure.kind) code=\(failure.diagnosticCode ?? "none") chain=\(errorChain(observedError))"
    }

    static func errorChain(_ error: NSError?) -> String {
        var current = error
        var visited = Set<ObjectIdentifier>()
        var codes: [String] = []
        while let value = current, visited.count < 8, visited.insert(ObjectIdentifier(value)).inserted {
            let domain: String?
            switch value.domain {
            case AVFoundationErrorDomain: domain = "AV"
            case "CoreMediaErrorDomain": domain = "CoreMedia"
            case NSURLErrorDomain: domain = "URL"
            case NSOSStatusErrorDomain: domain = "OSStatus"
            default: domain = nil
            }
            if let domain { codes.append("\(domain):\(value.code)") }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return codes.isEmpty ? "none" : codes.joined(separator: ">")
    }
}

#if canImport(UIKit)
/// A bare video surface whose backing layer is an `AVPlayerLayer`. Renders the
/// live stream and nothing else; the shared player overlay sits above it and
/// owns all transport UI and Siri Remote input.
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }
    #if os(tvOS)
    /// Invoked when the view moves to (or away from) a window, so the engine can
    /// drive that window's `AVDisplayManager` for the Dolby Vision / HDR switch.
    var onWindowChange: ((UIWindow?) -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?(window)
    }
    #endif
}
#endif
#endif
