#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

public struct CrashReportingConsentView: View {
    @Environment(\.themePalette) private var palette

    private let onChoice: (Bool) -> Void

    public init(onChoice: @escaping (Bool) -> Void) {
        self.onChoice = onChoice
    }

    public var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 32)
                    SettingsPanel(contentPadding: cardPadding) {
                        CrashReportingConsentPrompt(onChoice: onChoice)
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("diagnostics-consent-card")
                    Spacer(minLength: 72)
                    CrashReportingConsentFooter()
                }
                .frame(maxWidth: contentWidth)
                .padding(32)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollClipDisabled()
        }
        .background { AppBackground(palette: palette) }
        .accessibilityIdentifier("diagnostics-consent")
    }

    private var contentWidth: CGFloat {
        #if os(tvOS)
        900
        #else
        480
        #endif
    }

    private var cardPadding: EdgeInsets {
        #if os(tvOS)
        let inset = PlozzTheme.Spacing.xxxLarge
        return EdgeInsets(top: inset, leading: inset, bottom: inset, trailing: inset)
        #else
        return .settingsPanelDefault
        #endif
    }
}

private struct CrashReportingConsentPrompt: View {
    let onChoice: (Bool) -> Void

    var body: some View {
        VStack(spacing: 28) {
            Image("PlozzLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)

            VStack(spacing: 16) {
                OnboardingHeader(Text("Help improve Plozz?"))
                Text("Send diagnostics when something goes wrong to help improve reliability and performance.")
                    .font(.body)
            }
            .plozzForeground(.primary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            CrashReportingConsentChoices(onChoice: onChoice)
        }
    }
}

private struct CrashReportingConsentChoices: View {
    let onChoice: (Bool) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) {
                shareButton
                declineButton
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(spacing: 16) {
                shareButton
                declineButton
            }
        }
        .controlSize(.large)
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private var shareButton: some View {
        Button { onChoice(true) } label: { Text(SettingsCopy.shareDiagnostics) }
            .fixedSize(horizontal: false, vertical: true)
            .plozzActionButton(role: .primary)
            .accessibilityIdentifier("diagnostics-consent-share")
    }

    private var declineButton: some View {
        Button("Don't Share") { onChoice(false) }
            .fixedSize(horizontal: false, vertical: true)
            .plozzActionButton(role: .secondary)
            .accessibilityIdentifier("diagnostics-consent-decline")
    }
}

private struct CrashReportingConsentFooter: View {
    #if os(tvOS)
    @State private var showingRepository = false
    #endif
    @ScaledMetric(relativeTo: .body) private var iconSize = 20

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Text(SettingsCopy.automaticDiagnostics)
                Text(SettingsCopy.automaticDiagnosticsExclusions)
                Text("Sharing is optional. Change anytime in Settings > Help & Diagnostics.")
            }
            .font(.footnote)
            .plozzForeground(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            PrivacyPolicyLink()
                .plozzActionButton(role: .secondary)
                .controlSize(.small)

            Group {
                #if os(tvOS)
                Button {
                    showingRepository = true
                } label: {
                    repositoryLabel
                }
                #else
                Link(destination: AppLinks.repository) {
                    repositoryLabel
                }
                #endif
            }
            .plozzActionButton(role: .secondary)
            .controlSize(.small)
            .accessibilityIdentifier("diagnostics-consent-repository")
        }
        #if os(tvOS)
        .plozzSheet(isPresented: $showingRepository) {
            CrashReportingConsentRepositoryView()
        }
        #endif
    }

    private var repositoryLabel: some View {
        Label {
            Text("Open GitHub repo")
        } icon: {
            Image("GitHubMark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
        }
    }
}

#if os(tvOS)
private struct CrashReportingConsentRepositoryView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(SettingsCopy.automaticDiagnostics)
                    Text(SettingsCopy.automaticDiagnosticsExclusions)
                    Text("Sharing is optional and does not change any app features. Sending recent activity logs is a separate action in Settings.")
                    Text("Scan to open the Plozz GitHub repo.")
                    SettingsQRCode(string: AppLinks.repository.absoluteString, correctionLevel: .low)
                        .frame(width: 240, height: 240)
                        .frame(maxWidth: .infinity)
                    Text(AppLinks.repository.absoluteString)
                        .font(.footnote)
                }
                .padding(32)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Plozz on GitHub")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
#endif
#endif
