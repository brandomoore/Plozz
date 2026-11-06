import CoreModels
import CoreUI
import FeatureAuth
import SwiftUI
import UIKit
@testable import AppRuntime
@testable import AppShelliOS

/// Real application surfaces with isolated, non-networked preview accounts.
struct OfflineModeReviewFixture: View {
    private static var preparedModel: PlozziOSAppModel?
    @State private var app: PlozziOSAppModel
    private let page: String
    @State private var status = TransientStatusPresenter(displayDuration: .seconds(30))

    init() {
        let populated = ProcessInfo.processInfo.arguments.contains("--offline-populated")
        page = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--offline-page=") }
            .map { String($0.dropFirst("--offline-page=".count)) } ?? "home"
        if let model = Self.preparedModel {
            _app = State(initialValue: model)
            return
        }
        SyncSetupFeatureFlag().isEnabled = false
        UserDefaults.standard.set(true, forKey: OfflineMode.preferenceKey)
        OfflineMode.shared.setEnabled(true)
        let defaults = UserDefaults(suiteName: populated ? "OfflinePopulatedReview" : "OfflineReview.\(UUID())")!
        let accounts = AccountStore(secureStore: InMemorySecureStore())
        let profileStore = ProfileStore(defaults: defaults)
        let profiles = ProfilesModel(store: profileStore)
        let fixtureProfileID = defaults.string(forKey: "populatedFixtureProfileID")
        var profile: Profile
        if populated {
            profile = profiles.profiles.first { $0.id == fixtureProfileID }
                ?? profiles.add(name: "Alex", isAwaitingSetup: false)
            defaults.set(profile.id, forKey: "populatedFixtureProfileID")
        } else {
            profile = profiles.activeProfile
        }
        profile.name = "Alex"
        let accountID = populated ? OfflinePopulatedReview.accountID : "offline-review-\(UUID())"
        let isPlex = page == "sign-in"
        if isPlex {
            profile = profile.settingHomeUserBinding(
                .init(homeUserID: "alex", name: "Alex", requiresPIN: true, pinRequirementVerified: true),
                forPlexAccount: accountID
            )
        }
        profiles.update(profile)
        profiles.markFirstRunProfileSetupComplete()
        if !profiles.profiles.contains(where: { $0.name == "Sam" }) {
            _ = profiles.add(name: "Sam", avatarSymbol: "person.fill", colorIndex: 2, isAwaitingSetup: false)
        }
        profiles.select(profile.id)
        do {
            let account = Account(
                id: accountID,
                server: .init(id: accountID, name: "Home server", baseURL: URL(string: "https://fixture.invalid")!,
                              provider: isPlex ? .plex : .jellyfin),
                userID: "owner", userName: "Alex", deviceID: "preview"
            )
            try accounts.add(account, token: "FIXTURE")
            if populated, !ProcessInfo.processInfo.arguments.contains("--offline-reuse-downloads") {
                try OfflinePopulatedReview.seed(profile: profile, account: account)
                if let sam = profiles.profiles.first(where: { $0.name == "Sam" }) {
                    try OfflinePopulatedReview.seed(profile: sam, account: account, secondProfile: true)
                }
            }
        } catch { fatalError("Could not prepare offline preview: \(error)") }
        var featureFlags = RuntimeFeatureFlags.buildDefault
        if ProcessInfo.processInfo.arguments.contains("--offline-flag-disabled") {
            featureFlags.set(.offlineMode, enabled: false)
        }
        let model = PlozziOSAppModel(
            appAdmissionStore: AppAdmissionStore(defaults: defaults),
            accountStore: accounts, profileStore: profileStore,
            runtimeFeatureFlags: featureFlags
        )
        model.settings.theme.theme = .dark
        model.selectProfile(profile.id)
        let available = NavigationDestinationDefaults.iOS
        let enabled = [
            NavigationLibraryLayout.homeKey, NavigationLibraryLayout.discoverKey,
            NavigationLibraryLayout.liveTVKey, NavigationLibraryLayout.downloadsKey,
            NavigationLibraryLayout.searchKey
        ]
        model.settings.navigation.applyLibrarySections(
            .init(enabled: [NavigationLibraryLayout.homeKey],
                  disabled: available.filter { $0 != NavigationLibraryLayout.homeKey }),
            available: available, automaticallyHiddenKeys: NavigationDestinationDefaults.iOSAutomaticallyHiddenKeys
        )
        model.settings.navigation.applyLibrarySections(
            .init(enabled: enabled, disabled: available.filter { !enabled.contains($0) }),
            available: available, automaticallyHiddenKeys: NavigationDestinationDefaults.iOSAutomaticallyHiddenKeys
        )
        if populated { OfflinePopulatedReview.configure(model) }
        Self.preparedModel = model
        _app = State(initialValue: model)
    }

    var body: some View {
        Group {
            if page == "profiles" {
                PlozziOSProfileSelectionView(appModel: app, onComplete: {}, onCancel: {})
            } else if page == "source" {
                NavigationStack {
                    PlozziOSServersSettingsView(appModel: app, onAddServer: {
                        status.present(icon: "wifi.slash", text: "Unavailable in Offline Mode.")
                    })
                }
                .environment(app.profiles)
                .transientStatusOverlay(presenter: status, palette: .dark)
            } else {
                PlozziOSRootView(appModel: app)
            }
        }
        .environment(\.themePalette, .dark)
        .preferredColorScheme(.dark)
        .environment(\.locale, Locale(identifier: "en"))
        .environment(\.dynamicTypeSize, ProcessInfo.processInfo.arguments.contains("--offline-large-text")
            ? .accessibility3 : .large)
        .task {
            do {
                try await Task.sleep(for: .seconds(1))
                if ProcessInfo.processInfo.arguments.contains("--offline-populated") {
                    let deadline = ContinuousClock.now + .seconds(15)
                    while app.downloads.records.isEmpty, ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    OfflinePopulatedReview.configure(app)
                    if !app.isOfflineModeAvailable {
                        try await OfflinePopulatedReview.verifyDisabled(app)
                    } else {
                        try await OfflinePopulatedReview.prepareWatchlist(app)
                    }
                    if app.isOfflineModeAvailable, ProcessInfo.processInfo.arguments.contains("--offline-verify") {
                        try await OfflinePopulatedReview.verify(app)
                    }
                }
                if page == "movie-detail" {
                    guard let provider = app.accountsProviders.homeAccounts.first?.provider,
                          let navigate = app.screenshotDirector.navigateToItem else { throw AppError.notFound }
                    navigate(try await provider.item(id: "movie-0"))
                } else if page == "series-detail" {
                    guard let provider = app.accountsProviders.homeAccounts.first?.provider,
                          let navigate = app.screenshotDirector.navigateToItem else { throw AppError.notFound }
                    navigate(try await provider.item(id: "trail"))
                } else if page == "movie-playback" {
                    guard let provider = app.accountsProviders.homeAccounts.first?.provider,
                          let play = app.screenshotDirector.startPlayback else { throw AppError.notFound }
                    play(try await provider.item(id: "movie-1"), 45)
                } else if page == "movies" {
                    app.screenshotDirector.tab = "library:\(OfflinePopulatedReview.accountID):movies"
                } else if page == "shows" {
                    app.screenshotDirector.tab = "library:\(OfflinePopulatedReview.accountID):shows"
                } else if page != "home" && page != "profiles" && page != "sign-in" && page != "source" {
                    app.screenshotDirector.tab = page
                }
                await app.plexHomeUsers.waitForPlexPINRequirementCheck()
                try await Task.sleep(for: .seconds(1))
                if page == "source" {
                    status.present(
                        icon: "wifi.slash", text: "Unavailable in Offline Mode."
                    )
                }
                try await Task.sleep(for: .milliseconds(500))
                let ready = URL.documentsDirectory.appendingPathComponent("offline-review-ready")
                try page.write(to: ready, atomically: true, encoding: .utf8)
            } catch {
                do {
                    try String(describing: error).write(
                        to: URL.documentsDirectory.appendingPathComponent("offline-review-failure"),
                        atomically: true, encoding: .utf8
                    )
                } catch { fatalError("Could not preserve offline verification failure: \(error)") }
            }
        }
    }

}
