import CoreModels
import CoreUI
@testable import FeaturePlayback
import SwiftUI
import UIKit
import FeatureHomeCore
#if os(iOS)
import FeatureAuth
@testable import AppShelliOS
#else
@testable import FeatureHome
#endif

/// Real production views with deterministic, local-only disc data for visual review.
@MainActor
struct DiscReviewFixture: View {
    @State private var fixture = DiscReviewState()
    #if os(iOS)
    @State private var keyboardActions = PlozziOSPlayerKeyboardActions()
    #endif

    var body: some View {
        Group {
            if fixture.scenario.hasPrefix("detail") {
                DiscReviewDetail(item: fixture.item, isHome: fixture.scenario == "detail-home-resume")
                .environment(\.discPlaybackDefault,
                              fixture.scenario == "detail-menu-default" ? .openMenu : .playVideo)
            } else {
                player
            }
        }
        .background(.black)
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Locale(identifier: "en_US"))
        .preferredColorScheme(.dark)
    }

    @MainActor
    private struct DiscReviewDetail: View {
        let item: MediaItem
        let isHome: Bool
        @State private var trailer = HeroTrailerController()
        #if os(tvOS)
        @State private var background = HeroBackgroundSettingsModel(store: InMemoryHeroBackgroundSettingsStore())

        var body: some View {
            DetailHeroView(
                item: item, spoilerSettings: .default, playTitle: "Play", onPlay: {}, onPlayDisc: { _ in }
            )
            .environment(trailer)
            .environment(background)
        }
        #else
        @State private var appModel: PlozziOSAppModel = {
            SyncSetupFeatureFlag().isEnabled = false
            let defaults = UserDefaults(suiteName: "DiscReview.\(UUID().uuidString)")!
            let model = PlozziOSAppModel(
                accountStore: AccountStore(secureStore: InMemorySecureStore()),
                profileStore: ProfileStore(defaults: defaults)
            )
            model.settings.heroBackground.settings.detailMode = .off
            return model
        }()
        @State private var sidebar = PlozziOSSidebarGeometryModel()
        @State private var actions = DiscReviewActions()
        @State private var pendingResume: MediaItem?

        var body: some View {
            NavigationStack {
                ScrollView {
                    if isHome {
                        PlozziOSHomeHeroForeground(
                            item: item, detailItem: item, watchlistItem: item,
                            presentation: HeroPresentation(item: item, artworkStyle: .landscape, surface: .home),
                            style: UIDevice.current.userInterfaceIdiom == .phone ? .compactPortrait : .landscape,
                            onPlay: { pendingResume = $0 }
                        )
                        .padding(24)
                        .frame(maxWidth: .infinity, minHeight: 600, alignment: .bottomLeading)
                    } else {
                        PlozziOSDetailHeroSection(
                            item: item, backdropItem: item, playableItem: item, sources: [],
                            selectedSourceAccountID: nil, versions: item.versions, selectedVersionID: nil,
                            onSelectSource: { _ in }, onSelectVersion: { _ in }, actionHandler: actions,
                            onPlay: { selected, _ in pendingResume = selected }
                        )
                    }
                }
            }
            .resumePrompt(item: $pendingResume, anchorID: isHome ? item.id : "play") { _, _ in
                pendingResume = nil
            }
            .environment(appModel)
            .environment(trailer)
            .environment(sidebar)
            .environment(\.plozzMetrics, .touch(density: .standard))
        }
        #endif
    }

    @MainActor
    private final class DiscReviewActions: MediaItemActionHandling {
        func actions(for item: MediaItem, context: MediaItemActionContext) -> [MediaItemAction] {
            [.addToWatchlist, .markWatched]
        }
        func perform(_ action: MediaItemAction, on item: MediaItem, context: MediaItemActionContext) {}
    }

    private var player: some View {
        ZStack {
            #if os(tvOS)
            PlayerView(viewModel: fixture.player)
            #else
            PlayerView(viewModel: fixture.player, showsSharedControls: false, showsLoadingOverlay: false)
            if fixture.player.phase == .ready, !fixture.player.showBringUpSpinner,
               fixture.engine.discMenu?.presentsMenu != true {
                PlozziOSPlayerControlsOverlay(
                    viewModel: fixture.player, keyboardActions: keyboardActions,
                    hasVersions: false, versionsPresented: false,
                    onShowVersions: {}, onClose: {}
                )
            } else {
                VStack {
                    HStack {
                        PlozziOSPlayerCloseButton(action: {})
                        Spacer()
                    }
                    Spacer()
                }
                .foregroundStyle(.white)
                .modifier(PlayerTouchChromePadding())
            }
            PlayerLoadingOverlay(viewModel: fixture.player, discMenuRequested: fixture.opensMenu)
            #endif
        }
        .onChange(of: fixture.player.phase) { _, phase in
            if phase == .ready, fixture.scenario == "videos" { fixture.player.showsDiscVideos = true }
        }
    }
}

@MainActor
private final class DiscReviewState {
    let scenario: String
    let opensMenu: Bool
    let item: MediaItem
    let engine: DiscReviewEngine
    let player: PlayerViewModel

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let index = arguments.firstIndex(of: "--disc-review-fixture")
        scenario = index.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "menu"
        opensMenu = ["menu", "failure", "loading", "notice"].contains(scenario)
        var version = MediaVersion(id: "disc", container: "bdmv")
        version.discMenuAvailability = scenario == "detail-unavailable" ? .unavailable(.unsupportedRuntime) : .unknown
        item = MediaItem(id: "disc-review", title: "Original disc fixture", kind: .movie,
                         runtime: 7200, resumePosition: scenario.hasSuffix("-resume") ? 600 : nil,
                         allowsTitleBasedMetadataMatching: false, versions: [version])
        engine = DiscReviewEngine(scenario: scenario, opensMenu: opensMenu)
        var settings = PlaybackSettings.default
        settings.discPlayback = opensMenu ? .openMenu : .playVideo
        settings.fadeOnDynamicRangeChange = false
        settings.fadeOnFrameRateChange = false
        settings.useCommunityMarkers = false
        let engine = engine
        player = PlayerViewModel(
            provider: DiscReviewProvider(movie: item), itemID: item.id,
            playbackSettings: settings,
            engineFactory: .init(makeNative: { _ in engine }, makePlozzigen: { engine })
        )
    }
}

@MainActor
private final class DiscReviewEngine: VideoEngine {
    let displayName = "Local visual-review fixture"
    let status: VideoEngineStatus = .ready
    var isPaused = true
    let hasPresentedVideoFrame: Bool
    let currentTime: TimeInterval = 720
    let duration: TimeInterval = 7200
    let furthestObservedPosition: TimeInterval = 720
    let audioTracks: [MediaTrack] = []
    let subtitleTracks: [MediaTrack] = []
    var discMenu: DiscMenuPlaybackState?
    var onProgress: (@MainActor () -> Void)?
    var onFailure: (@MainActor (AppError) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onTracksChanged: (@MainActor () -> Void)?
    var onProbedSourceFactsChanged: (@MainActor (EngineProbedSourceFacts) -> Void)?
    var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    private let surface = UIView()

    init(scenario: String, opensMenu: Bool) {
        hasPresentedVideoFrame = scenario != "loading"
        surface.backgroundColor = UIColor(red: 0.035, green: 0.07, blue: 0.1, alpha: 1)
        if opensMenu {
            let state = DiscMenuPlaybackState()
            state.isActive = true
            state.isOpening = scenario == "loading"
            state.hasPresentedVideoFrame = hasPresentedVideoFrame
            state.isFirstPlay = scenario == "loading"
            state.isMenuVisible = scenario == "menu"
            if scenario == "failure" { state.failure = "This disc's menu format is not supported" }
            if scenario == "notice" { state.audioSelectionUnavailable = true }
            discMenu = state
        }
    }

    func load(request: PlaybackRequest, startPosition: TimeInterval) async {}
    func play() { isPaused = false }
    func pause() { isPaused = true }
    func seek(to seconds: TimeInterval) async {}
    func stop() {}
    func selectAudioTrack(_ track: MediaTrack?) {}
    func selectSubtitleTrack(_ track: MediaTrack?) {}
    func makeVideoOutputView() -> UIView { surface }
    func discVideos() async throws -> [DiscVideo] {
        [
            .init(playlist: 800, duration: 7200, chapterCount: 18),
            .init(playlist: 801, duration: 7440, chapterCount: 19),
            .init(playlist: 12, duration: 840, chapterCount: 3)
        ]
    }
}

private struct DiscReviewProvider: MediaProvider {
    let movie: MediaItem
    let kind = ProviderKind.jellyfin
    let session = UserSession(
        server: .init(id: "fixture", name: "Fixture", baseURL: URL(string: "https://fixture.invalid")!,
                      provider: .jellyfin),
        userID: "fixture", userName: "Fixture", deviceID: "fixture", accessToken: "fixture"
    )
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { movie }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        .init(items: [], startIndex: page.startIndex, totalCount: 0)
    }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        let anchor = try NetworkFileLocator(
            accountID: "fixture", sourceID: "fixture", credentialRevision: CredentialRevision(),
            relativePath: "Movie/BDMV/index.bdmv",
            representation: .init(size: 40, identity: .init(kind: .strongETag, value: "\"index\""),
                                  consistency: .changeDetecting),
            formatHint: .init(container: "bdmv")
        )
        var request = PlaybackRequest(item: movie, streamURL: URL(fileURLWithPath: "/fixture/BDMV/index.bdmv"))
        request.playbackSource = .networkDisc(try NetworkDiscLocator(
            anchor: anchor, files: [.init(path: "BDMV/index.bdmv", locator: anchor)]
        ))
        return request
    }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
