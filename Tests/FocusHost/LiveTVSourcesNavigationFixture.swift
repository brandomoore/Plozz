@testable import AppRuntime
@testable import AppShell
import CoreModels
import CoreSecureStore
import CoreUI
import FeatureAuthCore
import FeatureLiveTVCore
import FeatureSettings
import SwiftUI

struct LiveTVSourcesNavigationFixture: View {
    @State private var fixture: Fixture?
    @State private var issue: String?
    @State private var navigation = SettingsPageNavigation<String>()

    var body: some View {
        Group {
            if let fixture {
                SettingsPageStack(navigation: navigation, pageWidth: 960, onRootBack: {}) {
                    if ProcessInfo.processInfo.arguments.contains("--settings-overview-fixture") {
                        LiveTVSettingsView(
                            store: LiveTVViewSettingsStore(defaults: fixture.defaults, namespace: "fixture"),
                            preferencesStore: LiveTVPreferencesStore(defaults: fixture.defaults, namespace: "fixture")
                        ) { preferences in
                            AnyView(LiveTVShellSourcesContent(
                                runtime: fixture.runtime, library: fixture.library,
                                accounts: fixture.accounts, connectServer: nil, didConfigurePlaylist: {},
                                settingsPreferences: preferences
                            ))
                        }
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 24) {
                                SettingsPageHeader(SettingsCopy.tvSources)
                                LiveTVShellSourcesContent(
                                    runtime: fixture.runtime, library: fixture.library,
                                    accounts: fixture.accounts, connectServer: nil, didConfigurePlaylist: {}
                                )
                            }
                            .padding(28)
                        }
                    }
                } destination: { _ in EmptyView() }
                .environment(fixture.profiles)
                .environment(\.settingsInWorkspace, true)
                .task(id: fixture.library.refreshRequest) {
                    await fixture.library.refresh(accounts: fixture.accounts)
                }
            } else if let issue {
                Text(verbatim: issue).accessibilityIdentifier("sources-navigation-fixture-error")
            } else {
                ProgressView()
            }
        }
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark)
        .background { SettingsPageBackground() }
        .task {
            guard fixture == nil else { return }
            do {
                let prepared = try Fixture()
                await prepared.runtime.restore()
                await prepared.runtime.catalog.refresh()
                await prepared.runtime.scanBinding.waitUntilPrepared()
                await prepared.library.refresh(accounts: prepared.accounts)
                fixture = prepared
            } catch {
                issue = String(describing: error)
            }
        }
    }

    @MainActor
    private final class Fixture {
        let profiles: ProfilesModel
        let accounts: AccountsProvidersModel
        let runtime: LiveTVSourcesRuntime
        let library: LiveTVLibraryRuntime
        let defaults: UserDefaults

        init() throws {
            let namespace = "SourcesNavigation.\(UUID())"
            let defaults = UserDefaults(suiteName: namespace)!
            self.defaults = defaults
            let profiles = ProfilesModel(store: ProfileStore(defaults: defaults))
            profiles.select(profiles.add(name: "Sources fixture").id)
            self.profiles = profiles
            let profileID = profiles.activeProfileID
            let accounts = AccountsProvidersModel(
                accountStore: AccountStore(secureStore: InMemorySecureStore()),
                registry: ProviderRegistry(), profilesModel: profiles
            )
            accounts.reloadAccounts()
            self.accounts = accounts
            let store = LiveTVSourcesStore(secureStore: InMemorySecureStore(), namespace: namespace)
            let count = ProcessInfo.processInfo.arguments.contains("--settings-overview-fixture") ? 6 : 1
            try store.save(.init(playlists: (0..<count).map { index in
                .init(id: index == 0 ? "fixture" : "fixture-\(index)",
                      name: count == 1 ? "Fixture source" : "Fixture source \(index + 1)",
                      playlistURL: URL(string: "https://fixture.invalid/playlist.m3u")!)
            }))
            runtime = LiveTVSourcesRuntime(
                profileID: profileID, store: store,
                approvals: LiveTVSourceApprovalStore(defaults: defaults, profileID: profileID, namespace: namespace),
                cache: LiveTVIndexedCache(
                    url: FileManager.default.temporaryDirectory.appendingPathComponent(namespace + ".sqlite"),
                    namespace: namespace, authorizationScope: "fixture", secureStore: InMemorySecureStore()
                ),
                loader: SourcesNavigationLoader(),
                preferencesStore: LiveTVPreferencesStore(defaults: defaults, namespace: namespace),
                scanCoordinator: LiveTVChannelScanCoordinator(
                    store: LiveTVChannelHealthStore(defaults: defaults, namespace: namespace)
                ),
                context: { LiveTVSourceApprovalContext(profiles: profiles) },
                accountAuthorizationID: { accounts.liveTVAuthorizationID }
            )
            library = LiveTVLibraryRuntime(
                profileID: profileID, profiles: profiles,
                definitionsStore: LibraryChannelDefinitionStore(
                    secureStore: InMemorySecureStore(), namespace: namespace
                ),
                snapshotStore: LibraryChannelSnapshotStore(databaseURL: nil)
            )
        }
    }
}

private struct SourcesNavigationLoader: LiveTVSourceLoading {
    func loadPlaylist(from url: URL) async throws -> LiveTVPlaylistImport {
        try LiveTVPlaylistParser(baseURL: url).parse("""
        #EXTM3U
        #EXTINF:-1 tvg-id="fixture",Fixture channel
        https://fixture.invalid/channel.m3u8
        """)
    }

    func loadGuide(
        from url: URL, channels: [LiveTVPrototypeChannel], now: Date
    ) async throws -> LiveTVGuideImport {
        throw LiveTVSourceImportError.invalidGuide
    }
}
