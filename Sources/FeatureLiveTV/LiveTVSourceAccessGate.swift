import CoreModels
import CoreUI
import Observation
import SwiftUI

struct LiveTVSourceAccessGate<Content: View>: View {
    let model: LiveTVSourceManagementModel
    var unrestrictedContent: AnyView? = nil
    var isProfileAuthorized: @MainActor () -> Bool = { true }
    @ViewBuilder let content: (@escaping @MainActor () -> Bool) -> Content
    @Environment(ProfilesModel.self) private var profiles: ProfilesModel?

    var body: some View {
        if let profiles {
            LiveTVProfileSourceAccessGate(
                model: model, profiles: profiles, unrestrictedContent: unrestrictedContent,
                isProfileAuthorized: isProfileAuthorized, content: content
            )
        } else {
            VStack(alignment: .leading, spacing: 24) {
                ContentUnavailableView(
                    "Profile settings unavailable",
                    systemImage: "lock",
                    description: Text("Return to Live TV and reopen Sources.")
                )
                unrestrictedContent
            }
        }
    }
}

struct LiveTVLibraryChannelAccessGate<Content: View>: View {
    @ViewBuilder let content: (@escaping @MainActor () -> Bool) -> Content
    @Environment(ProfilesModel.self) private var profiles: ProfilesModel?

    var body: some View {
        if let profiles {
            LiveTVProfileSourceAccessGate(model: nil, profiles: profiles, content: content)
        } else {
            ContentUnavailableView(
                "Profile settings unavailable",
                systemImage: "lock",
                description: Text("Return to Live TV and reopen Sources.")
            )
        }
    }
}

private struct LiveTVProfileSourceAccessGate<Content: View>: View {
    let model: LiveTVSourceManagementModel?
    @State private var access: LiveTVSourceManagementAccess
    let unrestrictedContent: AnyView?
    let isProfileAuthorized: @MainActor () -> Bool
    @ViewBuilder let content: (@escaping @MainActor () -> Bool) -> Content
    @SettingsPageDismiss private var dismiss
    @State private var unlocking = false

    init(
        model: LiveTVSourceManagementModel?,
        profiles: ProfilesModel,
        unrestrictedContent: AnyView? = nil,
        isProfileAuthorized: @escaping @MainActor () -> Bool = { true },
        @ViewBuilder content: @escaping (@escaping @MainActor () -> Bool) -> Content
    ) {
        self.model = model
        _access = State(initialValue: LiveTVSourceManagementAccess(profiles: profiles))
        self.unrestrictedContent = unrestrictedContent
        self.isProfileAuthorized = isProfileAuthorized
        self.content = content
    }

    var body: some View {
        Group {
            if access.canManage {
                content { [weak access, isProfileAuthorized] in
                    access?.canManage == true && isProfileAuthorized()
                }
            } else if let unrestrictedContent {
                VStack(alignment: .leading, spacing: 24) {
                    SettingsSectionGroup(SettingsCopy.tvSources) {
                        Button("Unlock TV sources", systemImage: "lock") { unlocking = true }
                            .buttonStyle(SettingsFormButtonStyle())
                            .accessibilityIdentifier("live-tv-unlock-sources")
                    }
                    unrestrictedContent
                }
            } else {
                unlockForm
            }
        }
        .settingsPageDestination(isPresented: $unlocking) { unlockForm }
        .onAppear {
            model?.authorizeMutations { [weak access, isProfileAuthorized] in
                access?.canManage == true && isProfileAuthorized()
            }
        }
    }

    private var unlockForm: some View {
        PINEntryScaffold(
            title: KidsProfileCopy.parentalPINEnter,
            name: Text(KidsProfileCopy.parentalPIN),
            errorMessage: access.errorMessage,
            onSubmit: {
                access.unlock($0)
                if access.canManage { unlocking = false }
            },
            onCancel: {
                if unrestrictedContent != nil { unlocking = false }
                else { dismiss() }
            }
        ) {
            PINBadge {
                Image(systemName: "figure.and.child.holdinghands")
                    .font(.system(size: PINLayout.badgeSize * 0.45, weight: .semibold))
            }
        }
    }
}

@MainActor
@Observable
final class LiveTVSourceManagementAccess {
    private struct Scope: Equatable {
        let profileID: String
        let selectionGeneration: Int
        let lockRevision: ProfileLockRevision?
        let kidsRevision: ProfileLockRevision?

        @MainActor init(_ profiles: ProfilesModel) {
            profileID = profiles.activeProfileID
            selectionGeneration = profiles.selectionGeneration
            let profile = profiles.activeProfile
            lockRevision = profile.effectiveLockRevision
            kidsRevision = profile.effectiveKidsProfileRevision
        }
    }

    @ObservationIgnored private let profiles: ProfilesModel
    private let initialScope: Scope
    private var unlockedPIN: ParentalPIN?
    private(set) var errorMessage: LocalizedStringResource?

    init(profiles: ProfilesModel) {
        self.profiles = profiles
        initialScope = Scope(profiles)
    }

    var canManage: Bool {
        guard Scope(profiles) == initialScope else { return false }
        guard profiles.activeProfile.isKids, let pin = profiles.parentalPIN else { return true }
        return unlockedPIN == pin
    }

    func unlock(_ pin: String) {
        guard Scope(profiles) == initialScope, profiles.matchesParentalPIN(pin) else {
            errorMessage = ProfileLockCopy.incorrectPIN
            return
        }
        unlockedPIN = profiles.parentalPIN
        errorMessage = nil
    }

    func lock() {
        unlockedPIN = nil
        errorMessage = nil
    }
}
