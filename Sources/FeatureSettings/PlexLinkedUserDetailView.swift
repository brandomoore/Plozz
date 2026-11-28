#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Settings → Plex User picker.
///
/// Lists the Plex Home users reachable from each signed-in Plex account, with
/// the user's real Plex avatar, so the user can change which Plex Home user
/// the active profile plays as. The runtime authenticates the requested user
/// before saving the mapping, including when the target is the account owner.
struct PlexLinkedUserDetailView: View {
    let scope: ProfileLibrariesScope
    let accountID: String
    var canManage: () -> Bool = { true }

    @State private var users: [PlexHomeUser] = []
    @State private var loading = true

    private var plexAccounts: [Account] {
        scope.accounts.filter { $0.server.provider == .plex && scope.isAccountIncludedInActiveProfile($0.id) }
    }

    private var account: Account? {
        canManage() ? plexAccounts.first { $0.id == accountID } : nil
    }

    /// Signing in a SECOND Plex account on this server.
    ///
    /// Different from the Home users above, which all belong to the one account
    /// listed. Someone whose Plex login isn't in that Home — a housemate with
    /// their own Plex account and their own watchlist — has to sign in, and this
    /// is where they'd come looking. Mirrors the Jellyfin/Emby page so both
    /// providers answer "who am I here?" the same way.
    @ViewBuilder
    private func addAccountPanel(_ account: Account) -> some View {
        SettingsPanel {
            Button {
                guard self.account?.id == account.id else { return }
                scope.onAddUser(account.server)
            } label: {
                Label("Add Another Plex Account", systemImage: "person.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SettingsFocusButtonStyle(size: .prominent))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                SettingsPageHeader("Plex Home")
                if let account {
                    let admin = users.first(where: { $0.isAdmin })
                    let managed = users.filter { !$0.isAdmin }
                    SettingsPanel(
                        title: "On \(account.server.name)",
                        footer: "PIN-protected users must unlock when their Plozz profile becomes active."
                    ) {
                        // Rows separated by a gap rather than flush dividers so
                        // the focus lift doesn't paint over a divider line.
                        VStack(spacing: 14) {
                            ownerRow(admin: admin, account: account)
                            if loading && users.isEmpty {
                                HStack(spacing: 12) {
                                    ProgressView()
                                    Text("Loading Plex users…")
                                        .plozzForeground(.secondary)
                                }
                                .padding(.vertical, 16)
                            } else if managed.isEmpty {
                                Text(users.isEmpty
                                     ? "No Plex Home users found for this account."
                                     : "No managed users on this Plex account.")
                                    .plozzForeground(.secondary)
                                    .padding(.vertical, 12)
                            } else {
                                ForEach(managed) { user in
                                    userRow(user, account: account)
                                }
                            }
                        }
                    }
                    addAccountPanel(account)
                } else {
                    ContentUnavailableView("Source unavailable", systemImage: "person.crop.circle.badge.xmark")
                        .focusable()
                }
            }
            .frame(maxWidth: PlozzTheme.Metrics.settingsContentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
        .task(id: account?.id) {
            guard let account else { return }
            loading = true
            let result = await scope.plexHomeUsersFetcher(account.id)
            guard !Task.isCancelled, self.account?.id == account.id else { return }
            users = result
            loading = false
        }
    }

    private func isOwnerSelected(_ admin: PlexHomeUser?) -> Bool {
        guard let account else { return true }
        let binding = scope.activeProfile.homeUserBinding(forPlexAccount: account.id)
        return binding == nil || binding?.homeUserID == admin?.id
    }

    private func ownerRow(admin: PlexHomeUser?, account: Account) -> some View {
        Button {
            guard let admin, self.account?.id == account.id else { return }
            scope.onSelectPlexHomeUser(account.id, admin)
        } label: {
            if let admin {
                // Same shared row as the managed users, flagged as the owner.
                PlexHomeUserRow(
                    user: admin,
                    showsOwnerBadge: true,
                    accessory: isOwnerSelected(admin) ? .selected : .none
                )
            } else {
                HStack(spacing: 16) {
                    ZStack {
                        Circle().fill(ProviderIcon.tint(.plex).opacity(0.18))
                        Image(systemName: "person.crop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(ProviderIcon.tint(.plex))
                    }
                    .frame(width: 52, height: 52)
                    .overlay(Circle().strokeBorder(ProviderIcon.tint(.plex).opacity(0.45), lineWidth: 1.5))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Account owner").font(.headline)
                            Text("Account owner")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(ProviderIcon.tint(.plex).opacity(0.18)))
                                .foregroundStyle(ProviderIcon.tint(.plex))
                        }
                    }
                    Spacer()
                    if isOwnerSelected(admin) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .settingsRowGreenIndicator()
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(SettingsFocusButtonStyle())
        .disabled(admin == nil)
    }

    private func userRow(_ user: PlexHomeUser, account: Account) -> some View {
        let isSelected = scope.activeProfile.homeUserBinding(forPlexAccount: account.id)?.homeUserID == user.id
        return Button {
            guard self.account?.id == account.id else { return }
            scope.onSelectPlexHomeUser(account.id, user)
        } label: {
            PlexHomeUserRow(user: user, accessory: isSelected ? .selected : .none)
        }
        .buttonStyle(SettingsFocusButtonStyle())
    }
}
#endif
