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
        model.controls.title = "Wayward"
        model.controls.subtitle = "S1 E4 - Mud"
        model.controls.intendsPause = !ProcessInfo.processInfo.arguments.contains("--playing")
        model.controls.isScrubbing = ProcessInfo.processInfo.arguments.contains("--scrubbing")
        model.controls.scrubSeconds = model.controls.currentSeconds
        model.controls.engineCapabilities = ProcessInfo.processInfo.arguments.contains("--no-playback-speed")
            ? [] : [.playbackSpeed]
        if ProcessInfo.processInfo.arguments.contains("--playback-menu") {
            model.controls.engineCapabilities.formUnion([.videoZoom, .dialogEnhance])
        }
        model.controls.subtitleDelayAdjustable = ProcessInfo.processInfo.arguments.contains("--subtitle-delay")
        if ProcessInfo.processInfo.arguments.contains("--audio-delay") {
            model.controls.engineCapabilities.insert(.audioDelay)
        }
        model.controls.infoCard.cast = [MediaPerson(id: "actor", name: "Actor", role: "Character")]
        _model = State(initialValue: model)
    }

    private struct PlayerLayoutProvider: MediaProvider {
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
        func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
        func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
    }

    var body: some View {
        ZStack {
            (chapterScrollFixture ? Color(red: 0.25, green: 0.45, blue: 0.65)
                : ProcessInfo.processInfo.arguments.contains("--white-video") ? Color.white : .black)
                .ignoresSafeArea()
            if ProcessInfo.processInfo.arguments.contains("--native-avkit") {
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
                        hasVersions: false, versionsPresented: false, onShowVersions: {}, onClose: {}
                    )
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

    private struct LivePlayerLayoutFixture: View {
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
                _tracks = State(initialValue: LiveChannelPlayerModel(engine: try PlozzigenVideoEngine(), input: input))
            } catch {
                preconditionFailure("Could not create Live layout fixture: \(error)")
            }
        }

        var body: some View {
            LiveChannelOverlay(
                title: "Sample Channel", logoURL: nil, plozzChannelID: scheduled ? "fixture" : nil,
                channelID: "sample", input: input,
                program: hasProgram ? .init(
                    title: "Evening News", start: now.addingTimeInterval(-900), end: now.addingTimeInterval(900)
                ) : nil,
                earlierPrograms: [], libraryItem: nil, openLibraryItem: nil,
                phase: cyclesPhase ? phases[phaseIndex] : (paused ? .paused : .playing),
                isAtLiveEdge: behind == 0, behindLiveSeconds: behind, canPause: true, canGoLive: true,
                seekWindowSeconds: 3600, onSeekBy: { behind = max(0, behind - $0) },
                onSeekBehindLive: { behind = $0 }, focus: $focus, onClose: {},
                onPrevious: { channel -= 1 }, onPlayPause: { paused.toggle() }, onGoLive: { behind = 0 },
                onNext: { channel += 1 }, onMultiview: nil,
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
            .onDisappear { tracks.stop() }
        }
    }

    private var light: Bool { ProcessInfo.processInfo.arguments.contains("--light") }
}

private struct NativePlayerGlassFixture: UIViewControllerRepresentable {
    let showsControls: Bool

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        guard let url = Bundle.main.url(forResource: "four-three", withExtension: "mp4") else {
            preconditionFailure("Missing local player reference video.")
        }
        controller.player = AVPlayer(url: url)
        controller.showsPlaybackControls = showsControls
        controller.allowsVideoFrameAnalysis = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player?.pause()
        controller.player = nil
    }
}
