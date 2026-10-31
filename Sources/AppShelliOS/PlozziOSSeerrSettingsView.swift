#if os(iOS)
import CoreModels
import CoreUI
import SeerService
import SwiftUI

struct PlozziOSSeerrSettingsView: View {
    let appModel: PlozziOSAppModel
    @State private var urlText: String
    @State private var apiKey = ""
    @State private var users: [SeerUser] = []
    @State private var isLoadingUsers = false
    @State private var usersError: String?
    @State private var discoveredServers: [DiscoveredSeerServer] = []
    @State private var isScanning = false
    @State private var scanRequestID = 0
    private let discovery = SeerDiscovery()

    init(appModel: PlozziOSAppModel) {
        self.appModel = appModel
        _urlText = State(initialValue: appModel.seerService.savedBaseURLString ?? "")
    }

    var body: some View {
        List {
            Text(
                """
                Connect one Overseerr or Jellyseerr server for the household. \
                Each Plozz profile can make requests as a different user.
                """
            )
            .font(.footnote)
            .plozzForeground(.secondary)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            SettingsSectionGroup("Connection") {
                connectionContent
            }
            .settingsSearchGroup(appModel.seerService.isConfigured ? [] : ["seerr-profile-user"])

            if appModel.seerService.isConfigured {
                SettingsSectionGroup("Requests are made as") {
                    profileMappings
                } footer: {
                    Text(
                        """
                        Unlinked profiles request as the administrator. \
                        Linked profiles use that user’s permissions, quotas, and defaults.
                        """
                    )
                }
                .settingsSearchGroup(["seerr-profile-user"])
            }
        }
        .settingsPageSurface()
        .navigationTitle(Text(verbatim: "Seerr"))
        .task(id: appModel.seerService.connectionRevision) {
            let revision = appModel.seerService.connectionRevision
            users = []
            usersError = nil
            await appModel.seerService.refreshStatus()
            guard !Task.isCancelled,
                  appModel.seerService.connectionRevision == revision else {
                return
            }
            if appModel.seerService.isConfigured {
                await loadUsers(for: revision)
            } else {
                await scanForServers(reset: true)
            }
        }
        .task(id: scanRequestID) {
            guard scanRequestID > 0 else { return }
            await scanForServers(reset: true)
        }
    }

    @ViewBuilder
    private var connectionContent: some View {
        switch appModel.seerService.phase {
        case .unknown, .connecting:
            HStack {
                ProgressView()
                Text("Checking connection…")
                    .plozzForeground(.secondary)
            }
        case .unconfigured:
            connectionFields
        case let .connected(summary):
            Label {
                Text(summary)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .foregroundStyle(.green)
            if let savedURL = appModel.seerService.savedBaseURLString {
                Text(savedURL)
                    .font(.footnote)
                    .plozzForeground(.secondary)
            }
            Button("Test Connection") {
                Task { await appModel.seerService.refreshStatus() }
            }
            Button("Disconnect", role: .destructive) {
                appModel.disconnectSeerr()
            }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            if appModel.seerService.isConfigured {
                Button("Try Again") {
                    Task { await appModel.seerService.refreshStatus() }
                }
                Button("Disconnect", role: .destructive) {
                    appModel.disconnectSeerr()
                }
            } else {
                connectionFields
            }
        }
    }

    @ViewBuilder
    private var connectionFields: some View {
        if isScanning || !discoveredServers.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("On your network")
                        .font(.caption)
                        .plozzForeground(.secondary)
                    if isScanning {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                ForEach(discoveredServers) { server in
                    Button {
                        urlText = server.baseURL.absoluteString
                    } label: {
                        HStack {
                            Label(
                                server.baseURL.host ?? server.baseURL.absoluteString,
                                systemImage: "server.rack"
                            )
                            Spacer()
                            if let version = server.version {
                                Text("v\(version)")
                                    .font(.footnote)
                                    .plozzForeground(.secondary)
                            }
                        }
                    }
                }
            }
        }
        TextField("Server address", text: $urlText, prompt: Text(verbatim: "192.168.1.20:5055"))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .settingsSearchAnchor("seerr-profile-user")
        SecureField("API key", text: $apiKey)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        Button("Connect") {
            connect()
        }
        .disabled(!canConnect)
        Button(isScanning ? "Scanning…" : "Scan Local Network", systemImage: "wifi") {
            scanRequestID &+= 1
        }
        .disabled(isScanning)
    }

    @ViewBuilder
    private var profileMappings: some View {
        if isLoadingUsers {
            HStack {
                ProgressView()
                Text("Loading users…")
                    .plozzForeground(.secondary)
            }
        } else if let usersError {
            Label(usersError, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            Button("Try Again") {
                Task {
                    await loadUsers(for: appModel.seerService.connectionRevision)
                }
            }
        } else {
            if users.isEmpty {
                Text("No users found.")
                    .plozzForeground(.secondary)
            }
            ForEach(appModel.profiles.profiles) { profile in
                Menu {
                    Button {
                        appModel.setSeerrUser(nil, for: profile.id)
                    } label: {
                        Label(
                            "Admin — unrestricted",
                            systemImage: profile.seerrRequestIdentity == .admin
                                ? "checkmark"
                                : "person.crop.circle.badge.checkmark"
                        )
                    }
                    if !users.isEmpty {
                        Divider()
                        ForEach(users) { user in
                            Button {
                                guard isCurrentServerUser(user) else { return }
                                appModel.setSeerrUser(user, for: profile.id)
                            } label: {
                                Label {
                                    Text(verbatim: user.name)
                                } icon: {
                                    Image(
                                        systemName: isSelected(user, for: profile)
                                            ? "checkmark"
                                            : "person"
                                    )
                                }
                            }
                            .disabled(!isCurrentServerUser(user))
                        }
                    }
                } label: {
                    profileMappingLabel(profile)
                }
                .settingsSearchAnchor(
                    profile.id == appModel.profiles.profiles.first?.id
                        ? "seerr-profile-user" : "seerr-profile-\(profile.id)"
                )
            }
        }
    }

    private var canConnect: Bool {
        SeerConfig.normalizedBaseURL(from: urlText) != nil
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func connect() {
        guard let url = SeerConfig.normalizedBaseURL(from: urlText) else { return }
        Task {
            await appModel.seerService.connect(baseURL: url, apiKey: apiKey)
            guard appModel.seerService.isConfigured else { return }
            apiKey = ""
        }
    }

    private func loadUsers(for revision: UUID) async {
        isLoadingUsers = true
        usersError = nil
        defer {
            if appModel.seerService.connectionRevision == revision {
                isLoadingUsers = false
            }
        }
        do {
            let loadedUsers = try await appModel.seerService.users()
            guard appModel.seerService.connectionRevision == revision else { return }
            users = loadedUsers
        } catch is CancellationError {
            return
        } catch {
            guard appModel.seerService.connectionRevision == revision else { return }
            usersError = "Couldn’t load Seerr users."
        }
    }

    private func isCurrentServerUser(_ user: SeerUser) -> Bool {
        guard let serverIdentity = appModel.seerService.serverIdentity else {
            return false
        }
        return user.serverIdentity == serverIdentity
    }

    private func currentUser(for profile: Profile) -> SeerUser? {
        let identity = profile.seerrRequestIdentity
        guard !identity.requiresRelink(to: appModel.seerService.serverIdentity),
              let userID = identity.userID,
              let serverIdentity = appModel.seerService.serverIdentity else {
            return nil
        }
        return users.first {
            $0.id == userID && $0.serverIdentity == serverIdentity
        }
    }

    private func isSelected(_ user: SeerUser, for profile: Profile) -> Bool {
        guard isCurrentServerUser(user) else { return false }
        return currentUser(for: profile) == user
    }

    private func profileMappingLabel(_ profile: Profile) -> some View {
        let mappedUser = currentUser(for: profile)
        let needsRelink = profile.seerrRequestIdentity.userID != nil && mappedUser == nil
        return HStack {
            Text(profile.name)
            Spacer()
            if needsRelink {
                Text("Relink required")
                    .foregroundStyle(.orange)
            } else if let mappedUser {
                Text(verbatim: mappedUser.name)
                    .plozzForeground(.secondary)
            } else {
                Text("Admin — unrestricted")
                    .plozzForeground(.secondary)
            }
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption)
                .plozzForeground(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private var knownServerHosts: [String] {
        var seen = Set<String>()
        return appModel.accountsProviders.resolvedActiveAccounts.compactMap { resolved in
            guard let host = resolved.account.server.baseURL.host,
                  seen.insert(host).inserted else {
                return nil
            }
            return host
        }
    }

    private func scanForServers(reset: Bool = false) async {
        guard !appModel.seerService.isConfigured, !isScanning else { return }
        isScanning = true
        if reset {
            discoveredServers = []
        }
        defer { isScanning = false }

        for await server in discovery.discover(hostHints: knownServerHosts) {
            guard !Task.isCancelled else { return }
            if !discoveredServers.contains(where: { $0.id == server.id }) {
                discoveredServers.append(server)
            }
        }
    }
}
#endif
