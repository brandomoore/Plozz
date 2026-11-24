import CoreUI
import CrashReporting
import FeatureSettings
import SwiftUI

struct DiagnosticsSharingFixture: View {
    @State private var showsOnboarding = ProcessInfo.processInfo.arguments.contains("--diagnostics-onboarding")
    @State private var sharingEnabled = ProcessInfo.processInfo.arguments.contains("--diagnostics-enabled")
    @State private var message = ProcessInfo.processInfo.arguments.contains("--diagnostics-with-message")
        ? "Search returned no matches" : ""
    @State private var submissions = 0
    private let isConfigured = !ProcessInfo.processInfo.arguments.contains("--diagnostics-unavailable")
    private let isLight = ProcessInfo.processInfo.arguments.contains("--light")

    var body: some View {
        Group {
            if ProcessInfo.processInfo.arguments.contains("--diagnostics-error-details") {
                ContentFailureActions(report: .homeSection(.failed(.serverUnreachable), provider: .jellyfin)) {}
                    .environment(\.diagnosticSubmissionForm, IssueDiagnosticSubmissionForm(
                        sharingEnabled: $sharingEnabled, isConfigured: isConfigured
                    ))
            } else if showsOnboarding {
                CrashReportingConsentView { choice in
                    sharingEnabled = choice
                    showsOnboarding = false
                }
            } else {
                DiagnosticsSharingSettingsFixture(
                    sharingEnabled: $sharingEnabled, message: $message,
                    submissions: $submissions, isConfigured: isConfigured
                )
            }
        }
        .overlay(alignment: .bottomLeading) {
            Text(verbatim: "\(submissions)")
                .foregroundStyle(.clear)
                .accessibilityIdentifier("diagnostics-submission-count")
                .allowsHitTesting(false)
        }
        .environment(\.themePalette, isLight ? .light : .dark)
        .environment(\.colorScheme, isLight ? .light : .dark)
        .environment(\.locale, Locale(identifier: "en_US"))
        .preferredColorScheme(isLight ? .light : .dark)
    }
}

private struct DiagnosticsSharingSettingsFixture: View {
    @Binding var sharingEnabled: Bool
    @Binding var message: String
    @Binding var submissions: Int
    let isConfigured: Bool

    var body: some View {
        NavigationStack {
            List {
                SettingsSectionGroup {
                    Toggle(isOn: $sharingEnabled) { Text(SettingsCopy.shareDiagnostics) }
                        .disabled(!isConfigured)
                        .accessibilityIdentifier("diagnostics-sharing-toggle")
                }
                if !ProcessInfo.processInfo.arguments.contains("--diagnostics-sending"),
                   !ProcessInfo.processInfo.arguments.contains("--diagnostics-submitted") {
                    MobileDiagnosticsSubmissionSection(sharingEnabled: $sharingEnabled, isConfigured: isConfigured) { _ in
                        submissions += 1
                        return !ProcessInfo.processInfo.arguments.contains("--diagnostics-fail")
                    }
                } else {
                    buttonStateFixture
                }
            }
            .settingsPageSurface()
            .navigationTitle("Help & Diagnostics")
        }
    }

    private var buttonStateFixture: some View {
        SettingsSectionGroup("Send Diagnostics", accessory: { DiagnosticsInfoButton() }) {
            TextField(text: $message, axis: .vertical) { Text(SettingsCopy.diagnosticsMessage) }
                .accessibilityIdentifier("diagnostics-message")
            DiagnosticsSendButton(
                sharingEnabled: $sharingEnabled, isConfigured: isConfigured,
                hasMessage: CrashDiagnostics.normalizedNote(message) != nil,
                isSending: ProcessInfo.processInfo.arguments.contains("--diagnostics-sending"),
                isSubmitted: ProcessInfo.processInfo.arguments.contains("--diagnostics-submitted")
            ) { submissions += 1 }
        }
    }
}
