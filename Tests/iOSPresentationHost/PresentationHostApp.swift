import SwiftUI
import CoreModels
import CoreUI
import FeatureAuth
import FeatureHomeCore
@testable import AppShelliOS

@main
struct PresentationHostApp: App {
    private let interactionModel: PlozziOSAppModel?

    init() {
        guard ProcessInfo.processInfo.arguments.contains("--appearance-interaction-fixture")
            || ProcessInfo.processInfo.arguments.contains("--settings-interaction-fixture")
            || ProcessInfo.processInfo.arguments.contains("--navigation-interaction-fixture") else {
            interactionModel = nil
            return
        }
        // Seed once per process, not whenever SwiftUI recreates a fixture view.
        let sync = SyncSetupFeatureFlag()
        sync.isEnabled = false
        let model = PlozziOSAppModel()
        model.settings.density.density = .standard
        model.settings.cardStyle.captions = .default
        model.settings.cardStyle.style = .borderless
        model.settings.theme.theme = .dark
        model.settings.theme.gradientEnabled = true
        model.settings.playback.settings = .default
        model.settings.spoilers.settings = .default
        model.settings.detailPage.settings = .default
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

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--iptv-removal-fixture") {
                IPTVRemovalFixture()
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
            } else if ProcessInfo.processInfo.arguments.contains("--settings-interaction-fixture") {
                PlozziOSSettingsView(appModel: appModel, onClose: {}, systemColorScheme: .dark)
            } else {
                NavigationStack {
                    PlozziOSAppearanceSettingsView(
                        appModel: appModel,
                        theme: appModel.settings.theme,
                        transparency: appModel.settings.transparency,
                        cardStyle: appModel.settings.cardStyle,
                        density: appModel.settings.density,
                        watchIndicator: appModel.settings.watchIndicator,
                        navigation: appModel.settings.navigation
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
