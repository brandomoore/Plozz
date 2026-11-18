#if canImport(SwiftUI)
import CoreUI
import SwiftUI

public struct DiagnosticsInfoButton: View {
    @State private var showsInformation = false

    public init() {}

    public var body: some View {
        Button {
            showsInformation = true
        } label: {
            Label("About Diagnostic Sharing", systemImage: "info")
                .labelStyle(.iconOnly)
                .modifier(DiagnosticsControlLabelSize())
        }
        .plozzActionButton(role: .secondary)
        .buttonBorderShape(.circle)
        .controlSize(.regular)
        .modifier(DiagnosticsControlSize(isCircular: true))
        .accessibilityIdentifier("diagnostics-information-button")
        .plozzSheet(isPresented: $showsInformation) {
            DiagnosticsInformationView()
        }
    }
}

struct DiagnosticsControlLabelSize: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            // The label must accept the proposal for native glass to fill the control.
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

struct DiagnosticsControlSize: ViewModifier {
    var isCircular = false
    @ScaledMetric(relativeTo: .body) private var height = 44

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content
                .buttonSizing(.flexible)
                .fixedSize(horizontal: !isCircular, vertical: false)
                .frame(width: isCircular ? height : nil, height: height)
        } else {
            content.frame(minWidth: 44, minHeight: 44)
        }
        #else
        content.frame(minWidth: 44, minHeight: 44)
        #endif
    }
}

private struct DiagnosticsInformationView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Automatic Reports").font(.headline)
                        Text(SettingsCopy.automaticDiagnostics)
                        Text(SettingsCopy.automaticDiagnosticsExclusions)
                        Text("Sharing is optional. Change anytime in Settings > Help & Diagnostics.")
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Manual Reports").font(.headline)
                        Text(SettingsCopy.manualDiagnostics)
                    }
                    PrivacyPolicyLink()
                        .plozzActionButton(role: .secondary)
                }
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .padding(24)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Diagnostic Sharing")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
#endif
