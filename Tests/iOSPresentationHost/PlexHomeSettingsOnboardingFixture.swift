import CoreModels
import CoreUI
import FeatureAuth
import SwiftUI
@testable import AppRuntime
@testable import AppShelliOS

@MainActor
struct PlexHomeSettingsOnboardingFixture: View {
    @State private var app: PlozziOSAppModel
    @State private var language = AppLanguageSettingsModel()
    @State private var showsSettings = false
    private let users: [PlexHomeUser]

    init() {
        SyncSetupFeatureFlag().isEnabled = false
        let defaults = UserDefaults(suiteName: "PlexHomeSettingsOnboarding.\(UUID())")!
        let store = ProfileStore(defaults: defaults)
        let profiles = ProfilesModel(store: store)
        profiles.markFirstRunProfileSetupComplete()
        var locked = profiles.add(
            name: "Locked viewer", activeAccountIDs: ["plex"],
            plexHomeUserBindings: ["plex": .init(
                homeUserID: "locked", name: "Locked viewer", requiresPIN: false, pinRequirementVerified: true
            )]
        )
        locked.replaceLock(with: ProfileLock.make(pin: "1357", iterations: 1))
        profiles.update(locked)
        let accounts = AccountStore(secureStore: InMemorySecureStore())
        do {
            try accounts.add(.init(
                id: "plex", server: .init(
                    id: "server", name: "Fixture", baseURL: URL(string: "https://fixture.example.invalid")!, provider: .plex
                ), userID: "owner", userName: "Owner", deviceID: "fixture"
            ), token: "fixture-owner")
        } catch {
            preconditionFailure("Could not create synthetic Plex sign-in: \(error)")
        }
        let users = [
            PlexHomeUser(id: "parent", name: "Parent", requiresPIN: true, isAdmin: true),
            PlexHomeUser(id: "locked", name: "Locked viewer", requiresPIN: false)
        ]
        self.users = users
        let app = PlozziOSAppModel(accountStore: accounts, profileStore: store)
        app.plexHomeUsers.plexHomeUsersFetch = { _, _ in users }
        app.plexHomeUsers.plexHomeUserSwitch = { _, _, _, _ in "fixture-cloud" }
        app.plexHomeUsers.plexServerTokenResolve = { _, _, _ in "fixture-server" }
        _app = State(initialValue: app)
    }

    var body: some View {
        Button("Open Settings") { showsSettings = true }
            .sheet(isPresented: $showsSettings) {
                PlozziOSSettingsView(appModel: app, onClose: { showsSettings = false }, systemColorScheme: .dark)
                    .safeAreaInset(edge: .bottom) {
                        VStack {
                            Text(app.profiles.activeProfile.name).accessibilityIdentifier("onboarding-active-profile")
                            Button("Add Plex profiles") {
                                app.plexHomeUsers.presentUserSelection(.init(
                                    accountID: "plex", serverName: "Fixture", users: users, isFirstRun: false
                                ))
                            }
                        }
                    }
                    .onAppear { app.noteSettingsPresented(true) }
                    .onDisappear { app.noteSettingsPresented(false) }
            }
            .environment(app)
            .environment(language)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.plozzMetrics, .touch(density: .standard))
            .environment(\.themePalette, .dark)
            .preferredColorScheme(.dark)
    }
}
