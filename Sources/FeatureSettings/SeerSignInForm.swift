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
    @State private var discovering = false
    @State private var addressEdited = false
    @FocusState private var primaryFocused: Bool
    private enum Action { case check, existing(SeerLoginOption), password, apiKey, plex }
    private struct Operation: Identifiable {
        let id = UUID()
        let action: Action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let account = authenticatedAccount {
                SettingsSectionGroup("Account") {
                    Text(account.user.name).font(.headline)
                    Text(account.baseURL.absoluteString)
                        .font(.footnote).plozzForeground(.secondary)
                }
                Button { save(account) } label: {
                    Text("Use this account").frame(maxWidth: .infinity).plozzPageActionLabel()
                }
                .plozzPageActionButton()
                .focused($primaryFocused)
                Button("Use another account") { authenticatedAccount = nil }
                    .plozzPageActionButton(role: .secondary)
            } else if let plexURL {
                VStack(spacing: 24) {
                    Text("Sign in with Plex").font(.title2.bold())
                    SettingsQRCode(string: plexURL.absoluteString, centerMark: nil)
                        .frame(width: 260, height: 260)
                        .accessibilityLabel(Text("Scan to sign in with Plex"))
                    Text("Scan with your phone to sign in.")
                        .plozzForeground(.secondary)
                    #if os(iOS)
                    Link(destination: plexURL) {
                        Text("Open Plex sign-in").plozzPageActionLabel()
                    }
                    .plozzPageActionButton()
                    #endif
                    ProgressView("Waiting for sign-in")
                    Button("Cancel") { operation = nil; self.plexURL = nil }
                        .plozzPageActionButton(role: .secondary)
                }
                .frame(maxWidth: .infinity)
            } else {
                addressSection
                if mode == .media || mode == .local {
                    SettingsSectionGroup(passwordTitle) {
                        SettingsInputRow(mode == .local ? "Email" : "Username") {
                            TextField(mode == .local ? "Email" : "Username", text: $username)
                                .textContentType(mode == .local ? .emailAddress : .username)
                                .keyboardType(mode == .local ? .emailAddress : .default)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .settingsWorkspaceEntry()
                        }
                        SettingsInputRow("Password") {
                            SecureField("Password", text: $password).textContentType(.password)
                                .onSubmit { if canSubmit { start(.password) } }
                        }
                    }
                    .disabled(operation != nil)
                } else if mode == .apiKey {
                    SettingsSectionGroup("API key") {
                        SecureField("API key", text: $key)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .disabled(operation != nil)
                    }
                    Text("An API key gives this profile administrator access.")
                        .font(.footnote).plozzForeground(.secondary)
                }
                if let message = error { Text(message).foregroundStyle(.red) }
                Button(action: continueSignIn) {
                    HStack {
                        if operation != nil { ProgressView() }
                        Text(primaryTitle)
                    }
                    .frame(maxWidth: .infinity)
                    .plozzPageActionLabel()
                }
                .plozzPageActionButton()
                .disabled(!canSubmit)
                .focused($primaryFocused)
                alternatives
            }
            if authenticatedAccount != nil, let message = error {
                Text(message).foregroundStyle(.red)
            }
        }
        #if os(tvOS)
        .defaultFocus($primaryFocused, true)
        #endif
        .task(id: addressEdited) { if !addressEdited { await findAddress() } }
        .task(id: operation?.id) { [operation] in
            guard let operation else { return }
            await perform(operation)
        }
        .onDisappear { password = ""; key = ""; operation = nil; plexURL = nil }
        .onChange(of: seer.activeProfileID) {
            addressEdited = true
            operation = nil
            authenticatedAccount = nil
            password = ""
            key = ""
            plexURL = nil
        }
    }

    private var addressSection: some View {
        SettingsSectionGroup("Server") {
            if methods != nil, mode != .apiKey {
                HStack {
                    Text(address).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Change") { methods = nil; mode = .options; error = nil }
                        .plozzActionButton(role: .secondary)
                        .disabled(operation != nil)
                }
            } else {
                TextField("Server address", text: Binding(
                    get: { address },
                    set: { address = $0; addressEdited = true; suggestions = []; methods = nil; error = nil }
                ), prompt: Text(verbatim: "https://requests.example.com"))
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .settingsWorkspaceEntry()
                    .disabled(operation != nil)
                    .onSubmit { if canSubmit { continueSignIn() } }
            }
            if methods == nil, !addressEdited, mode == .options {
                if discovering { ProgressView("Looking for Seerr…") }
                ForEach(suggestions, id: \.absoluteString) { url in
                    Button(url.absoluteString) {
                        addressEdited = true
                        address = url.absoluteString
                        suggestions = []
                        start(.check)
                    }.settingsActionRow()
                }
            }
        }
    }

    private var availableAccounts: [SeerLoginOption] {
        guard let methods, methods.mediaServerLogin == true else { return [] }
        return seer.loginOptions().filter { $0.mediaServerType == methods.mediaServerType }
    }

    private var primaryTitle: LocalizedStringResource {
        switch mode {
        case .local, .media: return "Sign in"
        case .apiKey: return "Connect"
        case .options:
            if let account = availableAccounts.first { return "Sign in as \(account.name)" }
            if methods?.mediaServerLogin == true, methods?.mediaServerType == 1 { return "Sign in with Plex" }
            return "Continue"
        }
    }

    private var canSubmit: Bool {
        guard normalizedURL != nil, operation == nil, profileID == seer.activeProfileID else { return false }
        switch mode {
        case .local: return !username.isEmpty && !password.isEmpty
        case .media: return !username.isEmpty
        case .apiKey: return !key.isEmpty && !seer.refusesAdminRequests()
        case .options: return true
        }
    }

    private var passwordTitle: LocalizedStringResource {
        if mode == .local { return "Seerr account" }
        return methods?.mediaServerType == 3 ? "Emby account" : "Jellyfin account"
    }

    private func continueSignIn() {
        switch mode {
        case .local, .media: start(.password)
        case .apiKey: start(.apiKey)
        case .options:
            if let account = availableAccounts.first { start(.existing(account)) }
            else if methods?.mediaServerLogin == true, methods?.mediaServerType == 1 { start(.plex) }
            else if methods?.mediaServerLogin == true, [2, 3].contains(methods?.mediaServerType ?? 0) { mode = .media }
            else if methods?.localLogin == true { mode = .local }
            else if methods != nil { mode = .apiKey }
            else { start(.check) }
        }
    }

    private var alternatives: some View {
        let accounts = availableAccounts
        return VStack(spacing: 12) {
            if let methods, methods.mediaServerLogin == true || methods.localLogin == true {
                ForEach(accounts.filter { mode != .options || $0.id != accounts.first?.id }) { option in
                    Button {
                        selectMode(.options)
                        start(.existing(option))
                    } label: {
                        Text("Sign in as \(option.name)")
                            .frame(maxWidth: .infinity).plozzPageActionLabel()
                    }
                }
                if methods.mediaServerLogin == true {
                    if methods.mediaServerType == 1, mode != .options || !accounts.isEmpty {
                        Button {
                            selectMode(.options)
                            start(.plex)
                        } label: {
                            Text(accounts.isEmpty ? "Sign in with Plex" : "Use another Plex account")
                                .frame(maxWidth: .infinity).plozzPageActionLabel()
                        }
                    } else if [2, 3].contains(methods.mediaServerType ?? 0), mode != .media {
                        let title: LocalizedStringResource = methods.mediaServerType == 2
                            ? (accounts.isEmpty ? "Sign in with Jellyfin" : "Use another Jellyfin account")
                            : "Sign in with Emby"
                        Button { selectMode(.media) } label: {
                            Text(title).frame(maxWidth: .infinity).plozzPageActionLabel()
                        }
                    }
                }
                if methods.localLogin == true, mode != .local {
                    Button { selectMode(.local) } label: {
                        Text("Seerr account").frame(maxWidth: .infinity).plozzPageActionLabel()
                    }
                }
            } else if methods == nil, mode != .options {
                Button {
                    selectMode(.options)
                    if normalizedURL != nil { start(.check) }
                } label: {
                    Text("Use an account").frame(maxWidth: .infinity).plozzPageActionLabel()
                }
            }
            if mode != .apiKey {
                Button { selectMode(.apiKey) } label: {
                    Text("Use API key").frame(maxWidth: .infinity).plozzPageActionLabel()
                }
            }
        }
        .plozzPageActionButton(role: .secondary)
        .disabled(operation != nil)
    }

    private func selectMode(_ mode: Mode) {
        addressEdited = true
        self.mode = mode
        password = ""
        key = ""
        error = nil
    }

    private func findAddress() async {
        seer.synchronizeProfile()
        profileID = seer.activeProfileID
        address = seer.profileConnections.connections.first(where: { $0.id == replacing })?.baseURL.absoluteString
            ?? seer.savedBaseURLString ?? ""
        if !address.isEmpty { start(.check); return }
        discovering = true
        defer { discovering = false }
        do {
            let urls = try await seer.suggestedAddresses()
            guard discoveryIsCurrent else { return }
            suggestions = urls
        } catch is CancellationError { return }
        catch {
            guard discoveryIsCurrent else { return }
            self.error = "Couldn’t look up the server address. Enter it above."
        }
        if suggestions.isEmpty {
            for await server in seer.discoverServers(seer.localDiscoveryHosts()) {
                guard discoveryIsCurrent else { return }
                if !suggestions.contains(server.baseURL) { suggestions.append(server.baseURL) }
            }
        }
        guard discoveryIsCurrent else { return }
        if suggestions.count == 1 {
            address = suggestions[0].absoluteString
            suggestions = []
            start(.check)
        }
    }

    private var discoveryIsCurrent: Bool {
        !Task.isCancelled && !addressEdited && operation == nil && profileID == seer.activeProfileID
    }

    private var normalizedURL: URL? {
        guard let url = SeerConfig.normalizedBaseURL(from: address),
              SeerServerIdentity(baseURL: url) != nil else { return nil }
        return url
    }

    private func start(_ action: Action) {
        addressEdited = true
        error = nil
        operation = Operation(action: action)
    }

    private func perform(_ operation: Operation) async {
        defer {
            if self.operation?.id == operation.id { self.operation = nil; plexURL = nil }
        }
        guard let profileID else { return }
        guard let url = normalizedURL else { return }
        seer.synchronizeProfile()
        guard profileID == seer.activeProfileID else { error = "The active profile changed. Open Seerr settings again."; return }
        let revision = seer.connectionRevision
        let auth = seer.authentication(url)
        do {
            let account: SeerAuthenticatedAccount
            switch operation.action {
            case .check:
                let result = try await auth.methods()
                try Task.checkCancellation()
                seer.synchronizeProfile()
                guard self.operation?.id == operation.id, seer.activeProfileID == profileID,
                      seer.connectionRevision == revision else { return }
                methods = result
                if availableAccounts.isEmpty {
                    if result.mediaServerLogin == true, [2, 3].contains(result.mediaServerType ?? 0) { mode = .media }
                    else if result.mediaServerLogin != true, result.localLogin == true { mode = .local }
                    else if result.mediaServerLogin != true, result.localLogin != true { mode = .apiKey }
                }
                return
            case let .existing(option): account = try await option.authenticate(url)
            case .password: account = try await auth.password(username: username, password: password, local: mode == .local)
            case .apiKey: account = try await auth.apiKey(key)
            case .plex:
                guard let signIn = seer.plexSignIn else { throw AppError.unauthorized }
                account = try await signIn(url) {
                    guard self.operation?.id == operation.id, seer.activeProfileID == profileID else { return }
                    plexURL = $0
                }
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
            guard self.operation?.id == operation.id, seer.activeProfileID == profileID else { return }
            if error as? SeerAuthentication.Failure == .quickConnectUnavailable,
               case let .existing(option) = operation.action, option.mediaServerType == 2 {
                selectMode(.media)
                username = option.name
                self.error = "Enter your Jellyfin password to continue."
            } else if case .check = operation.action {
                self.error = "Couldn’t reach Seerr. Check the address and try again."
            } else {
                self.error = "Couldn’t sign in. Check your details and try again."
            }
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
