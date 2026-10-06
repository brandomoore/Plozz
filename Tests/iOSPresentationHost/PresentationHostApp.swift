import SwiftUI
import CoreModels
import CoreUI
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
            let enabled = ProcessInfo.processInfo.arguments.contains("--settings-in-more")
                ? available
                : [NavigationLibraryLayout.homeKey, NavigationLibraryLayout.downloadsKey,
                   NavigationLibraryLayout.settingsKey]
            model.settings.navigation.applyLibrarySections(
                .init(enabled: enabled, disabled: available.filter { !enabled.contains($0) }),
                available: available
            )
        }
        interactionModel = model
    }

    var body: some Scene {
        WindowGroup {
            if let interactionModel {
                SettingsInteractionFixture(appModel: interactionModel)
            } else {
                Color.black
            }
        }
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

    var body: some View {
        Group {
            if ProcessInfo.processInfo.arguments.contains("--navigation-interaction-fixture") {
                PlozziOSTabShell(
                    appModel: appModel,
                    onAddServer: {},
                    showingSettings: $showingSettings,
                    showingProfileSwitcher: $showingProfiles,
                    deferredPairingURL: $deferredPairingURL,
                    systemColorScheme: .dark
                )
                .environment(sidebarGeometry)
                .environment(heroTrailers)
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
