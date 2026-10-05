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
            title: "Discord",
            mark: "DiscordMark",
            brandColor: Color(red: 88 / 255, green: 101 / 255, blue: 242 / 255),
            caption: "Join the community",
            url: AppLinks.discord.absoluteString,
            accessibilityLabel: "Scan to join the Plozz Discord community"
        )
        code(
            title: "GitHub",
            mark: "GitHubMark",
            brandColor: .black,
            caption: "Source code and issues",
            url: repoURL,
            accessibilityLabel: "Scan to view the Plozz GitHub repository"
        )
    }

    private func code(
        title: String,
        mark: String,
        brandColor: Color,
        caption: LocalizedStringKey,
        url: String,
        accessibilityLabel: LocalizedStringKey
    ) -> some View {
        SettingsPanel {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) {
                    identity(title: title, mark: mark, brandColor: brandColor, caption: caption)
                    qrCode(url)
                }
                VStack(alignment: .leading, spacing: 24) {
                    identity(title: title, mark: mark, brandColor: brandColor, caption: caption)
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
        title: String,
        mark: String,
        brandColor: Color,
        caption: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(mark)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .foregroundStyle(.white)
                .padding(12)
                .background(brandColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text(verbatim: title)
                .font(.headline)
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
