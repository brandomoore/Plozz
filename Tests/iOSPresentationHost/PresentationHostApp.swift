import SwiftUI
import UIKit
import CoreModels
import CoreUI
import FeatureAuth
import FeatureHomeCore
@testable import FeatureLiveTV
import FeatureLiveTVCore
import FeatureSettings
@testable import AppShelliOS

@main
struct PresentationHostApp: App {
    @UIApplicationDelegateAdaptor(PresentationOrientationDelegate.self) private var orientationDelegate
    private let interactionModel: PlozziOSAppModel?

    init() {
        guard ProcessInfo.processInfo.arguments.contains("--appearance-interaction-fixture")
            || ProcessInfo.processInfo.arguments.contains("--settings-interaction-fixture")
            || ProcessInfo.processInfo.arguments.contains("--playback-settings-fixture")
            || ProcessInfo.processInfo.arguments.contains("--navigation-interaction-fixture") else {
            interactionModel = nil
            return
        }
        // Seed once per process, not whenever SwiftUI recreates a fixture view.
        let sync = SyncSetupFeatureFlag()
        sync.isEnabled = false
        if ProcessInfo.processInfo.arguments.contains("--sync-breakdown-fixture") {
            Self.seedSyncBreakdown()
        }
        let model = PlozziOSAppModel()
        if ProcessInfo.processInfo.arguments.contains("--settings-interaction-fixture") {
            var profile = model.profiles.activeProfile
            profile.isKids = ProcessInfo.processInfo.arguments.contains("--kids-settings")
            model.profiles.update(profile)
            model.profiles.setParentalPIN(
                ProcessInfo.processInfo.arguments.contains("--parental-pin")
                    ? ParentalPIN.make(pin: "1234", iterations: 1) : nil
            )
            DeveloperModeModel.shared.disable()
        }
        model.settings.density.density = .standard
        model.settings.cardStyle.captions = .default
        model.settings.cardStyle.artwork = .default
        model.settings.cardStyle.style = .borderless
        model.settings.theme.theme = .dark
        model.settings.theme.gradientEnabled = true
        model.settings.playback.settings = .default
        if ProcessInfo.processInfo.arguments.contains("--reset-read-ahead") {
            PlaybackReadAheadStore().save(.default)
        }
        if ProcessInfo.processInfo.arguments.contains("--silo-streaming") {
            model.settings.playback.settings.streaming.codec = .preferHEVC
        }
        model.settings.spoilers.settings = .default
        model.settings.detailPage.settings = .default
        model.settings.homeVisibility.useRowDefaults(.matchServer)
        model.settings.hero.settings = .default
        model.settings.heroBackground.settings = .default
        model.settings.subtitleBehavior.settings = .default
        model.settings.subtitlePolicy.overrides = [:]
        model.settings.subtitleStyle.style = .profileDefault
        model.settings.subtitleStyle.usesSeparateLiveTVStyle = false
        model.settings.nightShift.settings = .default
        if ProcessInfo.processInfo.arguments.contains("--navigation-interaction-fixture") {
            let available = NavigationDestinationDefaults.iOS
            let enabled: [String]
            if ProcessInfo.processInfo.arguments.contains("--settings-in-more") {
                enabled = available
            } else if ProcessInfo.processInfo.arguments.contains("--settings-first") {
                enabled = [
                    NavigationLibraryLayout.settingsKey, NavigationLibraryLayout.homeKey,
                    NavigationLibraryLayout.downloadsKey, NavigationLibraryLayout.searchKey
                ]
            } else {
                enabled = [
                    NavigationLibraryLayout.homeKey, NavigationLibraryLayout.downloadsKey,
                    NavigationLibraryLayout.settingsKey
                ]
            }
            // Explicitly show fixture pages even when their empty content would hide them automatically.
            model.settings.navigation.applyLibrarySections(
                .init(enabled: [], disabled: available), available: available
            )
            model.settings.navigation.applyLibrarySections(
                .init(enabled: enabled, disabled: available.filter { !enabled.contains($0) }),
                available: available
            )
        }
        interactionModel = model
    }

    private static func seedSyncBreakdown() {
        struct State: Encodable { let ledger: SyncLedger }
        do {
            let folder = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ).appendingPathComponent("PlozzSync", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var records: [SyncRecordID: Data] = [:]
            for (kind, count, size) in [
                ("profile", 3, 182), ("membership", 3, 96), ("descriptor", 2, 344),
                ("setting", 42, 384)
            ] {
                for index in 0..<count {
                    let name = kind == "setting" ? "setting:preview:key-\(index)" : "\(kind):preview-\(index)"
                    records[name] = Data(repeating: 0, count: size)
                }
            }
            var config = SyncLedger()
            _ = config.reconcileLocal(desired: records, now: 1)
            try JSONEncoder().encode(State(ledger: config)).write(
                to: folder.appendingPathComponent("cloud-config-v3.json"), options: .atomic
            )
            var media = SyncLedger()
            _ = media.reconcileLocal(desired: Dictionary(uniqueKeysWithValues: (0..<18).map { _ in
                ("watchlist:preview:\(UUID().uuidString)", Data(repeating: 0, count: 312))
            }), now: 1)
            try JSONEncoder().encode(media).write(
                to: folder.appendingPathComponent("cloud-media-state-v1.json"), options: .atomic
            )
        } catch {
            fatalError("Could not prepare isolated sync preview data: \(error)")
        }
    }

    private final class PresentationOrientationDelegate: NSObject, UIApplicationDelegate {
        func application(
            _ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?
        ) -> UIInterfaceOrientationMask {
            PlozziOSWindowOrientation.supportedOrientations(for: window)
        }
    }

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--tracker-history-import-fixture") {
                TrackerHistoryImportFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--source-settings") {
                SourceOnboardingFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--featured-card-fixture") {
                FeaturedCardInteractionFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--collection-settings-fixture") {
                CollectionSettingsInteractionFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--hero-request-controls-fixture") {
                HeroRequestControlsFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--home-hero-fixture") {
                HomeHeroInteractionFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--player-layout-fixture") {
                PlayerLayoutFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--device-setup-fixture") {
                DeviceSetupInteractionFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--player-glass-fixture") {
                PlayerGlassAppearanceFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--playback-failure-fixture") {
                PlaybackFailureFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--server-address-fixture") {
                ServerAddressNavigationFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--iptv-organization-fixture") {
                IPTVOrganizationFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--category-search-fixture") {
                LiveTVCategorySearchFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--sync-erasure-fixture") {
                SyncErasureInteractionFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--watchlist-feedback-fixture") {
                WatchlistFeedbackFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--touch-feedback-fixture") {
                TouchFeedbackFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--rotation-player-fixture") {
                PlayerRotationFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--plex-user-chooser-fixture") {
                PlexUserChooserInteractionFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--profile-selection-fixture") {
                ProfileSelectionInteractionFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--profile-picker-fixture") {
                ProfilePickerInteractionFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--downloads-interaction-fixture") {
                DownloadsInteractionFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--iptv-removal-fixture") {
                IPTVRemovalFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--source-retry-fixture") {
                SourceRetryFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--iptv-setup-fixture") {
                IPTVSetupFixture()
            } else if let interactionModel {
                SettingsInteractionFixture(appModel: interactionModel)
            } else {
                Color.black
            }
        }
    }
}

private struct CollectionSettingsInteractionFixture: View {
    private let provider = CollectionSettingsProvider()
    @State private var hero = HeroSettingsModel(store: InMemoryHeroSettingsStore())
    @State private var background = HeroBackgroundSettingsModel(store: InMemoryHeroBackgroundSettingsStore())
    @State private var cards: CardStyleSettingsModel
    @State private var visibility: HomeLibraryVisibilityModel

    init() {
        let suite = "CollectionSettingsInteractionFixture"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        _cards = State(initialValue: CardStyleSettingsModel(
            store: CardStyleSettingsStore(defaults: defaults),
            focusStore: CardFocusStyleSettingsStore(defaults: defaults),
            captionStore: CardCaptionSettingsStore(defaults: defaults),
            artworkStore: ArtworkSettingsStore(defaults: defaults)
        ))
        _visibility = State(initialValue: HomeLibraryVisibilityModel(
            store: HomeLibraryVisibilityStore(defaults: defaults)
        ))
    }

    var body: some View {
        // Inject through the production page, not above the navigation stack where it masks missing handoffs.
        NavigationStack {
            PlozziOSHomeSettingsView(
                hero: hero, heroBackground: background, cards: cards, visibility: visibility,
                accounts: [ResolvedAccount(account: Account(from: provider.session), provider: provider)]
            )
        }
        .environment(\.locale, Locale(identifier: "en_US"))
        .environment(\.themePalette, .dark)
        .environment(\.plozzMetrics, .touch(density: .standard))
        .preferredColorScheme(.dark)
    }
}

private struct CollectionSettingsProvider: MediaProvider, CapabilityReporting {
    let kind: ProviderKind = .plex
    let capabilities: ProviderCapability = [.libraryCollections]
    let session = UserSession(
        server: MediaServer(
            id: "collection-settings", name: "Collection server",
            baseURL: URL(string: "https://collection-settings.example.test")!, provider: .plex
        ),
        userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
    )

    func libraries() async throws -> [MediaLibrary] {
        [.init(id: "movies", title: "Movies", kind: .movie)]
    }
    func collections(in libraryID: String, page: PageRequest) async throws -> MediaPage {
        .init(items: [
            .init(id: "weekend", title: "Weekend picks", kind: .collection),
            .init(id: "favorites", title: "Favorites", kind: .collection)
        ], startIndex: 0, totalCount: 2)
    }
    func collectionMembers(of collectionID: String, page: PageRequest) async throws -> MediaPage {
        .init(items: [.init(id: "orbit", title: "Orbit", kind: .movie)], startIndex: 0, totalCount: 1)
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        .init(items: [], startIndex: page.startIndex, totalCount: 0)
    }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

private struct SourceRetryFixture: View {
    @State private var retries = 0
    @State private var sources: LiveTVSourceManagementModel
    @State private var imports: LiveTVPrototypeImportModel
    @State private var catalog = LiveTVPrototypeModel(channels: [])
    @State private var profiles: ProfilesModel
    @State private var loader: Loader

    init() {
        let allowsChanges = ProcessInfo.processInfo.arguments.contains("--allow-source-changes")
        let store = Store(allowsChanges: allowsChanges)
        let loader = Loader()
        _loader = State(initialValue: loader)
        _sources = State(initialValue: LiveTVSourceManagementModel(store: store, canMutate: { allowsChanges }))
        _imports = State(initialValue: LiveTVPrototypeImportModel(
            configuration: store.load(), loader: loader
        ))
        let domain = "SourcesRetryInteractionFixture"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        _profiles = State(initialValue: ProfilesModel(store: ProfileStore(defaults: defaults)))
    }

    var body: some View {
        VStack {
            NavigationStack {
                LiveTVSourcesView(
                    model: sources, imports: imports, refresh: {},
                    refreshSource: {
                        retries += 1
                        try await imports.reloadSource($0, into: catalog)
                    }
                )
            }
            Text(verbatim: "Retries: \(retries)").accessibilityIdentifier("fixture-source-retries")
            Button("Finish retry") { Task { await loader.finishRetry() } }
                .accessibilityIdentifier("fixture-finish-retry")
        }
        .environment(profiles)
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Locale(identifier: "en_US"))
        .task { await imports.reload(into: catalog) }
    }

    private final class Store: LiveTVSourcesStoring, @unchecked Sendable {
        private let lock = NSLock()
        private let allowsChanges: Bool
        private var configuration = LiveTVSourcesConfiguration(playlists: [.init(
            id: "source", name: "Test playlist", playlistURL: URL(string: "https://example.test/list.m3u")!
        )])

        init(allowsChanges: Bool) { self.allowsChanges = allowsChanges }

        func load() -> LiveTVSourcesConfiguration {
            lock.withLock { configuration }
        }

        func save(_ configuration: LiveTVSourcesConfiguration) throws {
            guard allowsChanges else { throw LiveTVSourcesStoreError.saveFailed }
            lock.withLock { self.configuration = configuration }
        }
    }

    private actor Loader: LiveTVSourceLoading {
        private var loads = 0
        private var completedRetries = 0

        func finishRetry() { completedRetries += 1 }

        func loadPlaylist(from url: URL) async throws -> LiveTVPlaylistImport {
            loads += 1
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while completedRetries < loads - 1, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            throw LiveTVSourceImportError.downloadFailed
        }
        func loadGuide(
            from url: URL, channels: [LiveTVPrototypeChannel], now: Date
        ) async throws -> LiveTVGuideImport {
            throw LiveTVSourceImportError.downloadFailed
        }
    }
}

private struct SyncErasureInteractionFixture: View {
    @State private var erasures = 0
    @State private var recovering = false
    @State private var showReview = false

    var body: some View {
        NavigationStack {
            VStack {
                Text(verbatim: "Erasures: \(erasures)")
                    .accessibilityIdentifier("fixture-erasure-count")
                Button("Review Erasure") { showReview = true }
            }
        }
        .plozzSheet(isPresented: $showReview) {
            SyncEraseDataView(
                profileID: "fixture",
                isAllowed: !ProcessInfo.processInfo.arguments.contains("--sync-erasure-denied"),
                status: SyncStatusProvider {
                    .init(summary: "Off", isSyncing: false, isRecovering: recovering)
                },
                erase: { erasures += 1; recovering = true }
            )
        }
        .environment(\.locale, Locale(identifier: "en_US"))
        .environment(\.themePalette, .dark)
    }
}

private struct IPTVRemovalFixture: View {
    private let session: UserSession

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let playlistHeaders = arguments.contains("--playlist-headers")
        let guideHeaders = arguments.contains("--guide-headers")
        let address = URL(string: "https://playlist.example.test/channels.m3u")!
        let guides = (1...4).map { URL(string: "https://guide.example.test/\($0).xml")! }
        let headers = Dictionary(uniqueKeysWithValues: (1...3).map { ("X-Guide-\($0)", "fixture-\($0)") })
        do {
            let credential = try IPTVCredential(
                mode: .playlist, address: address,
                headers: playlistHeaders ? headers : [:], guideURL: guides[0],
                additionalGuideURLs: playlistHeaders || guideHeaders ? [] : Array(guides.dropFirst()),
                guideHeaders: guideHeaders ? headers : [:]
            )
            session = UserSession(
                server: .init(id: "fixture", name: "Fixture playlist", baseURL: address, provider: .iptv),
                userID: "fixture", userName: "IPTV", deviceID: "fixture",
                accessToken: try credential.encoded()
            )
        } catch {
            fatalError("Invalid IPTV removal fixture: \(error)")
        }
    }

    var body: some View {
        NavigationStack {
            IPTVSignInView(
                deviceID: "fixture", reconnecting: session,
                onAuthenticated: { _ in fatalError("The removal fixture must not connect.") },
                onCancel: {}
            )
        }
        .environment(\.locale, Locale(identifier: "en_US"))
        .environment(\.themePalette, .dark)
        .environment(\.plozzMetrics, .touch(density: .standard))
    }
}

private struct SettingsInteractionFixture: View {
    let appModel: PlozziOSAppModel
    @State private var language = AppLanguageSettingsModel()
    @State private var showingSettings = false
    @State private var showingProfiles = false
    @State private var capturedSettingsURL: String?
    @State private var deferredPairingURL: URL?
    @State private var sidebarGeometry = PlozziOSSidebarGeometryModel()
    @State private var heroTrailers = HeroTrailerController()
    @State private var homeViewModelBox = LazyViewState<HomeViewModel>()

    var body: some View {
        Group {
            if ProcessInfo.processInfo.arguments.contains("--navigation-interaction-fixture") {
                PlozziOSTabShell(
                    appModel: appModel,
                    homeViewModelBox: homeViewModelBox,
                    onAddServer: {},
                    showingSettings: $showingSettings,
                    showingProfileSwitcher: $showingProfiles,
                    deferredPairingURL: $deferredPairingURL,
                    systemColorScheme: .dark
                )
                .environment(sidebarGeometry)
                .environment(heroTrailers)
                .overlay(alignment: .topTrailing) {
                    if ProcessInfo.processInfo.arguments.contains("--settings-direct-presentation") {
                        Button("Fixture Settings") { showingSettings = true }
                            .accessibilityIdentifier("fixture-open-settings")
                    }
                }
            } else if ProcessInfo.processInfo.arguments.contains("--playback-settings-fixture") {
                NavigationStack {
                    PlozziOSPlaybackSettingsView(
                        model: appModel.settings.playback,
                        audioPolicy: appModel.settings.audioPolicy,
                        hasStreamingServer: !ProcessInfo.processInfo.arguments.contains("--share-only-playback"),
                        streamingSupport: ProcessInfo.processInfo.arguments.contains("--silo-streaming")
                            ? .silo : .standard
                    )
                }
                .dynamicTypeSize(ProcessInfo.processInfo.arguments.contains("--large-text") ? .accessibility2 : .large)
                .tint(ThemePalette.dark.primaryText)
            } else if ProcessInfo.processInfo.arguments.contains("--settings-interaction-fixture") {
                PlozziOSSettingsView(appModel: appModel, onClose: {}, systemColorScheme: .dark)
                    .transformEnvironment(\.horizontalSizeClass) { sizeClass in
                        if ProcessInfo.processInfo.arguments.contains("--compact-settings") {
                            sizeClass = .compact
                        }
                    }
                    .dynamicTypeSize(ProcessInfo.processInfo.arguments.contains("--large-text") ? .accessibility2 : .large)
                    .environment(\.openURL, OpenURLAction { url in
                        guard ProcessInfo.processInfo.arguments.contains("--capture-settings-links") else {
                            return .systemAction
                        }
                        capturedSettingsURL = url.absoluteString
                        return .handled
                    })
                    .overlay(alignment: .bottom) {
                        if let capturedSettingsURL {
                            Text(verbatim: capturedSettingsURL)
                                .accessibilityIdentifier("fixture-opened-settings-url")
                        }
                    }
            } else {
                NavigationStack {
                    PlozziOSAppearanceSettingsView(
                        appModel: appModel,
                        theme: appModel.settings.theme,
                        transparency: appModel.settings.transparency,
                        cardStyle: appModel.settings.cardStyle,
                        density: appModel.settings.density,
                        watchIndicator: appModel.settings.watchIndicator
                    )
                }
            }
        }
        .environment(appModel)
        .environment(language)
        .environment(\.locale, Locale(identifier: "en_US"))
        .environment(\.themePalette, .dark)
        .environment(\.plozzMetrics, .touch(density: .standard))
        .preferredColorScheme(.dark)
    }
}
