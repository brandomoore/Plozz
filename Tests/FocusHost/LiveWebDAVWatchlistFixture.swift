import AppRuntime
@testable import AppShell
import CoreModels
import CoreNetworking
import SwiftUI

/// Uses the production shell and stores across launches on an owned simulator.
/// Only initial account setup comes from the private, opt-in credential broker.
struct LiveWebDAVWatchlistFixture: View {
    @State private var app: AppState?
    @State private var failed = false

    var body: some View {
        Group {
            if let app {
                RootView(appState: app)
                    .overlay(alignment: .bottomTrailing) {
                        Text(verbatim: receipt(app))
                            .font(.caption2)
                            .accessibilityIdentifier("webdav-watchlist-receipt")
                            .allowsHitTesting(false)
                    }
                    .onChange(of: receipt(app), initial: true) { _, value in
                        PlozzLog.app.info("WebDAV journey \(value)")
                    }
            } else {
                Text(verbatim: failed ? "WebDAV journey setup failed" : "Preparing WebDAV journey")
            }
        }
        .task {
            guard app == nil, !failed else { return }
            do {
                guard !AppState.isRunningUnitTests else { throw AppError.invalidResponse }
                // This simulator lane measures local persistence, not CloudKit delivery.
                SyncSetupFeatureFlag().isEnabled = false
                let state = AppState()
                if state.accountsProviders.accountStore.loadAccounts().isEmpty {
                    let config = try await configuration()
                    let service = MediaShareAccountConfigurationService(
                        accountStore: state.accountsProviders.accountStore
                    )
                    for folder in ["Movies", "TV"] {
                        let prepared = try service.prepareWebDAV(
                            baseURL: config.baseURL.appendingPathComponent(folder, isDirectory: true),
                            auth: .password(username: config.username, password: config.password),
                            trustPin: nil,
                            displayName: "Journey \(folder)",
                            libraryConfiguration: .init(
                                name: "Journey \(folder)",
                                contentType: folder == "Movies" ? .movies : .tvShows
                            )
                        )
                        try service.persist(prepared)
                    }
                    state.profilesModel.markFirstRunProfileSetupComplete()
                    state.profileFlow.setAutomaticallySignIn(true)
                    let introductions = FeatureIntroductionStore()
                    introductions.markCompleted(.navigationStyles)
                    introductions.markCompleted(.homeLayout)
                }
                if !state.profilesModel.profiles.contains(where: { $0.name == "Journey Other" }) {
                    var other = state.profilesModel.add(
                        name: "Journey Other",
                        activeAccountIDs: state.accountsProviders.accountStore.loadAccounts().map(\.id)
                    )
                    other.needsSetup = false
                    state.profilesModel.update(other)
                    ProfileAppearanceSetupStore().markCompleted(profileID: other.id)
                }
                app = state
            } catch {
                failed = true
                PlozzLog.app.error("WebDAV journey setup failed")
            }
        }
    }

    private func receipt(_ state: AppState) -> String {
        let snapshot = state.universalWatchlist.activeSnapshot
        let directory = AppState.universalWatchlistStorageDirectory()
        let location = directory == nil ? "memory"
            : directory?.path.contains("/tmp/") == true ? "temporary"
            : directory?.path.contains("/Caches/") == true ? "caches"
            : directory?.path.contains("/Application Support/") == true ? "support" : "other"
        return "saved=\(snapshot.activeAliasIDs.count) removed=\(snapshot.tombstoneCount) "
            + "accounts=\(state.accountsProviders.accounts.count) storage=\(location)"
    }

    private struct Configuration: Decodable {
        let baseURL: URL
        let username: String
        let password: String
    }

    private func configuration() async throws -> Configuration {
        guard let address = ProcessInfo.processInfo.environment["PLOZZ_WEBDAV_JOURNEY_BROKER"],
              let url = URL(string: address),
              url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
        else { throw AppError.invalidResponse }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(
            for: URLRequest(url: url, timeoutInterval: 20)
        )
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppError.invalidResponse
        }
        let config = try JSONDecoder().decode(Configuration.self, from: data)
        guard ["http", "https"].contains(config.baseURL.scheme),
              config.baseURL.host != nil, config.baseURL.user == nil,
              config.baseURL.password == nil, config.baseURL.query == nil,
              config.baseURL.fragment == nil, !config.password.isEmpty
        else { throw AppError.invalidResponse }
        return config
    }
}
