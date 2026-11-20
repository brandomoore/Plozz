import CoreModels
import CoreUI
import FeatureAuth
import SwiftUI
@testable import AppRuntime
@testable import AppShelliOS

@MainActor
struct ProfilePickerInteractionFixture: View {
    @State private var appModel: PlozziOSAppModel
    @State private var selectedName: String?
    private let profiles: [Profile]
    private let arguments = ProcessInfo.processInfo.arguments

    init() {
        let sync = SyncSetupFeatureFlag()
        sync.isEnabled = false
        let model = PlozziOSAppModel()
        let names = ["Alex", "Sam", "Jamie"]
        profiles = names.enumerated().map { index, name in
            if let existing = model.profiles.profiles.first(where: { $0.name == name }) {
                return existing
            }

            return model.profiles.add(
                name: name, avatarSymbol: ["person.fill", "star.fill", "moon.fill"][index],
                colorIndex: index
            )
        }
        _appModel = State(initialValue: model)
    }

    var body: some View {
        Group {
            if let selectedName {
                VStack {
                    Text(selectedName).accessibilityIdentifier("fixture-profile-result")
                    Button("Open picker") { self.selectedName = nil }
                }
            } else {
                PlozziOSProfilePickerView(
                    profiles: profiles, activeProfileID: profiles[0].id,
                    onSelect: { selectedName = $0.name },
                    manager: arguments.contains("--restricted-picker") ? nil : appModel,
                    onCancel: arguments.contains("--launch-picker") ? nil : { selectedName = "Cancelled" }
                )
            }
        }
        .environment(appModel)
        .environment(\.themePalette, .dark)
        .environment(\.gradientBackgroundsEnabled, true)
        .environment(\.locale, Locale(identifier: "en"))
        .preferredColorScheme(.dark)
    }
}

@MainActor
struct ProfileSelectionInteractionFixture: View {
    @State private var appModel: PlozziOSAppModel
    @State private var showsPicker = false
    @State private var completed = false
    @State private var isSelecting = false
    private let defaults: UserDefaults
    private let arguments = ProcessInfo.processInfo.arguments

    private var usesLaunchPicker: Bool { arguments.contains("--launch-selection") }
    private var needsLaunchPicker: Bool {
        isSelecting || appModel.mustChooseProfile || !appModel.didCompleteLaunchProfileSelection
    }

    init() {
        SyncSetupFeatureFlag().isEnabled = false
        defaults = UserDefaults(suiteName: "ProfileSelectionFixture.\(UUID())")!
        let store = ProfileStore(defaults: defaults)
        let profiles = ProfilesModel(store: store)
        var first = profiles.activeProfile
        first.name = "Alex"
        first.avatarEmoji = nil
        first.avatarSymbol = "person.fill"
        first.colorIndex = 0
        profiles.update(first)
        let isProtected = !ProcessInfo.processInfo.arguments.contains("--unprotected-plex-check")
        var protected = profiles.add(name: isProtected ? "Protected" : "Family", avatarSymbol: "person.fill", colorIndex: 1)
        protected = protected.settingHomeUserBinding(
            .init(homeUserID: "protected", name: protected.name, requiresPIN: isProtected, pinRequirementVerified: true),
            forPlexAccount: "plex"
        )
        if ProcessInfo.processInfo.arguments.contains("--two-pins") {
            protected.lock = ProfileLock.make(pin: "1234", iterations: 1)
        }
        if ProcessInfo.processInfo.arguments.contains("--matched-plex-pin") {
            protected.lock = ProfileLock.make(pin: "2468", matchesPlexPIN: true, iterations: 1)
        }
        profiles.update(protected)
        profiles.setActiveAccountIDs(
            ProcessInfo.processInfo.arguments.contains("--disabled-plex-source") ? [] : ["plex"],
            for: protected.id
        )
        if ProcessInfo.processInfo.arguments.contains("--local-profile") {
            var local = profiles.add(name: "Local", avatarSymbol: "star.fill", colorIndex: 2)
            local.lock = ProfileLock.make(pin: "1357", iterations: 1)
            profiles.update(local)
            profiles.setActiveAccountIDs([], for: local.id)
        }
        if ProcessInfo.processInfo.arguments.contains("--locked-fallback") {
            first.lock = ProfileLock.make(pin: "1357", iterations: 1)
            profiles.update(first)
            let guest = profiles.add(name: "Guest", avatarSymbol: "star.fill", colorIndex: 2)
            profiles.select(guest.id)
        } else {
            profiles.select(first.id)
        }
        let accounts = AccountStore(secureStore: InMemorySecureStore())
        do {
            try accounts.add(Account(
                id: "plex", server: MediaServer(
                    id: "fixture", name: "Fixture",
                    baseURL: URL(string: "https://plex.example")!, provider: .plex
                ), userID: "owner", userName: "Owner", deviceID: "fixture"
            ), token: "FIXTURE-OWNER")
        } catch {
            preconditionFailure("Could not create synthetic account: \(error)")
        }
        let model = PlozziOSAppModel(accountStore: accounts, profileStore: store)
        let slowCheck = ProcessInfo.processInfo.arguments.contains("--slow-plex-check")
        let failedCheck = ProcessInfo.processInfo.arguments.contains("--failed-plex-check")
        model.plexHomeUsers.plexHomeUsersFetch = { _, _ in
            try await Task.sleep(for: slowCheck ? .seconds(5) : .milliseconds(350))
            if failedCheck { throw URLError(.notConnectedToInternet) }
            return [
                PlexHomeUser(id: "owner", name: "Owner", requiresPIN: true),
                PlexHomeUser(id: "protected", name: "Server identity", requiresPIN: isProtected)
            ]
        }
        model.plexHomeUsers.plexHomeUserSwitch = { _, pin, _, _ in
            guard pin == (isProtected ? "2468" : nil) else { throw URLError(.userAuthenticationRequired) }
            if ProcessInfo.processInfo.arguments.contains("--slow-plex-authentication") {
                try await Task.sleep(for: .seconds(2))
            }
            return "FIXTURE-CLOUD"
        }
        model.plexHomeUsers.plexServerTokenResolve = { _, _, _ in "FIXTURE-SERVER" }
        if ProcessInfo.processInfo.arguments.contains("--initial-profile-lock") {
            model.profiles.select(protected.id)
            model.enforceActiveProfileLock()
        } else if ProcessInfo.processInfo.arguments.contains("--initial-plex-pin") {
            model.profiles.select(protected.id)
            model.refreshActiveProfileConfiguration()
        }
        _appModel = State(initialValue: model)
    }

    var body: some View {
        Group {
            if usesLaunchPicker, needsLaunchPicker {
                PlozziOSProfileSelectionView(
                    appModel: appModel,
                    onSelectionStarted: { isSelecting = true },
                    onComplete: { completed = true; isSelecting = false }
                )
            } else {
                VStack {
                    Text(completed ? "Selected" : "Home").accessibilityIdentifier("fixture-selection-result")
                    Button("Open picker") { showsPicker = true }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 1, green: 0, blue: 1))
            }
        }
        .id(usesLaunchPicker && needsLaunchPicker ? "picker" : appModel.profiles.activeProfileID)
        .plozzFullScreenCover(isPresented: $showsPicker) {
            PlozziOSProfileSelectionView(
                appModel: appModel,
                onComplete: { completed = true; showsPicker = false },
                onCancel: { showsPicker = false }
            )
        }
        .environment(\.themePalette, .dark)
        .environment(\.locale, Locale(identifier: "en"))
        .environment(\.gradientBackgroundsEnabled, true)
        .preferredColorScheme(.dark)
        .onAppear { if !usesLaunchPicker { showsPicker = true } }
    }
}
