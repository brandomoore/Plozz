import CoreModels
import CoreUI
import SwiftUI

public struct ProfileSourcesView: View {
    let scope: ProfileLibrariesScope
    private let canManage: @MainActor () -> Bool
    @Environment(\.profileSourceDestination) private var destination
    @Environment(\.profileSourcePlaylists) private var playlists
    @Environment(\.profileSourceGuideStore) private var guideStore
    @Environment(\.locale) private var locale
    @Environment(ProfilesModel.self) private var profiles: ProfilesModel?
    @State private var enrolledNames = [String: String]()

    public init(scope: ProfileLibrariesScope, canManage: @escaping @MainActor () -> Bool) {
        self.scope = scope
        self.canManage = canManage
    }

    public var body: some View {
        let accounts = scope.accounts.filter { scope.isAccountIncludedInActiveProfile($0.id) }
        GroupedSettingsPage(title: SettingsCopy.sources, backIdentifier: "sources-back") {
            if canManage(), let profile = profiles?.activeProfile, profile.id == scope.activeProfile.id {
                if !accounts.isEmpty, let destination {
                    SettingsSectionGroup {
                        ForEach(accounts) { account in
                            SettingsPageLink {
                                destination(account.id, { canManage() && profiles?.activeProfileID == profile.id
                                    && scope.isAccountIncludedInActiveProfile(account.id) })
                            } label: {
                                SettingsDisclosureLabel {
                                    HStack(spacing: 12) {
                                        ProviderBrandMark(provider: account.server.provider, size: 32,
                                                          mediaShareTransport: account.server.provider == .mediaShare
                                                            ? MediaShareTransportKind(mediaShareScheme: account.server.baseURL.scheme) : nil,
                                                          siteURL: account.server.baseURL)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(verbatim: profile.sourceDisplayName(for: account, enrolledName: enrolledNames[account.id]))
                                            subtitle(for: account)
                                                .font(.caption).settingsRowSecondary().lineLimit(2)
                                        }
                                    }
                                }
                            }
                            .settingsActionRow()
                            .settingsWorkspaceEntry(accounts.first?.id == account.id)
                            .accessibilityIdentifier("profile-source-\(account.id)")
                            .settingsSearchAnchor("profile-source-\(account.id)", fallbackFor:
                                searchTargets(for: account, in: accounts))
                        }
                    }
                }
                playlists?()
                SettingsSectionGroup {
                    Button {
                        guard canManage(), profiles?.activeProfileID == profile.id else { return }
                        scope.onAddAccount()
                    } label: {
                        Label { Text(SettingsCopy.addSource) } icon: { Image(systemName: "plus") }
                    }
                    .settingsActionRow()
                    .settingsWorkspaceEntry(accounts.isEmpty)
                    .accessibilityIdentifier("sources-add-source")
                    .settingsSearchAnchor("sources-add-source", fallbackFor:
                        SettingsSearchCatalog.targets(on: .accountLibraries).filter { target in
                            !accounts.contains { searchTargets(for: $0, in: accounts).contains(target) }
                        })
                }
            } else {
                ContentUnavailableView("Sources unavailable", systemImage: "lock")
            }
        }
        .task(id: scope.activeProfile.id) {
            enrolledNames = [:]
            guard profiles?.activeProfileID == scope.activeProfile.id, let store = guideStore?(scope.activeProfile.id) else { return }
            do {
                for source in try store.load().servers { enrolledNames[source.accountID] = source.name }
            } catch {
                // The embedded guide section owns the storage error and retry.
                enrolledNames.removeAll()
            }
        }
    }

    private func subtitle(for account: Account) -> Text {
        let libraries = (scope.discoveredLibraries.value ?? []).filter { $0.accountID == account.id }
        var names = libraries.map { $0.library.displayName(in: locale) }
        if enrolledNames[account.id] != nil {
            names.append(String(localized: "Live TV", locale: locale))
        }
        let provider = account.server.provider.displayName
        return Text(verbatim: names.isEmpty ? provider : provider + " · " + names.formatted(.list(type: .and, width: .narrow).locale(locale)))
    }

    private func searchTargets(for account: Account, in accounts: [Account]) -> [String] {
        var targets = [String]()
        if accounts.first?.id == account.id { targets += ["profile-source-inclusion", "profile-library-inclusion"] }
        if accounts.first(where: { $0.server.provider == .plex })?.id == account.id { targets.append("watcher-plex-user") }
        if accounts.first(where: { $0.server.provider.usesMediaBrowserAPI })?.id == account.id { targets.append("watcher-server-user") }
        return targets
    }
}

public struct ProfileSourceDetail<LiveControls: View>: View {
    private let profileID: String
    private let accountID: String
    private let readScope: @MainActor () -> ProfileLibrariesScope
    private let isAuthorized: @MainActor () -> Bool
    private let liveControls: () -> LiveControls
    @Environment(ProfilesModel.self) private var profiles: ProfilesModel?
    @Environment(\.managedProviderSetupRouter) private var setup
    @Environment(\.profileSourceGuideStore) private var guideStore
    @SettingsPageDismiss private var dismiss
    @State private var removing = false
    @State private var rename = ""
    @State private var editingName = false
    @State private var mutationFailed = false
    @State private var enrolledName: String?
    @State private var liveFormat: XtreamLiveFormat?

    public init(profileID: String, accountID: String, scope: @escaping @MainActor () -> ProfileLibrariesScope,
                isAuthorized: @escaping @MainActor () -> Bool, @ViewBuilder liveControls: @escaping () -> LiveControls) {
        self.profileID = profileID
        self.accountID = accountID
        readScope = scope
        self.isAuthorized = isAuthorized
        self.liveControls = liveControls
    }

    private var current: (ProfileLibrariesScope, Profile, Account)? {
        guard isAuthorized(), let profile = profiles?.activeProfile, profile.id == profileID else { return nil }
        let scope = readScope()
        guard scope.activeProfile.id == profileID, scope.isAccountIncludedInActiveProfile(accountID),
              let account = scope.accounts.first(where: { $0.id == accountID }) else { return nil }
        return (scope, profile, account)
    }

    public var body: some View {
        if let (scope, profile, account) = current {
            GroupedSettingsPage(verbatim: profile.sourceDisplayName(for: account, enrolledName: enrolledName),
                                backIdentifier: "profile-source-back") {
                librarySection(scope, account: account)
                if account.server.provider == .mediaShare, scope.onRescanShare != nil {
                    ShareLibraryStatusPanel(account: account) { id in
                        guard let (scope, _, _) = current else { return }
                        scope.onRescanShare?(id)
                    }
                }
                if account.server.provider == .plex {
                    SettingsSectionGroup {
                        SettingsPageLink {
                            PlexLinkedUserDetailView(scope: scope, accountID: accountID, canManage: { current != nil })
                        } label: {
                            LabeledContent("Watching as", value: profile.homeUserBinding(forPlexAccount: accountID)?.name
                                           ?? account.userName)
                        }
                        .settingsActionRow()
                    }
                } else if account.server.provider.usesMediaBrowserAPI {
                    SettingsSectionGroup {
                        LabeledContent("Watching as", value: account.userName)
                        Button("Sign in as another user") {
                            guard let (scope, _, account) = current else { return }
                            scope.onAddUser(account.server)
                        }.settingsActionRow()
                    }
                }
                liveControls()
                if account.server.provider == .iptv, let liveFormat {
                    SettingsSectionGroup {
                        formatPicker(liveFormat)
                    }
                }
                if let setup, !profile.isKids {
                    if [.jellyfin, .emby, .plex, .silo].contains(account.server.provider) {
                        SettingsSectionGroup("Connection addresses") {
                            ServerAddressSettingsLink(accounts: [account])
                        }
                    } else if account.server.provider == .iptv {
                        SettingsSectionGroup {
                            Button("Edit connection", systemImage: "pencil") {
                                if let (_, _, source) = current { setup.connectIPTV(account: source) }
                            }
                            .settingsActionRow()
                        }
                    }
                }
                SettingsSectionGroup {
                    Button {
                        guard let (_, owner, source) = current else { return }
                        rename = owner.sourceDisplayName(for: source, enrolledName: enrolledName)
                        editingName = true
                    } label: {
                        Label("Rename source", systemImage: "pencil")
                    }
                    .settingsActionRow()
                    if let setup, !profile.isKids, account.server.provider.supportsAccountReauthentication {
                        Button {
                            guard let (_, _, source) = current else { return }
                            setup.reauthenticationAccount = source
                        } label: { Label("Sign In Again", systemImage: "person.crop.circle") }
                        .settingsActionRow()
                    }
                    Button(role: .destructive) { removing = true } label: {
                        Label("Remove source", systemImage: "trash")
                    }
                    .settingsActionRow()
                }
                if mutationFailed {
                    InlineErrorMessage(Text("Couldn’t update this source. Reopen Sources and try again."))
                }
            }
            .task(id: accountID) {
                do {
                    enrolledName = try guideStore?(profileID)?.load().servers.first { $0.accountID == accountID }?.name
                } catch { mutationFailed = true }
                do {
                    if account.server.provider == .iptv, try scope.connectedIPTVMode?(accountID) == .xtream {
                        liveFormat = try formatPreference.load()
                    } else { liveFormat = nil }
                } catch { liveFormat = nil; mutationFailed = true }
                await scope.reloadLibraries()
            }
            .settingsPageDestination(isPresented: $editingName) {
                GroupedSettingsPage(title: "Rename source", backIdentifier: "rename-source-back") {
                    SettingsSectionGroup {
                        TextField("Source name", text: $rename)
                        Button("Save") {
                            guard let (_, currentProfile, source) = current, let profiles else {
                                mutationFailed = true
                                editingName = false
                                return
                            }
                            do {
                                try profiles.setSourceName(cleanedName, accountID: source.id, for: currentProfile.id)
                                mutationFailed = false
                            } catch { mutationFailed = true }
                            editingName = false
                        }
                        .disabled(cleanedName.isEmpty || cleanedName.utf8.count > 512 || current == nil)
                        .settingsActionRow()
                    }
                }
            }
            .confirmationDialog("Remove this source?", isPresented: $removing, titleVisibility: .visible) {
                Button("Remove source", role: .destructive) {
                    guard let (scope, _, _) = current, let store = guideStore?(profileID), let profiles else {
                        mutationFailed = true; return
                    }
                    do {
                        try store.removeServer(accountID: accountID)
                        scope.onSetAccountIncluded(accountID, false)
                        guard try !profiles.confirmedSourceMembership(for: profileID).contains(accountID) else {
                            mutationFailed = true; return
                        }
                        dismiss()
                    } catch { mutationFailed = true }
                }
            } message: { Text("This removes the source from this profile only.") }
        } else {
            ContentUnavailableView("Source unavailable", systemImage: "lock")
        }
    }

    private var cleanedName: String { rename.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var formatPreference: XtreamLiveFormatPreference {
        .init(accountID: accountID, profileID: profileID)
    }

    private func formatPicker(_ selected: XtreamLiveFormat) -> some View {
        let selection = Binding(get: { liveFormat ?? selected }, set: { value in
            do {
                guard let (scope, _, _) = current, try scope.connectedIPTVMode?(accountID) == .xtream else {
                    throw AppError.unauthorized
                }
                try formatPreference.save(value)
                liveFormat = value
                mutationFailed = false
            } catch { mutationFailed = true }
        })
        let options = Picker("Live stream format", selection: selection) {
            ForEach(XtreamLiveFormat.allCases, id: \.self) { Text(verbatim: $0.label).tag($0) }
        }.pickerStyle(.inline)
        let label = LabeledContent {
            SettingsMenuValue(Text(verbatim: selected.label))
        } label: { Label("Live stream format", systemImage: "bolt.horizontal") }
        return Group {
            #if os(tvOS)
            Menu { options } label: { label }.menuStyle(.button)
            #else
            SettingsControlMenu { options } label: { label }
            #endif
        }
        .accessibilityLabel(Text("Live stream format"))
        .accessibilityValue(Text(verbatim: selected.label))
        .accessibilityIdentifier("source-live-stream-format")
    }

    @ViewBuilder
    private func librarySection(_ scope: ProfileLibrariesScope, account: Account) -> some View {
        let available = (scope.discoveredLibraries.value ?? []).filter { $0.accountID == accountID }
        let libraries = account.server.baseURL.scheme?.lowercased() == "smb"
            ? AggregatedLibrary.smbPickerChoices(available, rootName: account.server.name) : available
        if !libraries.isEmpty {
            SettingsSectionGroup("Libraries") {
                ForEach(libraries) { library in
                    Button {
                        guard let (liveScope, _, _) = current,
                              liveScope.discoveredLibraries.value?.contains(where: { $0.key == library.key }) == true else { return }
                        liveScope.homeVisibility.setEnabled(!liveScope.homeVisibility.isVisibleOnHome(library), for: library.key)
                    } label: {
                        HStack {
                            library.library.displayName
                            Spacer()
                            if scope.homeVisibility.isVisibleOnHome(library) { Image(systemName: "checkmark") }
                        }
                    }
                    .accessibilityAddTraits(scope.homeVisibility.isVisibleOnHome(library) ? .isSelected : [])
                    .settingsActionRow()
                }
            }
        }
        if let error = scope.libraryFailures[accountID] {
            SettingsSectionGroup {
                InlineErrorMessage(Text(error.userMessage))
                Button("Retry") { Task { if let (scope, _, _) = current { await scope.reloadLibraries() } } }
                    .settingsActionRow()
            }
        } else if scope.refreshingLibraryAccountIDs.contains(accountID), libraries.isEmpty {
            ProgressView("Loading libraries…")
        }
    }
}
