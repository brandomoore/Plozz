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
            brand: .discord,
            caption: "Join the community",
            url: AppLinks.discord.absoluteString,
            accessibilityLabel: "Scan to join the Plozz Discord community"
        )
        code(
            brand: .github,
            caption: "Source code and issues",
            url: repoURL,
            accessibilityLabel: "Scan to view the Plozz GitHub repository"
        )
    }

    private func code(
        brand: SettingsCommunityLogo.Brand,
        caption: LocalizedStringKey,
        url: String,
        accessibilityLabel: LocalizedStringKey
    ) -> some View {
        SettingsPanel {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) {
                    identity(brand: brand, caption: caption)
                    qrCode(url)
                }
                VStack(alignment: .leading, spacing: 24) {
                    identity(brand: brand, caption: caption)
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
        brand: SettingsCommunityLogo.Brand,
        caption: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsCommunityLogo(brand: brand, height: 40)
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
