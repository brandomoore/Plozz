import AVKit
import CoreModels
import CoreUI
import EnginePlozzigen
import FeatureLiveTVCore
import SwiftUI
@testable import AppShelliOS
@testable import FeatureLiveTV
@testable import FeaturePlayback

struct PlayerLayoutFixture: View {
    fileprivate static let capturesFilm = ProcessInfo.processInfo.arguments.contains("--capture-open-movie")
    private static let populated = ProcessInfo.processInfo.arguments.contains("--populated-player")
    private static let sample = MediaItem(id: "sample", title: "Big Buck Bunny", kind: .movie, versions: [
        .init(id: "hd", width: 1920, height: 1080), .init(id: "sd", width: 854, height: 480)
    ])
    @State private var showsVersions = false
    @State private var version = "hd"
    @State private var model: PlayerViewModel
    @State private var timelineSampleIndex = 0
    @State private var scrubStarts = 0
    @State private var continueWatchingSelection = "none"
    @State private var continueWatchingSelections = 0
    private let chapterScrollFixture = ProcessInfo.processInfo.arguments.contains("--chapter-scroll-fixture")
    private let continueWatchingFixture = ProcessInfo.processInfo.arguments.contains("--continue-watching-player-fixture")

    init() {
        let provider = PlayerLayoutProvider()
        let isContinueWatching = ProcessInfo.processInfo.arguments.contains("--continue-watching-player-fixture")
        let episode = MediaItem(id: "layout", title: "Mud", kind: isContinueWatching ? .movie : .episode, seriesID: "series")
        let playlist = VideoPlaylistPlaybackContext(
            origin: .init(playlistID: "playlist", accountID: "layout", index: 0, totalCount: 1, item: episode),
            provider: provider
        )
        let model = PlayerViewModel(
            provider: provider, itemID: episode.id, episodeItem: episode,
            streamingOptions: Self.populated ? .init(quality: .hd1080) : nil,
            playlistContext: isContinueWatching ? nil : playlist
        )
        if isContinueWatching {
            model.continueWatchingSnapshot = {
                ["plex", "silo"].map { (accountID: String) in
                    MediaItem(
                        id: "\(accountID)-continue", title: "Continue \(accountID)", kind: .movie,
                        runtime: 3_600, resumePosition: 600, sourceAccountID: accountID
                    )
                }
            }
        }
        model.controls.duration = ProcessInfo.processInfo.arguments.contains("--long-video") ? 5_400 : 1_200
        model.controls.currentSeconds = ProcessInfo.processInfo.arguments.contains("--timeline-rollovers") ? 0 : 600
        model.controls.bufferedSeconds = 900
        model.controls.title = Self.capturesFilm ? "Big Buck Bunny" : "Wayward"
        model.controls.subtitle = Self.capturesFilm ? "" : "S1 E4 - Mud"
        model.controls.intendsPause = !Self.capturesFilm && !ProcessInfo.processInfo.arguments.contains("--playing")
        model.controls.isScrubbing = ProcessInfo.processInfo.arguments.contains("--scrubbing")
        model.controls.scrubSeconds = model.controls.currentSeconds
        model.controls.engineCapabilities = ProcessInfo.processInfo.arguments.contains("--no-playback-speed")
            ? [] : [.playbackSpeed]
        if ProcessInfo.processInfo.arguments.contains("--playback-menu") {
            model.controls.engineCapabilities.formUnion([.videoZoom, .dialogEnhance])
        }
        if Self.populated {
            model.controls.audioOptions = TrackMenuBuilder.audioOptions(
                tracks: PlayerLayoutLiveEngine.audio, selectedID: 1, preferred: []
            )
            model.controls.subtitleOptions = TrackMenuBuilder.subtitleOptions(
                tracks: PlayerLayoutLiveEngine.captions, selectedID: nil, preferred: [], detectedLanguages: [:]
            )
            model.controls.engineCapabilities.insert(.videoZoom)
            model.controls.playbackSpeed = 1
        }
        model.controls.subtitleDelayAdjustable = ProcessInfo.processInfo.arguments.contains("--subtitle-delay")
        if ProcessInfo.processInfo.arguments.contains("--audio-delay") {
            model.controls.engineCapabilities.insert(.audioDelay)
        }
        model.controls.infoCard.cast = [MediaPerson(id: "actor", name: "Actor", role: "Character")]
        _model = State(initialValue: model)
    }

    private struct PlayerLayoutProvider: StreamingQualityProviding {
        let kind = ProviderKind.jellyfin
        let session = UserSession(
            server: MediaServer(id: "layout", name: "Layout", baseURL: URL(string: "https://fixture.invalid")!,
                                provider: .jellyfin),
            userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
        )
        func libraries() async throws -> [MediaLibrary] { [] }
        func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
        func latest(limit: Int) async throws -> [MediaItem] { [] }
        func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
            throw AppError.notFound
        }
        func item(id: String) async throws -> MediaItem { throw AppError.notFound }
        func children(of itemID: String) async throws -> [MediaItem] { [] }
        func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
        func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
        func playbackInfo(for itemID: String, mediaSourceID: String?, forceTranscode: Bool,
                          streaming: StreamingPlaybackOptions) async throws -> PlaybackRequest { throw AppError.notFound }
        func releaseStreamingSession(_ request: PlaybackRequest) async {}
        func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
        func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
    }

    var body: some View {
        ZStack {
            (chapterScrollFixture ? Color(red: 0.25, green: 0.45, blue: 0.65)
                : ProcessInfo.processInfo.arguments.contains("--white-video") ? Color.white : .black)
                .ignoresSafeArea()
            if ProcessInfo.processInfo.arguments.contains("--live-presentation-row") {
                LivePresentationRowFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--native-avkit") {
                NativePlayerGlassFixture(showsControls: true).ignoresSafeArea()
            } else {
                if ProcessInfo.processInfo.arguments.contains("--video") {
                    NativePlayerGlassFixture(showsControls: false).ignoresSafeArea()
                }
                if ProcessInfo.processInfo.arguments.contains("--live-player") {
                    LivePlayerLayoutFixture()
                } else {
                    PlozziOSPlayerControlsOverlay(
                        viewModel: model, keyboardActions: PlozziOSPlayerKeyboardActions(),
                        hasVersions: Self.populated, versionsPresented: showsVersions,
                        onShowVersions: { showsVersions = true }, onClose: {}
                    )
                    .plozzSheet(isPresented: $showsVersions) {
                        PlozziOSPlayerVersionSheet(item: Self.sample, mediaSourceID: version) { version = $0 }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("player-layout-fixture")
                    .accessibilityValue("scrubbing:\(model.controls.isScrubbing),starts:\(scrubStarts)")
                }
            }
        }
        .statusBarHidden()
        .onChange(of: model.controls.isScrubbing) { _, active in
            if active { scrubStarts += 1 }
        }
        .onChange(of: model.pendingContinueWatching?.stablePresentationID) { _, _ in
            guard continueWatchingFixture, let selected = model.pendingContinueWatching else { return }
            continueWatchingSelection = selected.id
            continueWatchingSelections += 1
            model.cancelContinueWatchingSelection()
        }
        .environment(\.themePalette, light ? .light : .dark)
        .environment(\.colorScheme, light ? .light : .dark)
        .preferredColorScheme(light ? .light : .dark)
        .environment(\.plozzMetrics, .touch(density: .standard))
        .transformEnvironment(\.plozzReduceTransparency) { value in
            if chapterScrollFixture { value = true }
        }
        .transformEnvironment(\.plozzCardStyle) { value in
            if continueWatchingFixture {
                value = ProcessInfo.processInfo.arguments.contains("--cw-borderless") ? .borderless : .framed
            }
        }
        .transformEnvironment(\.plozzCardCaptionSettings) { value in
            if continueWatchingFixture {
                value = .init(preference: ProcessInfo.processInfo.arguments.contains("--cw-hide-labels") ? .hide : .show)
            }
        }
        .transformEnvironment(\.plozzContinueWatchingPresentation) { value in
            if continueWatchingFixture {
                let arguments = ProcessInfo.processInfo.arguments
                value.artworkStyle = arguments.contains("--cw-portrait-artwork") ? .portraitPosters
                    : arguments.contains("--cw-thumbnail") ? .thumbnail : .logoAndArtwork
            }
        }
        .task {
            guard chapterScrollFixture else { return }
            await model.load()
            model.controls.duration = 3_600
            model.controls.currentSeconds = 910
            model.controls.controlsVisible = true
            model.controls.infoCard.chapters = (0..<20).map {
                .init(start: Double($0) * 180, title: "Scene \($0 + 1)")
            }
        }
        .overlay(alignment: .topTrailing) {
            if continueWatchingFixture {
                Text(verbatim: "\(continueWatchingSelection):\(continueWatchingSelections)")
                    .accessibilityIdentifier("player-cw-selection")
                    .allowsHitTesting(false)
            }
            if ProcessInfo.processInfo.arguments.contains("--timeline-rollovers") {
                Button("Advance time") {
                    let duration = model.controls.duration
                    let samples = [0, 59, 60, 599, 600, 1_799, 1_800, 3_599, 3_600, duration - 1, duration]
                        .filter { $0 <= duration }
                    timelineSampleIndex = min(timelineSampleIndex + 1, samples.count - 1)
                    model.controls.currentSeconds = samples[timelineSampleIndex]
                }
                .accessibilityIdentifier("fixture-next-time")
                .accessibilityValue("\(timelineSampleIndex)")
                .padding(.top, 110)
            }
        }
    }

    private struct LivePresentationRowFixture: View {
        @State private var expanded = true

        var body: some View {
            LiveChannelPlayerView(
                channelID: "sample", title: "Sample Channel",
                input: .stream(url: URL(string: "https://fixture.invalid/live.m3u8")!, httpHeaders: [:]), logoURL: nil,
                makeEngine: { PlayerLayoutLiveEngine() }, onPreviousChannel: {}, onNextChannel: {},
                isFavorite: false, canToggleFavorite: false, onToggleFavorite: {},
                isExpanded: expanded, onExpandPreview: { expanded = true },
                presentationControls: { _ in
                    // PiP/AirPlay hide in preview. Keep a measurable control in their actual row.
                    AnyView(Button { expanded.toggle() } label: {
                        Rectangle().fill(.white).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Toggle preview")
                    .accessibilityIdentifier(expanded ? "fullscreen-row-probe" : "preview-row-probe"))
                }
            )
            .frame(width: expanded ? nil : 280, height: expanded ? nil : 158)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
        }
    }

    private struct LivePlayerLayoutFixture: View {
        private static let channelID = "sample"
        @State private var tracks: LiveChannelPlayerModel
        @State private var paused = false
        @State private var behind: TimeInterval = 0
        @State private var channel = 0
        @State private var scrubStarts = 0
        @State private var phaseIndex = 0
        @State private var guide = LiveTVPrototypeModel(
            now: Date(), channels: Array(LiveTVPrototypeModel().channels.prefix(4))
        )
        @State private var guideImports = LiveTVPrototypeImportModel(configuration: .init())
        @FocusState private var focus: LiveChannelControl?
        private let input: LiveChannelInput
        private let now = Date()
        private let cyclesPhase = ProcessInfo.processInfo.arguments.contains("--cycle-live-phase")
        private let hasProgram = !ProcessInfo.processInfo.arguments.contains("--no-guide-program")
        private let scheduled = ProcessInfo.processInfo.arguments.contains("--scheduled-channel")
        private let phases: [LiveChannelPlaybackPhase] = [
            .playing, .loading, .buffering, .seeking, .reconnecting, .paused,
            .failed(.startupTimedOut), .ended, .playing, .paused, .playing
        ]

        init() {
            input = .stream(url: URL(string: "https://fixture.invalid/live.m3u8")!, httpHeaders: [:])
            do {
                _tracks = State(initialValue: LiveChannelPlayerModel(
                    engine: PlayerLayoutFixture.populated ? PlayerLayoutLiveEngine() : try PlozzigenVideoEngine(),
                    channelID: Self.channelID, input: input
                ))
            } catch {
                preconditionFailure("Could not create Live layout fixture: \(error)")
            }
        }

        var body: some View {
            LiveChannelOverlay(
                title: PlayerLayoutFixture.capturesFilm ? "Open Cinema" : "Sample Channel",
                logoURL: nil, plozzChannelID: scheduled ? "fixture" : nil,
                channelID: Self.channelID, input: input,
                program: hasProgram ? .init(
                    title: PlayerLayoutFixture.capturesFilm ? "Big Buck Bunny" : "Evening News",
                    start: now.addingTimeInterval(-900), end: now.addingTimeInterval(900)
                ) : nil,
                earlierPrograms: [], libraryItem: nil, openLibraryItem: nil,
                phase: cyclesPhase ? phases[phaseIndex] : (paused ? .paused : .playing),
                isAtLiveEdge: behind == 0, behindLiveSeconds: behind, canPause: true, canGoLive: behind > 0,
                seekWindowSeconds: 3600, onSeekBy: { behind = max(0, behind - $0) },
                onSeekBehindLive: { behind = $0 }, focus: $focus, onClose: {},
                onPrevious: { channel -= 1 }, onPlayPause: { paused.toggle() }, onGoLive: { behind = 0 },
                onNext: { channel += 1 }, onMultiview: PlayerLayoutFixture.populated ? {} : nil,
                guideContent: { embedding in
                    AnyView(LiveTVPlayerGuideOverlay(
                        model: guide, imports: guideImports, playingChannelID: guide.channels.first?.id ?? "",
                        libraryCatalog: nil, loadLibraryGuide: nil, embedding: embedding, tune: { _ in channel += 1 }
                    ))
                },
                pendingGuideOpen: false, consumeGuideOpen: {}, onGuideCardChange: { _ in },
                loadOnNow: {
                    ProcessInfo.processInfo.arguments.contains("--empty-on-now") ? [] : [
                        .init(channelID: "other", channelName: "Another Channel", logoURL: nil, program: .init(
                            title: "Another Programme", start: now.addingTimeInterval(-900), end: now.addingTimeInterval(900)
                        ))
                    ]
                }, onTuneChannel: nil, tracks: tracks,
                diagnosticsEnabled: false, toggleDiagnostics: {},
                onTracksPresentationChange: { _ in }, onControlActivity: {}, onDismissControls: {},
                onTouchScrubbingChanged: { if $0 { scrubStarts += 1 } }
            )
            .ignoresSafeArea()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("live-player-layout-fixture")
            .accessibilityValue(Text(
                verbatim: "channel:\(channel),behind:\(Int(behind)),phase:\(phaseIndex),scrubs:\(scrubStarts)"
            ))
            .overlay(alignment: .topTrailing) {
                if cyclesPhase {
                    Button("Advance state") {
                        phaseIndex = min(phaseIndex + 1, phases.count - 1)
                        behind = (8...9).contains(phaseIndex) ? 1800 : 0
                    }
                    .accessibilityIdentifier("fixture-next-live-phase")
                    .accessibilityValue(Text(verbatim: "\(phaseIndex)"))
                    .padding(.top, 110)
                    .padding(.trailing, 21)
                }
            }
            .task { if PlayerLayoutFixture.populated { await tracks.start() } }
            .onDisappear { tracks.stop() }
        }
    }

    /// Supplies demuxed tracks through the same engine/model boundary as a tuned channel.
    @MainActor
    private final class PlayerLayoutLiveEngine: LiveChannelEngine {
        static let audio: [MediaTrack] = [.init(id: 1, kind: .audio, displayTitle: "English", language: "en", codec: "aac", channels: 2)]
        static let captions: [MediaTrack] = [.init(id: 2, kind: .subtitle, displayTitle: "English", language: "en", codec: "srt")]
        var status = VideoEngineStatus.ready
        var isPaused = false
        let capabilities: PlayerEngineCapabilities = [.videoZoom]
        let currentTime: TimeInterval = 10
        let duration: TimeInterval = 0
        let furthestObservedPosition: TimeInterval = 10
        var audioTracks: [MediaTrack] { Self.audio }
        var subtitleTracks: [MediaTrack] { Self.captions }
        var onProgress: (@MainActor () -> Void)?
        var onFailure: (@MainActor (AppError) -> Void)?
        var onEnded: (@MainActor () -> Void)?
        var onTracksChanged: (@MainActor () -> Void)?
        var onProbedSourceFactsChanged: (@MainActor (EngineProbedSourceFacts) -> Void)?
        var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
        var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
        var onLiveSourceReset: (@MainActor () -> Void)?
        let liveSnapshot = LiveChannelEngineSnapshot(phase: .playing, firstFrameReady: true, position: 10, route: .nativeHLS)
        func loadLive(url: URL, httpHeaders: [String: String]) async {}
        func seekToLiveEdge() async {}
        func load(request: PlaybackRequest, startPosition: TimeInterval) async {}
        func play() {}
        func pause() {}
        func stop() {}
        func seek(to seconds: TimeInterval) async {}
        func selectAudioTrack(_ track: MediaTrack?) {}
        func selectSubtitleTrack(_ track: MediaTrack?) {}
        func makeVideoOutputView() -> UIView { UIView() }
    }

    private var light: Bool { ProcessInfo.processInfo.arguments.contains("--light") }
}

private struct NativePlayerGlassFixture: UIViewControllerRepresentable {
    let showsControls: Bool

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let url = PlayerLayoutFixture.capturesFilm
            ? URL.documentsDirectory.appendingPathComponent("player-capture.mp4")
            : Bundle.main.url(forResource: "four-three", withExtension: "mp4")
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            preconditionFailure("Missing local player reference video.")
        }
        controller.player = AVPlayer(url: url)
        controller.showsPlaybackControls = showsControls
        controller.allowsVideoFrameAnalysis = false
        if PlayerLayoutFixture.capturesFilm {
            controller.player?.isMuted = true
            controller.player?.play()
        }
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player?.pause()
        controller.player = nil
    }
}
