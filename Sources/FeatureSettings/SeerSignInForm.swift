#if canImport(SwiftUI)
import CoreModels
import CoreUI
import Foundation
import SeerService
import SwiftUI

struct SeerSignInForm: View {
    let seer: SeerService
    var replacing: UUID?
    var onConnected: () -> Void = {}
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var key = ""
    @State private var methods: SeerLoginMethods?
    @State private var mode: Mode = .options
    @State private var operation: Operation?
    @State private var error: LocalizedStringResource?
    @State private var suggestions: [URL] = []
    @State private var plexURL: URL?
    @State private var profileID: String?
    @State private var authenticatedAccount: SeerAuthenticatedAccount?
    @State private var authenticationRevision: UUID?
    private enum Mode { case options, local, media, apiKey }
    private enum Action { case check, scan, existing(SeerLoginOption), password, apiKey, plex }
    private struct Operation: Identifiable {
        let id = UUID()
        let action: Action
    }

    var body: some View {
        SettingsSectionGroup("Sign in") {
            if let account = authenticatedAccount {
                Text(account.baseURL.absoluteString)
                    .font(.footnote).plozzForeground(.secondary)
                Text(account.user.name)
                Button("Use this account") { save(account) }.settingsActionRow()
                Button("Use another account") { authenticatedAccount = nil }.settingsActionRow()
            } else {
            SettingsInputRow("Server address") {
                TextField("Server address", text: $address, prompt: Text(verbatim: "https://requests.example.com"))
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .settingsWorkspaceEntry()
                    .disabled(operation != nil)
                    .onChange(of: address) { methods = nil; error = nil }
            }
            if methods == nil, mode == .options {
                ForEach(suggestions, id: \.absoluteString) { url in
                    Button(url.absoluteString) { address = url.absoluteString; start(.check) }.settingsActionRow()
                }
                Button("Continue") { start(.check) }
                    .settingsActionRow()
                    .disabled(normalizedURL == nil || operation != nil)
                Button("Find on local network") { start(.scan) }
                    .settingsActionRow().disabled(operation != nil)
            }
            if mode == .options, let methods {
                if methods.mediaServerLogin == true {
                    ForEach(seer.loginOptions().filter { $0.mediaServerType == methods.mediaServerType }) { option in
                        Button("Continue as \(option.name)") { start(.existing(option)) }
                            .settingsActionRow().disabled(operation != nil)
                    }
                    if methods.mediaServerType == 1 {
                        Button("Sign in with Plex") { start(.plex) }.settingsActionRow().disabled(operation != nil)
                    } else if methods.mediaServerType == 2 || methods.mediaServerType == 3 {
                        Button("Sign in with another account") { mode = .media }.settingsActionRow().disabled(operation != nil)
                    }
                }
                if methods.localLogin == true {
                    Button("Use Seerr account") { mode = .local }.settingsActionRow().disabled(operation != nil)
                }
            }
            if mode == .media || mode == .local {
                SettingsInputRow(mode == .local ? "Email" : "Username") {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .settingsWorkspaceEntry()
                }
                SettingsInputRow("Password") {
                    SecureField("Password", text: $password).textContentType(.password)
                }
                Button("Sign in") { start(.password) }
                    .settingsActionRow()
                    .disabled(username.isEmpty || password.isEmpty || operation != nil)
            }
            if mode == .apiKey {
                SettingsInputRow("API key") {
                    SecureField("API key", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Text("An API key gives this profile administrator access.")
                    .font(.footnote).plozzForeground(.secondary)
                Button("Connect") { start(.apiKey) }
                    .settingsActionRow()
                    .disabled(normalizedURL == nil || key.isEmpty || operation != nil || seer.refusesAdminRequests())
            } else {
                Button("Use API key") { mode = .apiKey }.settingsActionRow()
                    .disabled(operation != nil)
            }
            if mode != .options {
                Button("Other sign-in options") { mode = .options; start(.check) }.settingsActionRow()
                    .disabled(normalizedURL == nil || operation != nil)
            }
            if let plexURL {
                SettingsQRCode(string: plexURL.absoluteString, centerMark: nil)
                    .frame(width: 220, height: 220)
                    .accessibilityLabel(Text("Scan to sign in with Plex"))
                #if os(iOS)
                Link("Open Plex sign-in", destination: plexURL)
                #endif
            }
            if operation != nil { ProgressView() }
            }
            if let message = error { Text(message).foregroundStyle(.red) }
        }
        .task {
            seer.synchronizeProfile()
            profileID = seer.activeProfileID
            address = seer.profileConnections.connections.first(where: { $0.id == replacing })?.baseURL.absoluteString
                ?? seer.savedBaseURLString ?? ""
            if address.isEmpty {
                do {
                    suggestions = try await seer.suggestedAddresses()
                    if suggestions.count == 1 { address = suggestions[0].absoluteString }
                } catch is CancellationError { return }
                catch { self.error = "Couldn’t find a Seerr address. You can enter it above." }
            }
        }
        .task(id: operation?.id) {
            guard let operation else { return }
            await perform(operation)
        }
        .onDisappear { password = ""; key = ""; operation = nil; plexURL = nil }
        .onChange(of: seer.activeProfileID) {
            operation = nil
            authenticatedAccount = nil
            password = ""
            key = ""
            plexURL = nil
        }
    }

    private var normalizedURL: URL? {
        guard let url = SeerConfig.normalizedBaseURL(from: address),
              SeerServerIdentity(baseURL: url) != nil else { return nil }
        return url
    }

    private func start(_ action: Action) { error = nil; operation = Operation(action: action) }

    private func perform(_ operation: Operation) async {
        defer { if self.operation?.id == operation.id { self.operation = nil }; plexURL = nil }
        guard let profileID else { return }
        if case .scan = operation.action {
            suggestions = []
            for await server in SeerDiscovery().discover(hostHints: seer.localDiscoveryHosts()) {
                guard !Task.isCancelled, self.operation?.id == operation.id else { return }
                suggestions.append(server.baseURL)
            }
            if suggestions.isEmpty { error = "No Seerr servers found. Enter the server address above." }
            return
        }
        guard let url = normalizedURL else { return }
        seer.synchronizeProfile()
        guard profileID == seer.activeProfileID else { error = "The active profile changed. Open Seerr settings again."; return }
        let revision = seer.connectionRevision
        let auth = SeerAuthentication(baseURL: url)
        do {
            let account: SeerAuthenticatedAccount
            switch operation.action {
            case .scan: return
            case .check:
                let result = try await auth.methods()
                try Task.checkCancellation()
                guard self.operation?.id == operation.id else { return }
                methods = result
                return
            case let .existing(option): account = try await option.authenticate(url)
            case .password: account = try await auth.password(username: username, password: password, local: mode == .local)
            case .apiKey: account = try await auth.apiKey(key)
            case .plex:
                guard let signIn = seer.plexSignIn else { throw AppError.unauthorized }
                account = try await signIn(url) { plexURL = $0 }
            }
            try Task.checkCancellation()
            guard self.operation?.id == operation.id else { return }
            seer.synchronizeProfile()
            guard seer.activeProfileID == profileID, seer.connectionRevision == revision else { throw CancellationError() }
            authenticatedAccount = account
            authenticationRevision = revision
            password = ""
            key = ""
        } catch is CancellationError {
            return
        } catch {
            self.error = "Couldn’t sign in. Check the server and account, or choose another sign-in method."
        }
    }

    private func save(_ account: SeerAuthenticatedAccount) {
        guard let profileID, let authenticationRevision else { return }
        do {
            try seer.saveAccount(account, expectedProfileID: profileID, expectedRevision: authenticationRevision, replacing: replacing)
            onConnected()
        } catch is CancellationError {
            authenticatedAccount = nil
            error = "The active profile changed. Open Seerr settings again."
        } catch { self.error = "Couldn’t save the Seerr connection." }
    }
}
#endif
