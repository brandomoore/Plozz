#if os(iOS)
import AppRuntime
import CoreModels
import CoreNetworking
import CoreUI
import FeatureSettings
import FeatureSyncSetup
import SwiftUI

struct PlozziOSServersSettingsView: View {
    let appModel: PlozziOSAppModel
    let onAddServer: () -> Void
    @State private var selectedServerKey: String?

    private var groups: [ServerAccountGroup] {
        serverGroups(from: appModel.accounts)
    }

    var body: some View {
        SettingsPageList {
            SettingsSectionGroup(SettingsCopy.sources) {
                if groups.isEmpty {
                    Text("No sources have been added yet.")
                        .plozzForeground(.secondary)
                } else {
                    ForEach(groups, id: \.serverKey) { group in
                        // A plain Button (not NavigationLink) because SettingsSectionGroup
                        // re-emits its children through Group(subviews:), which renders
                        // every NavigationLink destination eagerly (tap any → opens the
                        // last) and breaks value links. A Button just sets state, and
                        // navigationDestination(item:) pushes exactly the tapped one.
                        Button {
                            selectedServerKey = group.serverKey
                        } label: {
                            serverRowLabel(group)
                        }
                        .settingsActionRow()
                    }
                }
            } footer: {
                Text("Sign-ins and network shares are available to every profile on this \(deviceName).")
            }

            SettingsSectionGroup {
                Button(action: onAddServer) {
                    Label {
                        Text(SettingsCopy.addSource)
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
                .settingsActionRow()
                .accessibilityIdentifier("sources-add-source")
            }
        }
        .navigationTitle(Text(SettingsCopy.sources))
        .navigationDestination(item: $selectedServerKey) { key in
            PlozziOSServerSettingsDetailView(appModel: appModel, serverKey: key)
        }
    }

    @ViewBuilder
    private func serverRowLabel(_ group: ServerAccountGroup) -> some View {
        HStack(spacing: 12) {
            ProviderBrandMark(
                provider: group.providerKind,
                size: 32,
                mediaShareTransport: group.transportKind
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(group.serverName)
                if let summary = summary(for: group) {
                    Text(summary)
                        .font(.caption)
                        .plozzForeground(.secondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .plozzForeground(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func summary(for group: ServerAccountGroup) -> LocalizedStringResource? {
        if group.accounts.count > 1 {
            return "\(group.accounts.count) sign-ins"
        }
        guard let account = group.accounts.first else { return nil }
        let user = account.userName.trimmingCharacters(in: .whitespaces)
        if user.isEmpty {
            return group.transportKind == .nfs ? nil : "Guest access"
        }
        return "Signed in as \(user)"
    }

}

private struct PlozziOSServerSettingsDetailView: View {
    let appModel: PlozziOSAppModel
    let serverKey: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedProviderSetupRouter) private var providerSetupRouter
    @State private var confirmRemoveServer = false
    @State private var confirmRemoveEverywhere = false
    @State private var selectedAccountID: String?

    private var group: ServerAccountGroup? {
        serverGroups(from: appModel.accounts).first {
            $0.serverKey == serverKey
        }
    }

    var body: some View {
        SettingsPageList {
            if let group {
                SettingsSectionGroup("Signed in as") {
                    ForEach(group.accounts) { account in
                        Button {
                            selectedAccountID = account.id
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.userName.isEmpty ? "Guest" : account.userName)
                                    Text(account.server.baseURL.host() ?? account.server.baseURL.absoluteString)
                                        .font(.caption)
                                        .plozzForeground(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.forward")
                                    .font(.footnote.weight(.semibold))
                                    .plozzForeground(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .settingsActionRow()
                    }
                } footer: {
                    Text("Removing a sign-in affects every profile on this \(deviceName).")
                }

                if group.providerKind == .iptv, let providerSetupRouter {
                    SettingsSectionGroup {
                        ForEach(group.accounts) { account in
                            Button("Edit connection", systemImage: "pencil") {
                                providerSetupRouter.connectIPTV(account: account)
                            }
                            .settingsActionRow()
                        }
                    }
                }

                if [.jellyfin, .emby, .plex, .silo].contains(group.providerKind),
                   providerSetupRouter != nil {
                    SettingsSectionGroup("Connection addresses") {
                        ServerAddressSettingsLink(accounts: group.accounts)
                    }
                }

                if group.accounts.count > 1 {
                    SettingsSectionGroup {
                        Button("Remove Server", role: .destructive) {
                            confirmRemoveServer = true
                        }
                        .settingsActionRow()
                    } footer: {
                        Text("Signs out every account on \(group.serverName).")
                    }
                }
            } else {
                ContentUnavailableView(
                    "Server Removed",
                    systemImage: "externaldrive.badge.xmark",
                    description: Text("This server is no longer available.")
                )
            }
        }
        .navigationTitle(group?.serverName ?? "Server")
        // When the server is gone (removed here, or the last sign-in removed on the
        // pushed account detail, or a remote "Remove Everywhere" landed), pop back to
        // the Servers list instead of stranding the user on an empty detail.
        .onChange(of: group == nil) { _, gone in
            if gone { dismiss() }
        }
        .navigationDestination(item: $selectedAccountID) { accountID in
            if let account = appModel.accounts.first(where: { $0.id == accountID }) {
                PlozziOSAccountDetailView(
                    appModel: appModel,
                    account: account
                )
            }
        }
        .confirmationDialog(
            "Remove \(group?.serverName ?? "server")?",
            isPresented: $confirmRemoveServer,
            titleVisibility: .visible
        ) {
            if appModel.offersRemoveEverywhere {
                Button("Remove Everywhere", role: .destructive) { confirmRemoveEverywhere = true }
                Button("Remove from This \(deviceName)", role: .destructive) {
                    for account in group?.accounts ?? [] {
                        appModel.removeAccount(id: account.id)
                    }
                }
            } else {
                Button("Remove Server", role: .destructive) {
                    for account in group?.accounts ?? [] {
                        appModel.removeAccount(id: account.id)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(appModel.offersRemoveEverywhere
                 ? "Remove it from all your devices, or just this \(deviceName)?"
                 : "Signs everyone out and removes this server.")
        }
        .alert("Remove from all devices?", isPresented: $confirmRemoveEverywhere) {
            Button("Remove Everywhere", role: .destructive) {
                for account in group?.accounts ?? [] {
                    appModel.removeAccountEverywhere(id: account.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(group?.serverName ?? "This server")” will also be removed from your other devices signed in to iCloud.")
        }
    }
}

struct PlozziOSMyLibrariesSettingsView: View {
    let appModel: PlozziOSAppModel
    let onAddServer: () -> Void
    /// Signs an additional user in to an already-added server. Same capability as
    /// the tvOS "Watching as" page, in the idiom iOS uses for this screen.
    var onAddUser: (MediaServer) -> Void = { _ in }
    /// Where this screen is being shown. Shared with tvOS, which renders the same
    /// page in both places for the same reason — see `ProfileLibrariesScope`.
    ///
    /// The controls are identical; only surrounding copy and presentation differ.
    /// Add-account actions are supplied by whichever host owns the screen, so
    /// they remain inside Settings or profile setup instead of escaping either.
    var presentation: ProfileLibrariesScope.Presentation = .settings

    var body: some View {
        let libraries = (appModel.settings.discoveredLibraries.state.value ?? [])
            .filter { !$0.library.isMusic }
            .map { ProfileLibraryChoice(accountID: $0.accountID, library: $0.library) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        PlozziOSMyLibrariesContent(
            appModel: appModel, onAddServer: onAddServer, onAddUser: onAddUser,
            presentation: presentation, groups: serverGroups(from: appModel.accounts),
            librariesByAccountID: Dictionary(grouping: libraries, by: \.accountID)
        )
    }
}

private struct PlozziOSMyLibrariesContent: View {
    @Environment(\.managedProviderSetupRouter) private var providerSetupRouter
    @Environment(SettingsSearchRequest.self) private var searchRequest: SettingsSearchRequest?
    let appModel: PlozziOSAppModel
    let onAddServer: () -> Void
    let onAddUser: (MediaServer) -> Void
    let presentation: ProfileLibrariesScope.Presentation
    let groups: [ServerAccountGroup]
    let librariesByAccountID: [String: [ProfileLibraryChoice]]
    private var discovery: DiscoveredLibrariesStore { appModel.settings.discoveredLibraries }
    private var unreachableAccountIDs: Set<String> { discovery.unreachableAccountIDs }
    private var libraryFailures: [String: AppError] { discovery.failures }

    private var profileID: String {
        appModel.profiles.activeProfileID
    }

    private func searchGroup(for target: String) -> ServerAccountGroup? {
        let candidates = groups.filter {
            target == "watcher-plex-user" ? $0.providerKind == .plex
                : target == "watcher-server-user" ? $0.providerKind != .mediaShare : true
        }
        return candidates.first(where: isWatching) ?? candidates.first
    }

    private func searchTargets(for group: ServerAccountGroup) -> [String] {
        let dependentTargets = ["profile-library-inclusion", "watcher-server-user", "watcher-plex-user"].filter {
            searchGroup(for: $0)?.serverKey == group.serverKey
        }
        return (group.serverKey == groups.first?.serverKey ? ["profile-source-inclusion"] : []) + dependentTargets
    }

    var body: some View {
        SettingsPageList {
            ProfileLibrariesSummary(profile: appModel.profiles.activeProfile)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 16, trailing: 0))
            if searchRequest?.targetID == "watcher-plex-user",
               searchGroup(for: "watcher-plex-user") == nil {
                Text("Add a Plex server to choose a Plex user.")
                    .settingsSearchAnchor("watcher-plex-user")
            } else if searchRequest?.targetID == "watcher-server-user",
                      searchGroup(for: "watcher-server-user") == nil {
                Text("Add a media server to choose who you watch as.")
                    .settingsSearchAnchor("watcher-server-user")
            }
            if groups.isEmpty {
                SettingsSectionGroup {
                    Text("No sources are available on this \(deviceName).")
                        .plozzForeground(.secondary)
                }
            } else {
                ForEach(groups, id: \.serverKey) { group in
                    serverGroup(group)
                }
            }
            if presentation == .settings || groups.isEmpty {
                SettingsSectionGroup {
                    Button(action: onAddServer) {
                        Label {
                            Text(SettingsCopy.addSource)
                        } icon: {
                            Image(systemName: "plus")
                        }
                    }
                    .accessibilityIdentifier("libraries-add-source")
                } footer: {
                    Text("New sources are available to every profile on this \(deviceName).")
                }
            }
        }
        .navigationTitle(SettingsCopy.libraries)
        .task(id: appModel.navigationLibrariesScopeKey) {
            await loadLibraries()
        }
        // Asks who you are on a Plex server you just switched on — the same
        // question setup asks, at the other moment it matters. Without it,
        // enabling a server later silently plays (and imports a watchlist) as the
        // account owner, which is the leak the setup step exists to prevent.
        //
        // Presented HERE, from the screen that owns the toggle, rather than from
        // the root: this screen is already inside a presented Settings sheet, and
        // SwiftUI won't show a second presentation from a view that's covered —
        // asking from the root would silently never appear.
        //
        // Suppressed during setup, which asks the same question inline.
        .plozzSheet(item: identityPromptBinding) { account in
            PlozziOSServerIdentityPromptView(
                appModel: appModel,
                account: account,
                onFinish: { appModel.concludeIdentityPrompt(for: account.id) },
                onDecline: { appModel.declineIdentityPrompt(for: account.id) }
            )
        }
    }

    private var identityPromptBinding: Binding<Account?> {
        Binding(
            // Only while Settings is actually up: the root presents the same
            // question when it isn't, and two presenters racing one piece of
            // state is undefined. Suppressed during setup, which asks inline.
            get: {
                presentation == .settings && appModel.isSettingsPresented
                    ? appModel.pendingIdentityAccount
                    : nil
            },
            set: { if $0 == nil { appModel.resolveIdentityPromptForPending() } }
        )
    }

    @ViewBuilder
    private func serverGroup(_ group: ServerAccountGroup) -> some View {
        SettingsSectionGroup {
            // The whole row is the master switch: provider brand + server name on
            // the left, the On/Off switch on the right — matching tvOS, where the
            // server's icon and name *are* the toggle.
            Toggle(
                isOn: Binding(
                    get: { isWatching(group) },
                    set: { setWatching($0, group: group) }
                )
            ) {
                HStack(spacing: 12) {
                    ProviderBrandMark(
                        provider: group.providerKind,
                        size: 32,
                        mediaShareTransport: group.transportKind
                    )
                    Text(group.serverName)
                }
            }
            .settingsSearchAnchor(
                group.serverKey == groups.first?.serverKey
                    ? "profile-source-inclusion" : "profile-source-\(group.serverKey)",
                fallbackFor: isWatching(group) ? [] : searchTargets(for: group)
            )

            if isWatching(group) {
                identityControl(for: group)

                if let account = activeAccount(in: group),
                   discovery.refreshingAccountIDs.contains(account.id),
                   librariesForActiveIdentity(in: group).isEmpty {
                    HStack {
                        ProgressView()
                        Text("Loading libraries…")
                    }
                } else if librariesForActiveIdentity(in: group).isEmpty {
                    if isUnreachable(group) {
                        libraryFailure(for: group)
                    } else {
                        Text("No video libraries are available.")
                            .plozzForeground(.secondary)
                    }
                } else {
                    // Checkmarks, not switches. The server above IS a switch —
                    // one thing, on or off — while these are a multi-select
                    // subset of it, which is what a checkmark means everywhere
                    // else in the app (Customize Home, Theme, Display Size).
                    // tvOS already drew them this way; a column of identical
                    // switches here made "watch this server" and "show this
                    // library" look like the same kind of decision.
                    ForEach(librariesForActiveIdentity(in: group)) { library in
                        libraryCheckRow(
                            library,
                            isSearchTarget: group.serverKey == searchGroup(for: "profile-library-inclusion")?.serverKey
                                && library.id == librariesForActiveIdentity(in: group).first?.id
                        )
                    }
                    if isUnreachable(group) { libraryFailure(for: group) }
                }
            }
        }
        .settingsSearchGroup(searchTargets(for: group))
    }

    private func libraryFailure(for group: ServerAccountGroup) -> some View {
        let account = activeAccount(in: group)
        let failure = account.flatMap { libraryFailures[$0.id] } ?? .serverUnreachable
        return HStack {
            Label {
                if failure == .serverUnreachable {
                    Text("Can't reach this server — it may be offline.")
                } else {
                    Text(failure.userMessage)
                }
            } icon: {
                Image(systemName: failure.requiresSignIn ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.triangle")
            }
            .plozzForeground(.secondary)
            Spacer()
            if failure.requiresSignIn, let account,
               account.server.provider.supportsAccountReauthentication, let providerSetupRouter {
                Button("Sign In Again") { providerSetupRouter.reauthenticationAccount = account }
            } else if failure.requiresSignIn, let account,
                      account.server.provider == .iptv, let providerSetupRouter {
                Button("Edit connection") { providerSetupRouter.connectIPTV(account: account) }
            } else {
                Button { Task { await loadLibraries() } } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    /// One library, as a checkmark child of its server's master switch.
    private func libraryCheckRow(_ library: ProfileLibraryChoice, isSearchTarget: Bool) -> some View {
        ProfileLibraryCheckRow(
            library: library, visibility: appModel.settings.homeVisibility,
            isSearchTarget: isSearchTarget
        )
    }

    @ViewBuilder
    private func identityControl(for group: ServerAccountGroup) -> some View {
        if group.providerKind == .plex, let account = activeAccount(in: group) {
            SettingsPageLink {
                PlozziOSPlexHomeUserSettingsView(
                    appModel: appModel,
                    account: account
                )
            } label: {
                HStack(spacing: 12) {
                    PlozziOSPlexIdentityAvatar(
                        url: plexIdentityAvatarURL(for: account),
                        name: plexIdentityName(for: account)
                    )
                    Text(plexIdentityName(for: account))
                }
            }
            .settingsActionRow()
            .settingsSearchAnchor(
                group.serverKey == searchGroup(for: "watcher-plex-user")?.serverKey
                    ? "watcher-plex-user" : "watcher-plex-\(group.serverKey)",
                fallbackFor: group.serverKey == searchGroup(for: "watcher-server-user")?.serverKey
                    ? ["watcher-server-user"] : []
            )
        } else if group.providerKind != .mediaShare, group.accounts.count > 1 {
            Picker(
                "Watching as",
                selection: Binding(
                    get: { activeAccount(in: group)?.id ?? group.accounts[0].id },
                    set: { selectAccount($0, in: group) }
                )
            ) {
                ForEach(group.accounts) { account in
                    Text(account.userName.isEmpty ? "Guest" : account.userName)
                        .tag(account.id)
                }
            }
            .settingsSearchAnchor(
                group.serverKey == searchGroup(for: "watcher-server-user")?.serverKey
                    ? "watcher-server-user" : "watcher-server-\(group.serverKey)"
            )
        }
        addUserButton(group)
    }

    /// Signs another user in to this server.
    ///
    /// Always shown, including when only one user is signed in — that's precisely
    /// the case where you can't otherwise tell the person you want is missing,
    /// and previously the only route was adding the whole server again from the
    /// chooser. Matches the tvOS "Watching as" page.
    @ViewBuilder
    private func addUserButton(_ group: ServerAccountGroup) -> some View {
        if group.providerKind != .mediaShare,
           let server = group.accounts.first?.server {
            Button {
                onAddUser(server)
            } label: {
                Label(
                    group.providerKind == .plex ? "Add Another Plex Account" : "Add Another User",
                    systemImage: "person.badge.plus"
                )
            }
        }
    }

    private func plexIdentityName(for account: Account) -> String {   // l10n:content — Plex user name
        let homeName = appModel.profiles.activeProfile
            .homeUserBinding(forPlexAccount: account.id)?
            .name
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let homeName, !homeName.isEmpty {
            return homeName
        }
        let accountName = account.userName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return accountName.isEmpty ? "Plex Administrator" : accountName
    }

    private func plexIdentityAvatarURL(for account: Account) -> URL? {
        let bindingURL = appModel.profiles.activeProfile
            .homeUserBinding(forPlexAccount: account.id)?
            .avatarURL
            .flatMap(URL.init(string:))
        return bindingURL ?? account.avatarURL
    }

    private func isWatching(_ group: ServerAccountGroup) -> Bool {
        let active = appModel.activeAccountIDs(for: profileID)
        return group.accounts.contains { active.contains($0.id) }
    }

    private struct PlozziOSPlexIdentityAvatar: View {
        let url: URL?
        let name: String

        var body: some View {
            Group {
                if let url {
                    FallbackAsyncImage(
                        urls: [url],
                        variant: .musicThumbnail
                    ) {
                        fallback
                    }
                } else {
                    fallback
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())
            .accessibilityHidden(true)
        }

        private var fallback: some View {
            Circle()
                .fill(Color.accentColor.opacity(0.18))
                .overlay {
                    Text(initials)
                        .font(.subheadline.bold())
                        .foregroundStyle(.tint)
                }
        }

        private var initials: String {
            let letters = name.split(separator: " ")
                .prefix(2)
                .compactMap(\.first)
                .map(String.init)
                .joined()
            return letters.isEmpty ? "P" : letters.uppercased()
        }
    }

    private func activeAccount(in group: ServerAccountGroup) -> Account? {
        let active = appModel.activeAccountIDs(for: profileID)
        return group.accounts.first { active.contains($0.id) }
    }

    private func setWatching(
        _ enabled: Bool,
        group: ServerAccountGroup,
        for targetProfileID: String? = nil
    ) {
        let profile = targetProfileID ?? profileID
        let selectedID = enabled ? group.accounts.first?.id : nil
        for account in group.accounts {
            appModel.setAccount(
                account.id,
                enabled: account.id == selectedID,
                for: profile
            )
        }
    }

    private func selectAccount(_ accountID: String, in group: ServerAccountGroup) {
        for account in group.accounts {
            appModel.setAccount(
                account.id,
                enabled: account.id == accountID,
                for: profileID
            )
        }
    }

    private func librariesForActiveIdentity(
        in group: ServerAccountGroup
    ) -> [ProfileLibraryChoice] {
        guard let account = activeAccount(in: group) else { return [] }
        return librariesByAccountID[account.id] ?? []
    }

    private func loadLibraries() async {
        await appModel.refreshNavigationLibraries()
    }

    /// Whether every account backing this server card failed its last library
    /// fetch (offline / unreachable).
    private func isUnreachable(_ group: ServerAccountGroup) -> Bool {
        guard let account = activeAccount(in: group) else { return false }
        return unreachableAccountIDs.contains(account.id)
    }
}

private struct ProfileLibraryCheckRow: View {
    let library: ProfileLibraryChoice
    let visibility: HomeLibraryVisibilityModel
    let isSearchTarget: Bool

    var body: some View {
        let isOn = visibility.isVisibleOnHome(library.key, library: library.library)
        Button {
            visibility.setEnabled(
                !visibility.isVisibleOnHome(library.key, library: library.library),
                for: library.key
            )
        } label: {
            HStack {
                Text(verbatim: library.title)
                Spacer(minLength: 12)
                SettingsCheckmark(isChecked: isOn, prominence: .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .settingsActionRow()
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .settingsSearchAnchor(
            isSearchTarget ? "profile-library-inclusion" : "profile-library-\(library.id)"
        )
    }
}

private struct ProfileLibraryChoice: Identifiable {
    let accountID: String
    let library: MediaLibrary

    var id: String { key }
    var key: String { "\(accountID):\(library.id)" }
    var title: String { library.title }   // l10n:content — library name from the server
}
#endif
