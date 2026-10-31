import AppShell
import CoreModels
import CoreUI
@testable import FeatureSettings
import SwiftUI

struct ViewCustomizationFixture: View {
    @State private var models: ProfileSettingsModel
    @State private var navigation: SettingsNavigationModel

    init() {
        let models = ProfileSettingsModel(namespace: "ViewCustomizationRemote.\(UUID())")
        models.cardStyleModel.artwork = ArtworkSettings(preference: .online)
        models.cardStyleModel.captions = .default
        if ProcessInfo.processInfo.arguments.contains("--preview-showcase") {
            models.heroSettingsModel.settings.style = .followsFocus
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-hero") {
            models.heroSettingsModel.settings.immersiveRows =
                !ProcessInfo.processInfo.arguments.contains("--preview-classic")
            models.heroSettingsModel.settings.spotlightEnabled =
                !ProcessInfo.processInfo.arguments.contains("--preview-hero-off")
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-row-style") {
            models.heroSettingsModel.settings.immersiveRows =
                !ProcessInfo.processInfo.arguments.contains("--preview-classic")
            models.heroSettingsModel.settings.showsRatings =
                !ProcessInfo.processInfo.arguments.contains("--preview-ratings-off")
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-episode-stills") {
            models.homeLibraryVisibilityModel.setContinueWatchingShowsSeriesArtwork(false)
        }
        let navigation = SettingsNavigationModel()
        navigation.appearanceRowID = ProcessInfo.processInfo.arguments.contains("--labels") ? "cards" : "artwork"
        _models = State(initialValue: models)
        _navigation = State(initialValue: navigation)
    }

    var body: some View {
        NavigationStack {
            if ProcessInfo.processInfo.arguments.contains("--preview-hero") {
                HomeHeroSettingsView(
                    libraries: [], accounts: [], visibility: models.homeLibraryVisibilityModel
                )
            } else if ProcessInfo.processInfo.arguments.contains("--preview-row-style") {
                HomeRowStyleSettingsView(libraries: [], accounts: [])
                    .frame(width: 1100)
            } else {
                AppearanceDetailView(
                    librariesScope: ProfileLibrariesScope(
                        accounts: [], activeProfile: .init(id: "fixture", name: "Viewer"),
                        discoveredLibraries: .empty, refreshingLibraryAccountIDs: [],
                        unreachableLibraryAccountIDs: [], reloadLibraries: {},
                        homeVisibility: models.homeLibraryVisibilityModel,
                        isAccountIncludedInActiveProfile: { _ in false },
                        onSetAccountIncluded: { _, _ in }, onAddAccount: {},
                        plexHomeUsersFetcher: { _ in [] }, onSelectPlexHomeUser: { _, _ in }
                    ),
                    settingsNavigation: navigation,
                    theme: models.themeModel, nightShift: models.nightShiftModel,
                    spoilers: models.spoilerModel
                )
            }
        }
        .environment(models.musicPlayerModel)
        .environment(models.uiDensityModel)
        .environment(models.cardStyleModel)
        .environment(models.watchStatusIndicatorModel)
        .environment(models.navigationStyleModel)
        .environment(models.transparencyModel)
        .environment(models.appLanguageModel)
        .environment(models.contentRatingModel)
        .environment(models.heroSettingsModel)
        .environment(models.heroBackgroundModel)
        .environment(\.plozzNavigationStyle, previewNavigationStyle)
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Locale(identifier: "en_US"))
    }

    private var previewNavigationStyle: NavigationStyle {
        if ProcessInfo.processInfo.arguments.contains("--preview-rail") { return .rail }
        if ProcessInfo.processInfo.arguments.contains("--preview-tabs") { return .tabBar }
        return .sidebar
    }
}
