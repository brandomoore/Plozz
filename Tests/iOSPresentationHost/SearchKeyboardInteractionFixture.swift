import CoreModels
import CoreUI
import FeatureAuth
import FeatureHomeCore
import SwiftUI
@testable import AppShelliOS

struct SearchKeyboardInteractionFixture: View {
    @State private var appModel: PlozziOSAppModel
    @State private var trailer = HeroTrailerController()
    @State private var sidebar = PlozziOSSidebarGeometryModel()
    @State private var showsSettings = false

    init() {
        SyncSetupFeatureFlag().isEnabled = false
        let accounts = AccountStore(secureStore: InMemorySecureStore())
        let defaults = UserDefaults(suiteName: "SearchKeyboardFixture.\(UUID().uuidString)")!
        let model = PlozziOSAppModel(accountStore: accounts, profileStore: ProfileStore(defaults: defaults))
        let profile = model.profiles.add(name: "Search", isAwaitingSetup: false)
        model.profiles.select(profile.id)
        model.refreshActiveProfileSettings()
        let provider = SearchKeyboardProvider()
        let account = Account(id: "search-keyboard", from: provider.session)
        model.accountsProviders.registry.register(.jellyfin) { _ in provider }
        do {
            try accounts.add(account, token: "fixture")
        } catch {
            fatalError("Could not prepare search fixture: \(error)")
        }
        model.profiles.setActiveAccountIDs([account.id], for: profile.id)
        model.accountsProviders.tokenResolver = { _ in "fixture" }
        model.accountsProviders.reloadAccounts()
        model.settings.cardStyle.captions = .default
        model.settings.heroBackground.settings.detailMode = .off
        model.metadataProviderSettingsModel.settings = MetadataProviderSettings(
            orderMode: .custom, preferOnlineArtwork: false,
            disabledOrder: MetadataSourceAttribution.all.map(\.id)
        )
        _appModel = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            PlozziOSSearchView(appModel: appModel, onShowSettings: { showsSettings = true })
        }
        .sheet(isPresented: $showsSettings) {
            Text("Settings opened").accessibilityIdentifier("search-fixture-settings")
        }
        .environment(appModel)
        .environment(trailer)
        .environment(sidebar)
        .environment(\.themePalette, .dark)
        .environment(\.plozzReduceTransparency, ProcessInfo.processInfo.arguments.contains("--search-opaque"))
        .environment(\.plozzMetrics, .touch(density: .standard))
        .environment(\.locale, Locale(identifier: "en_US"))
        .preferredColorScheme(.dark)
    }
}

private actor SearchKeyboardProvider: MediaProvider {
    nonisolated let kind: ProviderKind = .jellyfin
    nonisolated let session = UserSession(
        server: MediaServer(
            id: "search-keyboard", name: "Search fixture",
            baseURL: URL(string: "https://search-keyboard.example.invalid")!, provider: .jellyfin
        ),
        userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
    )
    private var hasFailedRetry = false

    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        .init(items: [], startIndex: 0, totalCount: 0)
    }
    func item(id: String) async throws -> MediaItem { Self.result(id: id) }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] {
        if query == "empty" { return [] }
        if query == "slow" { try await Task.sleep(for: .seconds(30)) }
        if query == "failed" { throw AppError.notFound }
        if query == "retry", !hasFailedRetry {
            hasFailedRetry = true
            throw AppError.notFound
        }
        return (1...(query == "many" ? 60 : 1)).map {
            Self.result(id: String(format: "%02d", $0))
        }
    }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }

    private static func result(id: String) -> MediaItem {
        MediaItem(id: id, title: "Keyboard result \(id)", kind: .movie, sourceAccountID: "search-keyboard")
    }
}
