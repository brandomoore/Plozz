import SwiftUI
import UIKit
import CoreModels
import CoreUI
import FeatureAuth
@testable import FeatureHomeCore
@testable import FeatureLiveTV
import FeatureLiveTVCore
import FeatureSettings
@testable import AppShelliOS

@objc protocol PresentationOrientationWindow {
    var supportedPresentationOrientations: UIInterfaceOrientationMask { get }
}

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
        let model: PlozziOSAppModel
        if ProcessInfo.processInfo.arguments.contains("--libraries-in-more")
            || ProcessInfo.processInfo.arguments.contains("--streaming-settings-source") {
            let accounts = AccountStore(secureStore: InMemorySecureStore())
            let provider = CollectionSettingsProvider(
                includesAllLibrariesFixture: ProcessInfo.processInfo.arguments.contains("--all-libraries-fixture")
            )
            let account = Account(id: "navigation-library", from: provider.session)
            let defaults = UserDefaults(suiteName: "MoreNavigationFixture.\(UUID().uuidString)")!
            model = PlozziOSAppModel(accountStore: accounts, profileStore: ProfileStore(defaults: defaults))
            let profile = model.profiles.add(name: "Navigation", isAwaitingSetup: false)
            model.profiles.select(profile.id)
            model.refreshActiveProfileSettings()
            model.accountsProviders.registry.register(.plex) { _ in provider }
            do {
                try accounts.add(account, token: "fixture")
            } catch {
                fatalError("Could not prepare the library navigation fixture: \(error)")
            }
            model.profiles.setActiveAccountIDs([account.id], for: model.profiles.activeProfileID)
            model.accountsProviders.tokenResolver = { _ in "fixture" }
            model.accountsProviders.reloadAccounts()
        } else {
            model = PlozziOSAppModel()
        }
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
        if ProcessInfo.processInfo.arguments.contains("--search-light-theme") {
            model.settings.theme.theme = .light
        } else if ProcessInfo.processInfo.arguments.contains("--search-black-theme") {
            model.settings.theme.theme = .pureBlack
        }
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
            var available = NavigationDestinationDefaults.iOS
            let enabled: [String]
            if ProcessInfo.processInfo.arguments.contains("--libraries-in-more") {
                let libraryKey = "navigation-library:movies"
                available.append(libraryKey)
                if ProcessInfo.processInfo.arguments.contains("--all-libraries-fixture") {
                    available.append(contentsOf: [NavigationLibraryLayout.allLibrariesKey, "navigation-library:shows"])
                }
                enabled = [
                    NavigationLibraryLayout.homeKey, NavigationLibraryLayout.downloadsKey,
                    NavigationLibraryLayout.watchlistKey, NavigationLibraryLayout.liveTVKey,
                    NavigationLibraryLayout.searchKey
                ] + (ProcessInfo.processInfo.arguments.contains("--all-libraries-fixture")
                     ? [NavigationLibraryLayout.allLibrariesKey] : [libraryKey])
            } else if ProcessInfo.processInfo.arguments.contains("--content-in-more") {
                enabled = [
                    NavigationLibraryLayout.homeKey, NavigationLibraryLayout.liveTVKey,
                    NavigationLibraryLayout.settingsKey, NavigationLibraryLayout.watchlistKey,
                    NavigationLibraryLayout.searchKey, NavigationLibraryLayout.downloadsKey
                ]
            } else if ProcessInfo.processInfo.arguments.contains("--profile-rail-fixture") {
                enabled = [
                    NavigationLibraryLayout.homeKey, NavigationLibraryLayout.watchlistKey,
                    NavigationLibraryLayout.liveTVKey, NavigationLibraryLayout.downloadsKey,
                    NavigationLibraryLayout.searchKey
                ]
            } else if ProcessInfo.processInfo.arguments.contains("--settings-in-more") {
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
                .init(enabled: [NavigationLibraryLayout.settingsKey],
                      disabled: available.filter { $0 != NavigationLibraryLayout.settingsKey }),
                available: available,
                automaticallyHiddenKeys: NavigationDestinationDefaults.iOSAutomaticallyHiddenKeys(available: available)
            )
            model.settings.navigation.applyLibrarySections(
                .init(enabled: [NavigationLibraryLayout.homeKey],
                      disabled: available.filter { $0 != NavigationLibraryLayout.homeKey }),
                available: available,
                automaticallyHiddenKeys: NavigationDestinationDefaults.iOSAutomaticallyHiddenKeys(available: available)
            )
            model.settings.navigation.applyLibrarySections(
                .init(enabled: enabled, disabled: available.filter { !enabled.contains($0) }),
                available: available,
                automaticallyHiddenKeys: NavigationDestinationDefaults.iOSAutomaticallyHiddenKeys(available: available)
            )
            if ProcessInfo.processInfo.arguments.contains("--default-navigation") {
                model.settings.navigation.resetLibraryLayout()
            } else if ProcessInfo.processInfo.arguments.contains("--five-navigation-pages") {
                let five = NavigationDestinationDefaults.iOSDefaultVisibleKeys
                    + [NavigationLibraryLayout.allLibrariesKey, "navigation-library:movies"]
                model.settings.navigation.applyLibrarySections(
                    .init(enabled: five, disabled: available.filter { !five.contains($0) }),
                    available: available,
                    automaticallyHiddenKeys: NavigationDestinationDefaults.iOSAutomaticallyHiddenKeys(available: available)
                )
            }
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
            // Hosted XCTest links its own package globals; ask its window for its registry's policy.
            if let owner = window?.windowScene?.keyWindow as? PresentationOrientationWindow {
                return owner.supportedPresentationOrientations
            }
            return PlozziOSWindowOrientation.supportedOrientations(for: window)
        }
    }

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--diagnostics-sharing-fixture") {
                DiagnosticsSharingFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--source-settings") {
                SourceOnboardingFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--featured-card-fixture") {
                FeaturedCardInteractionFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--collection-settings-fixture") {
                CollectionSettingsInteractionFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--hero-request-controls-fixture") {
                HeroRequestControlsFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--theme-mute-fixture") {
                ThemeMusicMuteFixture()
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
            } else if ProcessInfo.processInfo.arguments.contains("--plex-home-onboarding-fixture") {
                PlexHomeOnboardingFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--plex-home-settings-onboarding-fixture") {
                PlexHomeSettingsOnboardingFixture()
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

private struct ThemeMusicMuteFixture: View {
    @State private var theme = ThemeMusicController()
    @State private var trailer = HeroTrailerController()
    @State private var matchesItem = true
    @State private var isActive = true
    @State private var sampleURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                Text(theme.isMuted && theme.player.isMuted ? "Muted" : "Audible")
                    .accessibilityIdentifier("theme-player-audio")
                Toggle("Current item", isOn: $matchesItem)
                Toggle("Active detail", isOn: $isActive)
                Button("Stop theme", action: stop)
            }
            .navigationTitle("Theme music")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    PlozziOSDetailAudioMuteControl(
                        trailer: trailer, themeMusic: theme, itemID: "movie",
                        themePlaybackID: matchesItem ? "account:movie" : "account:other",
                        isActive: isActive
                    )
                }
            }
        }
        .task {
            do {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("theme-mute-fixture.wav")
                var sample = ThemeMusicPreviewSample.data()
                let pcmLength = 22_050 * 180 * 2
                sample.replaceSubrange(44..<sample.count, with: Data(count: pcmLength))
                for (offset, value) in [(4, pcmLength + 36), (40, pcmLength)] {
                    var size = UInt32(value).littleEndian
                    withUnsafeBytes(of: &size) { sample.replaceSubrange(offset..<(offset + 4), with: $0) }
                }
                try sample.write(to: url, options: .atomic)
                sampleURL = url
                theme.setAuthorization("fixture")
                let owner = UUID()
                precondition(theme.claimDetail(owner: owner, playbackID: "account:movie", authorizationID: "fixture"))
                let music = ThemeMusic(
                    itemID: "movie",
                    playbackSource: .publicURL(try SecretFreeURLSource(url: URL(string: "https://example.test/theme.wav")!))
                )
                theme.play(music, resolvedURL: url, playbackID: "account:movie", owner: owner,
                           authorizationID: "fixture", settings: ThemeMusicSettings(isEnabled: true))
            } catch {
                fatalError("Could not prepare theme mute fixture: \(error)")
            }
        }
        .onDisappear(perform: stop)
    }

    private func stop() {
        theme.stop()
        guard let sampleURL else { return }
        do {
            try FileManager.default.removeItem(at: sampleURL)
            self.sampleURL = nil
        } catch {
            fatalError("Could not clean up theme mute fixture: \(error)")
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

private struct CollectionSettingsProvider: MediaProvider, CapabilityReporting, StreamingQualityProviding {
    var includesAllLibrariesFixture = false
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
            + (includesAllLibrariesFixture ? [.init(id: "shows", title: "Shows", kind: .series)] : [])
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
        guard includesAllLibrariesFixture else {
            return .init(items: [], startIndex: page.startIndex, totalCount: 0)
        }
        let item = MediaItem(
            id: containerID == "movies" ? "orbit" : "harbor",
            title: containerID == "movies" ? "Orbit" : "Harbor",
            kind: kind
        )
        return .init(items: page.startIndex == 0 ? [item] : [], startIndex: page.startIndex, totalCount: 1)
    }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func playbackInfo(
        for itemID: String, mediaSourceID: String?, forceTranscode: Bool,
        streaming: StreamingPlaybackOptions
    ) async throws -> PlaybackRequest { throw AppError.notFound }
    func releaseStreamingSession(_ request: PlaybackRequest) async {}
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
    @State private var resumePreviewItem: MediaItem?

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
                .task {
                    let arguments = ProcessInfo.processInfo.arguments
                    if arguments.contains("--libraries-in-more") {
                        await appModel.refreshNavigationLibraries()
                        precondition(!appModel.visibleNavigationLibraries.isEmpty, "The library fixture must discover Movies")
                    }
                    if let index = arguments.firstIndex(of: "--navigation-more-row"),
                       arguments.indices.contains(index + 1) {
                        do {
                            try await OverflowNavigationCapture.openRow(named: arguments[index + 1])
                        } catch {
                            fatalError("Could not open the native More row: \(error)")
                        }
                    } else if arguments.contains("--capture-navigation") {
                        let title = arguments.firstIndex(of: "--navigation-tab").flatMap {
                            arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
                        }
                        do {
                            try await OverflowNavigationCapture.captureTabs(selecting: title)
                        } catch {
                            fatalError("Could not capture native navigation: \(error)")
                        }
                    } else if let index = arguments.firstIndex(of: "--navigation-destination"),
                       arguments.indices.contains(index + 1) {
                        appModel.screenshotDirector.tab = arguments[index + 1]
                    }
                }
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
                .resumePrompt(item: $resumePreviewItem) { _, _ in resumePreviewItem = nil }
                .task {
                    let arguments = ProcessInfo.processInfo.arguments
                    do {
                        if let index = arguments.firstIndex(of: "--playback-scroll-offset"),
                           arguments.indices.contains(index + 1),
                           let offset = Double(arguments[index + 1]) {
                            try await Task.sleep(for: .milliseconds(700))
                            let window = UIApplication.shared.connectedScenes
                                .compactMap { $0 as? UIWindowScene }
                                .flatMap(\.windows).first(where: \.isKeyWindow)
                            func scrollView(in view: UIView) -> UIScrollView? {
                                if let scroll = view as? UIScrollView,
                                   scroll.contentSize.height > scroll.bounds.height { return scroll }
                                return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
                            }
                            guard let window, let scroll = scrollView(in: window) else {
                                preconditionFailure("Playback fixture could not locate its settings list")
                            }
                            let maximum = max(0, scroll.contentSize.height - scroll.bounds.height
                                + scroll.adjustedContentInset.bottom)
                            scroll.setContentOffset(CGPoint(x: 0, y: min(offset, maximum)), animated: false)
                        }
                        if arguments.contains("--resume-prompt-fixture") {
                            appModel.settings.playback.settings.askBeforeResuming = true
                            try await Task.sleep(for: .milliseconds(700))
                            resumePreviewItem = MediaItem(
                                id: "resume-preview", title: "Big Buck Bunny", kind: .movie,
                                runtime: 600, resumePosition: 240
                            )
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        preconditionFailure("Playback fixture setup failed: \(error)")
                    }
                }
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
        .environment(\.themePalette, ThemePalette.palette(
            for: appModel.settings.theme.theme, systemColorScheme: .dark
        ))
        .environment(\.plozzMetrics, .touch(density: .standard))
        .preferredColorScheme(appModel.settings.theme.theme.preferredColorScheme ?? .dark)
        .overlay(alignment: .bottomLeading) {
            if ProcessInfo.processInfo.arguments.contains("--profile-rail-fixture") {
                ProfileToolbarLayoutIndicator()
            }
        }
    }
}

private struct ProfileToolbarLayoutIndicator: View {
    @Environment(\.plozziOSUsesVerticalToolbar) private var usesVerticalToolbar

    var body: some View {
        Text(verbatim: usesVerticalToolbar ? "vertical" : "horizontal")
            .accessibilityIdentifier("profile-toolbar-layout")
            .allowsHitTesting(false)
    }
}
