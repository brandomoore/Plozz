#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
#if canImport(UIKit)
import UIKit
#endif

/// Footer panel for Settings showing app identity, release notes, open-source
/// info, and QR codes for Discord and GitHub. Its two explicit rows provide
/// focus targets, so the surrounding informational card does not need focus.
struct SettingsAboutSection: View {
    let version: String
    let build: String
    let repoURL: String
    let showsReleaseNotes: Bool
    /// Invoked on each remote-select of the panel — drives the hidden Developer
    /// Mode unlock (seven selects). `nil` leaves the panel inert.
    var onActivate: (() -> Void)? = nil
    var compact = false

    var body: some View {
        if compact {
            compactContent
        } else {
            expandedContent
        }
    }

    private var compactContent: some View {
        VStack(spacing: 12) {
            SettingsPanel(contentPadding: .settingsPanelRowContent) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 20) {
                        if let onActivate {
                            Button(action: onActivate) { compactIdentity }
                                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                        } else {
                            compactIdentity
                        }
                        Spacer(minLength: 12)
                        if showsReleaseNotes {
                            SettingsRouteLink(value: SettingsRoute.releaseNotes) {
                                Label("Release Notes", systemImage: "doc.text")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    Text("Bring all of your media together into one unified experience. Free forever and open source.")
                        .settingsHelperText()
                        .fixedSize(horizontal: false, vertical: true)
                    PrivacyPolicyLink()
                        .buttonStyle(.bordered)
                }
            }
            SettingsCommunityLinks(repoURL: repoURL, compact: true)
        }
        .accessibilityIdentifier("settings-about-summary")
    }

    private var compactIdentity: some View {
        HStack(spacing: 16) {
            Image("PlozzLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Version \(version)").font(SettingsRowMetrics.titleFont)
                Text("Build \(build)")
                    .font(SettingsRowMetrics.helperFont)
                    .settingsRowSecondary()
            }
        }
        .padding(8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Version \(version), build \(build)")
    }

    private var expandedContent: some View {
        VStack(spacing: 24) {
            SettingsPanel {
                VStack(alignment: .leading, spacing: 16) {
                    Image("PlozzLogo")
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: 72, height: 72)

                    if let onActivate {
                        Button(action: onActivate) {
                            versionRow
                        }
                        .buttonStyle(SettingsFocusButtonStyle())
                    } else {
                        versionRow
                    }

                    if showsReleaseNotes {
                        SettingsRouteLink(value: SettingsRoute.releaseNotes) {
                            SettingsRowLabel(
                                icon: "doc.text",
                                title: "Release Notes",
                                trailing: {
                                    Image(systemName: "chevron.forward")
                                        .font(.caption.weight(.semibold))
                                        .settingsRowSecondary()
                                }
                            )
                        }
                        .buttonStyle(SettingsFocusButtonStyle())
                    }

                    Text("Bring all of your media together into one unified experience. Free forever and open source.")
                        .font(.callout)
                        .plozzForeground(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    PrivacyPolicyLink()
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            SettingsCommunityLinks(repoURL: repoURL)
        }
    }

    private var versionRow: some View {
        SettingsRowLabel(
            icon: "number",
            title: "Version \(version) (Build \(build))"
        )
        .accessibilityLabel("Version \(version), build \(build)")
    }
}

#endif
