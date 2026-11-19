import CoreModels
import CoreUI
import FeatureLiveTVCore
import FeaturePlayback
import Observation
import SwiftUI
import UIKit
@testable import FeatureLiveTV

struct LibraryChannelActionsFixture: View {
    @State private var opened: MediaItem?
    @State private var expanded = !ProcessInfo.processInfo.arguments.contains("--preview")
    @State private var engine = ChannelActionsEngine(item: Self.item)
    @FocusState private var guideFocus: LiveTVGuideFocusTarget?
    private let now = Date()

    private static var item: LibraryChannelItem {
        let movie = ProcessInfo.processInfo.arguments.contains("--movie")
        var media = MediaItem(
            id: movie ? "movie-1" : "episode-1",
            title: movie ? "Fixture Movie" : "Fixture Episode",
            kind: movie ? .movie : .episode, runtime: 1_800
        )
        if !movie {
            media.seriesID = "show-1"
            media.parentTitle = "Fixture Show"
        }
        do {
            return try LibraryChannelItem(
                item: media, library: .init(accountID: "fixture-account", libraryID: "library"),
                serverID: "server", userID: "user"
            )
        } catch {
            preconditionFailure("Invalid local channel fixture: \(error)")
        }
    }

    var body: some View {
        if ToolbarFootageView.requested {
            player.ignoresSafeArea()
                .environment(\.themePalette, .dark)
                .environment(\.colorScheme, .dark)
        } else {
            libraryActions
        }
    }

    private var libraryActions: some View {
        NavigationStack {
            Group {
                if ProcessInfo.processInfo.arguments.contains("--guide") {
                    guide
                } else {
                    player
                }
            }
            .navigationDestination(item: $opened) { subject in
                VStack {
                    Text("Opened \(subject.title)")
                    Text("\(subject.kind.rawValue):\(subject.id):\(subject.sourceAccountID ?? "")")
                    Text("Stopped \(engine.stops)")
                }
            }
        }
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark)
    }

    private var guide: some View {
        PrototypeGuideRow(
            channel: .init(
                id: "library:fixture", number: 1, name: "Fixture Channel", category: "Plozz",
                symbol: "tv", accent: 0, source: .plozz, tagline: ""
            ),
            programs: [.init(
                id: "programme", channelID: "library:fixture", title: "Current programme", subtitle: "",
                start: now.addingTimeInterval(-60), end: now.addingTimeInterval(1_740),
                libraryItem: Self.item
            )],
            start: now.addingTimeInterval(-60), now: now, width: 1_600,
            timeline: PrototypeTimelineScroll(), focus: $guideFocus, railActive: false, returnTarget: nil,
            favorite: false, playing: false, toggleFavorite: {}, tune: {}, details: { _ in },
            controls: {}, top: {}, goToNow: {},
            openLibraryItem: { opened = $0.navigationSubject }
        )
        .frame(width: 1_600)
        .defaultFocus($guideFocus, .channel("library:fixture", section: .channels))
    }

    private var player: some View {
        ZStack(alignment: .topLeading) {
            LiveChannelPlayerView(
                channelID: ToolbarFootageView.requested ? "cinema" : "library:fixture",
                title: ToolbarFootageView.requested ? "Open Movie Channel" : "Fixture Channel",
                input: ToolbarFootageView.requested
                    ? .stream(url: URL.documentsDirectory.appendingPathComponent("toolbar-live.mp4"), httpHeaders: [:])
                    : .libraryChannel(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, authorizationID: "fixture"),
                logoURL: nil, makeEngine: { engine }, onPreviousChannel: {}, onNextChannel: {},
                isFavorite: false, canToggleFavorite: true, onToggleFavorite: {},
                isExpanded: expanded, usesNativeFullscreen: ToolbarFootageView.requested,
                isActive: opened == nil, onReturnToGuide: { expanded = false },
                onMultiview: ToolbarFootageView.requested ? { true } : nil,
                displayTransitionSettings: {
                    ToolbarFootageView.requested
                        ? PlaybackSettings(fadeOnDynamicRangeChange: false, fadeOnFrameRateChange: false)
                        : .default
                },
                onOpenLibraryItem: { opened = $0.navigationSubject },
                program: ToolbarFootageView.requested ? .init(title: "Big Buck Bunny", start: now.addingTimeInterval(-240),
                                                              end: now.addingTimeInterval(356)) : nil
            )
            VStack(alignment: .leading) {
                Text(engine.policy.suppressesDisplayMatching ? "Matching off" : "Matching on")
                if !expanded {
                    Button("Watch channel") { expanded = true }
                }
            }
            .padding(50)
            .opacity(ToolbarFootageView.requested && expanded ? 0 : 1)
        }
    }
}

@MainActor @Observable
private final class ChannelActionsEngine: LiveChannelEngine {
    let currentLibraryItem: LibraryChannelItem?
    @ObservationIgnored lazy var outputView: UIView = ToolbarFootageView.requested
        ? ToolbarFootageView(name: "toolbar-live", paused: true) : UIView()
    var policy = LiveChannelOutputPolicy()
    var stops = 0
    var liveSnapshot = LiveChannelEngineSnapshot(
        phase: .playing, firstFrameReady: true, position: 100, bufferedPosition: 120,
        seekableRange: 0...1_800, behindLiveSeconds: 0, route: .localHLS
    )
    var status = VideoEngineStatus.ready
    var isPaused = false
    var currentTime: TimeInterval { 100 }
    var duration: TimeInterval { 1_800 }
    var furthestObservedPosition: TimeInterval { 100 }
    var supportsConcurrentPlayback: Bool { ToolbarFootageView.requested }
    var capabilities: PlayerEngineCapabilities { ToolbarFootageView.requested ? [.videoZoom] : [] }
    var audioTracks: [MediaTrack] { ToolbarFootageView.requested ? [
        .init(id: 1, kind: .audio, displayTitle: "English", language: "en"),
        .init(id: 2, kind: .audio, displayTitle: "Commentary", language: "en")
    ] : [] }
    var subtitleTracks: [MediaTrack] { ToolbarFootageView.requested ? [
        .init(id: 3, kind: .subtitle, displayTitle: "English", language: "en")
    ] : [] }
    var currentAudioTrackID: Int? { nil }
    @ObservationIgnored var onProgress: (@MainActor () -> Void)?
    @ObservationIgnored var onFailure: (@MainActor (AppError) -> Void)?
    @ObservationIgnored var onEnded: (@MainActor () -> Void)?
    @ObservationIgnored var onTracksChanged: (@MainActor () -> Void)?
    @ObservationIgnored var onProbedSourceFactsChanged: (@MainActor (EngineProbedSourceFacts) -> Void)?
    @ObservationIgnored var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    @ObservationIgnored var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    @ObservationIgnored var onLiveSourceReset: (@MainActor () -> Void)?

    init(item: LibraryChannelItem) {
        currentLibraryItem = ToolbarFootageView.requested ? nil : item
        if ToolbarFootageView.requested {
            liveSnapshot.position = 1_744
            liveSnapshot.behindLiveSeconds = 56
            liveSnapshot.phase = .paused
            isPaused = true
        }
    }
    func configureLiveOutput(_ policy: LiveChannelOutputPolicy) { self.policy = policy }
    func loadChannel(_ input: LiveChannelInput) async throws {}
    func loadLive(url: URL, httpHeaders: [String: String]) async {}
    func load(request: PlaybackRequest, startPosition: TimeInterval) async {}
    func play() {
        isPaused = false
        if ToolbarFootageView.requested { liveSnapshot.phase = .playing }
    }
    func pause() {
        isPaused = true
        if ToolbarFootageView.requested { liveSnapshot.phase = .paused }
    }
    func stop() { stops += 1; status = .idle }
    func seek(to seconds: TimeInterval) async {}
    func seekToLiveEdge() async {
        if ToolbarFootageView.requested {
            liveSnapshot.position = 1_800
            liveSnapshot.behindLiveSeconds = 0
        }
    }
    func selectAudioTrack(_ track: MediaTrack?) {}
    func selectSubtitleTrack(_ track: MediaTrack?) {}
    func makeVideoOutputView() -> UIView { outputView }
}
