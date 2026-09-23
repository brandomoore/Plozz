#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// A Plex Home user's avatar circle, sized to `size` pt. Renders the user's
/// real Plex `thumb` when reachable, falling back to their initial on a Plex-
/// tinted tile. Shared so every Plex-user surface (Settings picker, first-run
/// onboarding picker) shows an identical avatar.
public struct PlexHomeUserAvatar: View {
    private let user: PlexHomeUser
    private let size: CGFloat

    public init(user: PlexHomeUser, size: CGFloat = 52) {
        self.user = user
        self.size = size
    }

    public var body: some View {
        ServerUserAvatar(provider: .plex, name: user.name, avatarURL: user.avatarURL, size: size)
    }
}

/// The label content for a single Plex Home user row — a 52pt avatar, the
/// user's name, and inline badges (Account owner / PIN required), plus an
/// optional trailing selection checkmark. Designed to sit inside a
/// `Button { } .buttonStyle(SettingsFocusButtonStyle())`, so the Settings Plex-
/// user picker and the first-run onboarding picker render identically.
public struct PlexHomeUserRow: View {
    public typealias Accessory = ServerUserRow.Accessory

    private let user: PlexHomeUser
    private let showsOwnerBadge: Bool
    private let accessory: Accessory

    public init(
        user: PlexHomeUser,
        showsOwnerBadge: Bool = false,
        accessory: Accessory = .none
    ) {
        self.user = user
        self.showsOwnerBadge = showsOwnerBadge
        self.accessory = accessory
    }

    public var body: some View {
        ServerUserRow(
            provider: .plex, name: user.name, avatarURL: user.avatarURL,
            showsOwnerBadge: showsOwnerBadge, requiresPIN: user.requiresPIN, accessory: accessory
        )
    }
}
#endif
