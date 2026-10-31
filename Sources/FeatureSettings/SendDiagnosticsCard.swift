#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreNetworking
import CoreUI
import CrashReporting

/// "Send my recent activity to the developer" card, shared by the Help &
/// Diagnostics page (so it's discoverable without digging) and the Recent
/// Activity page (next to the log it sends).
///
/// Uses the existing diagnostic-sharing consent and transport.
struct SendDiagnosticsCard: View {
    @Binding var sharingEnabled: Bool
    let isConfigured: Bool
    private enum SendState { case idle, sent, failed }
    @State private var sendState: SendState = .idle
    @State private var isSending = false
    @State private var message: String = ""   // l10n:content — user-typed message text

    var body: some View {
        SettingsPanel(title: "Send Diagnostics", footer: footer) {
            VStack(alignment: .leading, spacing: 18) {
                TextField(text: $message) {
                    Text(SettingsCopy.diagnosticsMessage)
                }
                .accessibilityIdentifier("diagnostics-message")
                .disabled(!isConfigured || sendState == .sent || isSending)

                HStack(spacing: 16) {
                    DiagnosticsSendButton(
                        sharingEnabled: $sharingEnabled, isConfigured: isConfigured,
                        hasMessage: CrashDiagnostics.normalizedNote(message) != nil,
                        isSending: isSending, isSubmitted: sendState == .sent
                    ) {
                        let note = message
                        isSending = true
                        Task {
                            defer { isSending = false }
                            let ok = await CrashDiagnostics.send(note: note)
                            sendState = ok ? .sent : .failed
                            if ok { message = "" }
                        }
                    }
                    DiagnosticsInfoButton()
                }

                if !isConfigured {
                    Text(SettingsCopy.diagnosticSharingUnavailable).settingsHelperText()
                } else if !sharingEnabled {
                    Text(SettingsCopy.diagnosticSharingRequired).settingsHelperText()
                }
            }
        }
        .onChange(of: sharingEnabled) { sendState = .idle }
    }

    private var footer: LocalizedStringResource {
        switch sendState {
        case .idle:
            return SettingsCopy.diagnosticsMessagePrivacy
        case .sent:
            return "Diagnostics submitted for delivery. Thank you."
        case .failed:
            return SettingsCopy.diagnosticSubmissionFailed
        }
    }
}
#endif
