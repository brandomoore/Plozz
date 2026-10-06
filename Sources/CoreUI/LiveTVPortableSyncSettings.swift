import CoreModels
import SwiftUI

/// Place inside the existing Sync settings, using the same profile environment.
/// `isAvailable` describes real composition/storage availability, not sign-in guesses.
public struct LiveTVPortableSyncSettings: View {
    private let isAvailable: Bool?
    private let status: LocalizedStringResource?
    @Environment(ProfilesModel.self) private var profiles: ProfilesModel?

    public init(isAvailable: Bool? = nil, status: LocalizedStringResource? = nil) {
        self.isAvailable = isAvailable
        self.status = status
    }

    public var body: some View {
        if let profiles {
            LiveTVProfilePortableSyncSettings(
                isAvailable: isAvailable ?? LiveTVPortableSyncPresentation.shared.isAvailable(profiles: profiles),
                status: status ?? LiveTVPortableSyncPresentation.shared.summary(profileID: profiles.activeProfileID)
            )
            .id(profiles.activeProfileID)
        } else {
            Text("Live TV sync is unavailable.").settingsRowSecondary()
        }
    }
}

private struct LiveTVProfilePortableSyncSettings: View {
    let isAvailable: Bool
    let status: LocalizedStringResource?
    @AppStorage(SyncSetupFeatureFlag.storageKey) private var cloudEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !cloudEnabled {
                Text("Turn on iCloud Sync to sync Live TV.").settingsRowSecondary()
            } else if !isAvailable {
                Text("Live TV sync is unavailable on this device.").settingsRowSecondary()
            } else {
                if let status { Text(status).settingsRowSecondary() }
                Text("Live TV follows iCloud Sync for each profile. Playlist and guide addresses, imported playlists, channel settings and library schedules sync. Addresses and imported files use encrypted iCloud storage. Parental approvals stay on each device.")
                    .settingsRowSecondary()
            }
        }
    }
}
