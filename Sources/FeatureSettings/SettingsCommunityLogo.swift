#if canImport(SwiftUI)
import CoreUI
import SwiftUI

public struct SettingsCommunityLogo: View {
    public enum Brand: String, CaseIterable, Sendable {
        case discord = "DiscordLockup"
        case github = "GitHubLockup"
    }

    private let brand: Brand
    private let height: CGFloat

    public init(brand: Brand, height: CGFloat) {
        self.brand = brand
        self.height = height
    }

    public var body: some View {
        Image(brand.rawValue)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: logoHeight * aspectRatio, maxHeight: logoHeight, alignment: .leading)
            .frame(height: height, alignment: .leading)
            .plozzForeground(.primary)
            .accessibilityHidden(true)
    }

    private var logoHeight: CGFloat {
        // Discord's denser, wider artwork needs 75% height to match GitHub's visible ink area.
        height * (brand == .discord ? 0.75 : 1)
    }

    private var aspectRatio: CGFloat {
        brand == .discord ? 635.303 / 96 : 416.0 / 95
    }
}
#endif
