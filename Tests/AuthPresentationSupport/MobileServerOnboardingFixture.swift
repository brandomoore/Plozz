#if os(iOS)
import CoreModels
import CoreNetworking
import CoreUI
import FeatureAuth
import FeatureAuthCore
import FeatureDiscoveryCore
import ProviderSilo
import SwiftUI
@testable import AppShelliOS

@MainActor
struct MobileServerOnboardingFixture: View {
    let page: String
    let presentsAsSheet: Bool
    @State private var appModel: PlozziOSAppModel
    @State private var http: MobileOnboardingHTTP
    @State private var completedIDs: [String] = []
    @State private var showingSetup = true
    @State private var showingSourceChooser = false
    @State private var showingTransfer = false

    init(page: String, presentsAsSheet: Bool = false) {
        self.page = page
        self.presentsAsSheet = presentsAsSheet
        SyncSetupFeatureFlag().isEnabled = false
        let defaults = UserDefaults(suiteName: "MobileOnboarding.\(UUID().uuidString)")!
        let accounts = AccountStore(secureStore: InMemorySecureStore())
        let model = PlozziOSAppModel(accountStore: accounts, profileStore: ProfileStore(defaults: defaults))
        if ["discovery", "sources", "libraries"].contains(page) {
            do {
                try accounts.add(Account(
                    id: "fixture", server: Self.server(.jellyfin),
                    userID: "alex", userName: "Alex", deviceID: "fixture"
                ), token: "fixture")
                model.accountsProviders.reloadAccounts()
            } catch {
                fatalError("Could not prepare onboarding fixture: \(error)")
            }
        }
        _appModel = State(initialValue: model)
        _http = State(initialValue: MobileOnboardingHTTP(
            plexLinked: page == "plex-servers",
            rejectsFirstPassword: page == "password-error",
            rejectsFirstQuickConnect: page == "quick-error"
        ))
    }

    var body: some View {
        Group {
            if !completedIDs.isEmpty {
                Text("Added: \(completedIDs.sorted().joined(separator: ", "))")
                    .accessibilityIdentifier("onboarding-completed")
            } else if presentsAsSheet && page != "welcome" && !page.hasPrefix("home-") {
                Text("Servers")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .plozzSheet(isPresented: $showingSetup) {
                        content.presentationSizing(.page)
                    }
            } else {
                content
            }
        }
        .onChange(of: appModel.accounts.map(\.id)) { _, _ in
            if page == "flow" { completedIDs = appModel.accounts.map(\.server.id) }
            if page == "live" {
                completedIDs = appModel.accounts.map { "\($0.server.provider.rawValue):\($0.userName)" }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case "welcome":
            PlozziOSOnboardingView(appModel: appModel)
        case "chooser":
            addServer()
        case "live":
            AddServerView(appModel: appModel)
        case "discovery", "flow":
            addServer(provider: .jellyfin)
        case "silo-flow":
            addServer(provider: .silo)
        case "seeded":
            addServer(provider: .emby, address: "https://emby.example.test/media")
        case "iptv":
            AddServerView(appModel: appModel, initialProvider: .iptv)
        case "share":
            AddServerView(appModel: appModel, initialProvider: .mediaShare)
        case "home-empty", "home-new", "sources", "libraries", "libraries-empty":
            NavigationStack {
                Group {
                    if page == "sources" {
                        PlozziOSServersSettingsView(
                            appModel: appModel, onAddServer: { showingSourceChooser = true }
                        )
                    } else if page.hasPrefix("libraries") {
                        PlozziOSMyLibrariesSettingsView(
                            appModel: appModel, onAddServer: { showingSourceChooser = true }
                        )
                    } else {
                        PlozziOSHomeEmptyState(
                            hasAccounts: page == "home-empty",
                            onAddSource: { showingSourceChooser = true },
                            onReceiveSetup: page == "home-new" ? { showingTransfer = true } : nil
                        )
                    }
                }
                .plozzSheet(isPresented: $showingSourceChooser) {
                    addServer().presentationSizing(.page)
                }
                .plozzFullScreenCover(isPresented: $showingTransfer) {
                    PlozziOSSyncSetupReceiveView(appModel: appModel) { showingTransfer = false }
                }
            }
        default:
            NavigationStack {
                isolatedSignIn
                    .toolbar {
                        if page != "plex" && page != "plex-servers" {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { showingSetup = false }
                            }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var isolatedSignIn: some View {
        if page == "plex" || page == "plex-servers" {
            PlexServerSignInView(viewModel: PlexAuthViewModel(
                service: PlexAuthService(
                    deviceID: "fixture", http: http, probeHTTP: http,
                    config: .init(pollInterval: 0.1, timeout: 300)
                ),
                onAuthenticated: { completedIDs = [$0.server.id] },
                onAuthenticatedMany: { completedIDs = $0.map(\.server.id) }
            ))
        } else if page == "silo" {
            SiloSignInView(
                viewModel: SiloAuthViewModel(
                    server: Self.server(.silo), deviceID: "fixture",
                    service: SiloAuthentication(baseURL: Self.server(.silo).baseURL,
                                                http: OnboardingPreviewHTTP()),
                    onAuthenticated: { _ in }
                ),
                server: Self.server(.silo), showsCancelButton: false, onCancel: {}
            )
        } else if page == "password" || page == "password-error" {
            PasswordServerSignInView(
                server: Self.server(.jellyfin), appModel: appModel, http: http,
                onAuthenticated: { completedIDs = [$0.server.id] }, onUseQuickConnect: {}
            )
        } else {
            ManagedServerSignInView(
                server: Self.server(page == "emby" ? .emby : .jellyfin),
                appModel: appModel, onComplete: {}, onCancel: {},
                onAuthenticated: { completedIDs = [$0.server.id] }, http: http
            )
        }
    }

    private func addServer(provider: ProviderKind? = nil, address: String = "") -> AddServerView {
        AddServerView(
            appModel: appModel, initialProvider: provider, initialAddress: address, http: http,
            discoveryModel: { kind in
                ServerPickerViewModel(
                    provider: kind, discovery: MobileOnboardingDiscovery(server: Self.server(kind)),
                    validator: ServerValidator(provider: kind, http: http), store: MobileOnboardingRecents()
                )
            }
        )
    }

    static func server(_ provider: ProviderKind) -> MediaServer {
        MediaServer(
            id: "living-room", name: "Living Room",
            baseURL: URL(string: "https://\(provider.rawValue).example.test")!,
            provider: provider
        )
    }
}

private struct MobileOnboardingDiscovery: ServerDiscovering {
    let server: MediaServer
    func discover(timeout: TimeInterval) -> AsyncStream<MediaServer> {
        AsyncStream { continuation in
            continuation.yield(server)
            continuation.finish()
        }
    }
}

private struct MobileOnboardingRecents: LastServerStoring {
    var recentServers: [MediaServer] = []
}

actor MobileOnboardingHTTP: HTTPClient {
    let plexLinked: Bool
    private var rejectsFirstPassword: Bool
    private var rejectsFirstQuickConnect: Bool
    private let silo = OnboardingPreviewHTTP()

    init(plexLinked: Bool = false, rejectsFirstPassword: Bool = false,
         rejectsFirstQuickConnect: Bool = false) {
        self.plexLinked = plexLinked
        self.rejectsFirstPassword = rejectsFirstPassword
        self.rejectsFirstQuickConnect = rejectsFirstQuickConnect
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        if baseURL.host == "silo.example.test" {
            return try await silo.send(endpoint, baseURL: baseURL)
        }
        let body: String
        switch endpoint.path {
        case "/QuickConnect/Enabled":
            if rejectsFirstQuickConnect {
                rejectsFirstQuickConnect = false
                throw AppError.quickConnectUnavailable
            }
            body = "true"
        case "/QuickConnect/Initiate", "/QuickConnect/Connect":
            body = #"{"Authenticated":false,"Secret":"fixture","Code":"654321"}"#
        case "/Users/AuthenticateByName":
            if rejectsFirstPassword {
                rejectsFirstPassword = false
                throw AppError.invalidCredentials
            }
            body = #"{"User":{"Id":"alex","Name":"Alex"},"AccessToken":"fixture","ServerId":"living-room"}"#
        case "/System/Info/Public":
            body = #"{"Id":"living-room","ServerName":"Living Room","Version":"10.11.0"}"#
        case "/api/v2/pins":
            body = #"{"id":1,"code":"ABCD","expiresIn":300}"#
        case "/api/v2/pins/1":
            body = plexLinked
                ? #"{"id":1,"code":"ABCD","authToken":"fixture"}"#
                : #"{"id":1,"code":"ABCD"}"#
        case "/api/v2/user":
            body = #"{"uuid":"alex","username":"Alex"}"#
        case "/api/v2/resources":
            body = """
            [
              {"clientIdentifier":"home","name":"Home Server","provides":"server","owned":true,
               "accessToken":"fixture","connections":[{"uri":"https://home.example.test","local":true}]},
              {"clientIdentifier":"studio","name":"Studio Server","provides":"server","owned":true,
               "accessToken":"fixture","connections":[{"uri":"https://studio.example.test","local":true}]},
              {"clientIdentifier":"shared","name":"Friends and Family","provides":"server","owned":false,
               "accessToken":"fixture","connections":[{"uri":"https://shared.example.test","local":false}]}
            ]
            """
        case "/identity": body = "{}"
        default: throw AppError.notFound
        }
        return (Data(body.utf8), HTTPURLResponse(
            url: baseURL.appendingPathComponent(endpoint.path),
            statusCode: 200, httpVersion: nil, headerFields: nil
        )!)
    }
}
#endif
