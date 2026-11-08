#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

public struct ProfileChip: View {
    public let profile: Profile
    @Environment(\.themePalette) private var palette

    public init(profile: Profile) { self.profile = profile }

    public var body: some View {
        HStack(spacing: 8) {
            ProfileAvatarView(profile: profile, size: avatarSize)
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
        .accessibilityElement(children: .combine)
    }

    private var avatarSize: CGFloat {
        #if os(iOS)
        28
        #else
        44
        #endif
    }
}
#endif
