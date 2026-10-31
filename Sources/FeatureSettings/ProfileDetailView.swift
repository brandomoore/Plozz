#if os(tvOS)
import SwiftUI
import CoreModels
import CoreUI
import FeatureProfiles

/// Device-wide access preferences and household profile management.
struct ProfileDetailView: View {
    let context: SettingsContext
    let appVersion: String
    let appBuild: String
    let repoURL: String

    @State private var showingNewProfile = false

    var body: some View {
        ProfileSettingsContent(
            profiles: context.profiles,
            activeProfileID: context.activeProfile.id,
            automaticSignIn: context.automaticSignIn,
            onAddProfile: { showingNewProfile = true }
        )
        .plozzSheet(isPresented: $showingNewProfile) {
            ProfileEditorView(
                canDelete: false,
                photoSourceAccounts: context.accounts,
                existingColorIndices: context.profiles.map(\.colorIndex),
                existingEmojiAvatars: context.profiles.compactMap(\.avatarEmoji),
                plexHomeUsersFetcher: context.plexHomeUsersFetcher,
                onSave: { draft in
                    // Same path as the picker: create, switch in, then the
                    // app-level setup step. Routing both through one call is what
                    // stops a profile created here from skipping setup.
                    context.onCreateProfile(draft)
                    showingNewProfile = false
                },
                onCancel: { showingNewProfile = false }
            )
        }
    }
}

struct ProfileSettingsContent: View {
    let profiles: [Profile]
    let activeProfileID: String
    let automaticSignIn: AutomaticSignInSettings
    let onAddProfile: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsFormMetrics.sectionSpacing) {
                SettingsPageHeader("Profiles")
                ProfileAccessSettingsGroup(automaticSignIn: automaticSignIn)
                ProfilesSettingsList(
                    profiles: profiles,
                    activeProfileID: activeProfileID,
                    onAddProfile: onAddProfile
                )
            }
            .padding(.horizontal, SettingsFormMetrics.pageInset)
            .padding(.top, SettingsFormMetrics.pageTopInset)
            .padding(.bottom, SettingsFormMetrics.pageBottomInset)
        }
        .scrollClipDisabled()
    }
}

private struct ProfileAccessSettingsGroup: View {
    let automaticSignIn: AutomaticSignInSettings

    var body: some View {
        SettingsControlGroup {
            VStack(alignment: .leading, spacing: SettingsFormMetrics.relatedControlSpacing) {
                AutomaticSignInToggle(settings: automaticSignIn, showsDescription: false)
                    .settingsWorkspaceEntry()
                AutomaticSignInErrorMessage(settings: automaticSignIn)
                    .settingsHelperText()
            }
        }
        .tvOSFocusSection()
        .accessibilityIdentifier("profiles.accessSettings")
    }
}

private struct ProfilesSettingsList: View {
    let profiles: [Profile]
    let activeProfileID: String
    let onAddProfile: () -> Void

    var body: some View {
        SettingsControlGroup(dividerLeadingInset: SettingsRowMetrics.iconTitleInset) {
            ForEach(profiles) { profile in
                SettingsRouteLink(value: SettingsRoute.profileSettings(profileID: profile.id)) {
                    SettingsRowLabel(title: Text(profile.name), icon: {
                        ProfileAvatarView(profile: profile, size: SettingsRowMetrics.iconColumnWidth)
                    }, secondary: {
                        if profile.id == activeProfileID {
                            StatusChip("Active")
                        }
                    }, trailing: {
                        HStack(spacing: 8) {
                            if profile.isKids {
                                Image(systemName: "figure.and.child.holdinghands")
                            }
                            if profile.isLocked {
                                Image(systemName: "lock.fill")
                            }
                            Image(systemName: "chevron.forward")
                        }
                        .font(.caption)
                        .settingsRowSecondary()
                    })
                }
                .accessibilityIdentifier("profiles.manage.\(profile.id)")
            }
            Button(action: onAddProfile) {
                SettingsRowLabel(icon: "plus.circle", title: "Add Profile")
            }
            .accessibilityIdentifier("profiles.add")
        }
        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
        .tvOSFocusSection()
        .accessibilityIdentifier("profiles.list")
    }
}
#endif
