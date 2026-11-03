#if os(iOS)
import AppRuntime
import CoreModels
import CoreUI
import FeatureSettings
import SwiftUI

struct PlozziOSPlexHomeUserSettingsView: View {
    let appModel: PlozziOSAppModel
    let account: Account
    var onDecline: (() -> Void)?
    @State private var users: [PlexHomeUser] = []
    @State private var isLoading = false
    @State private var selectionRequest: PlexHomeUsersModel.PlexPINRequest?

    private var pendingSelection: PlexHomeUsersModel.PlexPINRequest? {
        guard let selectionRequest,
              appModel.plexHomeUsers.pendingPlexPINRequest == selectionRequest else { return nil }
        return selectionRequest
    }

    var body: some View {
        ZStack {
            if let request = pendingSelection,
               appModel.plexHomeUsers.plexPINEntryAvailability == .available
                || appModel.plexHomeUsers.plexReauthentication != nil {
                PlozziOSPlexPINView(
                    model: appModel.plexHomeUsers, request: request, dismissOnSuccess: false
                )
            } else {
                userList
            }
        }
        .navigationTitle("Plex User")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(pendingSelection != nil)
        .task(id: account.connectionScopeKey) {
            isLoading = true
            users = await appModel.plexHomeUsers.plexHomeUsers(forAccountID: account.id)
            isLoading = false
        }
        .onChange(of: appModel.plexHomeUsers.pendingPlexPINRequest) { _, request in
            if request != selectionRequest { releaseSelection() }
        }
        .onDisappear {
            if pendingSelection != nil { appModel.plexHomeUsers.cancelPlexPIN() }
            releaseSelection()
        }
    }

    private var userList: some View {
        List {
            SettingsPageHeader(
                "Who are you on \(account.server.name)?",
                subtitle: "Plozz will play as this person here, show their watchlist, and save to it."
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .accessibilityIdentifier("plex-user-explanation")

            SettingsSectionGroup("Account owner") {
                if let owner = users.first(where: \.isAdmin) {
                    userButton(owner)
                } else {
                    Text(verbatim: account.userName)
                        .plozzForeground(.secondary)
                }
            }
            SettingsSectionGroup("Home users") {
                if isLoading {
                    HStack {
                        ProgressView()
                        Text("Loading Plex Home…")
                    }
                } else if users.filter({ !$0.isAdmin }).isEmpty {
                    Text("No additional Plex Home users were found.")
                        .plozzForeground(.secondary)
                } else {
                    ForEach(users.filter { !$0.isAdmin }) { user in
                        userButton(user)
                    }
                }
            } footer: {
                Text("PIN-protected users must unlock when their Plozz profile becomes active.")
            }
            if pendingSelection != nil {
                SettingsSectionGroup {
                    if appModel.plexHomeUsers.plexPINEntryAvailability == .unavailable {
                        if let error = appModel.plexHomeUsers.plexPINError {
                            Text(error).foregroundStyle(.red)
                        }
                        Button("Sign In Again") { appModel.plexHomeUsers.beginPlexReauthentication() }
                            .settingsActionRow()
                        Button("Retry") { appModel.plexHomeUsers.retryPlexPINRequirement() }
                            .settingsActionRow()
                    }
                    Button("Cancel") { appModel.plexHomeUsers.cancelPlexPIN() }
                        .settingsActionRow()
                }
            }
            if let onDecline {
                SettingsSectionGroup {
                    Button(action: onDecline) {
                        Text(
                            "Don't use this server's watchlist",
                            comment: "Button declining to pick a user, which leaves the server's own watchlist out of this profile."
                        )
                    }
                    .settingsActionRow()
                    .disabled(pendingSelection != nil)
                }
            }
        }
        .settingsPageSurface()
        .accessibilityIdentifier("plex-user-chooser")
    }

    private func userButton(_ user: PlexHomeUser) -> some View {
        Button {
            appModel.plexHomeUsers.setPlexHomeUserForActiveProfile(accountID: account.id, user: user)
            if let request = appModel.plexHomeUsers.pendingPlexPINRequest,
               request.accountID == account.id, request.homeUserID == user.id {
                selectionRequest = request
                appModel.inlinePlexPINRequest = request
            }
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: user.avatarURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .plozzForeground(.secondary)
                }
                .frame(width: 40, height: 40)
                .clipShape(Circle())
                Text(verbatim: user.name)
                    .foregroundStyle(.primary)
                if user.requiresPIN {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .plozzForeground(.secondary)
                }
                Spacer()
                if pendingSelection?.homeUserID == user.id {
                    if appModel.plexHomeUsers.plexPINEntryAvailability == .checking {
                        ProgressView().accessibilityHidden(true)
                    }
                } else if isSelected(user) {
                    Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .settingsActionRow()
        .disabled(pendingSelection != nil)
        .accessibilityIdentifier("plex-user-\(user.id)")
        .accessibilityValue(accessibilityValue(for: user))
    }

    private func accessibilityValue(for user: PlexHomeUser) -> Text {
        if pendingSelection?.homeUserID == user.id {
            return appModel.plexHomeUsers.plexPINEntryAvailability == .checking
                ? Text("Loading") : appModel.plexHomeUsers.plexPINError.map(Text.init) ?? Text(verbatim: "")
        }
        return isSelected(user) ? Text("Selected") : Text(verbatim: "")
    }

    private func isSelected(_ user: PlexHomeUser) -> Bool {
        let binding = appModel.profiles.activeProfile.homeUserBinding(forPlexAccount: account.id)
        return binding?.homeUserID == user.id || (binding == nil && user.isAdmin)
    }

    private func releaseSelection() {
        if appModel.inlinePlexPINRequest == selectionRequest { appModel.inlinePlexPINRequest = nil }
        selectionRequest = nil
    }
}
#endif
