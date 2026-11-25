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
        }
        .onChange(of: sharingEnabled) { status = nil }
    }
}
#endif

public struct IssueDiagnosticSubmissionForm: DiagnosticSubmissionFormProviding {
    private let sharingEnabled: Binding<Bool>
    private let isConfigured: Bool

    public init(sharingEnabled: Binding<Bool>, isConfigured: Bool) {
        self.sharingEnabled = sharingEnabled
        self.isConfigured = isConfigured
    }

    public func form(for report: PlaybackDiagnosticReport) -> AnyView {
        AnyView(SendDiagnosticsCard(sharingEnabled: sharingEnabled, isConfigured: isConfigured, issue: report))
    }
}

struct SendDiagnosticsCard: View {
    @Binding var sharingEnabled: Bool
    let isConfigured: Bool
    var issue: PlaybackDiagnosticReport? = nil
    private enum SendState { case idle, sent, failed }
    @State private var sendState: SendState = .idle
    @State private var isSending = false
    @State private var message: String = ""   // l10n:content — user-typed message text
    #if os(iOS)
    @FocusState private var editing: Bool
    #endif

    var body: some View {
        SettingsPanel(title: "Send Diagnostics", footer: footer) {
            VStack(alignment: .leading, spacing: 18) {
                #if os(iOS)
                TextField(text: $message, axis: .vertical) { Text(SettingsCopy.diagnosticsMessage) }
                    .lineLimit(2...4)
                    .focused($editing)
                    .accessibilityIdentifier("diagnostics-message")
                    .disabled(!isConfigured || sendState == .sent || isSending)
                #else
                TextField(text: $message) {
                    Text(SettingsCopy.diagnosticsMessage)
                }
                .accessibilityIdentifier("diagnostics-message")
                .disabled(!isConfigured || sendState == .sent || isSending)
                #endif

                HStack(spacing: 16) {
                    DiagnosticsSendButton(
                        sharingEnabled: $sharingEnabled, isConfigured: isConfigured,
                        hasMessage: CrashDiagnostics.normalizedNote(message) != nil,
                        isSending: isSending, isSubmitted: sendState == .sent
                    ) {
                        guard !isSending, sendState != .sent, sharingEnabled,
                              let note = CrashDiagnostics.normalizedNote(message) else { return }
                        #if os(iOS)
                        editing = false
                        #endif
                        isSending = true
                        Task {
                            defer { isSending = false }
                            let ok = await CrashDiagnostics.send(note: note, issue: issue)
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

    private var footer: LocalizedStringResource? {
        switch sendState {
        case .idle:
            return nil
        case .sent:
            return "Diagnostics submitted for delivery. Thank you."
        case .failed:
            return SettingsCopy.diagnosticSubmissionFailed
        }
    }
}
#endif
