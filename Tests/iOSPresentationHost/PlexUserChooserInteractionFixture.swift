import CoreModels
import CoreUI
import FeatureAuth
import SwiftUI
@testable import AppRuntime
@testable import AppShelliOS

@MainActor
struct PlexUserChooserInteractionFixture: View {
    @State private var appModel: PlozziOSAppModel
    @State private var isPresented = true
    @State private var presentations = 0
    @State private var account: Account
    private static let usesProfilePicker = ProcessInfo.processInfo.arguments.contains("--pending-profile-chooser")

    init() {
        SyncSetupFeatureFlag().isEnabled = false
        let defaults = UserDefaults(suiteName: "PlexUserChooserFixture.\(UUID())")!
        let accounts = AccountStore(secureStore: InMemorySecureStore())
        let account = Account(
            id: "plex", server: .init(
                id: "fixture", name: "Fixture Plex", baseURL: URL(string: "https://plex.example")!, provider: .plex
            ), userID: "owner", userName: "Owner", deviceID: "fixture"
        )
        _account = State(initialValue: account)
        do { try accounts.add(account, token: "FIXTURE-OWNER") }
        catch { preconditionFailure("Could not create chooser fixture: \(error)") }
        let profileStore = ProfileStore(defaults: defaults)
        if Self.usesProfilePicker {
            let profiles = ProfilesModel(store: profileStore)
            let original = profiles.activeProfileID
            let other = profiles.add(name: "Other viewer", isAwaitingSetup: false)
            for id in [original, other.id] {
                profiles.setActiveAccountIDs([account.id], for: id)
                profiles.noteIdentityQuestions(for: [account.id], forProfile: id, knownNonPlexAccountIDs: [])
            }
            profiles.select(original)
            profiles.markFirstRunProfileSetupComplete()
        }
        let model = PlozziOSAppModel(
            appAdmissionStore: AppAdmissionStore(defaults: defaults), accountStore: accounts, profileStore: profileStore
        )
        let transport = PlexChooserFixtureTransport(
            slow: ProcessInfo.processInfo.arguments.contains("--slow-chooser"),
            failsOnce: ProcessInfo.processInfo.arguments.contains("--failed-chooser")
        )
        model.plexHomeUsers.plexHomeUsersFetch = { _, _ in await transport.users() }
        model.plexHomeUsers.plexHomeUserSwitch = { userID, pin, _, _ in
            try await transport.switchUser(userID, pin: pin)
        }
        model.plexHomeUsers.plexServerTokenResolve = { _, _, _ in "FIXTURE-SERVER" }
        _appModel = State(initialValue: model)
    }

    var body: some View {
        if Self.usesProfilePicker {
            PlozziOSRootView(appModel: appModel)
        } else {
            manualChooser
        }
    }

    private var manualChooser: some View {
        Text("Home").id(appModel.plexHomeUsers.plexIdentityGeneration)
            .plozzSheet(isPresented: $isPresented) {
                PlozziOSServerIdentityPromptView(
                    appModel: appModel, account: account,
                    onFinish: { isPresented = false }, onDecline: { isPresented = false }
                )
                .safeAreaInset(edge: .bottom) {
                    Text(verbatim: "\(presentations)")
                        .accessibilityIdentifier("fixture-chooser-presentations")
                }
                .onAppear { presentations += 1 }
            }
            .plozzFullScreenCover(item: Binding(
                get: { appModel.plexPINRequestForAppPresentation },
                set: { if $0 == nil { appModel.plexHomeUsers.cancelPlexPIN() } }
            )) { _ in
                Text("Unexpected global PIN").accessibilityIdentifier("fixture-global-pin")
            }
            .environment(\.themePalette, .dark)
            .environment(\.locale, Locale(identifier: "en"))
            .preferredColorScheme(.dark)
    }
}

private actor PlexChooserFixtureTransport {
    let slow: Bool
    let failsOnce: Bool
    private var switches = 0

    init(slow: Bool, failsOnce: Bool) {
        self.slow = slow
        self.failsOnce = failsOnce
    }

    func users() -> [PlexHomeUser] {
        [
            .init(id: "owner", name: "Owner", requiresPIN: false, isAdmin: true),
            .init(id: "korra", name: "Korra", requiresPIN: false),
            .init(id: "protected", name: "Aang", requiresPIN: true)
        ]
    }

    func switchUser(_ userID: String, pin: String?) async throws -> String {
        if userID == "korra" {
            switches += 1
            try await Task.sleep(for: slow ? .seconds(4) : .milliseconds(350))
            if failsOnce, switches == 1 { throw URLError(.notConnectedToInternet) }
        }
        if userID == "protected", pin != "2468" { throw URLError(.userAuthenticationRequired) }
        return "FIXTURE-CLOUD"
    }
}
