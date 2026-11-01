#if os(iOS)
import CoreModels
import CoreNetworking
import CoreUI
import FeatureAuthCore
import FeatureAuth
import FeatureDiscoveryCore
import ProviderPlex
import SwiftUI

struct AddServerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var chosenProvider: ProviderKind?
    @State private var address: String
    @State private var server: MediaServer?
    @State private var jellyfinDiscovery: ServerPickerViewModel
    @State private var embyDiscovery: ServerPickerViewModel
    @State private var siloDiscovery: ServerPickerViewModel
    @State private var validationMessage: LocalizedStringResource?
    @State private var isValidating = false
    @State private var validationTask: Task<Void, Never>?

    let appModel: PlozziOSAppModel
    private let initialProvider: ProviderKind?
    private var startsAtProvider: Bool { initialProvider != nil }
    private let http: any HTTPClient
    private let initialIPTVPlaylist: LiveTVPlaylistSource?
    private let initialIPTVAccount: Account?
    private let initialProfileID: String
    private let initialIPTVMode: IPTVCredential.Mode

    init(
        appModel: PlozziOSAppModel, initialProvider: ProviderKind? = nil, initialAddress: String = "",
        initialIPTVPlaylist: LiveTVPlaylistSource? = nil, initialIPTVAccount: Account? = nil,
        initialIPTVMode: IPTVCredential.Mode = .playlist,
        http: any HTTPClient = URLSessionHTTPClient(),
        discoveryModel: @MainActor (ProviderKind) -> ServerPickerViewModel = { ServerPickerViewModel(provider: $0) }
    ) {
        self.appModel = appModel
        self.http = http
        _jellyfinDiscovery = State(initialValue: discoveryModel(.jellyfin))
        _embyDiscovery = State(initialValue: discoveryModel(.emby))
        _siloDiscovery = State(initialValue: discoveryModel(.silo))
        self.initialProvider = initialProvider
        self.initialIPTVPlaylist = initialIPTVPlaylist
        self.initialIPTVAccount = initialIPTVAccount
        initialProfileID = appModel.profiles.activeProfileID
        self.initialIPTVMode = initialIPTVMode
        // Pre-fill the address when adopting a server synced from another device, so
        // the user only has to sign in. Plex is account-based (no address field).
        _address = State(initialValue: initialProvider == .plex ? "" : initialAddress)
    }

    var body: some View {
        NavigationStack {
            if let initialProvider {
                connectionContent(for: initialProvider)
            } else {
                ServerOnboardingPage(provider: nil, title: Text("Add Server")) {
                    ServerProviderChoices { selected in
                        validationTask?.cancel()
                        isValidating = false
                        address = ""
                        server = nil
                        validationMessage = nil
                        chosenProvider = selected
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                .navigationDestination(item: $chosenProvider) { selected in
                    connectionContent(for: selected)
                }
            }
        }
        .onChange(of: appModel.profiles.activeProfileID) { _, profileID in
            if profileID != initialProfileID { dismiss() }
        }
    }

    @ViewBuilder
    private func connectionContent(for provider: ProviderKind) -> some View {
        Group {
            if provider == .iptv {
                IPTVSignInView(
                    deviceID: appModel.deviceID,
                    address: initialIPTVPlaylist?.playlistURL.absoluteString ?? address,
                    name: initialIPTVPlaylist?.name ?? "",
                    guideAddress: initialIPTVPlaylist?.guideURLs.first?.absoluteString ?? "",
                    guideURLs: initialIPTVPlaylist?.guideURLs ?? [],
                    reconnecting: initialIPTVAccount.map {
                        $0.session(token: appModel.accountStore.token(for: $0.id) ?? "")
                    },
                    initialMode: initialIPTVMode,
                    onAuthenticated: {
                        guard appModel.profiles.activeProfileID == initialProfileID,
                              initialIPTVAccount.map({ previous in
                                  appModel.accounts.contains {
                                      $0.id == previous.id && $0.credentialRevision == previous.credentialRevision
                                  }
                              }) != false else { throw IPTVAuthViewModel.CompletionError.persistence }
                        guard appModel.persist([$0], activateIPTVAccount: initialIPTVAccount == nil) else {
                            throw IPTVAuthViewModel.CompletionError.persistence
                        }
                        dismiss()
                    },
                    onCancel: { dismiss() }
                )
            } else if provider == .mediaShare {
                PlozziOSUnifiedAddShareView(
                    appModel: appModel, embedsNavigationStack: false,
                    onComplete: { dismiss() }
                )
            } else if provider == .plex {
                PlexServerSignInView(appModel: appModel, http: http, onComplete: { dismiss() })
            } else {
                ServerOnboardingPage(
                    provider: provider, title: Text(verbatim: provider.displayName)
                ) {
                    ManagedServerDiscoverySection(
                        model: discoveryModel(for: provider),
                        onSelect: { selectDiscoveredServer($0, provider: provider) }
                    )
                    SettingsSectionGroup("Enter address") {
                        TextField("Server address", text: $address)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.continue)
                            .onSubmit { continueSignIn(provider: provider) }
                            .disabled(isValidating)
                            .accessibilityIdentifier("add-server-address")
                    } footer: {
                        if provider == .silo {
                            Text("Use the address you open Silo with in a browser. An IP address alone uses port 8090; include a different port or path if your server needs it.")
                        } else {
                            Text("Use a hostname, IP address, or full URL.")
                        }
                    }
                    if let validationMessage {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button {
                        continueSignIn(provider: provider)
                    } label: {
                        Group {
                            if isValidating {
                                ProgressView("Checking server…")
                            } else {
                                Text("Connect")
                            }
                        }
                        .font(.body)
                        .frame(maxWidth: .infinity, minHeight: 24)
                    }
                    .plozzActionButton()
                    .controlSize(.large)
                    .disabled(isValidating || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("add-server-connect")
                }
                .navigationDestination(item: $server) { server in
                    ManagedServerSignInView(
                        server: server, appModel: appModel,
                        onComplete: { dismiss() }, http: http
                    )
                }
                .task(id: provider) {
                    let model = discoveryModel(for: provider)
                    let accounts = appModel.accounts.filter { $0.server.provider == provider }
                    let grouped = Dictionary(grouping: accounts, by: { $0.server.identityKey })
                    model.setSignedInServers(grouped.values.compactMap { accounts in
                        guard let first = accounts.first else { return nil }
                        return SignedInServer(server: first.server, userNames: accounts.map(\.userName))
                    }.sorted { $0.server.name.localizedStandardCompare($1.server.name) == .orderedAscending })
                    model.startScan()
                    defer { model.stopScan() }
                    try? await Task.sleep(for: .seconds(86_400))
                }
                .onDisappear {
                    validationTask?.cancel()
                    isValidating = false
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if startsAtProvider && provider != .iptv && provider != .mediaShare && provider != .plex {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func continueSignIn(provider: ProviderKind) {
        guard !isValidating else { return }
        validationMessage = nil
        let model = discoveryModel(for: provider)
        model.manualURLText = address
        guard model.canSubmitManualURL else { return }
        isValidating = true
        validationTask = Task {
            let validated = await model.submitManualURL()
            guard !Task.isCancelled, (initialProvider ?? chosenProvider) == provider else { return }
            isValidating = false
            guard appModel.profiles.activeProfileID == initialProfileID else { return }
            if let validated { server = validated }
            else if case let .error(message) = model.phase { validationMessage = message }
        }
    }

    private func discoveryModel(for provider: ProviderKind) -> ServerPickerViewModel {
        switch provider {
        case .silo: siloDiscovery
        case .emby: embyDiscovery
        default: jellyfinDiscovery
        }
    }

    private func selectDiscoveredServer(_ selectedServer: MediaServer, provider: ProviderKind) {
        guard !isValidating, appModel.profiles.activeProfileID == initialProfileID else { return }
        address = selectedServer.baseURL.absoluteString
        validationMessage = nil
        discoveryModel(for: provider).select(selectedServer)
        server = selectedServer
    }

}

struct ManagedServerDiscoverySection: View {
    let model: ServerPickerViewModel
    let onSelect: (MediaServer) -> Void

    var body: some View {
        SettingsSectionGroup("Servers") {
            if model.phase == .scanning {
                ProgressView().controlSize(.small)
            } else {
                Button("Scan Again") { model.startScan() }
                    .disabled(model.phase == .validating)
            }
        } content: {
            if discoveryServers.isEmpty {
                Text(model.phase == .scanning
                     ? "Looking on your local network…"
                     : "No nearby servers found. Enter an address below, or scan again.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(discoveryServers) { server in
                Button {
                    onSelect(server)
                } label: {
                    HStack(spacing: 12) {
                        ProviderBrandMark(provider: server.provider, size: 32)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: server.name).font(.headline)
                            Text(verbatim: server.baseURL.absoluteString)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.forward")
                            .foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                }
                .disabled(model.phase == .validating)
                .accessibilityIdentifier("discovered-server-\(server.id)")
            }
        }
    }

    private var discoveryServers: [MediaServer] {
        model.signedInServers.map(\.server) + model.recentServers + model.discoveredServers
    }
}

struct ManagedServerSignInView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var usesPassword: Bool
    let server: MediaServer
    let appModel: PlozziOSAppModel
    let onAuthenticated: (UserSession) throws -> Void
    let verificationOnly: Bool
    let onCancel: (() -> Void)?
    private let http: any HTTPClient

    init(
        server: MediaServer,
        appModel: PlozziOSAppModel,
        onComplete: @escaping () -> Void,
        verificationOnly: Bool = false,
        onCancel: (() -> Void)? = nil,
        onAuthenticated: ((UserSession) throws -> Void)? = nil,
        http: any HTTPClient = URLSessionHTTPClient()
    ) {
        self.server = server
        self.appModel = appModel
        self.verificationOnly = verificationOnly
        self.onCancel = onCancel
        self.http = http
        let profileID = appModel.profiles.activeProfileID
        self.onAuthenticated = onAuthenticated ?? {
            guard appModel.profiles.activeProfileID == profileID else { throw AppError.cancelled }
            guard appModel.persist([$0]) else { throw AppError.unknown("") }
            onComplete()
        }
        _usesPassword = State(initialValue: server.provider == .emby)
    }

    var body: some View {
        if server.provider == .silo {
            SiloSignInView(
                server: server, deviceID: appModel.deviceID, verificationOnly: verificationOnly,
                onAuthenticated: { session in
                    try onAuthenticated(session)
                    var store = UserDefaultsLastServerStore()
                    store.remember(session.server)
                },
                onCancel: {
                    if let onCancel { onCancel() } else { dismiss() }
                })
        } else if usesPassword {
            PasswordServerSignInView(
                server: server,
                appModel: appModel,
                http: http,
                onAuthenticated: onAuthenticated,
                onUseQuickConnect: server.provider == .jellyfin
                    ? { usesPassword = false }
                    : nil
            )
        } else {
            QuickConnectServerSignInView(
                server: server,
                appModel: appModel,
                http: http,
                onAuthenticated: onAuthenticated,
                onUsePassword: { usesPassword = true }
            )
        }
    }
}

struct QuickConnectServerSignInView: View {
    @State private var viewModel: QuickConnectViewModel
    private let server: MediaServer
    private let onUsePassword: () -> Void

    init(
        server: MediaServer,
        appModel: PlozziOSAppModel,
        http: any HTTPClient = URLSessionHTTPClient(),
        onAuthenticated: @escaping (UserSession) throws -> Void,
        onUsePassword: @escaping () -> Void
    ) {
        self.server = server
        self.onUsePassword = onUsePassword
        _viewModel = State(
            initialValue: QuickConnectViewModel(
                service: QuickConnectService(
                    server: server,
                    deviceID: appModel.deviceID,
                    http: http
                ),
                onAuthenticated: onAuthenticated
            )
        )
    }

    var body: some View {
        ServerOnboardingPage(
            provider: .jellyfin, title: Text(verbatim: server.name),
            subtitle: Text("Open Jellyfin on another device, choose **Quick Connect**, and enter this code.")
        ) {
            phaseContent
                .frame(maxWidth: .infinity)
            Button {
                onUsePassword()
            } label: {
                Text("Use Password")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 24)
            }
            .plozzActionButton(role: .secondary)
            .controlSize(.large)
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { viewModel.start() }
        .onDisappear { viewModel.cancel() }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch viewModel.phase {
        case .idle, .requesting:
            ProgressView("Requesting a code…")
        case let .awaitingApproval(code, expiresAt):
            ServerConnectionCode(code: code, expiresAt: expiresAt, lifetime: viewModel.codeLifetime)
        case .success:
            Label("Signed in", systemImage: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
        case let .error(message):
            ContentUnavailableView {
                Label("Quick Connect unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button {
                    viewModel.retry()
                } label: {
                    Text("Try Again").font(.body).frame(maxWidth: .infinity, minHeight: 24)
                }
                .plozzActionButton()
                .controlSize(.large)
            }
        }
    }
}

struct PasswordServerSignInView: View {
    @State private var viewModel: PasswordSignInViewModel
    @FocusState private var field: Field?
    private enum Field { case username, password }

    private let server: MediaServer
    private let onUseQuickConnect: (() -> Void)?

    init(
        server: MediaServer,
        appModel: PlozziOSAppModel,
        http: any HTTPClient = URLSessionHTTPClient(),
        onAuthenticated: @escaping (UserSession) throws -> Void,
        onUseQuickConnect: (() -> Void)? = nil
    ) {
        self.server = server
        self.onUseQuickConnect = onUseQuickConnect
        _viewModel = State(
            initialValue: PasswordSignInViewModel(
                service: PasswordSignInService(
                    server: server,
                    deviceID: appModel.deviceID,
                    http: http
                ),
                onAuthenticated: onAuthenticated
            )
        )
    }

    var body: some View {
        ServerOnboardingPage(
            provider: server.provider, title: Text("Sign In"),
            subtitle: Text(verbatim: server.name)
        ) {
            SettingsSectionGroup {
                TextField("Username", text: $viewModel.username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($field, equals: .username)
                    .onSubmit { field = .password }
                    .accessibilityIdentifier("server-sign-in-username")

                SecureField("Password", text: $viewModel.password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($field, equals: .password)
                    .onSubmit { viewModel.submit() }
                    .accessibilityIdentifier("server-sign-in-password")
            } footer: {
                Text(verbatim: server.baseURL.absoluteString)
            }
            .disabled(viewModel.phase == .submitting)

            if case let .error(message) = viewModel.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                field = nil
                viewModel.submit()
            } label: {
                Group {
                    if case .submitting = viewModel.phase { ProgressView() }
                    else { Text("Sign In") }
                }
                .font(.body)
                .frame(maxWidth: .infinity, minHeight: 24)
            }
            .plozzActionButton()
            .controlSize(.large)
            .disabled(!viewModel.canSubmit)
            .accessibilityIdentifier("server-sign-in-submit")

            if let onUseQuickConnect {
                Button {
                    onUseQuickConnect()
                } label: {
                    Text("Use Quick Connect")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 24)
                }
                .plozzActionButton(role: .secondary)
                .controlSize(.large)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { viewModel.cancel() }
    }
}

struct PlexServerSignInView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var viewModel: PlexAuthViewModel
    @State private var selectedServerIDs = Set<String>()
    @State private var didSeedSelection = false
    @State private var showCancelConfirm = false
    @State private var browserOpenFailed = false

    init(appModel: PlozziOSAppModel, http: any HTTPClient = URLSessionHTTPClient(),
         onComplete: @escaping () -> Void) {
        let profileID = appModel.profiles.activeProfileID
        _viewModel = State(
            initialValue: PlexAuthViewModel(
                service: PlexAuthService(deviceID: appModel.deviceID, http: http),
                onAuthenticated: {
                    guard appModel.profiles.activeProfileID == profileID else { throw AppError.cancelled }
                    guard appModel.persist([$0]) else { throw AppError.unknown("") }
                    onComplete()
                },
                onAuthenticatedMany: {
                    guard appModel.profiles.activeProfileID == profileID else { throw AppError.cancelled }
                    guard appModel.persist($0) else { throw AppError.unknown("") }
                    onComplete()
                }
            )
        )
    }

    init(viewModel: PlexAuthViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        ServerOnboardingPage(
            provider: .plex,
            title: isChoosingServers ? Text("Choose your servers") : Text("Link your Plex account")
        ) {
            switch viewModel.phase {
            case .idle, .requesting:
                ProgressView("Requesting a Plex link code…")
                    .frame(maxWidth: .infinity)
            case let .awaitingLink(code, authorizationURL, expiresAt):
                Button {
                    openURL(authorizationURL) { accepted in
                        browserOpenFailed = !accepted
                    }
                } label: {
                    Label("Open Plex to link", systemImage: "safari")
                        .font(.body)
                        .frame(maxWidth: .infinity, minHeight: 24)
                }
                .plozzActionButton()
                .controlSize(.large)
                if browserOpenFailed {
                    Label("Could not open the browser. Enter the code at plex.tv/link on another device.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 16) {
                    VStack(spacing: 4) {
                        Text("Or enter a code at")
                            .foregroundStyle(.secondary)
                        Text(verbatim: "plex.tv/link").font(.title3.bold())
                    }
                    ServerConnectionCode(code: code, expiresAt: expiresAt, lifetime: viewModel.codeLifetime)
                }
                .frame(maxWidth: .infinity)
            case .loadingServers:
                ProgressView("Loading your Plex servers…")
                    .frame(maxWidth: .infinity)
            case let .selectingServer(servers):
                PlexServerSelection(servers: servers, selected: $selectedServerIDs)
                Button {
                    viewModel.selectServers(servers.filter { selectedServerIDs.contains($0.id) })
                } label: {
                    Text("Continue").font(.body).frame(maxWidth: .infinity, minHeight: 24)
                }
                .plozzActionButton()
                .controlSize(.large)
                .disabled(selectedServerIDs.isEmpty)
                .accessibilityIdentifier("plex-servers-continue")
            case let .error(message):
                ContentUnavailableView {
                    Label("Unable to link Plex", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button {
                        didSeedSelection = false
                        viewModel.retry()
                    } label: {
                        Text("Try Again").font(.body).frame(maxWidth: .infinity, minHeight: 24)
                    }
                    .plozzActionButton()
                    .controlSize(.large)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    if isChoosingServers { showCancelConfirm = true }
                    else { dismiss() }
                }
                .confirmationDialog("Start over?", isPresented: $showCancelConfirm, titleVisibility: .visible) {
                    Button("Start Over", role: .destructive) { dismiss() }
                    Button("Keep Going", role: .cancel) {}
                } message: {
                    Text("You'll go back to the start and no server will be added.")
                }
            }
        }
        .interactiveDismissDisabled(isChoosingServers)
        .onChange(of: viewModel.phase, initial: true) { _, phase in
            if case let .selectingServer(servers) = phase, !didSeedSelection {
                didSeedSelection = true
                selectedServerIDs = Set(servers.filter(\.isOwned).map(\.id))
            }
        }
        .task { viewModel.startIfNeeded() }
        .onDisappear { viewModel.cancel() }
    }

    private var isChoosingServers: Bool {
        if case .selectingServer = viewModel.phase { return true }
        return false
    }
}

struct PlozziOSAccountReauthenticationView: View {
    @Environment(\.dismiss) private var dismiss
    let appModel: PlozziOSAppModel
    let account: Account

    var body: some View {
        if account.server.provider == .plex {
            recoveryContent
        } else {
            NavigationStack { recoveryContent }
        }
    }

    private var recoveryContent: some View {
        AccountReauthenticationView(
            model: appModel.accountsProviders.makeAccountReauthentication(
                account: account,
                isAuthorized: {
                    appModel.isActiveProfileAuthorized && !appModel.managementRequiresParentalPIN
                },
                onComplete: {
                    dismiss()
                    appModel.plexHomeUsers.ensurePlexIdentityForActiveProfile()
                }
            ),
            onCancel: { dismiss() }
        ) { model in
            ManagedServerSignInView(
                server: account.server, appModel: appModel, onComplete: {},
                verificationOnly: true,
                onCancel: {
                    model.cancel(); dismiss()
                },
                onAuthenticated: model.complete
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.cancel()
                        dismiss()
                    }
                }
            }
        }
    }
}
#endif
