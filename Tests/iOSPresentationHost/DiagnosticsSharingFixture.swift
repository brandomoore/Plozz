import CoreUI
import CrashReporting
import FeatureSettings
import SwiftUI

struct DiagnosticsSharingFixture: View {
    @State private var sharingEnabled = ProcessInfo.processInfo.arguments.contains("--diagnostics-enabled")
    @State private var message = ProcessInfo.processInfo.arguments.contains("--diagnostics-with-message")
        ? "Search returned no matches" : ""
    @State private var submissions = 0
    private let isConfigured = !ProcessInfo.processInfo.arguments.contains("--diagnostics-unavailable")

    var body: some View {
        NavigationStack {
            List {
                SettingsSectionGroup {
                    Toggle(isOn: $sharingEnabled) { Text(SettingsCopy.shareDiagnostics) }
                        .disabled(!isConfigured)
                        .accessibilityIdentifier("diagnostics-sharing-toggle")
                }
                SettingsSectionGroup("Send Diagnostics", accessory: { DiagnosticsInfoButton() }) {
                    TextField(text: $message, axis: .vertical) { Text(SettingsCopy.diagnosticsMessage) }
                        .lineLimit(2...4)
                        .accessibilityIdentifier("diagnostics-message")
                        .disabled(!isConfigured)
                    DiagnosticsSendButton(
                        sharingEnabled: $sharingEnabled, isConfigured: isConfigured,
                        hasMessage: CrashDiagnostics.normalizedNote(message) != nil,
                        isSending: ProcessInfo.processInfo.arguments.contains("--diagnostics-sending"),
                        isSubmitted: ProcessInfo.processInfo.arguments.contains("--diagnostics-submitted")
                    ) { submissions += 1 }
                } footer: {
                    if !isConfigured {
                        Text(SettingsCopy.diagnosticSharingUnavailable)
                    } else if !sharingEnabled {
                        Text(SettingsCopy.diagnosticSharingRequired)
                    }
                    Text(SettingsCopy.diagnosticsMessagePrivacy)
                }
            }
            .settingsPageSurface()
            .navigationTitle("Help & Diagnostics")
        }
        .overlay(alignment: .bottomLeading) {
            Text(verbatim: "\(submissions)")
                .foregroundStyle(.clear)
                .accessibilityIdentifier("diagnostics-submission-count")
                .allowsHitTesting(false)
        }
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Locale(identifier: "en_US"))
        .preferredColorScheme(.dark)
    }
}
