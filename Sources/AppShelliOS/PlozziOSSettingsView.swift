#if os(iOS)
import AppRuntime
import CoreModels
import CoreNetworking
import CoreUI
import FeaturePlayback
import FeatureAuth
import FeatureProfiles
import FeatureSettings
import FeatureSyncSetup
import SwiftUI
import UIKit

struct PlozziOSSettingsView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showingAddServer = false
    @State private var providerSetupRouter = ManagedProviderSetupRouter()
    @State private var iptvSetup: ManagedProviderSetupRouter.Request?
    /// A server we're signing an ADDITIONAL user into, so the Add Server sheet
    /// opens pre-filled with it instead of at the provider chooser.
    @State private var addUserServer: MediaServer?
    let appModel: PlozziOSAppModel
    let onClose: () -> Void
    /// Opens the profile picker. Owned by the root, because the picker can raise
    /// PIN gates that must not be asked for from under the Settings sheet.
    var onSwitchProfile: () -> Void = {}
    /// Requests a profile switch once Settings is actually gone.
    ///
    /// The gates a switch can raise are covers on the ROOT; asking for one from
    /// under this sheet is the arrangement SwiftUI drops, and because the gate's
    /// binding stays true it is never re-requested — switching would wedge until
    /// relaunch. So the row hands the id up and the shell applies it in the
    /// sheet's `onDismiss`.
    var onSwitchTo: (String) -> Void = { _ in }
    let systemColorScheme: ColorScheme

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                PlozziOSSettingsSplitView(
                    appModel: appModel,
                    onAddServer: showAddServer,
                    onAddUser: showAddUser(on:),
                    onClose: onClose,
                    onSwitchProfile: onSwitchProfile,
                    onSwitchTo: onSwitchTo
                )
            } else {
                NavigationStack {
                    PlozziOSSettingsCompactMenu(
                        appModel: appModel,
                        onAddServer: showAddServer,
                        onAddUser: showAddUser(on:),
                        onSwitchProfile: onSwitchProfile,
                        onSwitchTo: onSwitchTo
                    )
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Close", systemImage: "xmark", action: onClose)
                                .labelStyle(.iconOnly)
                        }
                    }
                }
                .toolbarBackground(.hidden, for: .navigationBar)
            }
        }
        .environment(appModel.profiles)
        .environment(\.managedProviderSetupRouter, providerSetupRouter)
        .plozzSheet(item: $providerSetupRouter.addressAccount) { account in
            let profileID = appModel.profiles.activeProfileID
            ServerAddressesView(
                account: account, store: appModel.accountStore,
                isAuthorized: {
                    appModel.profiles.activeProfileID == profileID && !appModel.managementRequiresParentalPIN
                },
                onChanged: { appModel.accountsProviders.reloadAccounts(updatingServerAddressesFor: account.id) }
            )
            .presentationSizing(.page)
        }
        .plozzSheet(item: $providerSetupRouter.reauthenticationAccount) { account in
            PlozziOSAccountReauthenticationView(appModel: appModel, account: account)
                .presentationSizing(.page)
        }
        .onChange(of: appModel.profiles.activeProfileID) { _, _ in
            providerSetupRouter.addressAccount = nil
            providerSetupRouter.reauthenticationAccount = nil
        }
        .onChange(of: appModel.liveTVAdmissionDiagnostic, initial: true) { _, diagnostic in
            HandoffDiagnostics.emit("SOURCES event=appAdmission \(diagnostic)")
        }
        .onChange(of: providerSetupRouter.request?.id) { _, _ in
            guard let request = providerSetupRouter.request else { return }
            iptvSetup = request
            providerSetupRouter.request = nil
            showAddServer()
        }
        .scrollContentBackground(.hidden)
        .background { SettingsPageBackground() }
        .transientStatusOverlay(
            presenter: appModel.transientStatusPresenter,
            bottomPadding: 24,
            palette: palette
        )
        .environment(\.themePalette, palette)
        .environment(\.colorScheme, palette.isLight ? .light : .dark)
        .tint(palette.primaryText)
        .plozzSheet(
            isPresented: $showingAddServer,
            onDismiss: {
                appModel.finishManagedServerPresentation()
                addUserServer = nil
                iptvSetup = nil
            }
        ) {
            AddServerView(
                appModel: appModel,
                initialProvider: iptvSetup == nil ? addUserServer?.provider ?? .jellyfin : .iptv,
                initialAddress: addUserServer?.baseURL.absoluteString ?? "",
                initialIPTVPlaylist: iptvSetup?.playlist, initialIPTVAccount: iptvSetup?.account,
                initialIPTVMode: iptvSetup?.mode ?? .playlist
            )
                .presentationSizing(.page)
        }
        .plozzSheet(item: plexUserSelectionBinding) { selection in
            PlozziOSPlexUserSelectionView(
                appModel: appModel,
                selection: selection,
                onImportAll: appModel.importPlexHomeProfilesDuringOnboarding,
                onSelect: appModel.selectPlexUserDuringOnboarding
            )
        }
        .plozzSheet(item: plexPINBinding) { request in
            PlozziOSPlexPINView(
                model: appModel.plexHomeUsers,
                request: request
            )
        }
        .plozzSheet(item: librarySelectionBinding) { selection in
            PlozziOSLibrarySelectionView(
                appModel: appModel, accountIDs: selection.accountIDs
            )
        }
    }

    /// Signs an additional user in to a server that's already added — the iOS half
    /// of "Watching as ▸ Add Another User". Reuses the Add Server sheet,
    /// pre-filled, so there's one sign-in path rather than two.
    private func showAddUser(on server: MediaServer) {
        addUserServer = server
        showAddServer()
    }

    private func showAddServer() {
        appModel.beginManagedServerPresentation()
        showingAddServer = true
    }

    private var plexUserSelectionBinding:
        Binding<PlexHomeUsersModel.PendingPlexUserSelection?>
    {
        Binding(
            get: { appModel.plexHomeUsers.pendingPlexUserSelection },
            set: { selection in
                if selection == nil {
                    appModel.cancelPlexUserSelectionDuringOnboarding()
                }
            }
        )
    }

    private var plexPINBinding:
        Binding<PlexHomeUsersModel.PlexPINRequest?>
    {
        Binding(
            get: { appModel.plexPINRequestForAppPresentation },
            set: { request in
                if request == nil {
                    appModel.plexHomeUsers.dismissPlexPINIfPresented()
                }
            }
        )
    }

    private var librarySelectionBinding:
        Binding<PlozziOSAppModel.PendingLibrarySelection?>
    {
        Binding(
            get: { appModel.pendingLibrarySelection },
            set: { selection in
                if selection == nil {
                    appModel.completeLibrarySelection()
                }
            }
        )
    }

    private var palette: ThemePalette {
        ThemePalette.palette(
            for: appModel.settings.theme.theme,
            systemColorScheme: systemColorScheme
        )
    }
}

private enum PlozziOSSettingsDestination: Hashable {
    case search(String)
    case profiles
    case requests
    case servers
    case myLibraries
    /// Parental PIN prompt unsealing a Kids Profile's restricted settings.
    case grownUps
    /// This profile's own management page, reached from Parental Controls.
    case manageProfile
    /// The profile's own name, avatar and colour. Deliberately outside Parental
    /// Controls — it can't escalate anything.
    case profileAppearance
    /// The household's Parental PIN.
    case parentalPIN
    case profile(ProfileSettingsCategory)
    case downloads
    case syncSetup
    case metadata
    case diagnostics
    case attributions
    case releaseNotes

    var isSearchResult: Bool {
        if case .search = self { return true }
        return false
    }
}

private struct PlozziOSProfileSettingsSection<Row: View, Management: View>: View {
    let profileName: String
    let showsParentalControls: Bool
    @ViewBuilder let row: (ProfileSettingsCategory) -> Row
    @ViewBuilder let management: () -> Management

    var body: some View {
        SettingsSectionGroup(verbatim: profileName) {
            ForEach(ProfileSettingsCategory.allCases) { category in
                if category == .language {
                    PlozziOSSettingsLanguagePicker()
                        .settingsSearchAnchor("language")
                } else if category == .libraries {
                    if !showsParentalControls { row(category) }
                    management()
                } else {
                    row(category)
                }
            }
        } footer: {
            Text(profileScopeFooter)
        }
    }
}

struct PlozziOSSettingsCategoryLabel: View {
    let category: ProfileSettingsCategory
    let accounts: [Account]
    let isAccountIncluded: (String) -> Bool
    var isSealed = false

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(category.title)
                if category == .libraries {
                    SettingsLibrarySourcesSummary(
                        accounts: accounts, isAccountIncluded: isAccountIncluded
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if let summary = category.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } icon: {
            Image(systemName: isSealed ? "lock.fill" : category.symbol)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct PlozziOSSettingsLanguagePicker: View {
    @Environment(AppLanguageSettingsModel.self) private var appLanguage
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        @Bindable var appLanguage = appLanguage
        Menu {
            Picker("Language", selection: $appLanguage.language) {
                ForEach(AppLanguage.available()) { language in
                    Group {
                        if let endonym = language.endonym {
                            Text(verbatim: endonym)
                        } else {
                            Text(AppLanguage.systemOptionTitle)
                        }
                    }
                    .tag(language)
                }
            }
            .pickerStyle(.inline)
        } label: {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Language", systemImage: "globe")
                    currentLanguage
                }
            } else {
                LabeledContent {
                    currentLanguage
                } label: {
                    Label("Language", systemImage: "globe")
                }
            }
        }
        .accessibilityIdentifier("settings-category-language")
        .accessibilityHint("Applies to Plozz's own labels. Media titles keep the language your server provides, and system prompts follow the device.")
    }

    private var currentLanguage: some View {
        HStack(spacing: 8) {
            if let endonym = appLanguage.language.endonym {
                Text(verbatim: endonym)
            } else {
                Text(AppLanguage.systemOptionTitle)
            }
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.weight(.semibold))
                .accessibilityHidden(true)
        }
        .foregroundStyle(.secondary)
    }
}

private struct PlozziOSProfileSettingsPage: View {
    let category: ProfileSettingsCategory
    let appModel: PlozziOSAppModel
    let onAddServer: () -> Void
    let onAddUser: (MediaServer) -> Void
    let canManageProviders: Bool
    var isPresented = true
    var searchPage: SettingsSearchPage? = nil

    var body: some View {
        switch category {
        case .playback:
            PlozziOSPlaybackSettingsView(
                model: appModel.settings.playback, audioPolicy: appModel.settings.audioPolicy,
                hasStreamingServer: appModel.accountsProviders.resolvedActiveAccounts.contains {
                    $0.provider is any StreamingQualityProviding
                },
                streamingSupport: appModel.streamingQualitySupport
            )
        case .subtitles:
            PlozziOSSubtitleSettingsView(
                behavior: appModel.settings.subtitleBehavior, policy: appModel.settings.subtitlePolicy,
                style: appModel.settings.subtitleStyle
            )
        case .liveTV:
            LiveTVSettingsView(
                store: LiveTVViewSettingsStore(namespace: appModel.profiles.activeNamespace),
                preferencesStore: LiveTVPreferencesStore(namespace: appModel.profiles.activeNamespace),
                sourceManagement: { preferences in
                    AnyView(PlozziOSLiveTVSourcesDestination(
                        profileID: appModel.profiles.activeProfile.id,
                        preferencesNamespace: appModel.profiles.activeNamespace,
                        accountsProviders: appModel.accountsProviders, profiles: appModel.profiles,
                        connectServer: onAddServer,
                        didConfigurePlaylist: { _ = appModel.recordSuccessfulIPTVSetup() },
                        isPresented: isPresented,
                        isProfileAuthorized: { [appModel] in appModel.isLiveTVProfileAuthorized },
                        settingsPreferences: preferences
                    ))
                },
                searchPage: searchPage ?? .liveTV
            )
            .id(appModel.profiles.activeProfile.id)
        case .libraries:
            PlozziOSMyLibrariesSettingsView(
                appModel: appModel, onAddServer: onAddServer, onAddUser: onAddUser
            )
        case .appearance:
            PlozziOSAppearanceSettingsView(
                appModel: appModel, theme: appModel.settings.theme,
                transparency: appModel.settings.transparency, cardStyle: appModel.settings.cardStyle,
                density: appModel.settings.density, watchIndicator: appModel.settings.watchIndicator,
                canManageProviders: canManageProviders
            )
        case .screensNavigation:
            PlozziOSScreensNavigationSettingsView(appModel: appModel)
        case .trackers:
            PlozziOSTrackerSettingsView(appModel: appModel)
        case .language:
            List { PlozziOSSettingsLanguagePicker().settingsSearchAnchor("language") }
                .settingsPageSurface()
                .navigationTitle("Language")
        }
    }
}

var deviceName: String {
    UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
}

/// Heading for the settings every profile shares. Named for the audience rather
/// than the hardware, because most of what's in the group syncs — see
/// `SettingsCopy.everyone`. The reach lives in the section footer instead, so
/// toggling iCloud Sync never appears to move a row into a different scope.
private var deviceSettingsTitle: LocalizedStringResource { SettingsCopy.everyone }

/// Whether this device is currently sharing settings with the user's others.
/// Read at render time so the scope footers track the iCloud Sync row live.
private var settingsScopeSyncEnabled: Bool { SyncSetupFeatureFlag().isEnabled }

/// Reach clause for the shared-settings group.
private var everyoneScopeFooter: LocalizedStringResource {
    SettingsCopy.everyoneScope(syncEnabled: settingsScopeSyncEnabled, deviceName: deviceName)
}

/// Reach clause for the active profile's own settings.
private var profileScopeFooter: LocalizedStringResource {
    SettingsCopy.profileScope(syncEnabled: settingsScopeSyncEnabled, deviceName: deviceName)
}

private struct PlozziOSSettingsSplitView: View {
    @Environment(\.themePalette) private var palette
    let appModel: PlozziOSAppModel
    let onAddServer: () -> Void
    var onAddUser: (MediaServer) -> Void = { _ in }
    let onClose: () -> Void
    var onSwitchProfile: () -> Void = {}
    /// Requests a profile switch once Settings is actually gone.
    ///
    /// The gates a switch can raise are covers on the ROOT; asking for one from
    /// under this sheet is the arrangement SwiftUI drops, and because the gate's
    /// binding stays true it is never re-requested — switching would wedge until
    /// relaunch. So the row hands the id up and the shell applies it in the
    /// sheet's `onDismiss`.
    var onSwitchTo: (String) -> Void = { _ in }
    @State private var selection: PlozziOSSettingsDestination?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Whether this profile shows a separate parent-controlled group. Only a
    /// Kids Profile does, and only once a Parental PIN exists — without one
    /// there's nothing to control with.
    private var showsParentalControlsSection: Bool {
        appModel.profiles.activeProfile.isKids
            && appModel.profiles.parentalPIN != nil
    }

    private var isParentalSealed: Bool {
        appModel.profiles.activeProfile.isKids
            && appModel.profiles.parentalPIN != nil
            && !isParentalUnlocked
    }

    private var profileIdentityHeader: some View {
        SettingsSectionGroup {
            PlozziOSProfileIdentityHeader(
                appModel: appModel,
                onSwitchProfile: onSwitchProfile
            )
        }
    }
    @State private var confirmSignOutAll = false
    /// Whether the Parental PIN has been entered for the Kids Profile currently
    /// open. View state, cleared when the profile changes, so unsealing once
    /// never becomes unsealing for good.
    @State private var isParentalUnlocked = false
    /// Where to go once the Parental PIN is accepted.
    ///
    /// The detail pane is driven by `selection`, not a navigation stack, so the
    /// unlock view's `dismiss()` does nothing here — it stayed on screen and let
    /// you keep typing a PIN that had already worked. Remembering the row that
    /// was tapped lets the unlock carry you INTO it, which is what someone
    /// expects anyway.
    @State private var parentalUnlockTarget: PlozziOSSettingsDestination?
    private var developerMode: DeveloperModeModel { .shared }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ScrollView {
                VStack(spacing: 18) {
                    // Live media-share scan/enrich progress. Renders nothing when
                    // idle, so Settings is unchanged unless a share is working.
                    ShareScanStatusHeader(
                        status: appModel.shareScanStatus,
                        shareIDs: appModel.mediaShareAccountIDs
                    )

                    // The active profile's settings come FIRST: they are what
                    // anyone actually opens Settings to change, where the device
                    // group is setup done once.
                    // Who you are, as the way to become someone else — the
                    // avatar-in-the-corner convention every streaming app uses.
                    // Always present, Kids Profile or not: hiding the exit was
                    // never the protection, the Parental PIN gate is.
                    profileIdentityHeader

                    PlozziOSProfileSettingsSection(
                        profileName: appModel.profiles.activeProfile.name,
                        showsParentalControls: showsParentalControlsSection
                    ) { category in
                        Button {
                            selection = .profile(category)
                        } label: {
                            PlozziOSSettingsCategoryLabel(
                                category: category, accounts: appModel.accounts,
                                isAccountIncluded: { appModel.activeAccountIDs(
                                    for: appModel.profiles.activeProfileID
                                ).contains($0) }
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings-category-\(category.rawValue)")
                    } management: {
                        if showsParentalControlsSection {
                            settingsRow(
                                .profileAppearance,
                                title: KidsProfileCopy.nameAndAvatar,
                                systemImage: "person.crop.circle"
                            )
                        } else if appModel.profiles.activeProfile.isKids {
                            settingsRow(
                                .manageProfile,
                                title: KidsProfileCopy.manageProfile,
                                systemImage: "person.crop.circle"
                            )
                        }
                    }

                    // Real rows with real names; the grouping and the lock carry
                    // the meaning. Mirrors tvOS.
                    if showsParentalControlsSection {
                        SettingsSectionGroup(KidsProfileCopy.parentalControls) {
                            sealableRow(
                                .myLibraries,
                                title: SettingsCopy.libraries,
                                systemImage: "rectangle.stack"
                            )
                            sealableRow(
                                .manageProfile,
                                title: KidsProfileCopy.manageProfile,
                                systemImage: "person.crop.circle"
                            )
                        } footer: {
                            // See the tvOS twin: the lock says "sealed" already.
                            if !isParentalSealed {
                                Text(KidsProfileCopy.parentalControlsOpen)
                            }
                        }
                    }

                    // No household section on a Kids Profile. The card that used
                    // to explain its absence was a second "Kids Profile" heading
                    // that did nothing; once Parental Controls exists, a missing
                    // shared section needs no caption. See the tvOS twin.
                    if !appModel.profiles.activeProfile.isKids {
                        SettingsSectionGroup(deviceSettingsTitle) {
                            settingsRow(
                                .servers,
                                title: "Servers",
                                systemImage: "externaldrive.connected.to.line.below"
                            )
                            Button {
                                selection = .profiles
                            } label: {
                                Label("Profiles", systemImage: "person.2")
                                    .frame(
                                        maxWidth: .infinity,
                                        alignment: .leading
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            // Household-level, so it sits here rather than on a
                            // profile — one PIN for everyone, not a property of
                            // any one person. Matches tvOS.
                            settingsRow(
                                .parentalPIN,
                                title: KidsProfileCopy.parentalPIN,
                                systemImage: "figure.and.child.holdinghands"
                            )
                            settingsRow(
                                .requests,
                                verbatimTitle: "Seerr",
                                systemImage: "sparkles.tv"
                            )
                            settingsRow(
                                .syncSetup,
                                title: "iCloud Sync",
                                systemImage: "icloud"
                            )
                            settingsRow(
                                .metadata,
                                title: "Metadata Providers",
                                systemImage: "sparkles.rectangle.stack"
                            )
                            settingsRow(
                                .downloads,
                                title: "Downloads",
                                systemImage: "arrow.down.circle"
                            )
                        } footer: {
                            Text(everyoneScopeFooter)
                        }
                    }

                    PlozziOSSettingsVersionSection(isKidsProfile: appModel.profiles.activeProfile.isKids) {
                        settingsRow(.releaseNotes, title: "Release Notes", systemImage: "doc.text")
                    }
                    PlozziOSCommunitySettingsSection()
                    PlozziOSMoreAppsSettingsSection()

                    SettingsSectionGroup("Privacy") {
                        PrivacyPolicyLink()
                    }

                    SettingsSectionGroup("Support") {
                        settingsRow(.diagnostics, title: "Help & Diagnostics", systemImage: "ladybug")
                        settingsRow(.attributions, title: SettingsCopy.attributions, systemImage: "doc.text.magnifyingglass")
                        if !appModel.accounts.isEmpty, !appModel.profiles.activeProfile.isKids {
                            Button("Sign Out of All Accounts", role: .destructive) {
                                confirmSignOutAll = true
                            }
                        }
                    }
                    // Hidden until Developer Mode is unlocked (tap Version seven
                    // times). Gating on the runtime flag rather than
                    // `#if DEBUG` hides these in every build — including the
                    // Debug-config branded builds — while keeping them reachable.
                    if developerMode.isEnabled, !appModel.profiles.activeProfile.isKids {
                        SettingsSectionGroup("Developer") {
                            Button("Reset to First Run") {
                                appModel.resetToFirstRunForDebugging()
                                onClose()
                            }
                            Button("Turn Off Developer Mode", role: .destructive) {
                                developerMode.disable()
                            }
                        }
                        PlozziOSDeveloperInfoSection()
                    }
                }
            }
            .navigationTitle("")
            .modifier(PlozziOSSettingsSearch(
                appModel: appModel, isShowingDestination: selection?.isSearchResult == true
            ) { selection = .search($0.id) })
            .toolbar(removing: .sidebarToggle)
            .settingsPageSurface(titleDisplayMode: .inline, horizontalInset: 16)
        } detail: {
            NavigationStack {
                ZStack {
                    SettingsPageBackground()
                    Group {
                        settingsDetail
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .id(selection)
            .toolbar(removing: .sidebarToggle)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close", systemImage: "xmark", action: onClose)
                        .labelStyle(.iconOnly)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        // Switching profiles re-seals: an unlock proves who is standing there
        // now, not who was standing there for a different profile.
        .onChange(of: appModel.profiles.activeProfileID) { _, _ in
            isParentalUnlocked = false
            parentalUnlockTarget = nil
            selection = nil
        }
        // A PIN replaced on another device must invalidate an unlock proved
        // against the old one.
        .onChange(of: appModel.profiles.parentalPIN) { _, _ in
            isParentalUnlocked = false
            if showsParentalControlsSection {
                parentalUnlockTarget = nil
                selection = nil
            }
        }
        .toolbar(removing: .sidebarToggle)
        .toolbarBackground(.hidden, for: .navigationBar)
        .alert("Sign out of all accounts?", isPresented: $confirmSignOutAll) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {
                for account in appModel.accounts {
                    appModel.removeAccount(id: account.id)
                }
            }
        } message: {
            Text("This removes every server and network share from this device.")
        }
        .onChange(of: columnVisibility) { _, visibility in
            if visibility != .all {
                columnVisibility = .all
            }
        }
    }

    /// A Parental Controls row: goes to `destination`, or to the PIN prompt while
    /// sealed — remembering `destination` so the unlock lands there rather than
    /// dumping you back on the list to tap the same row again.
    private func sealableRow(
        _ destination: PlozziOSSettingsDestination,
        title: LocalizedStringResource,
        systemImage: String
    ) -> some View {
        Button {
            if isParentalSealed {
                parentalUnlockTarget = destination
                selection = .grownUps
            } else {
                selection = destination
            }
        } label: {
            if destination == .myLibraries {
                PlozziOSSettingsCategoryLabel(
                    category: .libraries, accounts: appModel.accounts,
                    isAccountIncluded: { appModel.activeAccountIDs(
                        for: appModel.profiles.activeProfileID
                    ).contains($0) },
                    isSealed: isParentalSealed
                )
            } else {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: isParentalSealed ? "lock.fill" : systemImage)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }

    private func settingsRow(
        _ destination: PlozziOSSettingsDestination,
        title: LocalizedStringResource,
        systemImage: String
    ) -> some View {
        settingsRow(destination, label: Text(title), systemImage: systemImage)
    }

    /// A row labelled with a BRAND name (e.g. "Seerr"). Brands are never
    /// translated, so this spelling keeps them out of the String Catalog.
    private func settingsRow(
        _ destination: PlozziOSSettingsDestination,
        verbatimTitle: String,
        systemImage: String
    ) -> some View {
        settingsRow(destination, label: Text(verbatim: verbatimTitle), systemImage: systemImage)
    }

    private func settingsRow(
        _ destination: PlozziOSSettingsDestination,
        label title: Text,
        systemImage: String
    ) -> some View {
        Button {
            selection = destination
        } label: {
            Label { title } icon: { Image(systemName: systemImage) }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var settingsDetail: some View {
        // The default must also be safe for Kids, not just the visible sidebar rows.
        switch selection ?? .profile(.playback) {
        case .search(let id):
            if let entry = SettingsSearchCatalog.entry(id: id) {
                PlozziOSSettingsSearchDestination(
                    entry: entry, appModel: appModel, onAddServer: onAddServer, onAddUser: onAddUser,
                    onFinish: { selection = .profile(.playback) }
                )
            }
        case .profiles:
            PlozziOSProfilesView(appModel: appModel, onClose: onClose, onSwitchTo: onSwitchTo)
        case .requests:
            PlozziOSSeerrSettingsView(appModel: appModel)
        case .servers:
            PlozziOSServersSettingsView(
                appModel: appModel,
                onAddServer: onAddServer
            )
        case .grownUps:
            PlozziOSGrownUpsUnlockView(appModel: appModel) {
                isParentalUnlocked = true
                // Carry on into the row that was tapped. Without this the pane
                // would keep showing the PIN screen it just accepted.
                selection = parentalUnlockTarget ?? .myLibraries
                parentalUnlockTarget = nil
            }
        case .parentalPIN:
            PlozziOSParentalPINSettingsView(appModel: appModel)
        case .profileAppearance:
            PlozziOSProfileEditorHost(
                appModel: appModel,
                editingProfile: appModel.profiles.activeProfile,
                canDelete: false,
                onFinished: { selection = nil }
            )
        case .manageProfile:
            PlozziOSProfileSettingsView(
                appModel: appModel,
                profileID: appModel.profiles.activeProfileID,
                isParentalUnlocked: isParentalUnlocked
            )
        case .myLibraries:
            PlozziOSMyLibrariesSettingsView(
                appModel: appModel,
                onAddServer: onAddServer,
                onAddUser: onAddUser
            )
        case .profile(let category):
            PlozziOSProfileSettingsPage(
                category: category, appModel: appModel, onAddServer: onAddServer,
                onAddUser: onAddUser, canManageProviders: !isParentalSealed,
                isPresented: selection == .profile(category)
            )
        case .downloads:
            PlozziOSDownloadSettingsView(model: appModel.downloads)
        case .syncSetup:
            PlozziOSSyncSetupSettingsView(appModel: appModel)
        case .metadata:
            PlozziOSMetadataSettingsView(appModel: appModel, deps: appModel.makeMetadataSettingsDependencies())
        case .diagnostics:
            PlozziOSDiagnosticsSettingsView(
                appModel: appModel,
                model: appModel.settings.diagnostics,
                crashReporting: appModel.crashReporting
            )
        case .attributions:
            PlozziOSAttributionsView()
        case .releaseNotes:
            ReleaseNotesSettingsView(model: .shared)
        }
    }
}

struct PlozziOSMoreAppsSettingsSection: View {
    var body: some View {
        SettingsSectionGroup("More apps") {
            Link(destination: AppLinks.mozzTestFlight) {
                HStack(spacing: 16) {
                    Image("MozzAppIcon")
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: "Mozz")
                            .font(.body.weight(.medium))
                        Text("Free, open-source music player")
                            .font(.footnote)
                            .plozzForeground(.secondary)
                        Text("TestFlight public beta")
                            .font(.footnote)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.up.forward")
                        .font(.subheadline.weight(.semibold))
                        .plozzForeground(.secondary)
                        .accessibilityHidden(true)
                }
                .multilineTextAlignment(.leading)
            }
            .accessibilityHint(Text("Opens TestFlight."))
            .accessibilityIdentifier("settings-mozz-beta")
        }
    }
}

struct PlozziOSCommunitySettingsSection: View {
    @ScaledMetric(relativeTo: .body) private var iconSize = 22

    var body: some View {
        SettingsSectionGroup("Community") {
            communityLink(
                Text(verbatim: "Discord"), icon: "DiscordMark",
                url: AppLinks.discord
            )
            communityLink(
                Text(verbatim: "GitHub"), icon: "GitHubMark",
                url: AppLinks.repository
            )
        }
    }

    private func communityLink(
        _ title: Text, icon: String, url: URL
    ) -> some View {
        Link(destination: url) {
            HStack(spacing: 16) {
                Label {
                    title
                } icon: {
                    Image(icon)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: iconSize, height: iconSize)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.forward")
                    .font(.subheadline.weight(.semibold))
                    .plozzForeground(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(title)
    }
}

private struct PlozziOSSettingsVersionSection<ReleaseLink: View>: View {
    let isKidsProfile: Bool
    @ViewBuilder let releaseLink: () -> ReleaseLink
    @State private var showDeveloperUnlockedAlert = false

    var body: some View {
        SettingsSectionGroup(verbatim: "Plozz") {
            LabeledContent("Version") {
                Text(AppVersionIdentity.current.displayVersion)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // Developer reset can remove parental restrictions, so Kids must never unlock it.
                guard !isKidsProfile else { return }
                if case .justEnabled = DeveloperModeModel.shared.registerUnlockActivation() {
                    showDeveloperUnlockedAlert = true
                }
            }
            LabeledContent("Build") {
                Text(AppVersionIdentity.current.displayBuild)
            }
            if ReleaseNotesModel.shared.isAvailable { releaseLink() }
        }
        .alert("Developer Mode Enabled", isPresented: $showDeveloperUnlockedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Diagnostic tools are now shown in Settings under Developer. Turn them off again from that section.")
        }
    }
}

/// Read-only "Device & Build" facts shown under Developer Mode: which build is
/// installed (canonical vs a `--branded` side-by-side app), release channel, and
/// whether the App Group / crash endpoint are present. A Copy button dumps it all
/// as text for a bug report.
private struct PlozziOSDeveloperInfoSection: View {
    var body: some View {
        SettingsSectionGroup("Device & Build") {
            ForEach(DeveloperInfo.snapshot()) { item in
                LabeledContent(item.label, value: item.value)
            }
            LabeledContent("OS", value: ProcessInfo.processInfo.operatingSystemVersionString)
            Button {
                UIPasteboard.general.string = DeveloperInfo.copyText(
                    DeveloperInfo.snapshot(),
                    extra: [DeveloperInfoItem(
                        id: "os",
                        label: "OS",
                        value: ProcessInfo.processInfo.operatingSystemVersionString
                    )]
                )
            } label: {
                Label("Copy Info", systemImage: "doc.on.doc")
            }
        }
    }
}

private struct PlozziOSSettingsCompactMenu: View {
    let appModel: PlozziOSAppModel
    let onAddServer: () -> Void
    var onAddUser: (MediaServer) -> Void = { _ in }
    var onSwitchProfile: () -> Void = {}
    /// Requests a profile switch once Settings is actually gone.
    ///
    /// The gates a switch can raise are covers on the ROOT; asking for one from
    /// under this sheet is the arrangement SwiftUI drops, and because the gate's
    /// binding stays true it is never re-requested — switching would wedge until
    /// relaunch. So the row hands the id up and the shell applies it in the
    /// sheet's `onDismiss`.
    var onSwitchTo: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var confirmSignOutAll = false
    @State private var showMetadata = false
    @State private var searchSelection: SettingsSearchEntry?
    @State private var isHeaderCollapsed = false
    @State private var expandedTitleHeight: CGFloat = 0
    private var developerMode: DeveloperModeModel { .shared }
    /// Whether the Parental PIN has been entered for the Kids Profile currently
    /// open. View state, cleared when the profile changes.
    @State private var isParentalUnlocked = false

    /// Whether this profile shows a separate parent-controlled group. Only a
    /// Kids Profile does, and only once a Parental PIN exists.
    private var showsParentalControlsSection: Bool {
        appModel.profiles.activeProfile.isKids
            && appModel.profiles.parentalPIN != nil
    }

    private var isParentalSealed: Bool {
        showsParentalControlsSection && !isParentalUnlocked
    }

    private var profileIdentityHeader: some View {
        SettingsSectionGroup {
            PlozziOSProfileIdentityHeader(
                appModel: appModel,
                onSwitchProfile: onSwitchProfile
            )
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("Settings")
                    .font(.largeTitle.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("settings-expanded-title")
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        expandedTitleHeight = height
                    }

                // Live media-share scan/enrich progress. Renders nothing when idle.
                ShareScanStatusHeader(
                    status: appModel.shareScanStatus,
                    shareIDs: appModel.mediaShareAccountIDs
                )

                profileIdentityHeader

                PlozziOSProfileSettingsSection(
                    profileName: appModel.profiles.activeProfile.name,
                    showsParentalControls: showsParentalControlsSection
                ) { category in
                    NavigationLink {
                        PlozziOSProfileSettingsPage(
                            category: category, appModel: appModel, onAddServer: onAddServer,
                            onAddUser: onAddUser, canManageProviders: !isParentalSealed
                        )
                    } label: {
                        PlozziOSSettingsCategoryLabel(
                            category: category, accounts: appModel.accounts,
                            isAccountIncluded: { appModel.activeAccountIDs(
                                for: appModel.profiles.activeProfileID
                            ).contains($0) }
                        )
                    }
                    .accessibilityIdentifier("settings-category-\(category.rawValue)")
                } management: {
                    if showsParentalControlsSection {
                        NavigationLink {
                            PlozziOSProfileAppearancePage(
                                appModel: appModel,
                                profileID: appModel.profiles.activeProfileID
                            )
                        } label: {
                            Label(KidsProfileCopy.nameAndAvatar, systemImage: "person.crop.circle")
                        }
                    } else if appModel.profiles.activeProfile.isKids {
                        NavigationLink {
                            PlozziOSProfileSettingsView(
                                appModel: appModel,
                                profileID: appModel.profiles.activeProfileID
                            )
                        } label: {
                            Label(KidsProfileCopy.manageProfile, systemImage: "person.crop.circle")
                        }
                    }
                }

                // Real rows with real names; the grouping and the lock carry the
                // meaning. Mirrors the split view and tvOS.
                if showsParentalControlsSection {
                    SettingsSectionGroup(KidsProfileCopy.parentalControls) {
                        // Stable rows; the GATE is inside the destination. Swapping
                        // the link on `isParentalSealed` made a correct PIN delete
                        // the page the user was standing on.
                        NavigationLink {
                            PlozziOSParentalGate(
                                appModel: appModel,
                                isSealed: isParentalSealed,
                                onUnlock: { isParentalUnlocked = true }
                            ) {
                                PlozziOSMyLibrariesSettingsView(
                                    appModel: appModel,
                                    onAddServer: onAddServer,
                                    onAddUser: onAddUser
                                )
                            }
                        } label: {
                            PlozziOSSettingsCategoryLabel(
                                category: .libraries, accounts: appModel.accounts,
                                isAccountIncluded: { appModel.activeAccountIDs(
                                    for: appModel.profiles.activeProfileID
                                ).contains($0) },
                                isSealed: isParentalSealed
                            )
                        }
                        NavigationLink {
                            PlozziOSParentalGate(
                                appModel: appModel,
                                isSealed: isParentalSealed,
                                onUnlock: { isParentalUnlocked = true }
                            ) {
                                PlozziOSProfileSettingsView(
                                    appModel: appModel,
                                    profileID: appModel.profiles.activeProfileID,
                                    isParentalUnlocked: isParentalUnlocked
                                )
                            }
                        } label: {
                            Label(
                                KidsProfileCopy.manageProfile,
                                systemImage: isParentalSealed ? "lock.fill" : "person.crop.circle"
                            )
                        }
                    } footer: {
                        if !isParentalSealed {
                            Text(KidsProfileCopy.parentalControlsOpen)
                        }
                    }
                }

                // Withheld on a Kids Profile: every destructive control in the app
                // lives in here (remove server, delete profile, sign out of
                // everything).
                if !appModel.profiles.activeProfile.isKids {
                    SettingsSectionGroup(deviceSettingsTitle) {
                        NavigationLink {
                            PlozziOSServersSettingsView(
                                appModel: appModel,
                                onAddServer: onAddServer
                            )
                        } label: {
                            Label("Servers", systemImage: "externaldrive.connected.to.line.below")
                        }
                        NavigationLink {
                            PlozziOSProfilesView(
                                appModel: appModel,
                                onClose: { dismiss() },
                                onSwitchTo: onSwitchTo
                            )
                        } label: {
                            Label("Profiles", systemImage: "person.2")
                        }
                        // Household-level, so it sits here rather than on a profile.
                        NavigationLink {
                            PlozziOSParentalPINSettingsView(appModel: appModel)
                        } label: {
                            Label(
                                KidsProfileCopy.parentalPIN,
                                systemImage: "figure.and.child.holdinghands"
                            )
                        }

                        NavigationLink {
                            PlozziOSSeerrSettingsView(appModel: appModel)
                        } label: {
                            Label {
                                Text(verbatim: "Seerr")
                            } icon: {
                                Image(systemName: "sparkles.tv")
                            }
                        }

                        NavigationLink {
                            PlozziOSSyncSetupSettingsView(appModel: appModel)
                        } label: {
                            Label("iCloud Sync", systemImage: "icloud")
                        }
                        // This link needs an explicit destination to keep neighboring actions independent.
                        Button {
                            showMetadata = true
                        } label: {
                            Label("Metadata Providers", systemImage: "sparkles.rectangle.stack")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        NavigationLink {
                            PlozziOSDownloadSettingsView(model: appModel.downloads)
                        } label: {
                            Label("Downloads", systemImage: "arrow.down.circle")
                        }
                    } footer: {
                        Text(everyoneScopeFooter)
                    }
                }

                PlozziOSSettingsVersionSection(isKidsProfile: appModel.profiles.activeProfile.isKids) {
                    NavigationLink {
                        ReleaseNotesSettingsView(model: .shared)
                    } label: {
                        Label("Release Notes", systemImage: "doc.text")
                    }
                }
                PlozziOSCommunitySettingsSection()
                PlozziOSMoreAppsSettingsSection()

                SettingsSectionGroup("Privacy") {
                    PrivacyPolicyLink()
                }

                SettingsSectionGroup("Support") {
                    NavigationLink {
                        PlozziOSDiagnosticsSettingsView(
                            appModel: appModel,
                            model: appModel.settings.diagnostics,
                            crashReporting: appModel.crashReporting
                        )
                    } label: {
                        Label("Help & Diagnostics", systemImage: "ladybug")
                    }
                    NavigationLink {
                        PlozziOSAttributionsView()
                    } label: {
                        Label(SettingsCopy.attributions, systemImage: "doc.text.magnifyingglass")
                    }
                    if !appModel.accounts.isEmpty, !appModel.profiles.activeProfile.isKids {
                        Button("Sign Out of All Accounts", role: .destructive) {
                            confirmSignOutAll = true
                        }
                    }
                }

                // Hidden until Developer Mode is unlocked (tap Version seven
                // times). Gated on the runtime flag in every build.
                if developerMode.isEnabled, !appModel.profiles.activeProfile.isKids {
                    SettingsSectionGroup("Developer") {
                        Button("Reset to First Run") {
                            appModel.resetToFirstRunForDebugging()
                            dismiss()
                        }
                        Button("Turn Off Developer Mode", role: .destructive) {
                            developerMode.disable()
                        }
                    }
                    PlozziOSDeveloperInfoSection()
                }

                if let accountError = appModel.accountError {
                    SettingsSectionGroup {
                        Label(accountError, systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .contentMargins(.top, 8, for: .scrollContent)
        .settingsPageSurface(
            titleDisplayMode: .inline,
            horizontalInset: 16
        )
        .navigationTitle(isHeaderCollapsed ? "Settings" : "")
        .modifier(PlozziOSSettingsSearch(
            appModel: appModel, isShowingDestination: searchSelection != nil
        ) { searchSelection = $0 })
        .navigationDestination(item: $searchSelection) { entry in
            PlozziOSSettingsSearchDestination(
                entry: entry, appModel: appModel, onAddServer: onAddServer, onAddUser: onAddUser,
                onFinish: { searchSelection = nil }
            )
        }
        .onChange(of: appModel.profiles.activeProfileID) { _, _ in searchSelection = nil }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > expandedTitleHeight
        } action: { _, collapsed in
            isHeaderCollapsed = collapsed
        }
        .onChange(of: appModel.profiles.activeProfileID) { _, _ in isParentalUnlocked = false }
        .onChange(of: appModel.profiles.parentalPIN) { _, _ in isParentalUnlocked = false }
        .navigationDestination(isPresented: $showMetadata) {
            PlozziOSMetadataSettingsView(appModel: appModel, deps: appModel.makeMetadataSettingsDependencies())
        }
        .alert("Sign out of all accounts?", isPresented: $confirmSignOutAll) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {
                for account in appModel.accounts {
                    appModel.removeAccount(id: account.id)
                }
            }
        } message: {
            Text("This removes every server and network share from this device.")
        }
    }
}

private struct PlozziOSSettingsSearch: ViewModifier {
    let appModel: PlozziOSAppModel
    var isShowingDestination = false
    let onSelect: (SettingsSearchEntry) -> Void
    @State private var query = ""
    @State private var isPresented = false
    @FocusState private var isFocused: Bool

    private var showsResults: Bool { isPresented || !query.isEmpty }

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26.0, *), UIDevice.current.userInterfaceIdiom == .phone {
                searchableContent(content)
                    .toolbar { DefaultToolbarItem(kind: .search, placement: .bottomBar) }
            } else {
                searchableContent(content)
            }
        }
        .onChange(of: appModel.profiles.activeProfileID) { _, _ in
            query = ""
            isPresented = false
            isFocused = false
        }
        .onChange(of: isShowingDestination) { wasShowing, isShowing in
            if wasShowing && !isShowing && !query.isEmpty {
                isPresented = true
                isFocused = true
            }
        }
    }

    @ViewBuilder private func searchableContent(_ content: Content) -> some View {
        let searchable = content
            .opacity(showsResults ? 0 : 1)
            .allowsHitTesting(!showsResults)
            .accessibilityHidden(showsResults)
            .overlay {
                if showsResults {
                    SettingsSearchResults(
                        query: query,
                        platform: UIDevice.current.userInterfaceIdiom == .phone ? .phone : .tablet,
                        isKids: appModel.profiles.activeProfile.isKids
                    ) { entry, _ in
                        isFocused = false
                        onSelect(entry)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .simultaneousGesture(TapGesture().onEnded { isFocused = false })
                    .background { SettingsPageBackground() }
                }
            }
            .searchable(
                text: $query, isPresented: $isPresented,
                placement: UIDevice.current.userInterfaceIdiom == .phone
                    ? .automatic : .navigationBarDrawer(displayMode: .always),
                prompt: "Search settings"
            )
        searchable.searchFocused($isFocused)
    }
}

private struct PlozziOSSettingsSearchDestination: View {
    let entry: SettingsSearchEntry
    let appModel: PlozziOSAppModel
    let onAddServer: () -> Void
    let onAddUser: (MediaServer) -> Void
    let onFinish: () -> Void
    @State private var unlockedProfileID: String?
    @State private var showsParentalUnlock = false
    @State private var showsCustomQuality = false

    private var isParentalUnlocked: Bool {
        unlockedProfileID == appModel.profiles.activeProfileID
    }

    private var needsSeparateSubtitleStyle: Bool {
        entry.page == .liveSubtitleStyle && !appModel.settings.subtitleStyle.usesSeparateLiveTVStyle
    }

    private var targetID: String {
        needsSeparateSubtitleStyle ? "live-subtitle-style" : entry.anchorID
    }

    var body: some View {
        Group {
            if entry.isAvailable(
                on: UIDevice.current.userInterfaceIdiom == .phone ? .phone : .tablet,
                isKids: appModel.profiles.activeProfile.isKids
            ) {
                if entry.page.requiresParentalAuthorization, appModel.managementRequiresParentalPIN, !isParentalUnlocked {
                    authorizationPrompt
                } else {
                    SettingsSearchLanding(targetID: targetID) { destination }
                        .id("\(appModel.profiles.activeProfileID)-\(entry.id)-\(targetID)")
                }
            } else {
                ContentUnavailableView("Setting unavailable", systemImage: "magnifyingglass")
            }
        }
        .plozzSheet(isPresented: $showsParentalUnlock) {
            PlozziOSGrownUpsUnlockView(appModel: appModel) {
                unlockedProfileID = appModel.profiles.activeProfileID
            }
        }
        .onChange(of: appModel.profiles.activeProfileID) { _, _ in
            unlockedProfileID = nil
            showsParentalUnlock = false
            showsCustomQuality = false
        }
        .onChange(of: appModel.profiles.parentalPIN) { _, _ in
            unlockedProfileID = nil
            showsParentalUnlock = false
        }
    }

    private var authorizationPrompt: some View {
        List {
            Button { showsParentalUnlock = true } label: { Text(KidsProfileCopy.parentalPIN) }
        }
        .settingsPageSurface()
        .navigationTitle(Text(KidsProfileCopy.parentalPIN))
        .task { showsParentalUnlock = true }
    }

    @ViewBuilder private var destination: some View {
        switch entry.destinationPage(on: UIDevice.current.userInterfaceIdiom == .phone ? .phone : .tablet) {
        case .playback: profilePage(.playback)
        case .playbackAdvanced:
            PlaybackAdvancedSettingsView(playback: appModel.settings.playback)
        case .streamingAdvanced:
            if appModel.accountsProviders.resolvedActiveAccounts.contains(where: {
                $0.provider is any StreamingQualityProviding
            }) {
                @Bindable var playback = appModel.settings.playback
                if let network = entry.qualityNetwork {
                    profilePage(.playback)
                        .plozzSheet(isPresented: $showsCustomQuality, onDismiss: onFinish) {
                            StreamingCustomQualityEditor(
                                quality: playback.settings.streaming[keyPath: network.keyPath],
                                support: appModel.streamingQualitySupport
                            ) { playback.settings.streaming[keyPath: network.keyPath] = $0 }
                        }
                        .task { showsCustomQuality = true }
                } else {
                    PlozziOSAdvancedStreamingSettings(
                        settings: $playback.settings.streaming, support: appModel.streamingQualitySupport
                    )
                }
            } else {
                profilePage(.playback)
            }
        case .externalPlayer:
            ExternalPlayerSettingsView(custom: entry.id == "external-template")
        case .skipMarkers:
            SkipMarkerSettingsView(
                model: appModel.settings.playback, initialKind: entry.skipKind, initialCategory: entry.contentCategory
            )
        case .subtitles:
            if entry.id == "subtitle-remember" { profilePage(.playback) }
            else { profilePage(.subtitles) }
        case .subtitleStyle:
            @Bindable var style = appModel.settings.subtitleStyle
            SubtitleStyleSettingsView(style: $style.style, initialPage: entry.subtitlePage)
        case .liveSubtitleStyle:
            if needsSeparateSubtitleStyle {
                profilePage(.subtitles)
            } else {
                @Bindable var style = appModel.settings.subtitleStyle
                SubtitleStyleSettingsView(
                    style: $style.resolvedLiveTVStyle, isLiveTV: true, initialPage: entry.subtitlePage
                )
            }
        case .theme:
            PlozziOSThemeSettingsView(theme: appModel.settings.theme, transparency: appModel.settings.transparency)
        case .cards:
            CardAppearanceControls(
                cards: appModel.settings.cardStyle, watchIndicator: appModel.settings.watchIndicator,
                density: appModel.settings.density, visibility: appModel.settings.homeVisibility
            )
            .environment(appModel.settings.hero)
        case .cardLabels:
            CardCaptionCustomizationView(
                cards: appModel.settings.cardStyle, visibility: appModel.settings.homeVisibility,
                initialView: entry.cardCaptionView
            )
            .environment(appModel.settings.hero)
        case .artwork:
            if entry.anchorID.hasPrefix("artwork-view-") {
                ArtworkCustomizationView(
                    cards: appModel.settings.cardStyle,
                    continueWatchingShowsSeriesArtwork: appModel.settings.homeVisibility.continueWatchingShowsSeriesArtwork,
                    continueWatchingLayout: appModel.settings.homeVisibility.continueWatchingLayout
                )
                .environment(appModel.settings.hero)
            } else {
            PlozziOSArtworkSettingsView(
                appModel: appModel, cardStyle: appModel.settings.cardStyle,
                canManageProviders: !appModel.managementRequiresParentalPIN || isParentalUnlocked
            )
            }
        case .circadian: PlozziOSNightShiftSettingsView(model: appModel.settings.nightShift)
        case .allScreens:
            PlozziOSAllScreensSettingsView(
                contentRatings: appModel.settings.contentRatings, spoilers: appModel.settings.spoilers
            )
        case .navigation: PlozziOSNavigationSettingsView(appModel: appModel)
        case .home, .hero, .heroContent, .heroRatings, .heroTrailers, .heroDiscovery,
             .heroLibraries, .heroCollections, .homeRows, .homeFiltering, .homeLabels, .continueWatching:
            PlozziOSHomeSettingsView(
                hero: appModel.settings.hero, heroBackground: appModel.settings.heroBackground,
                cards: appModel.settings.cardStyle, visibility: appModel.settings.homeVisibility,
                accounts: appModel.accountsProviders.resolvedActiveAccounts,
                spoilerSettings: appModel.settings.spoilers.settings,
                searchPage: entry.page
            )
        case .detail:
            PlozziOSDetailPageSettingsView(
                cards: appModel.settings.cardStyle, heroBackground: appModel.settings.heroBackground,
                themeMusic: appModel.settings.themeMusic, detailPage: appModel.settings.detailPage
            )
        case .detailRatingSources:
            PlozziOSDetailRatingPriorityView(model: appModel.settings.detailPage)
        case .libraries:
            LibraryPresentationSettingsView(
                model: appModel.settings.libraryPresentation, cards: appModel.settings.cardStyle,
                visibility: appModel.settings.homeVisibility,
                accounts: appModel.accountsProviders.resolvedActiveAccounts,
                loader: LibraryPresentationLoader(
                    settings: appModel.settings.libraryPresentation, namespace: appModel.profiles.activeNamespace
                )
            )
            .id(ObjectIdentifier(appModel.settings.libraryPresentation))
        case .liveTV, .liveTVSources, .liveTVGuide, .liveTVVisibility: profilePage(.liveTV)
        case .language: profilePage(.language)
        case .trackers: profilePage(.trackers)
        case .downloads: PlozziOSDownloadSettingsView(model: appModel.downloads)
        case .profiles:
            List {
                SettingsSectionGroup {
                    AutomaticSignInToggle(settings: appModel.automaticSignInSettings)
                } footer: {
                    AutomaticSignInErrorMessage(settings: appModel.automaticSignInSettings)
                }
            }
            .settingsPageSurface()
            .navigationTitle("Profiles")
        case .profileAppearance:
            PlozziOSProfileAppearancePage(appModel: appModel, profileID: appModel.profiles.activeProfileID)
        case .profileSettings:
            PlozziOSProfileSettingsView(
                appModel: appModel, profileID: appModel.profiles.activeProfileID,
                isParentalUnlocked: isParentalUnlocked
            )
        case .accountLibraries: profilePage(.libraries)
        case .seerr: PlozziOSSeerrSettingsView(appModel: appModel)
        case .sync: PlozziOSSyncSetupSettingsView(appModel: appModel)
        case .metadata:
            PlozziOSMetadataSettingsView(appModel: appModel, deps: appModel.makeMetadataSettingsDependencies())
        case .metadataDiagnostics:
            PlozziOSMetadataDiagnosticsView(deps: appModel.makeMetadataSettingsDependencies())
        case .diagnostics:
            PlozziOSDiagnosticsSettingsView(
                appModel: appModel, model: appModel.settings.diagnostics, crashReporting: appModel.crashReporting
            )
        case .musicPlayer, .topShelf:
            ContentUnavailableView("Setting unavailable", systemImage: "magnifyingglass")
        case .releaseNotes:
            ReleaseNotesSettingsView(model: .shared)
        }
    }

    private func profilePage(_ category: ProfileSettingsCategory) -> some View {
        PlozziOSProfileSettingsPage(
            category: category, appModel: appModel, onAddServer: onAddServer, onAddUser: onAddUser,
            canManageProviders: !appModel.managementRequiresParentalPIN || isParentalUnlocked,
            searchPage: entry.page
        )
    }
}

private extension PlozziOSAppModel {
    var automaticSignInSettings: AutomaticSignInSettings {
        AutomaticSignInSettings(
            isEnabled: Binding(
                get: { self.plexHomeUsers.automaticallySignIn },
                set: { self.setAutomaticallySignIn($0) }
            ),
            error: plexHomeUsers.automaticSignInError
        )
    }
}

private struct PlozziOSProfilesView: View {
    @Environment(\.themePalette) private var palette
    let appModel: PlozziOSAppModel
    @State private var showingAddProfile = false
    @State private var editingProfile: Profile?
    @State private var selectedProfileRoute: PlozziOSProfileSettingsRoute?
    /// Closes Settings, so a switch can raise its gates from the root.
    var onClose: () -> Void = {}
    /// Hands a requested switch to the shell, applied once Settings is gone.
    var onSwitchTo: (String) -> Void = { _ in }
    /// Whether this list is editing profiles rather than switching between them.
    ///
    /// One screen for both, like the tvOS picker: the rows are the same rows, so
    /// sending editing to its own page duplicated the list and cost a tap. The
    /// toggle is a full-size ROW at the bottom rather than a control in the
    /// section header — that header is footnote-sized uppercase, so anything in
    /// it is tiny by construction.
    @State private var isEditingProfiles = false

    private var orderedProfiles: [Profile] { appModel.profiles.profilesByRecency }

    private var automaticSignIn: AutomaticSignInSettings {
        appModel.automaticSignInSettings
    }

    /// One optional route owned by this page. A row cannot activate another
    /// row's destination, and there is no per-row NavigationLink state for
    /// SwiftUI's split-view reconciliation to accidentally stack.
    private func openSettings(for profile: Profile) {
        selectedProfileRoute = PlozziOSProfileSettingsRoute(profileID: profile.id)
    }

    var body: some View {
        List {
            SettingsSectionGroup {
                AutomaticSignInToggle(settings: automaticSignIn)
            } footer: {
                AutomaticSignInErrorMessage(settings: automaticSignIn)
            }
            SettingsSectionGroup(isEditingProfiles ? "Edit Profiles" : "Who’s watching?") {
                // Tapping a row switches; in editing mode it opens that
                // profile's settings instead. Long-press does the same without
                // leaving switching mode — the iOS Home screen pairing, and the
                // touch answer to tvOS's "you can't put a button on a focused
                // tile".
                ForEach(orderedProfiles) { profile in
                    Button {
                        if isEditingProfiles {
                            openSettings(for: profile)
                        } else {
                            guard profile.id != appModel.profiles.activeProfileID else { return }
                            // Requested, not performed here. The Parental PIN and
                            // profile lock gates are covers on the ROOT, and one
                            // asked for from under this sheet is the arrangement
                            // SwiftUI drops — silently, and with the gate's
                            // binding left true so it is never re-requested. The
                            // shell applies this in the sheet's `onDismiss`.
                            onSwitchTo(profile.id)
                            onClose()
                        }
                    } label: {
                        HStack {
                            PlozziOSProfileAvatar(
                                profile: profile,
                                size: 34
                            )
                            Text(profile.name)
                            Spacer()
                            // Glance the access state so the list answers
                            // "who's locked?" without opening each one.
                            if profile.isKids {
                                Image(systemName: "figure.and.child.holdinghands")
                                    .plozzForeground(.secondary)
                            }
                            if profile.isLocked {
                                Image(systemName: "lock.fill")
                                    .plozzForeground(.secondary)
                            }
                            if isEditingProfiles {
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .plozzForeground(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Deliberately no swipe-to-delete or context-menu delete.
                    // Both called `removeProfile` directly, which skipped the
                    // target profile's own PIN and its confirmation — so a locked
                    // profile could be deleted from the outside without ever
                    // opening it. Deletion lives on the profile's own page, where
                    // `ProfileActionsList` seals it behind that lock, exactly as
                    // tvOS does.
                    .contextMenu {
                        Button("Edit Profile", systemImage: "pencil") {
                            openSettings(for: profile)
                        }
                    }
                }
                Button("Add Profile", systemImage: "person.badge.plus") {
                    showingAddProfile = true
                }
                // Full-size row, so the control is as prominent as what it acts
                // on. Long-press already reaches editing; this is the version
                // someone can find without knowing to try.
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isEditingProfiles.toggle() }
                } label: {
                    Label(
                        isEditingProfiles ? "Done Editing" : "Edit Profiles",
                        systemImage: isEditingProfiles ? "checkmark.circle" : "pencil"
                    )
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle("Profiles")
        // One typed value, one push. Closure-based destinations inside this
        // ForEach were all being activated by the containing split/stack,
        // producing a back-stack containing every profile in list order.
        .navigationDestination(item: $selectedProfileRoute) { route in
            PlozziOSProfileSettingsView(
                appModel: appModel,
                profileID: route.profileID
            )
        }
        .plozzSheet(isPresented: $showingAddProfile) {
            NavigationStack {
                PlozziOSProfileEditorHost(
                    appModel: appModel,
                    onFinished: { showingAddProfile = false }
                )
            }
        }
        .plozzSheet(item: $editingProfile) { profile in
            NavigationStack {
                PlozziOSProfileEditorHost(
                    appModel: appModel,
                    editingProfile: profile,
                    canDelete: appModel.profiles.profiles.count > 1,
                    onFinished: { editingProfile = nil }
                )
            }
        }
        // New-profile setup. A profile is created holding EVERY server, so this
        // runs before its first watchlist import and asks which servers it
        // actually uses and who it watches as on each — otherwise the household's
        // aggregate watchlist lands in a brand new (often child) profile. See
        // `PlozziOSAppModel.ProfileOnboardingStep`.
        //
        // Presented from this page, which is the one that presents Add Profile:
        // a cover asked for from the root would be blocked by the Settings sheet
        // this page lives inside and silently never appear.
        //
        // ONE cover for the whole sequence, switching its content, rather than a
        // cover per step: presenting on `item` would tear the cover down and put
        // a new one up on every step, and SwiftUI drops a presentation requested
        // while another is still dismissing — which is exactly how the theme step
        // went missing before.
        .plozzFullScreenCover(isPresented: Binding(
            get: { appModel.isPresentingProfileOnboarding(from: .settings) },
            set: { if !$0 { appModel.cancelProfileOnboarding() } }
        )) {
            PlozziOSProfileOnboardingCover(appModel: appModel)
        }
    }
}

/// Identifies which profile a management page should open.
struct PlozziOSProfileSettingsRoute: Hashable {
    let profileID: String
}

struct PlozziOSAccountDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedProviderSetupRouter) private var providerSetupRouter

    let appModel: PlozziOSAppModel
    let account: Account
    @State private var confirmRemoval = false
    @State private var confirmEverywhere = false

    private var offerEverywhere: Bool { appModel.offersRemoveEverywhere }

    var body: some View {
        List {
            SettingsSectionGroup("Account") {
                LabeledContent("Provider", value: account.server.provider.displayName)
                if !account.userName.isEmpty {
                    LabeledContent("User", value: account.userName)
                }
                LabeledContent("Server", value: account.server.name)
                LabeledContent("Address", value: account.server.baseURL.absoluteString)
            }

            if account.server.provider == .plex {
                SettingsSectionGroup("Plex Home") {
                    NavigationLink {
                        PlozziOSPlexHomeUserSettingsView(
                            appModel: appModel,
                            account: account
                        )
                    } label: {
                        Label("Plex User", systemImage: "person.crop.circle")
                    }
                }
            }

            if account.server.provider == .mediaShare {
                PlozziOSShareScanSection(
                    state: appModel.shareScanStatus.state(
                        forShareID: account.id
                    ),
                    onScan: {
                        appModel.rescanShare(accountID: account.id)
                    }
                )
            }

            SettingsSectionGroup {
                if account.server.provider.supportsAccountReauthentication, let providerSetupRouter {
                    Button("Sign In Again", systemImage: "arrow.clockwise") {
                        providerSetupRouter.reauthenticationAccount = account
                    }
                }
                Button("Remove Server", role: .destructive) {
                    confirmRemoval = true
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle(account.server.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Remove \(account.server.name)?",
            isPresented: $confirmRemoval,
            titleVisibility: .visible
        ) {
            if offerEverywhere {
                Button("Remove Everywhere", role: .destructive) { confirmEverywhere = true }
                Button("Remove from This \(deviceName)", role: .destructive) {
                    appModel.removeAccount(id: account.id)
                    dismiss()
                }
            } else {
                Button("Remove", role: .destructive) {
                    appModel.removeAccount(id: account.id)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(offerEverywhere
                 ? "Remove it from all your devices, or just this \(deviceName)?"
                 : "Signs out and removes this server.")
        }
        .alert("Remove from all devices?", isPresented: $confirmEverywhere) {
            Button("Remove Everywhere", role: .destructive) {
                appModel.removeAccountEverywhere(id: account.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(account.server.name)” will also be removed from your other devices signed in to iCloud.")
        }
    }
}

private struct PlozziOSShareScanSection: View {
    let state: ShareScanState?
    let onScan: () -> Void

    var body: some View {
        SettingsSectionGroup("Library") {
            LabeledContent {
                ZStack(alignment: .trailing) {
                    idleValue
                        .opacity(isBusy ? 0 : 1)
                    busyValue
                        .monospacedDigit()
                        .opacity(isBusy ? 1 : 0)
                }
            } label: {
                ZStack(alignment: .leading) {
                    Text("Last scanned")
                        .opacity(isBusy ? 0 : 1)
                    Text(state?.phase ?? LocalizedStringResource("Updating library"))
                        .opacity(isBusy ? 1 : 0)
                }
            }
            ShareScanProgressBar(fraction: state?.fraction)
                .frame(height: isBusy ? 6 : 0)
                .opacity(isBusy ? 1 : 0)
                .clipped()

            Button("Scan Now", systemImage: "arrow.clockwise", action: onScan)
                .disabled(isBusy)
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var isBusy: Bool {
        state?.isBusy == true
    }

    private var busyValue: Text {
        guard let detail = state?.progressDetail else {
            return Text(verbatim: "")
        }
        return scanProgressDetailText(detail)
    }

    private var idleValue: Text {
        if let date = state?.lastScanAt {
            return Text(date, format: .relative(presentation: .named))
        }
        return Text("Never")
    }
}

struct PlozziOSAppearanceSettingsView: View {
    let appModel: PlozziOSAppModel
    @Bindable var theme: ThemeSettingsModel
    @Bindable var transparency: TransparencyPreferenceModel
    @Bindable var cardStyle: CardStyleSettingsModel
    @Bindable var density: UIDensitySettingsModel
    @Bindable var watchIndicator: WatchStatusIndicatorSettingsModel
    var canManageProviders = false
    @State private var destination: Page?

    private enum Page: String, CaseIterable, Identifiable {
        case theme, cards, artwork, circadian
        var id: Self { self }
        var title: LocalizedStringResource {
            switch self {
            case .theme: "Theme"
            case .cards: "Cards"
            case .artwork: "Artwork"
            case .circadian: "Circadian Mode"
            }
        }
    }

    var body: some View {
        List {
            SettingsSectionGroup {
                ForEach(Page.allCases) { page in
                    Button { destination = page } label: {
                        SettingsDisclosureLabel { Text(page.title) }
                    }
                    .accessibilityIdentifier("appearance-\(page.rawValue)")
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle("Appearance")
        .navigationDestination(item: $destination) { page in
            switch page {
            case .theme:
                PlozziOSThemeSettingsView(theme: theme, transparency: transparency)
            case .cards:
                CardAppearanceControls(
                    cards: cardStyle, watchIndicator: watchIndicator,
                    density: density, visibility: appModel.settings.homeVisibility
                )
                .environment(appModel.settings.hero)
            case .artwork:
                PlozziOSArtworkSettingsView(
                    appModel: appModel, cardStyle: cardStyle, canManageProviders: canManageProviders
                )
            case .circadian:
                PlozziOSNightShiftSettingsView(model: appModel.settings.nightShift)
            }
        }
    }
}

private struct PlozziOSThemeSettingsView: View {
    @Bindable var theme: ThemeSettingsModel
    @Bindable var transparency: TransparencyPreferenceModel

    var body: some View {
        List {
            SettingsSectionGroup {
                Picker("Appearance", selection: $theme.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Label(theme.displayName, systemImage: theme.symbolName).tag(theme)
                    }
                }
                .settingsSearchAnchor("theme")
                Toggle("Gradient Backgrounds", isOn: $theme.gradientEnabled)
                    .settingsSearchAnchor("gradient-backgrounds")
                Picker("Liquid Glass", selection: $transparency.preference) {
                    ForEach(TransparencyPreference.allCases) { preference in
                        Text(preference == .system ? "System" : preference.displayName)
                            .tag(preference)
                    }
                }
                .settingsSearchAnchor("liquid-glass")
            }
            .settingsSearchGroup(["theme", "gradient-backgrounds", "liquid-glass"])
        }
        .settingsPageSurface()
        .navigationTitle("Theme")
    }
}

private struct PlozziOSScreensNavigationSettingsView: View {
    let appModel: PlozziOSAppModel
    @State private var destination: Page?

    private enum Page: String, CaseIterable, Identifiable {
        case home, libraries, navigation, detail, allScreens
        var id: Self { self }
        var title: LocalizedStringResource {
            switch self {
            case .home: "Home"
            case .libraries: "Libraries"
            case .navigation: "App navigation"
            case .detail: "Movie & show details"
            case .allScreens: "All screens"
            }
        }
    }

    var body: some View {
        List {
            SettingsSectionGroup {
                Button { destination = .navigation } label: {
                    SettingsDisclosureLabel { Text(Page.navigation.title) }
                }
                .accessibilityIdentifier("screens-navigation")
                Button { destination = .allScreens } label: {
                    SettingsDisclosureLabel { Text(Page.allScreens.title) }
                }
                .accessibilityIdentifier("screens-all-screens")
            }
            SettingsSectionGroup {
                ForEach([Page.home, .libraries, .detail]) { page in
                    Button { destination = page } label: {
                        SettingsDisclosureLabel { Text(page.title) }
                    }
                    .accessibilityIdentifier("screens-\(page.rawValue)")
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle("Screens & Navigation")
        .navigationDestination(item: $destination) { page in
            switch page {
            case .allScreens:
                PlozziOSAllScreensSettingsView(
                    contentRatings: appModel.settings.contentRatings, spoilers: appModel.settings.spoilers
                )
            case .home:
                PlozziOSHomeSettingsView(
                    hero: appModel.settings.hero, heroBackground: appModel.settings.heroBackground,
                    cards: appModel.settings.cardStyle,
                    visibility: appModel.settings.homeVisibility,
                    accounts: appModel.accountsProviders.resolvedActiveAccounts,
                    spoilerSettings: appModel.settings.spoilers.settings
                )
                .id(ObjectIdentifier(appModel.settings.homeVisibility))
            case .navigation:
                PlozziOSNavigationSettingsView(appModel: appModel)
            case .libraries:
                LibraryPresentationSettingsView(
                    model: appModel.settings.libraryPresentation, cards: appModel.settings.cardStyle,
                    visibility: appModel.settings.homeVisibility,
                    accounts: appModel.accountsProviders.resolvedActiveAccounts,
                    loader: LibraryPresentationLoader(
                        settings: appModel.settings.libraryPresentation,
                        namespace: appModel.profiles.activeNamespace
                    )
                )
                .id(ObjectIdentifier(appModel.settings.libraryPresentation))
            case .detail:
                PlozziOSDetailPageSettingsView(
                    cards: appModel.settings.cardStyle,
                    heroBackground: appModel.settings.heroBackground,
                    themeMusic: appModel.settings.themeMusic, detailPage: appModel.settings.detailPage
                )
            }
        }
    }
}

struct PlozziOSAllScreensSettingsView: View {
    let contentRatings: ContentRatingSettingsModel
    let spoilers: SpoilerSettingsModel

    var body: some View {
        List {
            SettingsSectionGroup {
                ContentRatingToggle(model: contentRatings)
                    .settingsSearchAnchor("content-ratings")
            }
            .settingsSearchGroup(["content-ratings"])
            PlozziOSSpoilerSettingsControls(model: spoilers)
        }
        .settingsPageSurface()
        .navigationTitle("All screens")
    }
}

private struct PlozziOSNavigationSettingsView: View {
    let appModel: PlozziOSAppModel

    private var navigationLibrariesScope: ProfileLibrariesScope {
        let profile = appModel.profiles.activeProfile
        let discovery = appModel.settings.discoveredLibraries
        let libraries = appModel.visibleNavigationLibraries
        let state: LoadState<[AggregatedLibrary]> = if !libraries.isEmpty {
            .loaded(libraries)
        } else if let failure = discovery.failures.values.first {
            .failed(failure)
        } else {
            discovery.state
        }
        return ProfileLibrariesScope(
            accounts: appModel.accounts,
            activeProfile: profile,
            discoveredLibraries: state,
            refreshingLibraryAccountIDs: discovery.refreshingAccountIDs,
            unreachableLibraryAccountIDs: discovery.unreachableAccountIDs,
            libraryFailures: discovery.failures,
            reloadLibraries: { await appModel.refreshNavigationLibraries() },
            homeVisibility: appModel.settings.homeVisibility,
            isAccountIncludedInActiveProfile: {
                appModel.activeAccountIDs(for: profile.id).contains($0)
            },
            onSetAccountIncluded: {
                appModel.setAccount($0, enabled: $1, for: profile.id)
            },
            onAddAccount: {},
            plexHomeUsersFetcher: {
                await appModel.plexHomeUsers.plexHomeUsers(forAccountID: $0)
            },
            onSelectPlexHomeUser: {
                appModel.plexHomeUsers.setPlexHomeUserForActiveProfile(
                    accountID: $0,
                    user: $1
                )
            }
        )
    }

    var body: some View {
        List {
            SettingsSectionGroup("Hide or Reorder Navigation") {
                NavigationLibrariesDetailView(
                    scope: navigationLibrariesScope,
                    navigation: appModel.settings.navigation,
                    excludedKeys: [
                        NavigationLibraryLayout.musicKey,
                    ]
                )
                .id(appModel.navigationLibrariesScopeKey)
            }
            .settingsSearchAnchor("navigation-order")
            .settingsSearchGroup(["navigation-order"])
        }
        .settingsPageSurface()
        .navigationTitle("App navigation")
    }
}

struct PlozziOSArtworkSettingsView: View {
    let appModel: PlozziOSAppModel
    @Bindable var cardStyle: CardStyleSettingsModel
    let canManageProviders: Bool
    var returnsToMetadata = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ArtworkSettingsControls(cards: cardStyle)
            if canManageProviders {
                SettingsSectionGroup {
                    if returnsToMetadata {
                        Button {
                            dismiss()
                        } label: {
                            HStack {
                                Text("Metadata Providers (TMDB, TheTVDB…)")
                                Spacer()
                                Image(systemName: "chevron.forward")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("artwork-metadata-providers")
                    } else {
                        NavigationLink("Metadata Providers (TMDB, TheTVDB…)") {
                            PlozziOSMetadataSettingsView(
                                appModel: appModel, deps: appModel.makeMetadataSettingsDependencies(),
                                returnsToArtwork: true
                            )
                        }
                        .accessibilityIdentifier("artwork-metadata-providers")
                    }
                } footer: {
                    Text("Shared by all profiles.")
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle("Artwork")
    }
}

struct PlozziOSHomeSettingsView: View {
    @Bindable var hero: HeroSettingsModel
    @Bindable var heroBackground: HeroBackgroundSettingsModel
    let cards: CardStyleSettingsModel
    let visibility: HomeLibraryVisibilityModel
    let accounts: [ResolvedAccount]
    var spoilerSettings: SpoilerSettings = .default
    var searchPage: SettingsSearchPage = .home
    @State private var librarySnapshot: (scope: HomeSectionCatalogModel.RequestID, choices: [HomeLibraryChoice])?

    private var libraryRequestID: HomeSectionCatalogModel.RequestID {
        HomeSectionCatalogModel.requestID(libraries: [], accounts: accounts, visibility: visibility)
    }

    private var libraries: [HomeLibraryChoice] {
        guard let librarySnapshot, librarySnapshot.scope == libraryRequestID else { return [] }
        return librarySnapshot.choices
    }

    var body: some View {
        HomeRowsSettingsView(
            libraries: aggregatedHomeLibraries, accounts: accounts, visibility: visibility,
            spoilerSettings: spoilerSettings, searchPage: searchPage
        )
        .id(ObjectIdentifier(visibility))
        .environment(hero)
        .environment(heroBackground)
        .environment(cards)
        .task(id: libraryRequestID) {
            await loadLibraries()
        }
    }

    private var aggregatedHomeLibraries: [AggregatedLibrary] {
        libraries.compactMap { choice in
            guard let account = accounts.first(where: { $0.account.id == choice.accountID })?.account else {
                return nil
            }

            return AggregatedLibrary(
                accountID: choice.accountID, accountName: account.userName,
                serverName: choice.serverName, providerKind: account.server.provider,
                transportKind: MediaShareTransportKind(mediaShareScheme: account.server.baseURL.scheme),
                library: choice.library
            )
        }
    }

    private func loadLibraries() async {
        let scope = libraryRequestID
        let previousLibraries = libraries
        var loaded: [HomeLibraryChoice] = []
        for resolved in accounts {
            let discovered: [MediaLibrary]
            do {
                discovered = try await resolved.provider.libraries()
                try Task.checkCancellation()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                PlozzLog.app.error("Home settings library discovery failed")
                loaded += previousLibraries.filter { $0.accountID == resolved.account.id }
                continue
            }
            loaded.append(
                contentsOf: discovered
                    .filter { !$0.isMusic }
                    .map {
                        HomeLibraryChoice(
                            accountID: resolved.account.id,
                            serverName: resolved.account.server.name,
                            library: $0
                        )
                    }
            )
        }
        guard !Task.isCancelled else { return }
        librarySnapshot = (scope: scope, choices: loaded)
    }
}

private struct HomeLibraryChoice {
    let accountID: String
    let serverName: String
    let library: MediaLibrary
}

private struct PlozziOSDetailPageSettingsView: View {
    let cards: CardStyleSettingsModel
    @Bindable var heroBackground: HeroBackgroundSettingsModel
    @Bindable var themeMusic: ThemeMusicSettingsModel
    @Bindable var detailPage: DetailPageSettingsModel

    var body: some View {
        List {
            SettingsSectionGroup("Hero") {
                HeroLogoSizeControl(
                    size: $detailPage.settings.logoSize, textSize: $detailPage.settings.textSize, surface: .detail
                )
                .settingsSearchAnchor("detail-size")
            }
            .settingsSearchGroup(["detail-size", "detail-logo-size", "detail-text-size"])
            SettingsSectionGroup("Review scores") {
                Toggle("Show review scores", isOn: $detailPage.settings.showsHeaderRatings)
                    .settingsSearchAnchor(
                        "detail-ratings",
                        fallbackFor: detailPage.settings.showsHeaderRatings ? [] : ["detail-rating-count"]
                    )
                if detailPage.settings.showsHeaderRatings {
                    HeaderReviewScoreCountPicker(settings: $detailPage.settings).settingsSearchAnchor("detail-rating-count")
                }
                NavigationLink {
                    PlozziOSDetailRatingPriorityView(model: detailPage)
                } label: {
                    Text("Rating sources & order")
                }
            }
            .settingsSearchGroup(["detail-ratings", "detail-rating-count"])
            SettingsSectionGroup("Age recommendation") {
                Toggle("Show Common Sense age", isOn: $detailPage.settings.showsHeaderFamilyGuidance)
                    .settingsSearchAnchor("detail-age")
            }
            .settingsSearchGroup(["detail-age"])
            SettingsSectionGroup("Behind the hero") {
                Picker(
                    "Background",
                    selection: $heroBackground.settings.detailMode
                ) {
                    ForEach(HeroBackgroundMode.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .settingsSearchAnchor(
                    "detail-background",
                    fallbackFor: (heroBackground.settings.detailMode == .trailer ? [] : ["detail-trailer-muted"])
                        + (heroBackground.settings.detailMode == .themeMusic ? [] : ["theme-music-volume"])
                )
                if heroBackground.settings.detailMode == .trailer {
                    Toggle(
                        "Start muted",
                        isOn: $heroBackground.settings.detailTrailerMuted
                    ).settingsSearchAnchor("detail-trailer-muted")
                }
                if heroBackground.settings.detailMode == .themeMusic {
                    ThemeMusicVolumeControl(model: themeMusic)
                }
            } footer: {
                Text("Choose what plays behind the hero on a movie or show's details screen. Trailer and theme music never play together.")
            }
            .settingsSearchGroup(["detail-background", "detail-trailer-muted", "theme-music-volume"])
            SettingsSectionGroup("Cards") {
                CardCaptionSettingsLink(cards: cards, scope: .detail)
            }
        }
        .settingsPageSurface()
        .navigationTitle("Movie & show details")
    }
}

private struct PlozziOSDetailRatingPriorityView: View {
    @Bindable var model: DetailPageSettingsModel

    var body: some View {
        List {
            Section {
                ForEach(model.settings.orderedSources, id: \.self) { source in
                    Toggle(isOn: Binding(
                        get: { model.settings.enabledRatingSources.contains(source) },
                        set: { enabled in
                            if enabled {
                                model.settings.enabledRatingSources.insert(source)
                            } else {
                                model.settings.enabledRatingSources.remove(source)
                            }
                        }
                    )) {
                        switch source {
                        case .community: Text("Community")
                        case .critic: Text("Critics")
                        default: Text(verbatim: source.displayName)
                        }
                    }
                    .settingsSearchAnchor(
                        "rating-source-\(source.rawValue)",
                        fallbackFor: source == model.settings.orderedSources.first ? ["rating-source-enabled"] : []
                    )
                }
                .onMove { offsets, destination in
                    var order = model.settings.orderedSources
                    order.move(fromOffsets: offsets, toOffset: destination)
                    model.settings.ratingSourceOrder = order
                }
            } footer: {
                Text("Enable as many sources as you want, then tap Edit to set their priority. Not every title has every score. The header shows the first available enabled sources, up to your chosen maximum. AniList is used only for anime.")
            }
        }
        .toggleStyle(SettingsSwitchToggleStyle())
        .settingsPageSurface()
        .navigationTitle("Rating sources & order")
        .toolbar { EditButton().settingsSearchAnchor("rating-source-order") }
    }
}

struct PlozziOSPlaybackSettingsView: View {
    @Environment(\.locale) private var locale
    @Bindable var model: PlaybackSettingsModel
    @Bindable var audioPolicy: AudioPolicyModel
    let hasStreamingServer: Bool
    let streamingSupport: StreamingQualitySupport
    @State private var showsAdvancedStreaming = false
    @State private var showsAdvancedPlayback = false
    @State private var showsSkipMarkerSettings = false

    private static let policyCategories: [ContentCategory] = [.movie, .tvShow, .anime]
    private static let audioOptions: [AudioLanguagePreference] =
        [.original, .device] + SubtitleLanguageCatalog.languages.map {
            .language($0.code)
        }

    var body: some View {
        List {
            PlozziOSStreamingSettings(
                settings: $model.settings.streaming, hasCompatibleServer: hasStreamingServer,
                support: streamingSupport,
                onShowAdvanced: { showsAdvancedStreaming = true }
            )
            PlaybackReadAheadControl()
                .settingsSearchAnchor("read-ahead")
            LivePlaybackBufferControl()
                .settingsSearchAnchor("live-buffer")
            if UIDevice.current.userInterfaceIdiom == .phone {
                SettingsSectionGroup {
                    Picker("Player orientation", selection: $model.settings.orientation) {
                        ForEach(PlaybackOrientation.allCases, id: \.self) {
                            Text($0.title).tag($0)
                        }
                    }
                    .accessibilityIdentifier("playback-orientation")
                    .settingsSearchAnchor("player-orientation")
                }
            }
            SkipMarkerSettingsControl(model: model, onOpenSettings: { showsSkipMarkerSettings = true })
                .settingsSearchGroup(["skip-intros"])

            SettingsSectionGroup("Skipping") {
                Picker("Skip backward", selection: $model.settings.skipBackwardInterval) {
                    ForEach(SkipInterval.allCases, id: \.self) {
                        Text(verbatim: $0.title(locale: locale)).tag($0)
                    }
                }
                .settingsSearchAnchor("skip-backward")
                Picker("Skip forward", selection: $model.settings.skipForwardInterval) {
                    ForEach(SkipInterval.allCases, id: \.self) {
                        Text(verbatim: $0.title(locale: locale)).tag($0)
                    }
                }
                .settingsSearchAnchor("skip-forward")
                Picker("Resume rewind", selection: $model.settings.resumeRewindInterval) {
                    ForEach(ResumeRewindInterval.allCases, id: \.self) {
                        Text(verbatim: $0.title(locale: locale)).tag($0)
                    }
                }
                .settingsSearchAnchor("resume-rewind")
            }
            .settingsSearchGroup(["skip-backward", "skip-forward", "resume-rewind"])

            SettingsSectionGroup("Playback") {
                Toggle("Ask to resume or start over", isOn: $model.settings.askBeforeResuming)
                    .accessibilityIdentifier("playback-ask-before-resuming")
                    .settingsSearchAnchor("ask-before-resuming")
                PlaybackVersionPreferencePicker(model: model)
                    .settingsSearchAnchor("version-selection")
                Toggle("Remember series version choices", isOn: $model.settings.rememberVersionPerSeries)
                    .accessibilityIdentifier("playback-remember-series-version")
                    .settingsSearchAnchor("remember-series-version")
                Toggle("Background Audio", isOn: $model.settings.backgroundAudio)
                    .settingsSearchAnchor("background-audio")
                Toggle(isOn: $model.settings.volumeBrightnessGestures) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Volume and brightness gestures")
                        Text("Swipe up or down on the left for brightness, or on the right for system volume.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("playback-volume-brightness-gestures")
                .settingsSearchAnchor("volume-brightness")
                Toggle("Seek without pausing", isOn: $model.settings.seekWithoutPausing)
                    .settingsSearchAnchor("seek-without-pausing")
                // Autoplay first: whether the next episode starts at all, then
                // whether the card announces it. Independent switches.
                Toggle("Autoplay next episode", isOn: $model.settings.autoPlayNextEpisode)
                    .settingsSearchAnchor("autoplay-next-episode")
                Toggle("Autoplay next playlist item", isOn: $model.settings.autoPlayNextPlaylistItem)
                    .settingsSearchAnchor("autoplay-next-playlist")
                Toggle("Show Up Next card", isOn: $model.settings.showUpNextCard)
                    .settingsSearchAnchor(
                        "show-up-next-card", fallbackFor: model.settings.showUpNextCard ? [] : ["up-next-lead"]
                    )
                if model.settings.showUpNextCard {
                    Picker("Up Next lead time", selection: $model.settings.upNextLeadSeconds) {
                        ForEach(PlaybackSettings.upNextLeadSecondsOptions, id: \.self) {
                            Text("\($0) sec").tag($0)
                        }
                    }.settingsSearchAnchor("up-next-lead")
                }
                Toggle(
                    "Sync watch state across servers",
                    isOn: $model.settings.syncWatchAcrossServers
                ).settingsSearchAnchor("cross-server-watch-sync")
            }
            .settingsSearchGroup([
                "ask-before-resuming", "version-selection", "remember-series-version", "background-audio",
                "volume-brightness", "seek-without-pausing", "autoplay-next-episode",
                "autoplay-next-playlist", "show-up-next-card", "up-next-lead", "cross-server-watch-sync"
            ])

            SettingsSectionGroup(LocalizedStringResource(
                "settings.section.tracks",
                defaultValue: "Tracks",
                comment: "Settings section for default audio and subtitle track selection. Media streams inside a video file, not music tracks."
            )) {
                // Set separately, "Everything else" takes over the one
                // preference, so it isn't shown twice.
                if audioPolicy.overrides.isEmpty {
                    Picker("Preferred audio language", selection: $model.settings.audioLanguagePreference) {
                        ForEach(Self.audioOptions, id: \.self) { preference in
                            audioName(preference).tag(preference)
                        }
                    }
                    .settingsSearchAnchor("audio-language")
                }
                Toggle("Set separately for movies, TV shows & anime", isOn: audioOverridesEnabled)
                    .settingsSearchAnchor(
                        "audio-separate",
                        fallbackFor: audioPolicy.overrides.isEmpty
                            ? Self.policyCategories.map { "audio-language-\($0.rawValue)" } : []
                    )
                if !audioPolicy.overrides.isEmpty {
                    ForEach(Self.policyCategories + [.other], id: \.self) { category in
                        Picker(selection: category == .other
                            ? $model.settings.audioLanguagePreference
                            : audioBinding(for: category)
                        ) {
                            ForEach(Self.audioOptions, id: \.self) { preference in
                                audioName(preference).tag(preference)
                            }
                        } label: {
                            SeparateSettingLabel(category: category)
                        }
                        .settingsSearchAnchor(category == .other ? "audio-language" : "audio-language-\(category)")
                    }
                }
                Toggle(
                    "Remember audio language per series",
                    isOn: $model.settings.rememberAudioTrackPerSeries
                )
                .settingsSearchAnchor("remember-audio")
                Toggle(
                    "Remember subtitles per series",
                    isOn: $model.settings.rememberSubtitleTrackPerSeries
                )
                .settingsSearchAnchor("subtitle-remember")
            }
            .settingsSearchGroup(
                ["audio-language", "audio-separate", "remember-audio", "subtitle-remember"]
                    + Self.policyCategories.map { "audio-language-\($0.rawValue)" }
            )
            SettingsSectionGroup("Audio") {
                LosslessAudioControl()
                    .settingsSearchAnchor("lossless-audio")
                SpatialAudioControl(isOn: $model.settings.trueHDAtmosEnabled)
                    .settingsSearchAnchor("spatial-audio")
            }
            .settingsSearchGroup(["lossless-audio", "spatial-audio"])
            SettingsSectionGroup {
                Button { showsAdvancedPlayback = true } label: {
                    SettingsDisclosureLabel { Text("Advanced") }
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle("Playback")
        .navigationDestination(isPresented: $showsSkipMarkerSettings) {
            SkipMarkerSettingsView(model: model)
        }
        .navigationDestination(isPresented: $showsAdvancedStreaming) {
            PlozziOSAdvancedStreamingSettings(settings: $model.settings.streaming, support: streamingSupport)
        }
        .navigationDestination(isPresented: $showsAdvancedPlayback) {
            PlaybackAdvancedSettingsView(playback: model)
        }
    }

    private var audioOverridesEnabled: Binding<Bool> {
        Binding(
            get: { !audioPolicy.overrides.isEmpty },
            set: {
                audioPolicy.overrides = $0
                    ? AudioPolicy.smartDefaultOverrides()
                    : [:]
            }
        )
    }

    private func audioBinding(
        for category: ContentCategory
    ) -> Binding<AudioLanguagePreference> {
        Binding(
            get: {
                audioPolicy.overrides[category]
                    ?? model.settings.audioLanguagePreference
            },
            set: { audioPolicy.overrides[category] = $0 }
        )
    }

    private func audioName(_ preference: AudioLanguagePreference) -> Text {
        switch preference {
        case .original:
            return Text("Original language")
        case .device:
            return Text("Device language")
        case .language(let code):
            return Text(
                verbatim: SubtitleLanguageCatalog.displayName(
                    forCode: code,
                    in: locale
                ) ?? code
            )
        }
    }
}

private struct PlozziOSSubtitleSettingsView: View {
    @Bindable var behavior: SubtitleBehaviorModel
    @Bindable var policy: SubtitlePolicyModel
    @Bindable var style: SubtitleStyleModel

    private static let policyCategories: [SubtitleContentCategory] =
        [.movie, .tvShow, .anime]

    var body: some View {
        List {
            SettingsSectionGroup("Appearance") {
                NavigationLink("Customize subtitle style") {
                    SubtitleStyleSettingsView(style: $style.style)
                }
            }
            SettingsSectionGroup("Live TV subtitle style") {
                Toggle("Use a separate style for Live TV", isOn: $style.usesSeparateLiveTVStyle)
                    .settingsSearchAnchor("live-subtitle-style")
                Text("Use the same subtitle appearance everywhere, or choose a separate look for Live TV.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if style.usesSeparateLiveTVStyle {
                    NavigationLink("Customize Live TV subtitles") {
                        SubtitleStyleSettingsView(style: $style.resolvedLiveTVStyle, isLiveTV: true)
                    }
                }
            }
            .settingsSearchGroup(["live-subtitle-style"])

            SettingsSectionGroup("Behavior") {
                // Set separately, "Everything else" takes over the one mode,
                // so it isn't shown twice.
                if policy.overrides.isEmpty {
                    Picker("Show subtitles", selection: $behavior.settings.subtitleMode) {
                        ForEach(SubtitleMode.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .settingsSearchAnchor("subtitle-default")
                }
                Toggle("Set separately for movies, TV shows & anime", isOn: subtitleOverridesEnabled)
                    .settingsSearchAnchor(
                        "subtitle-separate",
                        fallbackFor: policy.overrides.isEmpty
                            ? Self.policyCategories.map { "subtitle-default-\($0.rawValue)" } : []
                    )
                if !policy.overrides.isEmpty {
                    ForEach(Self.policyCategories + [.other], id: \.self) { category in
                        Picker(selection: category == .other
                            ? $behavior.settings.subtitleMode
                            : modeBinding(for: category)
                        ) {
                            ForEach(SubtitleMode.allCases, id: \.self) {
                                Text($0.displayName).tag($0)
                            }
                        } label: {
                            SeparateSettingLabel(category: category)
                        }
                        .settingsSearchAnchor(category == .other ? "subtitle-default" : "subtitle-default-\(category)")
                    }
                }
                Toggle(
                    "Download subtitles automatically",
                    isOn: $behavior.settings.autoDownloadSubtitles
                ).settingsSearchAnchor("subtitle-download")
                TextField(
                    "Preferred language code",
                    text: Binding(
                        get: { behavior.settings.preferredSubtitleLanguage ?? "" },
                        set: {
                            behavior.settings.preferredSubtitleLanguage =
                                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? nil
                                : $0
                        }
                    )
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .settingsSearchAnchor("subtitle-language")
                Picker(
                    "SDH subtitles",
                    selection: $behavior.settings.hearingImpairedPreference
                ) {
                    ForEach(HearingImpairedPreference.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .accessibilityIdentifier("subtitle-sdh")
                .settingsSearchAnchor("subtitle-sdh")
                Text(behavior.settings.hearingImpairedPreference.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .settingsSearchGroup(
                ["subtitle-default", "subtitle-separate", "subtitle-download", "subtitle-language", "subtitle-sdh"]
                    + Self.policyCategories.map { "subtitle-default-\($0.rawValue)" }
            )

            SettingsSectionGroup("Subtitle search") {
                Picker(
                    "Forced subtitles",
                    selection: $behavior.settings.forcedSearchPreference
                ) {
                    ForEach(ForcedSubtitlePreference.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }.settingsSearchAnchor("subtitle-forced-search")
            }
            .settingsSearchGroup(["subtitle-forced-search"])
        }
        .settingsPageSurface()
        .navigationTitle("Subtitles")
    }

    private var baseRule: SubtitlePolicy.Rule {
        SubtitlePolicy.inheriting(from: behavior.settings).basePolicy
    }

    private var subtitleOverridesEnabled: Binding<Bool> {
        Binding(
            get: { !policy.overrides.isEmpty },
            set: {
                policy.overrides = $0
                    ? SubtitlePolicy.smartDefaultOverrides(base: baseRule)
                    : [:]
            }
        )
    }

    private func modeBinding(
        for category: SubtitleContentCategory
    ) -> Binding<SubtitleMode> {
        Binding(
            get: { policy.overrides[category]?.mode ?? baseRule.mode },
            set: {
                var rule = policy.overrides[category] ?? baseRule
                rule.mode = $0
                policy.overrides[category] = rule
            }
        )
    }
}

/// A per-type picker's name, with what "Everything else" covers beneath it.
private struct SeparateSettingLabel: View {
    let category: ContentCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(category.separateSettingTitle)
            if let hint = category.separateSettingHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PlozziOSSpoilerSettingsControls: View {
    @Bindable var model: SpoilerSettingsModel

    var body: some View {
        SettingsSectionGroup("Spoiler Protection") {
            Toggle("Protect unwatched episodes", isOn: $model.settings.isEnabled)
                .settingsSearchAnchor("spoilers")
            Picker("Thumbnail treatment", selection: $model.settings.mode) {
                ForEach(SpoilerSettings.Mode.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            .disabled(!model.settings.isEnabled).settingsSearchAnchor("spoiler-treatment")
            Toggle(
                "Hide ratings until watched",
                isOn: $model.settings.hideRatingsUntilWatched
            )
            .settingsSearchAnchor("hide-ratings")
        } footer: {
            Text(LocalizedStringResource(
                "settings.spoilers.footer",
                defaultValue: """
                    Episode titles, summaries, and artwork can be hidden until \
                    you watch them. Tap blurred ratings on the details screen \
                    to reveal them.
                    """,
                comment: "Footer under the Spoilers settings group on iPhone/iPad, explaining what the switches above it do."
            ))
        }
        .settingsSearchGroup(["spoilers", "hide-ratings"])
    }
}

private struct PlozziOSNightShiftSettingsView: View {
    @Bindable var model: NightShiftSettingsModel
    @Environment(\.locale) private var locale

    var body: some View {
        List {
            SettingsSectionGroup {
                Toggle("Circadian Mode", isOn: $model.settings.isEnabled)
                    .settingsSearchAnchor(
                        "circadian",
                        fallbackFor: model.settings.isEnabled ? [] : SettingsSearchCatalog.targets(on: .circadian)
                    )
                Picker("Schedule", selection: $model.settings.scheduleMode) {
                    ForEach(NightShiftScheduleMode.allCases) {
                        Text($0.displayName).tag($0)
                    }
                }
                .disabled(!model.settings.isEnabled)
                .settingsSearchAnchor(
                    model.settings.isEnabled ? "circadian-schedule-mobile" : "circadian-disabled-schedule",
                    fallbackFor: model.settings.isEnabled ? SettingsSearchCatalog.circadianScheduleFallbacks(
                        isEnabled: true, mode: model.settings.scheduleMode
                    ) : []
                )

                if model.settings.isEnabled {
                    scheduleDetails
                }
            } footer: {
                Text(model.scheduleSummary(locale: locale))
            }
            .settingsSearchGroup(
                model.settings.isEnabled
                    ? ["circadian", "circadian-schedule-mobile", "circadian-region", "circadian-on", "circadian-off"]
                        + (model.settings.scheduleMode == .alwaysOn ? ["circadian-fade"] : [])
                    : SettingsSearchCatalog.targets(on: .circadian)
            )

            if model.settings.isEnabled {
                SettingsSectionGroup("Picture") {
                    Picker("Warmth", selection: $model.settings.warmth) {
                        ForEach(NightShiftWarmth.allCases) {
                            Text($0.displayName).tag($0)
                        }
                    }.settingsSearchAnchor("circadian-warmth")
                    Picker("Dimness", selection: $model.settings.dimness) {
                        ForEach(NightShiftDimness.allCases) {
                            Text($0.displayName).tag($0)
                        }
                    }.settingsSearchAnchor("circadian-dimness")
                    if model.settings.scheduleMode != .alwaysOn {
                        Picker("Fade", selection: $model.settings.fadeMinutes) {
                            ForEach(fadeOptions, id: \.self) { minutes in
                                Text(fadeLabel(minutes))
                                    .tag(minutes)
                            }
                        }.settingsSearchAnchor("circadian-fade")
                    }
                }
                .settingsSearchGroup(
                    ["circadian-warmth", "circadian-dimness"]
                        + (model.settings.scheduleMode == .alwaysOn ? [] : ["circadian-fade"])
                )

                SettingsSectionGroup("Preview") {
                    Toggle("Preview at Full Strength", isOn: $model.isPreviewing)
                    Button("Preview a Day", systemImage: "sun.and.horizon") {
                        model.runDayNightPreview()
                    }
                    if model.previewProgress != nil {
                        LabeledContent("Simulated time") {
                            Text(model.previewClockText)
                                .monospacedDigit()
                        }
                        ProgressView(value: model.previewProgress ?? 0)
                    }
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle("Circadian Mode")
        .onChange(of: model.settings.isEnabled) { _, enabled in
            if !enabled {
                model.isPreviewing = false
            }
        }
        .onDisappear {
            model.isPreviewing = false
        }
    }

    @ViewBuilder
    private var scheduleDetails: some View {
        switch model.settings.scheduleMode {
        case .solar:
            Picker("Location", selection: $model.settings.regionID) {
                ForEach(NightShiftRegion.sortedCatalog) { region in
                    Text(region.name).tag(region.id)
                }
            }.settingsSearchAnchor("circadian-region")
        case .manual:
            DatePicker(
                "Turns on",
                selection: timeBinding(for: \.manualOnMinutes),
                displayedComponents: .hourAndMinute
            ).settingsSearchAnchor("circadian-on")
            DatePicker(
                "Turns off",
                selection: timeBinding(for: \.manualOffMinutes),
                displayedComponents: .hourAndMinute
            ).settingsSearchAnchor("circadian-off")
        case .alwaysOn:
            EmptyView()
        }
    }

    private func timeBinding(
        for keyPath: WritableKeyPath<NightShiftSettings, Int>
    ) -> Binding<Date> {
        Binding(
            get: {
                let minutes = model.settings[keyPath: keyPath]
                var components = DateComponents()
                components.year = 2001
                components.month = 1
                components.day = 1
                components.hour = minutes / 60
                components.minute = minutes % 60
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents(
                    [.hour, .minute],
                    from: date
                )
                model.settings[keyPath: keyPath] =
                    (components.hour ?? 0) * 60 + (components.minute ?? 0)
            }
        )
    }

    private var fadeOptions: [Int] {
        Array(
            Set(
                NightShiftSettingsModel.fadeOptions
                    + [model.settings.fadeMinutes]
            )
        )
        .sorted()
    }

    private func fadeLabel(_ minutes: Int) -> String {
        minutes == 0
            ? "Off"
            : NightShiftSettingsModel.fadeLabel(minutes: minutes)
    }
}

private struct PlozziOSAttributionsView: View {
    var body: some View {
        List {
            Text(PlozzAttributions.introduction)
                .font(.footnote)
                .plozzForeground(.secondary)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            ForEach(PlozzAttributions.entries) { entry in
                SettingsSectionGroup(verbatim: entry.title) {
                    Text(verbatim: entry.detail)
                    if !entry.licenses.isEmpty {
                        PlozziOSLicenseBadges(licenses: entry.licenses)
                    }
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle("Attributions")
    }
}

private struct PlozziOSLicenseBadges: View {
    let licenses: [PlozzAttributionLicense]

    var body: some View {
        HStack {
            ForEach(licenses) { license in
                Text(license.label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.tint.opacity(0.14), in: Capsule())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(licenses.map(\.label).joined(separator: ", "))
    }
}

/// The active profile's avatar and name, as a button that opens the picker.
///
/// Tapping who you are to become someone else is the convention every streaming
/// app shares, and it puts switching at the top of Settings instead of several
/// rows down inside a household section a Kids Profile can't even see.
private struct PlozziOSProfileIdentityHeader: View {
    let appModel: PlozziOSAppModel
    let onSwitchProfile: () -> Void

    var body: some View {
        Button(action: onSwitchProfile) {
            HStack(spacing: 14) {
                PlozziOSProfileAvatar(profile: appModel.profiles.activeProfile, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: appModel.profiles.activeProfile.name)
                        .font(.headline)
                    Text(KidsProfileCopy.openProfiles(
                        profileCount: appModel.profiles.profiles.count
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.tint)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .plozzForeground(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#endif
