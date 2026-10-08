#if canImport(SwiftUI)
import CoreModels
import CoreUI
import FeatureProfiles
import SeerService
import SwiftUI

/// Profile-setup step for the household Seerr connection and per-profile acting
/// user.
///
/// One screen serves first run and every later profile. If Seerr is disconnected,
/// it can be enabled here; once connected, the adult chooses which Seerr user owns
/// this profile's requests. Kids Profiles never offer the unrestricted admin.
public struct ProfileSeerrSetupView: View {
    private let seer: SeerService
    private let profile: Profile
    private let onSelect: (SeerUser?) -> Void
    private let onContinue: () -> Void

    @Environment(\.themePalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var serverAddress = ""
    @State private var apiKey = ""
    @State private var users: LoadState<[SeerUser]> = .idle
    @State private var selectedUser: SeerUser?
    @State private var selectedAdmin = false
    @State private var didPrefill = false

    public init(
        seer: SeerService,
        profile: Profile,
        onSelect: @escaping (SeerUser?) -> Void,
        onContinue: @escaping () -> Void
    ) {
        self.seer = seer
        self.profile = profile
        self.onSelect = onSelect
        self.onContinue = onContinue
    }

    public var body: some View {
        page
        .environment(\.colorScheme, palette.isLight ? .light : .dark)
        .task(id: seer.connectionRevision) {
            let revision = seer.connectionRevision
            if !didPrefill {
                didPrefill = true
                serverAddress = seer.savedBaseURLString ?? ""
            }
            selectedUser = nil
            selectedAdmin = false
            users = .idle
            await seer.refreshStatus()
            guard !Task.isCancelled, seer.connectionRevision == revision else {
                return
            }
            if seer.isConfigured {
                await loadUsers(for: revision)
            }
        }
    }

    @ViewBuilder
    private var page: some View {
        #if os(iOS)
        SettingsPageScroll {
            pageContent
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        #else
        ZStack {
            AppBackground(palette: palette).ignoresSafeArea()
            ScrollView {
                pageContent
                .frame(
                    maxWidth: PlozzTheme.Metrics.settingsContentMaxWidth,
                    alignment: .leading
                )
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 48)
                .padding(.vertical, 32)
            }
            .scrollClipDisabled()
        }
        #endif
    }

    private var pageContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        heading
                        profileChip
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 12) {
                        heading
                        profileChip
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Text("Choose whose Seerr permissions, quota, approvals, and quality profile this Plozz profile uses.")
                    .font(.subheadline)
                    .plozzForeground(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            switch seer.phase {
            case .connected:
                connectedContent
            default:
                connectionContent
            }
            actionBar
        }
    }

    private var heading: some View {
        Text(
            "Requests as",
            comment: "Heading in profile setup followed by a separate avatar-and-name chip identifying the Plozz profile whose Seerr request identity is being configured. It is a standalone heading, not an action or a sentence fragment to translate together with the name."
        )
        #if os(iOS)
        .font(.title2.bold())
        #else
        .font(.largeTitle.bold())
        #endif
        .plozzForeground(.primary)
    }

    private var profileChip: some View {
        HStack(spacing: 8) {
            ProfileAvatarView(profile: profile, size: profileAvatarSize)
                .accessibilityHidden(true)
            Text(verbatim: profile.name)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .plozzForeground(.primary)
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .background(palette.cardSurface, in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(palette.cardBorder, lineWidth: 1)
        }
    }

    private var profileAvatarSize: CGFloat {
        #if os(iOS)
        28
        #else
        44
        #endif
    }

    private var panelPadding: EdgeInsets {
        #if os(iOS)
        EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        #else
        .settingsPanelDefault
        #endif
    }

    private var connectionContent: some View {
        SettingsPanel(
            title: "Connect Seerr",
            footer: "Seerr is shared by every Plozz profile. The acting user is chosen separately for each profile.",
            contentPadding: panelPadding
        ) {
            VStack(alignment: .leading, spacing: 16) {
                TextField(
                    "Server address (e.g. https://requests.example.com)",
                    text: $serverAddress
                )
                .textContentType(.URL)
                #if os(tvOS) || os(iOS)
                .keyboardType(.URL)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
                #endif

                SecureField("Admin API key", text: $apiKey)
                    .textContentType(.password)
                    #if os(tvOS) || os(iOS)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    #endif

                if case .connecting = seer.phase {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Connecting…").plozzForeground(.secondary)
                    }
                } else {
                    Button {
                        connect()
                    } label: {
                        Label("Connect", systemImage: "link")
                    }
                    .buttonStyle(SettingsFocusButtonStyle(size: .prominent))
                    .disabled(!canConnect)
                }

                if case let .failed(message) = seer.phase {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private var connectedContent: some View {
        SettingsPanel(
            footer: profile.isKids
                ? "Kids Profiles must use a Seerr user. Admin requests are unavailable."
                : "Admin is unrestricted. Choose a user to use their quota and approval flow instead.",
            contentPadding: panelPadding
        ) {
            VStack(spacing: 14) {
                if !profile.isKids {
                    selectionRow(
                        title: Text("Admin — unrestricted"),
                        subtitle: Text("No per-user quota or approval."),
                        avatarURL: nil,
                        fallback: "person.crop.circle.badge.checkmark",
                        selected: selectedAdmin
                    ) {
                        selectedUser = nil
                        selectedAdmin = true
                    }
                }

                switch users {
                case .idle, .loading:
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Loading Seerr users…").plozzForeground(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 16)
                case .failed:
                    Button {
                        Task { await loadUsers(for: seer.connectionRevision) }
                    } label: {
                        Label("Retry loading users", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(SettingsFocusButtonStyle())
                case .empty:
                    VStack(alignment: .leading, spacing: 10) {
                        if profile.seerrRequestIdentity.userID != nil {
                            Label(
                                "Relink required. Choose a user from this Seerr server.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(.orange)
                        }
                        Text("No Seerr users found.")
                            .plozzForeground(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
                case let .loaded(list):
                    if profileNeedsRelink {
                        Label(
                            "Relink required. Choose a user from this Seerr server.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(list) { user in
                        selectionRow(
                            title: Text(verbatim: user.name),
                            subtitle: user.subtitle.map { Text(verbatim: $0) },
                            avatarURL: user.avatarURL,
                            fallback: "person.fill",
                            selected: selectedUser == user
                        ) {
                            guard isCurrentServerUser(user) else { return }
                            selectedUser = user
                            selectedAdmin = false
                        }
                        .disabled(!isCurrentServerUser(user))
                    }
                }
            }
            .tvOSFocusSection()
        }
    }

    private var actionBar: some View {
        actionLayout {
            Button(action: onContinue) {
                actionLabel("Not Now")
            }
            .plozzActionButton(role: .secondary)
            Button {
                if selectedAdmin {
                    onSelect(nil)
                    onContinue()
                    return
                }
                guard let selectedUser, isCurrentServerUser(selectedUser) else {
                    self.selectedUser = nil
                    return
                }
                onSelect(selectedUser)
                onContinue()
            } label: {
                actionLabel("Continue")
            }
            .plozzActionButton()
            .disabled(!canContinue)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .tvOSFocusSection()
    }

    private var actionLayout: AnyLayout {
        #if os(iOS)
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        #else
        AnyLayout(HStackLayout(spacing: 20))
        #endif
    }

    private func actionLabel(_ title: LocalizedStringResource) -> some View {
        Text(title)
            #if os(iOS)
            .lineLimit(nil)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            #endif
    }

    /// - Parameters:
    ///   - title: `Text` rather than `String` because callers pass BOTH app copy
    ///     ("Admin — unrestricted") and provider content (a Seerr user's name); a
    ///     `String` forced the copy case to resolve eagerly and rendered verbatim.
    private func selectionRow(
        title: Text,
        subtitle: Text?,
        avatarURL: URL?,
        fallback: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let portrait = avatar(url: avatarURL, fallback: fallback)
        let indicator = Image(systemName: "checkmark.circle.fill")
            .settingsRowGreenIndicator()
            .opacity(selected ? 1 : 0)
            .accessibilityHidden(true)
        let text = VStack(alignment: .leading, spacing: 3) {
            title.font(.headline)
            if let subtitle {
                subtitle
                    .font(.caption)
                    .settingsRowSecondary()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)

        return Button(action: action) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            portrait
                            Spacer()
                            indicator
                        }
                        text
                    }
                } else {
                    HStack(spacing: 16) {
                        portrait
                        text
                        indicator
                    }
                }
            }
            .padding(.vertical, 12)
            #if !os(iOS)
            .padding(.horizontal, 14)
            #endif
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func avatar(url: URL?, fallback: String) -> some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    default:
                        Image(systemName: fallback)
                    }
                }
            } else {
                Image(systemName: fallback)
            }
        }
        #if os(iOS)
        .frame(width: 44, height: 44)
        #else
        .frame(width: 52, height: 52)
        #endif
        .background(palette.cardSurface, in: Circle())
        .clipShape(Circle())
    }

    private var canConnect: Bool {
        SeerConfig.normalizedBaseURL(from: serverAddress) != nil
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func connect() {
        guard let url = SeerConfig.normalizedBaseURL(from: serverAddress) else { return }
        Task { await seer.connect(baseURL: url, apiKey: apiKey) }
    }

    private var profileNeedsRelink: Bool {
        let identity = profile.seerrRequestIdentity
        guard let userID = identity.userID else { return false }
        guard !identity.requiresRelink(to: seer.serverIdentity),
              let serverIdentity = seer.serverIdentity else {
            return true
        }
        guard let list = users.value else { return false }
        return !list.contains {
            $0.id == userID && $0.serverIdentity == serverIdentity
        }
    }

    private func isCurrentServerUser(_ user: SeerUser) -> Bool {
        guard let serverIdentity = seer.serverIdentity else { return false }
        return user.serverIdentity == serverIdentity
    }

    private var canContinue: Bool {
        selectedAdmin || selectedUser.map { isCurrentServerUser($0) } == true
    }

    private func loadUsers(for revision: UUID) async {
        users = .loading
        do {
            let list = try await seer.users()
            guard seer.connectionRevision == revision else { return }
            users = list.isEmpty ? .empty : .loaded(list)
            let identity = profile.seerrRequestIdentity
            if !selectedAdmin, selectedUser == nil,
               !identity.requiresRelink(to: seer.serverIdentity),
               let userID = identity.userID,
               let serverIdentity = seer.serverIdentity {
                selectedUser = list.first {
                    $0.id == userID && $0.serverIdentity == serverIdentity
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard seer.connectionRevision == revision else { return }
            users = .failed((error as? AppError) ?? .unknown(""))
        }
    }
}
#endif
