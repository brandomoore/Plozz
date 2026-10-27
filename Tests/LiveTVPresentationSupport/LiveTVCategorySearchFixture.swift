import CoreModels
import CoreUI
import FeatureLiveTV
import FeatureLiveTVCore
import FeatureProfiles
import SwiftUI
#if os(iOS)
import AVFoundation
@testable import AppShelliOS
import FeaturePlayback
import Observation
import UIKit
#endif

struct LiveTVCategorySearchFixture: View {
    @State private var profiles: ProfilesModel
    @State private var showsProfile = false
    @State private var isExpanded = false
    private let namespace = "CategorySearch.\(UUID().uuidString)"
    private var palette: ThemePalette {
        ProcessInfo.processInfo.arguments.contains("--category-preview-light") ? .light : .dark
    }

    init() {
        let defaults = UserDefaults(suiteName: "CategorySearchProfiles.\(UUID().uuidString)")!
        _profiles = State(initialValue: ProfilesModel(store: ProfileStore(defaults: defaults)))
    }

    var body: some View {
        NavigationStack {
            LiveTVPrototypeView(
                preferencesStore: CategorySearchPreferences(),
                viewSettingsStore: CategorySearchSettings(),
                sourceStore: CategorySearchSources(),
                onExpandedChange: { isExpanded = $0 },
                sourceLoader: CategorySearchLoader(),
                preferencesNamespace: namespace,
                sourceApprovalContext: { [profiles] in LiveTVSourceApprovalContext(profiles: profiles) },
                topBarAccessory: profileAction
            ) { playback in
                #if os(iOS)
                CategoryPreviewPlayer(playback: playback)
                #else
                Color.black
                    .accessibilityIdentifier("category-search-playback")
                    .accessibilityLabel(Text(playback.channel.name))
                    .accessibilityValue(Text(verbatim: playback.isExpanded ? "Fullscreen" : "Preview"))
                #endif
            }

        }
        .environment(profiles)
        .environment(\.locale, Locale(identifier: "en_US"))
        .environment(\.themePalette, palette)
        .environment(\.colorScheme, palette.isLight ? .light : .dark)
        .preferredColorScheme(palette.isLight ? .light : .dark)
        .background { AppBackground(palette: palette) }
        #if os(iOS)
        .liveChannelSystemOverlays()
        .plozziOSLivePlayerOrientation(
            isPresented: isExpanded,
            orientation: ProcessInfo.processInfo.arguments.contains("--category-preview-landscape") ? .landscape
                : (ProcessInfo.processInfo.arguments.contains("--category-preview-portrait") ? .portrait : .auto)
        )
        .environment(\.plozzMetrics, .touch(density: .standard))
        .sheet(isPresented: $showsProfile) {
            Text("Profile settings").accessibilityIdentifier("category-search-profile-settings")
        }
        #endif
    }

    private var profileAction: AnyView? {
        #if os(iOS)
        AnyView(
            Button { showsProfile = true } label: {
                ProfileAvatarView(profile: profiles.activeProfile, size: 36, rendersAsImage: true)
            }
            .buttonBorderShape(.circle)
            .accessibilityLabel("Profile settings")
            .accessibilityIdentifier("live-tv-profile")
        )
        #else
        nil
        #endif
    }
}

#if os(iOS)
private struct CategoryPreviewPlayer: View {
    let playback: LiveTVPrototypePlayback
    @State private var engine: CategoryPreviewEngine
    @State private var playbackEngine: LibraryLiveChannelEngine
    @State private var expansions = 0

    init(playback: LiveTVPrototypePlayback) {
        self.playback = playback
        let engine = CategoryPreviewEngine()
        _engine = State(initialValue: engine)
        _playbackEngine = State(initialValue: LibraryLiveChannelEngine(engine: engine))
    }

    var body: some View {
        LiveChannelPlayerView(
            channelID: playback.channel.id, title: playback.channel.name,
            input: playback.input, logoURL: nil, makeEngine: { playbackEngine },
            onPreviousChannel: playback.previousChannel, onNextChannel: playback.nextChannel,
            isFavorite: false, canToggleFavorite: false, onToggleFavorite: {},
            isExpanded: playback.isExpanded, isPreviewVisible: playback.isPreviewVisible, onExpandPreview: {
                expansions += 1
                playback.expandPreview()
            },
            previewReflectionHeight: playback.previewReflectionHeight,
            previewTopReflectionHeight: playback.previewTopReflectionHeight,
            previewLeadingReflectionWidth: playback.previewLeadingReflectionWidth,
            previewTrailingReflectionWidth: playback.previewTrailingReflectionWidth,
            isActive: playback.isPlaybackActive, onReturnToGuide: playback.returnToGuide,
            onPlaybackStarted: playback.playbackStarted, reportingID: playback.reportingID,
            countsAsWatching: playback.countsAsWatching, program: playback.program
        )
        .overlay(alignment: .topLeading) {
            VStack {
                Text("Loads: \(engine.loads)")
                    .accessibilityIdentifier("category-preview-loads")
                Text("Expands: \(expansions)")
                    .accessibilityIdentifier("category-preview-expands")
                Text(engine.identity.uuidString)
                    .accessibilityIdentifier("category-preview-engine")
                Text(engine.liveSnapshot.firstFrameReady && playbackEngine.hasPresentedVideoFrame
                    ? "Frame: ready" : "Frame: waiting")
                    .accessibilityIdentifier("category-preview-frame")
            }
            .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("category-search-playback")
        .accessibilityLabel(Text(playback.channel.name))
        .accessibilityValue(Text(verbatim: playback.isExpanded ? "Fullscreen" : "Preview"))
    }
}

@MainActor @Observable
private final class CategoryPreviewEngine: LiveChannelEngine {
    let identity = UUID()
    @ObservationIgnored private let native = NativeVideoEngine(startsMuted: true)
    var videoAspectRatio: Double? { native.videoAspectRatio }
    var nowPlayingPlayer: AVPlayer? { native.nowPlayingPlayer }
    var hasPresentedVideoFrame: Bool { native.hasPresentedVideoFrame }
    var loads = 0
    var liveSnapshot = LiveChannelEngineSnapshot(
        phase: .idle, firstFrameReady: false, position: 100, bufferedPosition: 120,
        seekableRange: 0...1800, behindLiveSeconds: 0, route: .localHLS
    )
    var status = VideoEngineStatus.idle
    var isPaused = false
    var currentTime: TimeInterval { 100 }
    var duration: TimeInterval { 1800 }
    var furthestObservedPosition: TimeInterval { 100 }
    var audioTracks: [MediaTrack] { [] }
    var subtitleTracks: [MediaTrack] { [] }
    var currentAudioTrackID: Int? { nil }
    @ObservationIgnored var onProgress: (@MainActor () -> Void)?
    @ObservationIgnored var onFailure: (@MainActor (AppError) -> Void)?
    @ObservationIgnored var onEnded: (@MainActor () -> Void)?
    @ObservationIgnored var onTracksChanged: (@MainActor () -> Void)?
    @ObservationIgnored var onProbedSourceFactsChanged: (@MainActor (EngineProbedSourceFacts) -> Void)?
    @ObservationIgnored var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    @ObservationIgnored var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    @ObservationIgnored var onLiveSourceReset: (@MainActor () -> Void)?

    init() {
        native.onProgress = { [weak self] in
            guard let self else { return }
            liveSnapshot.firstFrameReady = native.hasPresentedVideoFrame
            onProgress?()
        }
        native.onFailure = { [weak self] error in
            guard let self else { return }
            status = .failed(error)
            liveSnapshot.phase = .failed
            onFailure?(error)
        }
    }

    func loadLive(url: URL, httpHeaders: [String: String]) async {
        loads += 1
        status = .loading
        liveSnapshot.phase = .loading
        liveSnapshot.firstFrameReady = false
        let name = ProcessInfo.processInfo.arguments.contains("--category-preview-dim")
            ? "live-continuity-dim" : "live-continuity"
        guard let fixture = Bundle.main.url(forResource: name, withExtension: "mp4") else {
            preconditionFailure("The category preview fixture video is missing.")
        }
        await native.load(request: PlaybackRequest(
            item: MediaItem(id: "preview", title: "Synthetic video", kind: .movie), streamURL: fixture
        ), startPosition: 0)
        guard !Task.isCancelled else { return }
        status = native.status
        isPaused = false
        liveSnapshot.phase = native.status == .ready ? .playing : .failed
    }
    func load(request: PlaybackRequest, startPosition: TimeInterval) async {}
    func play() { native.play(); isPaused = false; liveSnapshot.phase = .playing }
    func pause() { native.pause(); isPaused = true; liveSnapshot.phase = .paused }
    func stop() {
        native.stop()
        status = .idle
        liveSnapshot.phase = .idle
        liveSnapshot.firstFrameReady = false
    }
    func seek(to seconds: TimeInterval) async {}
    func seekToLiveEdge() async {}
    func selectAudioTrack(_ track: MediaTrack?) {}
    func selectSubtitleTrack(_ track: MediaTrack?) {}
    func makeVideoOutputView() -> UIView {
        native.makeVideoOutputView()
    }
}
#endif

private final class CategorySearchPreferences: LiveTVPreferencesStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var preferences = LiveTVPreferences()

    func load() throws -> LiveTVPreferences { lock.withLock { preferences } }
    func save(_ preferences: LiveTVPreferences) throws { lock.withLock { self.preferences = preferences } }
}

private struct CategorySearchSettings: LiveTVViewSettingsStoring {
    func load() -> LiveTVViewSettings {
        .init(autoPreview: false, hasChosenAutoPreview: true,
              startsWithCategories: !ProcessInfo.processInfo.arguments.contains("--category-search-guide-first"))
    }
    func save(_ settings: LiveTVViewSettings) {}
}

private struct CategorySearchSources: LiveTVSourcesStoring {
    func load() throws -> LiveTVSourcesConfiguration {
        .init(playlists: [
            .init(id: "category-search", name: "Sample TV",
                  playlistURL: URL(string: "https://fixture.invalid/channels.m3u")!,
                  guideURLs: [URL(string: "https://fixture.invalid/guide.xml")!])
        ])
    }

    func save(_ configuration: LiveTVSourcesConfiguration) throws {}
}

private struct CategorySearchLoader: LiveTVSourceLoading {
    func loadPlaylist(from url: URL) async throws -> LiveTVPlaylistImport {
        if ProcessInfo.processInfo.arguments.contains("--category-search-failure") {
            throw URLError(.cannotConnectToHost)
        }
        return try LiveTVPlaylistParser(baseURL: url).parse("""
        #EXTM3U
        #EXTINF:-1 tvg-id="arena" group-title="Sports",Arena One
        https://fixture.invalid/arena.m3u8
        #EXTINF:-1 tvg-id="stadium" group-title="Sports",Stadium Live
        https://fixture.invalid/stadium.m3u8
        #EXTINF:-1 tvg-id="world" group-title="International Sports",World Arena
        https://fixture.invalid/world.m3u8
        #EXTINF:-1 tvg-id="report" group-title="Entertainment",Sports Report
        https://fixture.invalid/report.m3u8
        #EXTINF:-1 tvg-id="news" group-title="News",Daily News
        https://fixture.invalid/news.m3u8
        """)
    }

    func loadGuide(
        from url: URL, channels: [LiveTVPrototypeChannel], now: Date
    ) async throws -> LiveTVGuideImport {
        let start = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 1_800) * 1_800)
        let titles = ["Matchday Live", "Championship Highlights", "World Sports", "The Sports Review", "News Today"]
        let programs = channels.enumerated().flatMap { index, channel in
            (0..<4).map { slot in
                LiveTVPrototypeProgram(
                    id: "\(channel.id)-\(slot)", channelID: channel.id,
                    title: slot.isMultiple(of: 2) ? titles[index % titles.count] : "Weekend Highlights",
                    subtitle: "", start: start.addingTimeInterval(Double(slot) * 1_800),
                    end: start.addingTimeInterval(Double(slot + 1) * 1_800)
                )
            }
        }
        return .init(
            programs: programs, matchedChannelCount: channels.count,
            guideChannelCount: channels.count, programCount: programs.count,
            coverageStart: start, coverageEnd: start.addingTimeInterval(7_200)
        )
    }
}
