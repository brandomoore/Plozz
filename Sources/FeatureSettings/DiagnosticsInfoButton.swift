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
            Label("About Diagnostic Sharing", systemImage: "info.circle")
                .labelStyle(.iconOnly)
                .font(.body)
                .frame(minWidth: 44, minHeight: 44)
        }
        #if os(tvOS)
        .buttonStyle(.bordered)
        #else
        .buttonStyle(.borderless)
        #endif
        .accessibilityIdentifier("diagnostics-information-button")
        .plozzSheet(isPresented: $showsInformation) {
            DiagnosticsInformationView()
        }
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
