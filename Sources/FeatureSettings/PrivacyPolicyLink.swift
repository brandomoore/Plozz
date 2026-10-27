#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

public struct PrivacyPolicyLink: View {
    #if os(tvOS)
    @State private var showsPolicy = false
    #endif

    public init() {}

    public var body: some View {
        Group {
            #if os(tvOS)
            Button {
                showsPolicy = true
            } label: {
                policyLabel
            }
            .plozzSheet(isPresented: $showsPolicy) {
                PrivacyPolicyQRCodeView()
            }
            #else
            Link(destination: AppLinks.privacyPolicy) {
                policyLabel
            }
            #endif
        }
        .accessibilityIdentifier("privacy-policy-link")
    }

    private var policyLabel: some View {
        Label("Privacy Policy", systemImage: "hand.raised")
    }
}

#if os(tvOS)
struct PrivacyPolicyQRCodeView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Scan to read how Plozz and its connected services handle your data.")
                        .fixedSize(horizontal: false, vertical: true)
                    SettingsQRCode(string: AppLinks.privacyPolicy.absoluteString, correctionLevel: .low, centerMark: nil)
                        .frame(width: 240, height: 240)
                        .frame(maxWidth: .infinity)
                    Text(verbatim: AppLinks.privacyPolicy.absoluteString)
                        .font(.footnote)
                }
                .padding(32)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Privacy Policy")
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
