import SwiftUI
import CoreModels
import CoreUI
@testable import AppShelliOS

@main
struct PresentationHostApp: App {
    private let interactionModel: PlozziOSAppModel?

    init() {
        guard ProcessInfo.processInfo.arguments.contains("--appearance-interaction-fixture")
            || ProcessInfo.processInfo.arguments.contains("--settings-interaction-fixture") else {
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

    var body: some View {
        Group {
            if ProcessInfo.processInfo.arguments.contains("--settings-interaction-fixture") {
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
