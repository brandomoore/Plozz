#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreNetworking
import CoreUI
import CrashReporting

#if os(iOS)
public struct MobileDiagnosticsSubmissionSection: View {
    @Binding private var sharingEnabled: Bool
    @State private var message = ""
    @State private var status: LocalizedStringResource?
    @State private var isSending = false
    @FocusState private var editing: Bool
    private let isConfigured: Bool
    private let submit: @MainActor (String) async -> Bool

    public init(sharingEnabled: Binding<Bool>, isConfigured: Bool, submit: @escaping @MainActor (String) async -> Bool) {
        _sharingEnabled = sharingEnabled
        self.isConfigured = isConfigured
        self.submit = submit
    }

    public var body: some View {
        SettingsSectionGroup("Send Diagnostics", accessory: { DiagnosticsInfoButton() }) {
            TextField(text: $message, axis: .vertical) { Text(SettingsCopy.diagnosticsMessage) }
                .lineLimit(2...4)
                .padding(.vertical, MobileSettingsMetrics.descriptionBottomInset - MobileSettingsMetrics.controlVerticalInset)
                .focused($editing)
                .accessibilityIdentifier("diagnostics-message")
                .disabled(!isConfigured || isSending)
                .onChange(of: message) { if !message.isEmpty { status = nil } }
            DiagnosticsSendButton(
                sharingEnabled: $sharingEnabled, isConfigured: isConfigured,
                hasMessage: CrashDiagnostics.normalizedNote(message) != nil, isSending: isSending
            ) {
                guard !isSending else { return }
                let note = message
                editing = false
                isSending = true
                status = nil
                Task {
                    let sent = await submit(note)
                    if sent { message = "" }
                    status = sent ? "Diagnostics submitted for delivery. Thank you." : SettingsCopy.diagnosticSubmissionFailed
                    isSending = false
                }
            }
            if let status { Text(status).plozzForeground(.secondary) }
        } footer: {
            if !isConfigured { Text(SettingsCopy.diagnosticSharingUnavailable) }
            else if !sharingEnabled { Text(SettingsCopy.diagnosticSharingRequired) }
            Text(SettingsCopy.diagnosticsMessagePrivacy)
        }
        .onChange(of: sharingEnabled) { status = nil }
    }
}
#endif

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
