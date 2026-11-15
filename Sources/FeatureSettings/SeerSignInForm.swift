#if canImport(SwiftUI)
import CoreModels
import CoreUI
import Foundation
import SeerService
import SwiftUI

struct SeerSignInForm: View {
    let seer: SeerService
    var replacing: UUID?
    var suggestsSetup = false
    var onConnected: () -> Void = {}
    @State private var manualSetup = false
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
    @State private var discoveryRevision = UUID()
    @State private var rescan = false
    @State private var addressEdited = false
    @State private var detectedServer = false
    @State private var choosingAccount = false
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
                SeerPlexSignInView(url: plexURL) { operation = nil; self.plexURL = nil }
            } else if showsSuggestedSetup {
                SeerSuggestedSetupView(
                    address: address,
                    detectedServer: detectedServer,
                    accountName: suggestedAccountName,
                    provider: mediaProvider,
                    signInTitle: suggestedSignInTitle,
                    signInHelp: passwordRequirement,
                    canContinue: methods != nil,
                    discovering: discovering,
                    signingIn: operation != nil,
                    multipleServers: suggestions.count > 1,
                    error: error,
                    onContinue: continueSuggestedSignIn,
                    onManual: openManualSetup
                )
            } else {
                if methods == nil, mode == .options, !addressEdited || !suggestions.isEmpty {
                    SeerServerDiscoverySection(
                        suggestions: suggestions, discovering: discovering,
                        onScan: { suggestions = []; addressEdited = false; rescan = true; discoveryRevision = UUID() },
                        onSelect: { url in
                            address = url.absoluteString
                            suggestions = []
                            start(.check)
                        }
                    )
                }
                addressSection
                if mode == .options || mode == .media, let passwordRequirement {
                    Text(passwordRequirement).font(.footnote).plozzForeground(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                        if mode == .options || mode == .media {
                            mediaSignInLabel(primaryTitle)
                        } else {
                            Text(primaryTitle)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .plozzPageActionLabel()
                }
                .plozzPageActionButton()
                .disabled(!canSubmit)
                .focused($primaryFocused)
                .accessibilityIdentifier("seerr-sign-in-continue")
                alternatives
            }
            if authenticatedAccount != nil, let message = error {
                Text(message).foregroundStyle(.red)
            }
        }
        .settingsSignInFields()
        #if os(tvOS)
        .defaultFocus($primaryFocused, true)
        #endif
        .sheet(isPresented: $choosingAccount) {
            SeerAccountPage(title: "Choose existing account", dismissTitle: "Cancel") {
                SettingsSectionGroup {
                    ForEach(availableAccounts) { option in
                        Button { chooseExistingAccount(option.id) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: option.name).font(.headline).plozzForeground(.primary)
                                if let name = option.serverName, !name.isEmpty {
                                    Text(verbatim: name).plozzForeground(.secondary)
                                }
                                if let url = option.serverURL {
                                    Text(verbatim: url.absoluteString)
                                        .font(.caption).plozzForeground(.secondary)
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .settingsActionRow()
                        .accessibilityIdentifier("seerr-existing-account-\(option.id)")
                    }
                }
            }
        }
        .task(id: addressEdited ? nil : discoveryRevision) { if !addressEdited { await findAddress() } }
        .onChange(of: seer.setupDiscoveryScope) {
            guard !addressEdited else { return }
            methods = nil
            address = ""
            detectedServer = false
            seer.prepareSetup()
            applyPreparedSetup()
        }
        .onChange(of: seer.setupDiscovery.selected) { applyPreparedSetup() }
        .onChange(of: seer.setupDiscovery.servers) { applyPreparedSetup() }
        .onChange(of: seer.setupDiscovery.isSearching) { applyPreparedSetup() }
        .task(id: operation?.id) { [operation] in
            guard let operation else { return }
            await perform(operation)
        }
        .onDisappear {
            password = ""; key = ""; operation = nil; plexURL = nil
            seer.setupDiscovery.cancel()
        }
        .onChange(of: seer.activeProfileID) {
            choosingAccount = false
            addressEdited = true
            operation = nil
            authenticatedAccount = nil
            password = ""
            key = ""
            plexURL = nil
        }
    }

    private var addressSection: some View {
        SettingsSectionGroup("Seerr server address") {
            TextField("Seerr server address", text: Binding(get: { address }, set: editAddress),
                      prompt: Text(verbatim: "https://requests.example.com"))
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .settingsWorkspaceEntry()
                .disabled(operation != nil)
                .accessibilityIdentifier("seerr-server-address")
                .onSubmit { if canSubmit { continueSignIn() } }
        }
    }

    private func editAddress(_ value: String) {
        guard address != value else { return }
        address = value
        addressEdited = true
        detectedServer = false
        suggestions = []
        discovering = false
        choosingAccount = false
        seer.setupDiscovery.cancel()
        methods = nil
        operation = nil
        authenticatedAccount = nil
        authenticationRevision = nil
        username = ""
        password = ""
        key = ""
        if mode != .apiKey { mode = .options }
        error = nil
    }

    private var mediaProvider: ProviderKind? {
        guard methods?.mediaServerLogin == true else { return nil }
        switch methods?.mediaServerType {
        case 1: return .plex
        case 2: return .jellyfin
        case 3: return .emby
        default: return nil
        }
    }

    private func mediaSignInLabel(_ title: LocalizedStringResource) -> some View {
        HStack(spacing: 8) {
            if let provider = mediaProvider {
                ProviderBrandMark(provider: provider, size: 20, showsBackground: false)
                    .accessibilityHidden(true)
            }
            Text(title)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(verbatim: mediaProvider?.displayName ?? ""))
    }

    private var availableAccounts: [SeerLoginOption] {
        guard methods?.jellyfinQuickConnect != false else { return [] }
        return matchingAccounts
    }

    private var matchingAccounts: [SeerLoginOption] {
        guard let methods, methods.mediaServerLogin == true else { return [] }
        return seer.loginOptions().filter { $0.mediaServerType == methods.mediaServerType }
    }

    private var passwordRequirement: LocalizedStringResource? {
        guard methods?.mediaServerType == 2, methods?.jellyfinQuickConnect == false else { return nil }
        return "This server needs your Jellyfin password. Update Seerr for password-free sign-in."
    }

    private var suggestedPasswordUsername: String? {
        if methods?.jellyfinQuickConnect == false, matchingAccounts.count == 1 {
            return matchingAccounts.first?.name
        }
        return suggestedEmbyUsername
    }

    private var showsSuggestedSetup: Bool { suggestsSetup && !manualSetup }

    private var suggestedEmbyUsername: String? {
        guard methods?.mediaServerLogin == true, methods?.mediaServerType == 3 else { return nil }
        let names = seer.embyUsernames()
        return names.count == 1 ? names.first : nil
    }

    private var suggestedAccountName: String? {
        let accounts = availableAccounts
        return accounts.count == 1 ? accounts.first?.name : suggestedEmbyUsername
    }

    private var suggestedSignInTitle: LocalizedStringResource {
        if availableAccounts.count > 1 { return "Choose existing account" }
        guard let methods else { return "Continue" }
        if methods.mediaServerLogin == true {
            switch methods.mediaServerType {
            case 1: return "Sign in with Plex"
            case 2: return "Sign in with Jellyfin"
            case 3: return "Sign in with Emby"
            default: break
            }
        }
        return "Continue"
    }

    private func continueSuggestedSignIn() {
        guard !discovering, operation == nil, profileID == seer.activeProfileID else { return }
        if !availableAccounts.isEmpty {
            continueExistingAccount()
        } else if methods != nil, let url = normalizedURL, let profileID {
            do { try seer.rememberSetupServer(url, expectedProfileID: profileID) }
            catch is CancellationError { return }
            catch { self.error = "Couldn’t save the server address. Try again."; return }
            if methods?.mediaServerLogin == true, methods?.mediaServerType == 1, availableAccounts.isEmpty {
                start(.plex)
            } else {
                openManualSetup()
                if methods?.mediaServerLogin != true {
                    mode = methods?.localLogin == true ? .local : .apiKey
                }
            }
        }
    }

    private var existingAccountTitle: LocalizedStringResource {
        if availableAccounts.count == 1, let account = availableAccounts.first {
            return "Continue as \(account.name)"
        }
        return "Choose existing account"
    }

    private func continueExistingAccount() {
        seer.synchronizeProfile()
        let accounts = availableAccounts
        guard profileID == seer.activeProfileID, operation == nil, !accounts.isEmpty else {
            error = "This account is no longer available. Choose another account."
            return
        }
        if accounts.count == 1, let account = accounts.first {
            selectMode(.options)
            start(.existing(account))
        } else {
            choosingAccount = true
        }
    }

    private func chooseExistingAccount(_ id: String) {
        guard choosingAccount else { return }
        choosingAccount = false
        seer.synchronizeProfile()
        guard profileID == seer.activeProfileID, operation == nil,
              let account = availableAccounts.first(where: { $0.id == id }) else {
            error = "This account is no longer available. Choose another account."
            return
        }
        selectMode(.options)
        start(.existing(account))
    }

    private func openManualSetup() {
        seer.synchronizeProfile()
        guard profileID == nil || profileID == seer.activeProfileID else { return }
        profileID = seer.activeProfileID
        let passwordUsername = suggestedPasswordUsername
        seer.setupDiscovery.cancel()
        discovering = false
        addressEdited = true
        manualSetup = true
        error = nil
        if let passwordUsername {
            username = passwordUsername
            mode = .media
        } else if methods?.mediaServerLogin == true,
                  [2, 3].contains(methods?.mediaServerType ?? 0), availableAccounts.isEmpty {
            mode = .media
        }
    }

    private var primaryTitle: LocalizedStringResource {
        switch mode {
        case .local, .media: return "Sign in"
        case .apiKey: return "Connect"
        case .options:
            if !availableAccounts.isEmpty { return existingAccountTitle }
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
            if !availableAccounts.isEmpty { continueExistingAccount() }
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
                if !accounts.isEmpty, mode != .options {
                    Button(action: continueExistingAccount) {
                        mediaSignInLabel(existingAccountTitle)
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
                        Button { selectMode(.media) } label: {
                            mediaSignInLabel("Enter username and password")
                                .frame(maxWidth: .infinity).plozzPageActionLabel()
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
        if mode == .local || self.mode == .local { username = "" }
        self.mode = mode
        password = ""
        key = ""
        error = nil
    }

    private func findAddress() async {
        seer.synchronizeProfile()
        profileID = seer.activeProfileID
        address = seer.profileConnections.connections.first(where: { $0.id == replacing })?.baseURL.absoluteString
            ?? seer.profileConnections.setupServer?.canonicalURL
            ?? seer.savedBaseURLString ?? ""
        detectedServer = false
        if !address.isEmpty, !showsSuggestedSetup {
            start(.check)
            return
        }
        seer.prepareSetup(force: rescan, resolvingAllServers: !showsSuggestedSetup)
        rescan = false
        applyPreparedSetup()
    }

    private func applyPreparedSetup() {
        guard discoveryIsCurrent, seer.setupDiscovery.scope == seer.setupDiscoveryScope else { return }
        let preparation = seer.setupDiscovery
        discovering = preparation.isSearching
        suggestions = preparation.servers.map(\.baseURL)
        error = preparation.error
        if showsSuggestedSetup, let selected = preparation.selected {
            address = selected.baseURL.absoluteString
            methods = selected.loginMethods
            detectedServer = preparation.scope?.preferredURL == nil
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
            if replacing == nil, seer.profileConnections.connections.isEmpty {
                do { try seer.rememberSetupServer(url, expectedProfileID: profileID) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    self.error = "Couldn’t save the server address. Try again."
                    return
                }
            }
            let account: SeerAuthenticatedAccount
            switch operation.action {
            case .check:
                let result = try await auth.setupMethods()
                try Task.checkCancellation()
                seer.synchronizeProfile()
                guard self.operation?.id == operation.id, seer.activeProfileID == profileID,
                      seer.connectionRevision == revision else { return }
                methods = result
                if availableAccounts.isEmpty {
                    if let suggestedPasswordUsername { username = suggestedPasswordUsername }
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
            if showsSuggestedSetup, case .existing = operation.action {
                save(account)
            }
        } catch is CancellationError {
            return
        } catch {
            guard self.operation?.id == operation.id, seer.activeProfileID == profileID else { return }
            if error as? SeerAuthentication.Failure == .quickConnectUnavailable,
               case let .existing(option) = operation.action, option.mediaServerType == 2 {
                manualSetup = true
                selectMode(.media)
                username = option.name
                methods?.jellyfinQuickConnect = false
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

struct SeerSuggestedSetupView: View {
    let address: String
    let detectedServer: Bool
    let accountName: String?
    let provider: ProviderKind?
    let signInTitle: LocalizedStringResource
    let signInHelp: LocalizedStringResource?
    let canContinue: Bool
    let discovering: Bool
    let signingIn: Bool
    let multipleServers: Bool
    let error: LocalizedStringResource?
    let onContinue: () -> Void
    let onManual: () -> Void
    @FocusState private var primaryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSectionGroup(serverTitle) {
                ZStack {
                    if discovering || signingIn {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel(Text(signingIn ? "Signing in…" : "Looking for Seerr…"))
                            .accessibilityIdentifier("seerr-setup-progress")
                    }
                }
                .frame(width: 20, height: 20)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
            } content: {
                Group {
                    if let url = URL(string: address), SeerServerIdentity(baseURL: url) != nil {
                        SeerDiscoveredServerRow(address: url)
                    } else {
                        Group {
                            if discovering {
                                Text("Looking for Seerr…")
                            } else if multipleServers {
                                Text("Choose a server in manual setup.")
                            } else {
                                Text("No server found. Enter its address manually.")
                            }
                        }
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                }
                .accessibilityIdentifier("seerr-suggested-server")
            }
            if let signInHelp {
                Text(signInHelp).font(.footnote).plozzForeground(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: onContinue) {
                HStack {
                    if let provider {
                        ProviderBrandMark(provider: provider, size: 24, showsBackground: false)
                            .accessibilityLabel(Text(verbatim: provider.displayName))
                    }
                    Text(primaryTitle)
                }
                .frame(maxWidth: .infinity).plozzPageActionLabel()
            }
            .plozzPageActionButton()
            .disabled(discovering || signingIn || !canContinue || address.isEmpty)
            .focused($primaryFocused)
            .accessibilityIdentifier("seerr-suggested-continue")
            Button(action: onManual) {
                Text("Set up manually").frame(maxWidth: .infinity).plozzPageActionLabel()
            }
            .plozzPageActionButton(role: .secondary)
            .disabled(signingIn)
            .accessibilityIdentifier("seerr-manual-setup")
            if let error { Text(error).foregroundStyle(.red) }
        }
        #if os(tvOS)
        .defaultFocus($primaryFocused, true)
        #endif
    }

    private var primaryTitle: LocalizedStringResource {
        if let accountName { return "Continue as \(accountName)" }
        return signInTitle
    }

    private var serverTitle: LocalizedStringResource {
        if detectedServer { return "Detected server" }
        return address.isEmpty ? "Servers" : "Server"
    }
}

struct SeerPlexSignInView: View {
    let url: URL
    let onCancel: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var browserOpenFailed = false

    var body: some View {
        VStack(spacing: 24) {
            Text("Sign in with Plex").font(.title2.bold())
            #if os(tvOS)
            SettingsQRCode(string: url.absoluteString, centerMark: nil)
                .frame(width: 260, height: 260)
                .accessibilityLabel(Text("Scan to sign in with Plex"))
            Text("Scan with your phone to sign in.")
                .plozzForeground(.secondary)
            #else
            Button(action: openPlex) {
                Text("Open Plex sign-in").frame(maxWidth: .infinity).plozzPageActionLabel()
            }
            .plozzPageActionButton()
            if browserOpenFailed {
                Text("Couldn’t open Plex. Try again.").foregroundStyle(.red)
            }
            #endif
            ProgressView("Waiting for sign-in")
            Button("Cancel", action: onCancel)
                .plozzPageActionButton(role: .secondary)
        }
        .frame(maxWidth: .infinity)
        #if os(iOS)
        .task(id: url) { openPlex() }
        #endif
    }

    private func openPlex() {
        openURL(url) { accepted in browserOpenFailed = !accepted }
    }
}

private struct SeerServerDiscoverySection: View {
    let suggestions: [URL]
    let discovering: Bool
    let onScan: () -> Void
    let onSelect: (URL) -> Void

    var body: some View {
        SettingsSectionGroup(sectionTitle) {
            if discovering {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(Text("Looking for Seerr…"))
            } else {
                Button("Scan Again", action: onScan)
            }
        } content: {
            if suggestions.isEmpty {
                Text(discovering
                     ? "Looking on your local network…"
                     : "No nearby servers found. Enter an address below, or scan again.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(suggestions, id: \.absoluteString) { url in
                Button { onSelect(url) } label: {
                    SeerDiscoveredServerRow(address: url)
                }
                .settingsActionRow()
                .accessibilityHint("Select server")
                .accessibilityIdentifier("seerr-discovered-server-\(url.absoluteString)")
            }
        }
    }

    private var sectionTitle: LocalizedStringResource {
        switch suggestions.count {
        case 0: return "Servers"
        case 1: return "Detected server"
        default: return "Detected servers"
        }
    }
}

private struct SeerDiscoveredServerRow: View {
    let address: URL

    var body: some View {
        ServerDiscoveryRow(name: Text("Seerr"), address: address, showsDisclosure: false) {
            Image("SeerrIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .settingsRowIcon()
        }
    }
}

#endif
