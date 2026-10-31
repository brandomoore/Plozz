#if canImport(SwiftUI)
import CoreUI
import SwiftUI

/// Offers consent before sending is available; enabling sharing never submits a report.
public struct DiagnosticsSendButton: View {
    @Binding private var sharingEnabled: Bool
    private let isConfigured: Bool
    private let hasMessage: Bool
    private let isSending: Bool
    private let isSubmitted: Bool
    private let send: () -> Void
    @State private var showingConsent = false

    public init(
        sharingEnabled: Binding<Bool>, isConfigured: Bool, hasMessage: Bool,
        isSending: Bool = false, isSubmitted: Bool = false, send: @escaping () -> Void
    ) {
        _sharingEnabled = sharingEnabled
        self.isConfigured = isConfigured
        self.hasMessage = hasMessage
        self.isSending = isSending
        self.isSubmitted = isSubmitted
        self.send = send
    }

    public var body: some View {
        Button {
            if sharingEnabled {
                send()
            } else {
                showingConsent = true
            }
        } label: {
            Label {
                if isSubmitted {
                    Text("Submitted")
                } else if isConfigured && !sharingEnabled {
                    Text(SettingsCopy.enableDiagnosticSharing)
                } else {
                    Text("Send to Developer")
                }
            } icon: {
                Image(systemName: isSubmitted ? "checkmark.circle.fill" : "paperplane")
            }
        }
        .buttonStyle(.bordered)
        .disabled(!isConfigured || isSending || isSubmitted || (sharingEnabled && !hasMessage))
        .accessibilityIdentifier(isConfigured && !sharingEnabled ? "diagnostics-enable-sharing" : "diagnostics-submit")
        .plozzSheet(isPresented: $showingConsent) {
            CrashReportingConsentView { enabled in
                if isConfigured { sharingEnabled = enabled }
                showingConsent = false
            }
        }
    }
}
#endif
