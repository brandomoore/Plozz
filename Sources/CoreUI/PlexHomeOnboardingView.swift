#if canImport(SwiftUI)
import CoreModels
import CoreNetworking
import SwiftUI

public enum PlexHomeProfileImportResult: Equatable, Sendable {
    case added, existing, failed
}

/// One Plex Home decision followed by the viewer's identity, without authenticating
/// any of the other profiles being imported.
public struct PlexHomeOnboardingView: View {
    private let users: [PlexHomeUser]
    private let onSelect: (PlexHomeUser, Bool) -> Void
    private let onImportAll: () -> PlexHomeProfileImportResult

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        users: [PlexHomeUser],
        onImportAll: @escaping () -> PlexHomeProfileImportResult,
        onSelect: @escaping (PlexHomeUser, Bool) -> Void
    ) {
        self.users = users
        self.onImportAll = onImportAll
        self.onSelect = onSelect
    }

    public var body: some View {
        PlexHomeOnboardingContent(
            users: users, reduceMotion: reduceMotion, onImportAll: onImportAll, onSelect: onSelect
        )
    }
}

struct PlexHomeOnboardingContent: View {
    let users: [PlexHomeUser]
    let reduceMotion: Bool
    let onSelect: (PlexHomeUser, Bool) -> Void
    let onImportAll: () -> PlexHomeProfileImportResult
    private enum Stage: Hashable { case choice, added, existing, allProfiles, oneUser }
    @State private var stage: Stage = .choice
    @State private var importFailed = false
    @FocusState private var focused: String?

    init(
        users: [PlexHomeUser], reduceMotion: Bool,
        onImportAll: @escaping () -> PlexHomeProfileImportResult,
        onSelect: @escaping (PlexHomeUser, Bool) -> Void
    ) {
        self.users = users
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
            profileAvatars
            OnboardingHeader(Text("Add your Plex Home profiles?"))
            VStack(spacing: 16) {
                Button("Add all profiles") {
                    importFailed = false
                    switch onImportAll() {
                    case .added: stage = .added
                    case .existing: stage = .existing
                    case .failed: importFailed = true
                    }
                }
                    .plozzActionButton(role: .primary)
                    .focused($focused, equals: "add-all")
                    .accessibilityIdentifier("plex-home-add-all")
                Button("Just me") { stage = .oneUser }
                    .plozzActionButton(role: .secondary)
                    .accessibilityIdentifier("plex-home-just-me")
            }
            if importFailed {
                Text("Couldn't add profiles. Try again.")
                    .plozzForeground(.secondary)
            }
        }
    }

    private var importConfirmation: some View {
        VStack(spacing: 28) {
            profileAvatars
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

    private var profileAvatars: some View {
        WrappingHStackLayout(alignment: .center, spacing: 12, lineSpacing: 12) {
            ForEach(orderedUsers) { user in
                PlexHomeUserAvatar(user: user, size: previewAvatarSize)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: user.name))
                    .accessibilityAddTraits(.isImage)
                    .accessibilityIdentifier("plex-home-preview-\(user.id)")
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
                        onSelect(user, addAllProfiles)
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
            if !addAllProfiles {
                Button("Back") { stage = .choice }
                    .plozzActionButton(role: .secondary)
                    .accessibilityIdentifier("plex-home-back")
            }
        }
        #if os(tvOS)
        .onExitCommand {
            if !addAllProfiles { stage = .choice }
        }
        #endif
    }
}
#endif
