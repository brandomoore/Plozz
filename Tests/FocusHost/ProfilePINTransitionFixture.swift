@testable import AppShell
@testable import AppRuntime
import CoreModels
import CoreSecureStore
import CoreUI
import FeatureAuth
import SwiftUI
import UIKit

struct ProfilePINTransitionFixture: View {
    @State private var app: AppState

    init() {
        let suite = "ProfilePINTransitionFixture"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let profiles = ProfilesModel(store: ProfileStore(defaults: defaults))
        let usesPlex = ProcessInfo.processInfo.arguments.contains("--plex-pin")
        var locked = profiles.add(name: "Locked viewer")
        locked.avatarEmoji = "🦊"
        locked.replaceLock(with: ProfileLock.make(pin: "1111", iterations: 1))
        if usesPlex {
            locked = locked.settingHomeUserBinding(
                .init(homeUserID: "viewer", name: "Different server name", requiresPIN: true),
                forPlexAccount: "plex"
            )
        }
        profiles.update(locked)
        profiles.select(ProfileStore.defaultProfileID)
        let accountStore = AccountStore(secureStore: InMemorySecureStore())
        if usesPlex {
            let account = Account(
                id: "plex",
                server: MediaServer(
                    id: "plex", name: "Fixture", baseURL: URL(string: "https://plex.example.com")!, provider: .plex
                ),
                userID: "owner", userName: "Owner", deviceID: "fixture"
            )
            try! accountStore.add(account, token: "fixture-token")
        }
        let state = AppState(
            accountStore: accountStore,
            profilesModel: profiles
        )
        state.plexHomeUsers.plexHomeUsersFetch = { _, _ in
            [PlexHomeUser(id: "viewer", name: "Different server name", requiresPIN: true)]
        }
        state.plexHomeUsers.plexHomeUserSwitch = { _, pin, _, _ in
            guard pin == "2222" else { throw AppError.unauthorized }
            return "fixture-viewer-token"
        }
        state.plexHomeUsers.plexServerTokenResolve = { _, _, _ in "fixture-server-token" }
        state.profileFlow.requestProfileSelection()
        _app = State(initialValue: state)
    }

    var body: some View {
        Group {
            if app.profileFlow.isPresentingProfileSelection {
                ProfileSelectionView(appState: app, canCancel: false)
            } else {
                Text(verbatim: "Opened \(app.profilesModel.activeProfile.name)")
                    .accessibilityIdentifier("profile-handoff-complete")
            }
        }
        .environment(app.profilesModel)
        .environment(\.themePalette, .dark)
        .environment(\.locale, Locale(identifier: "en_US"))
        .overlay(alignment: .bottomLeading) {
            Text(verbatim: UIAccessibility.isReduceMotionEnabled ? "Reduced motion" : "Full motion")
                .accessibilityIdentifier("profile-handoff-motion")
        }
    }
}
