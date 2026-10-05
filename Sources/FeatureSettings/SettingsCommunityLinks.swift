#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

public struct SettingsCommunityLinks: View {
    private let repoURL: String

    public init(repoURL: String = AppLinks.repository.absoluteString) {
        self.repoURL = repoURL
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                codes
            }
            VStack(spacing: 24) {
                codes
            }
        }
    }

    @ViewBuilder
    private var codes: some View {
        code(
            lockup: "DiscordLockup",
            caption: "Join the community",
            url: AppLinks.discord.absoluteString,
            accessibilityLabel: "Scan to join the Plozz Discord community"
        )
        code(
            lockup: "GitHubLockup",
            caption: "Source code and issues",
            url: repoURL,
            accessibilityLabel: "Scan to view the Plozz GitHub repository"
        )
    }

    private func code(
        lockup: String,
        caption: LocalizedStringKey,
        url: String,
        accessibilityLabel: LocalizedStringKey
    ) -> some View {
        SettingsPanel {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) {
                    identity(lockup: lockup, caption: caption)
                    qrCode(url)
                }
                VStack(alignment: .leading, spacing: 24) {
                    identity(lockup: lockup, caption: caption)
                    qrCode(url)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(idealWidth: 560, maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private func identity(
        lockup: String,
        caption: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(lockup)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 260, maxHeight: 40, alignment: .leading)
                .plozzForeground(.primary)
                .accessibilityHidden(true)
            Text(caption)
                .font(.caption)
                .plozzForeground(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
    }

    private func qrCode(_ url: String) -> some View {
        SettingsQRCode(string: url, centerMark: nil)
            .frame(width: 180, height: 180)
            .accessibilityHidden(true)
    }
}
#endif
