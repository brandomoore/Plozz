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
        let note = CrashDiagnostics.normalizedNote(message)
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
                hasMessage: note != nil, isSending: isSending
            ) {
                guard !isSending, let note else { return }
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
            else if note == nil && !message.isEmpty { Text(SettingsCopy.diagnosticsDescriptionRequired) }
        }
        .onChange(of: sharingEnabled) { status = nil }
    }
}
#endif

public struct IssueDiagnosticSubmissionForm: DiagnosticSubmissionFormProviding {
    private let sharingEnabled: Binding<Bool>
    private let isConfigured: Bool
    private let submit: @MainActor (String, PlaybackDiagnosticReport) async -> Bool

    public init(
        sharingEnabled: Binding<Bool>, isConfigured: Bool,
        submit: @escaping @MainActor (String, PlaybackDiagnosticReport) async -> Bool = {
            await CrashDiagnostics.send(note: $0, issue: $1)
        }
    ) {
        self.sharingEnabled = sharingEnabled
        self.isConfigured = isConfigured
        self.submit = submit
    }

    public func form(for report: PlaybackDiagnosticReport) -> AnyView {
        AnyView(SendDiagnosticsCard(sharingEnabled: sharingEnabled, isConfigured: isConfigured) { note in
            await submit(note, report)
        })
    }
}

struct SendDiagnosticsCard: View {
    @Binding var sharingEnabled: Bool
    let isConfigured: Bool
    var submit: @MainActor (String) async -> Bool = { await CrashDiagnostics.send(note: $0) }
    private enum SendState { case idle, sent, failed }
    @State private var sendState: SendState = .idle
    @State private var isSending = false
    @State private var message: String = ""   // l10n:content — user-typed message text
    #if os(iOS)
    @FocusState private var editing: Bool
    #endif

    var body: some View {
        let note = CrashDiagnostics.normalizedNote(message)
        SettingsPanel(title: "Send Diagnostics", footer: footer) {
            VStack(alignment: .leading, spacing: 18) {
                #if os(iOS)
                TextField(text: $message, axis: .vertical) { Text(SettingsCopy.diagnosticsMessage) }
                    .lineLimit(2...4)
                    .focused($editing)
                    .accessibilityIdentifier("diagnostics-message")
                    .disabled(!isConfigured || isSending)
                #else
                TextField(text: $message) {
                    Text(SettingsCopy.diagnosticsMessage)
                }
                .accessibilityIdentifier("diagnostics-message")
                .disabled(!isConfigured || isSending)
                #endif

                HStack(spacing: 16) {
                    DiagnosticsSendButton(
                        sharingEnabled: $sharingEnabled, isConfigured: isConfigured,
                        hasMessage: note != nil,
                        isSending: isSending, isSubmitted: sendState == .sent
                    ) {
                        guard !isSending, sendState != .sent, sharingEnabled, let note else { return }
                        #if os(iOS)
                        editing = false
                        #endif
                        isSending = true
                        sendState = .idle
                        Task {
                            defer { isSending = false }
                            let ok = await submit(note)
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
                } else if note == nil && !message.isEmpty {
                    Text(SettingsCopy.diagnosticsDescriptionRequired).settingsHelperText()
                }
            }
        }
        .onChange(of: message) { if !message.isEmpty { sendState = .idle } }
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
