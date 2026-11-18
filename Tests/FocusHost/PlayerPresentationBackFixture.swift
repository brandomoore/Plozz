import CoreModels
import CoreUI
import FeatureHomeCore
import Foundation
import Observation
import SwiftUI
import UIKit
@testable import AppShell
@testable import FeaturePlayback

@MainActor
struct PlayerPresentationBackFixture: View {
    @State private var state = PlayerPresentationBackState()
    @State private var presented = false
    @State private var started = false
    @State private var dismissed = false

    var body: some View {
        VStack {
            if dismissed {
                Text(verbatim: "Player dismissed")
                    .accessibilityIdentifier("player-back-dismissed")
                evidence
            } else {
                Text(verbatim: "Preparing player")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .fullScreenCover(isPresented: $presented, onDismiss: { dismissed = true }) {
            PlayerPresentation(
                request: PlayRequest(
                    item: state.provider.movie,
                    startPosition: 0,
                    versionPreferences: state.preferences
                ),
                make: { request, _, _ in state.makePlayer(request) },
                makeFailover: { _, _ in nil },
                showDiagnostics: false,
                themePalette: .dark,
                versionPreferences: state.preferences,
                prepareVersion: { choice, item in
                    state.choice = choice
                    do {
                        return try await choice.prepare(
                            item,
                            provider: state.provider,
                            settings: state.settings,
                            preferences: state.preferences
                        )
                    } catch is CancellationError {
                        state.preparationCancelled = true
                        throw CancellationError()
                    }
                },
                versionAuthorizationScope: ["player-back-fixture"]
            )
            .overlay(alignment: .topLeading) {
                evidence.allowsHitTesting(false)
            }
        }
        .environment(\.locale, Locale(identifier: "en_US"))
        .environment(\.colorScheme, .dark)
        .environment(\.themePalette, .dark)
        .onReceive(
            NotificationCenter.default.publisher(for: UIFocusSystem.didUpdateNotification)
        ) { notification in
            guard let context = notification.userInfo?[
                UIFocusSystem.focusUpdateContextUserInfoKey
            ] as? UIFocusUpdateContext else { return }
            state.surfaceFocused = context.nextFocusedItem is PlayerInputView
        }
        .task {
            guard !started else { return }
            started = true
            presented = true
        }
    }

    private var evidence: some View {
        VStack(alignment: .leading) {
            marker("player-back-phase", state.player?.phase == .ready ? "ready" : "pending")
            marker("player-back-make-count", String(state.makeCount))
            marker("player-back-load-count", String(state.engine.loadCount))
            marker("player-back-stop-count", String(state.engine.stopCount))
            marker("player-back-preparing", String(state.choice?.isPreparing == true))
            marker("player-back-cancelled", String(state.preparationCancelled))
            marker("player-back-surface-focus", String(state.surfaceFocused))
            marker("player-back-controls", String(state.player?.controls.controlsVisible == true))
            marker("player-back-panel", String(state.player?.controls.isPanelOpen == true))
        }
        .font(.caption2)
    }

    private func marker(_ identifier: String, _ value: String) -> some View {
        Text(verbatim: value).accessibilityIdentifier(identifier)
    }
}

@MainActor
@Observable
private final class PlayerPresentationBackState {
    let defaults: UserDefaults
    let settings: PlaybackSettingsModel
    let preferences: VersionPreferenceStore
    let provider: PlayerPresentationBackProvider
    let engine = PlayerPresentationBackEngine()
    var player: PlayerViewModel?
    var choice: PlaybackVersionChoiceModel?
    var makeCount = 0
    var preparationCancelled = false
    var surfaceFocused = false

    init() {
        let suite = "com.thatcube.Plozz.FocusHost.PlayerPresentationBack"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        self.defaults = defaults
        let settings = PlaybackSettingsModel(store: PlaybackSettingsStore(defaults: defaults))
        settings.settings.versionSelectionMode = .askEveryTime
        settings.settings.useCommunityMarkers = false
        settings.settings.fadeOnDynamicRangeChange = false
        settings.settings.fadeOnFrameRateChange = false
        self.settings = settings
        preferences = VersionPreferenceStore(defaults: defaults)
        let arguments = ProcessInfo.processInfo.arguments
        provider = PlayerPresentationBackProvider(
            holdDetails: arguments.contains("--player-back-hold-details"),
            offerVersions: arguments.contains("--player-back-versions")
        )
    }

    func makePlayer(_ request: PlayRequest) -> PlayerViewModel {
        makeCount += 1
        let engine = self.engine
        let player = PlayerViewModel(
            provider: provider,
            itemID: request.item.id,
            mediaSourceID: request.item.selectedVersionID,
            behavior: SubtitleBehavior(
                preferredSubtitleLanguage: "eng",
                autoDownloadSubtitles: false
            ),
            playbackSettings: settings.settings,
            startPosition: request.startPosition,
            engineFactory: EngineFactory(makeNative: { _ in engine }),
            preferencesStore: PlaybackPreferencesStore(defaults: defaults)
        )
        self.player = player
        return player
    }
}

private struct PlayerPresentationBackProvider: MediaProvider, CapabilityReporting {
    let holdDetails: Bool
    let offerVersions: Bool
    let kind: ProviderKind = .jellyfin
    let capabilities: ProviderCapability = [.video, .remoteSubtitles]
    let session = UserSession(
        server: MediaServer(
            id: "player-back-server", name: "Back fixture",
            baseURL: URL(string: "https://example.test")!, provider: .jellyfin
        ),
        userID: "fixture", userName: "Fixture",
        deviceID: "fixture", accessToken: "fixture"
    )

    var movie: MediaItem {
        MediaItem(
            id: "player-back-movie", title: "Back regression", kind: .movie,
            versions: offerVersions ? [
                MediaVersion(id: "low", height: 720, videoRange: "SDR"),
                MediaVersion(id: "high", height: 1080, videoRange: "SDR")
            ] : []
        )
    }

    func item(id: String) async throws -> MediaItem {
        if holdDetails { try await Task.sleep(for: .seconds(60)) }
        return movie
    }

    func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        PlaybackRequest(
            item: movie, streamURL: URL(string: "https://example.test/unused.mp4")!
        )
    }

    func remoteSubtitleSearch(
        itemID: String, language: String, preference: SubtitleSearchPreference
    ) async throws -> [RemoteSubtitle] {
        [RemoteSubtitle(id: "back-result", name: "Back regression subtitle", language: "eng")]
    }

    func downloadRemoteSubtitle(itemID: String, subtitleID: String) async throws {
        throw AppError.notFound
    }

    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func items(
        in containerID: String, kind: MediaItemKind, page: PageRequest
    ) async throws -> MediaPage {
        MediaPage(items: [], startIndex: page.startIndex, totalCount: 0)
    }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

@MainActor
@Observable
private final class PlayerPresentationBackEngine: VideoEngine {
    var status: VideoEngineStatus = .idle
    var isPaused = true
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 7200
    var furthestObservedPosition: TimeInterval = 0
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var onProgress: (@MainActor () -> Void)?
    var onFailure: (@MainActor (AppError) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onTracksChanged: (@MainActor () -> Void)?
    var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onProbedSourceFactsChanged: (@MainActor (EngineProbedSourceFacts) -> Void)?
    var loadCount = 0
    var stopCount = 0
    var preventsDisplaySleep: Bool { false }
    var hasPresentedVideoFrame: Bool { status == .ready }
    private let output = UIView()

    func load(request: PlaybackRequest, startPosition: TimeInterval) async {
        loadCount += 1
        currentTime = startPosition
        status = .ready
    }
    func play() { isPaused = false }
    func pause() { isPaused = true }
    func seek(to seconds: TimeInterval) async { currentTime = seconds }
    func stop() {
        stopCount += 1
        status = .idle
    }
    func selectAudioTrack(_ track: MediaTrack?) {}
    func selectSubtitleTrack(_ track: MediaTrack?) {}
    func makeVideoOutputView() -> UIView { output }
}

@MainActor
struct DiscMenuInputFixture: View {
    @State private var fixture = DiscMenuInputFixtureState()

    var body: some View {
        DiscMenuPlayerContent(
            model: fixture.player, state: fixture.menu,
            dismiss: {}, showVideos: {}
        )
        .overlay(alignment: .topLeading) {
            Text(verbatim: fixture.keys.map(String.init).joined(separator: ","))
                .accessibilityIdentifier("disc-input-keys")
                .allowsHitTesting(false)
        }
    }
}

@MainActor
@Observable
private final class DiscMenuInputFixtureState {
    let player: PlayerViewModel
    let menu = DiscMenuPlaybackState()
    var keys: [UInt32] = []

    init() {
        let engine = PlayerPresentationBackEngine()
        player = PlayerViewModel(
            provider: PlayerPresentationBackProvider(holdDetails: false, offerVersions: false),
            itemID: "disc-input-fixture", engineFactory: .init(makeNative: { _ in engine })
        )
        menu.isActive = true
        menu.isOpening = false
        menu.isMenuVisible = true
        menu.sendKey = { [weak self] key in self?.keys.append(key) }
    }
}
