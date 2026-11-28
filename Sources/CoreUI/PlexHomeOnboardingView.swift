#if canImport(SwiftUI)
import CoreModels
import CoreNetworking
import SwiftUI
#if os(iOS)
import UIKit
#endif

public enum PlexHomeProfileImportResult: Equatable, Sendable {
    case added, existing, failed
}

/// One Plex Home decision followed by the viewer's identity, without authenticating
/// any of the other profiles being imported.
public struct PlexHomeOnboardingView: View {
    private let users: [PlexHomeUser]
    private let serverName: String
    private let existingUserIDs: Set<String>
    private let onSelect: (PlexHomeUser, Bool) -> Bool
    private let onImportAll: () -> PlexHomeProfileImportResult

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        serverName: String, users: [PlexHomeUser], existingUserIDs: Set<String>,
        onImportAll: @escaping () -> PlexHomeProfileImportResult,
        onSelect: @escaping (PlexHomeUser, Bool) -> Bool
    ) {
        self.users = users
        self.serverName = serverName
        self.existingUserIDs = existingUserIDs
        self.onImportAll = onImportAll
        self.onSelect = onSelect
    }

    public var body: some View {
        PlexHomeOnboardingContent(
            serverName: serverName, users: users, existingUserIDs: existingUserIDs,
            reduceMotion: reduceMotion, onImportAll: onImportAll, onSelect: onSelect
        )
    }
}

struct PlexHomeOnboardingContent: View {
    let serverName: String
    let users: [PlexHomeUser]
    let existingUserIDs: Set<String>
    let reduceMotion: Bool
    let onSelect: (PlexHomeUser, Bool) -> Bool
    let onImportAll: () -> PlexHomeProfileImportResult
    private enum Stage: Hashable { case choice, added, existing, allProfiles, oneUser }
    @State private var stage: Stage = .choice
    @State private var importFailed = false
    @State private var expandsExisting = false
    @State private var expandsNew = false
    @FocusState private var focused: String?

    init(
        serverName: String, users: [PlexHomeUser], existingUserIDs: Set<String>, reduceMotion: Bool,
        onImportAll: @escaping () -> PlexHomeProfileImportResult,
        onSelect: @escaping (PlexHomeUser, Bool) -> Bool
    ) {
        self.serverName = serverName
        self.users = users
        self.existingUserIDs = existingUserIDs
        _stage = State(initialValue: users.count == 1 ? .oneUser : .choice)
        self.reduceMotion = reduceMotion
        self.onImportAll = onImportAll
        self.onSelect = onSelect
    }

    private var orderedUsers: [PlexHomeUser] {
        users.sorted {
            if $0.isAdmin != $1.isAdmin { return $0.isAdmin }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var pageTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 16)),
            removal: .opacity.combined(with: .offset(y: -12))
        )
    }

    var body: some View {
        ScrollView {
            ZStack(alignment: .top) {
                switch stage {
                case .allProfiles, .oneUser:
                    userSelection(addAllProfiles: stage == .allProfiles)
                        .transition(pageTransition)
                case .added, .existing:
                    importConfirmation
                        .transition(pageTransition)
                case .choice:
                    importChoice
                        .transition(pageTransition)
                }
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
        .defaultScrollAnchor(.top)
        .defaultScrollAnchor(.center, for: .alignment)
        .animation(
            reduceMotion ? .easeInOut(duration: 0.14) : .smooth(duration: 0.38, extraBounce: 0),
            value: stage
        )
        .task(id: stage) {
            if stage == .added || stage == .existing {
                do {
                    try await Task.sleep(for: .milliseconds(reduceMotion ? 800 : 1_000))
                    guard !Task.isCancelled else { return }
                    stage = .allProfiles
                } catch is CancellationError {
                    return
                } catch {
                    PlozzLog.app.error("Plex Home confirmation transition failed: \(error)")
                    stage = .allProfiles
                }
            } else {
                focused = stage == .choice ? "add-all" : orderedUsers.first?.id
            }
        }
    }

    private var importChoice: some View {
        VStack(spacing: 28) {
            profileGroups
            OnboardingHeader(Text("Who should use \(serverName)?"))
            VStack(spacing: 16) {
                Button {
                    importFailed = false
                    switch onImportAll() {
                    case .added: stage = .added
                    case .existing: stage = .existing
                    case .failed: importFailed = true
                    }
                } label: {
                    if users.count == 2 { Text("Connect both profiles") }
                    else { Text("Connect all \(users.count) profiles") }
                }
                .plozzActionButton(role: .primary)
                .focused($focused, equals: "add-all")
                .accessibilityIdentifier("plex-home-add-all")
                Button("Choose one profile") { importFailed = false; stage = .oneUser }
                    .plozzActionButton(role: .secondary)
                    .accessibilityIdentifier("plex-home-just-me")
            }
            if importFailed { connectionError }
        }
    }

    private var importConfirmation: some View {
        VStack(spacing: 28) {
            Label {
                if stage == .added { Text("Profiles added") }
                else { Text("Profiles ready") }
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .font(.title2.weight(.bold))
            .accessibilityAddTraits(.isHeader)
        }
    }

    private var connectionError: some View {
        Text("Couldn’t connect the selected profiles. Try again.")
            .plozzForeground(.secondary)
    }

    @ViewBuilder private var profileGroups: some View {
        let existing = orderedUsers.filter { existingUserIDs.contains($0.id) }
        let new = orderedUsers.filter { !existingUserIDs.contains($0.id) }
        if !existing.isEmpty && !new.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    avatarGroup(deviceHeading, existing, expanded: $expandsExisting)
                    Divider()
                    avatarGroup(Text("New profiles from Plex"), new, expanded: $expandsNew)
                }
                .fixedSize(horizontal: true, vertical: false)
                VStack(spacing: 20) {
                    avatarGroup(deviceHeading, existing, expanded: $expandsExisting)
                    Divider()
                    avatarGroup(Text("New profiles from Plex"), new, expanded: $expandsNew)
                }
            }
        } else if new.isEmpty {
            avatarGroup(deviceHeading, existing, expanded: $expandsExisting)
        } else {
            avatarGroup(Text("New profiles from Plex"), new, expanded: $expandsNew)
        }
    }

    private var deviceHeading: Text {
        #if os(tvOS)
        Text("Already on this Apple TV")
        #elseif os(iOS)
        switch UIDevice.current.userInterfaceIdiom {
        case .pad: Text("Already on this iPad")
        case .phone: Text("Already on this iPhone")
        default: Text("Already on this device")
        }
        #else
        Text("Already on this device")
        #endif
    }

    private func avatarGroup(_ title: Text, _ members: [PlexHomeUser], expanded: Binding<Bool>) -> some View {
        VStack(spacing: 12) {
            title.font(.headline).accessibilityAddTraits(.isHeader)
            WrappingHStackLayout(alignment: .center, spacing: 10, lineSpacing: 12) {
                ForEach(expanded.wrappedValue || members.count <= 6 ? members : Array(members.prefix(5))) { user in
                    VStack(spacing: 6) {
                        PlexHomeUserAvatar(user: user, size: previewAvatarSize)
                        Text(verbatim: user.name).font(.caption).lineLimit(2)
                    }
                    .frame(width: previewAvatarSize + 36)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: user.name))
                    .accessibilityAddTraits(.isImage)
                    .accessibilityIdentifier("plex-home-preview-\(user.id)")
                }
                if members.count > 6 {
                    Button {
                        expanded.wrappedValue.toggle()
                    } label: {
                        if expanded.wrappedValue { Text("Show fewer") }
                        else { Text("Show \(members.count - 5) more") }
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var previewAvatarSize: CGFloat {
        #if os(tvOS)
        64
        #else
        52
        #endif
    }

    private func userSelection(addAllProfiles: Bool) -> some View {
        VStack(spacing: 24) {
            OnboardingHeader(addAllProfiles ? Text("Choose your profile") : Text("Choose your Plex user"))
            VStack(spacing: 14) {
                ForEach(orderedUsers) { user in
                    Button {
                        importFailed = !onSelect(user, addAllProfiles)
                    } label: {
                        PlexHomeUserRow(user: user, showsOwnerBadge: user.isAdmin)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    #if os(tvOS)
                    .buttonStyle(SettingsFocusButtonStyle())
                    #else
                    .buttonStyle(.plain)
                    #endif
                    .focused($focused, equals: user.id)
                    .accessibilityIdentifier("plex-home-user-\(user.id)")
                }
            }
            if importFailed { connectionError }
            if !addAllProfiles && users.count > 1 {
                Button("Back") { importFailed = false; stage = .choice }
                    .plozzActionButton(role: .secondary)
                    .accessibilityIdentifier("plex-home-back")
            }
        }
        #if os(tvOS)
        .onExitCommand {
            if !addAllProfiles && users.count > 1 { importFailed = false; stage = .choice }
        }
        #endif
    }
}
#endif
