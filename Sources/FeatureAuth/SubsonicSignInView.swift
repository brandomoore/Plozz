import CoreModels
import CoreUI
import FeatureAuthCore
import SwiftUI

public struct SubsonicSignInView: View {
    @State private var model: SubsonicAuthViewModel
    private let showsCancelButton: Bool
    private let onCancel: () -> Void

    public init(
        deviceID: String, address: String = "", username: String = "", showsCancelButton: Bool = true,
        onAuthenticated: @escaping (UserSession) throws -> Void, onCancel: @escaping () -> Void
    ) {
        _model = State(initialValue: SubsonicAuthViewModel(
            deviceID: deviceID, address: address, username: username, onAuthenticated: onAuthenticated
        ))
        self.showsCancelButton = showsCancelButton
        self.onCancel = onCancel
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                ProviderBrandMark(provider: .subsonic, size: 72).accessibilityHidden(true)
                OnboardingHeader(Text(verbatim: ProviderKind.subsonic.displayName))
                SettingsSectionGroup {
                    TextField("Server address", text: $model.address)
                        .textContentType(.URL)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("subsonic-address")
                }
                .disabled(model.isConnecting)
                SettingsSectionGroup {
                    TextField("Username", text: $model.username)
                        .textContentType(.username)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("subsonic-username")
                    Picker("Sign in with", selection: $model.usesAPIKey) {
                        Text("Password").tag(false)
                        Text("API Key").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("subsonic-auth-method")
                    .onChange(of: model.usesAPIKey) { _, _ in model.password = "" }
                    if model.usesAPIKey {
                        SecureField("API key", text: $model.password)
                            .accessibilityIdentifier("subsonic-secret")
                    } else {
                        SecureField("Password", text: $model.password)
                            .textContentType(.password)
                            .accessibilityIdentifier("subsonic-secret")
                    }
                } footer: {
                    if model.usesAPIKey {
                        Text("Requires a server that supports API keys.")
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("subsonic-api-key-help")
                    }
                }
                .disabled(model.isConnecting)
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(action: model.signIn) {
                    Group {
                        if model.isConnecting { ProgressView("Signing in…") }
                        else { Text("Sign In") }
                    }
                    .frame(maxWidth: .infinity)
                    .plozzPageActionLabel()
                }
                .plozzPageActionButton()
                .disabled(!model.canSubmit)
                .accessibilityIdentifier("subsonic-sign-in")
                if showsCancelButton {
                    Button(role: .cancel, action: cancel) {
                        Text("Cancel").frame(maxWidth: .infinity).plozzPageActionLabel()
                    }
                    .plozzPageActionButton(role: .secondary)
                    .accessibilityIdentifier("subsonic-cancel")
                }
            }
            .controlSize(.large)
            #if os(iOS)
            .frame(maxWidth: 640)
            .padding(20)
            #else
            .frame(maxWidth: 840)
            .padding(32)
            #endif
            .frame(maxWidth: .infinity)
        }
        .background { SettingsPageBackground() }
        .onDisappear { model.cancel() }
        #if os(tvOS)
        .onExitCommand(perform: cancel)
        #endif
    }

    private func cancel() { model.cancel(); onCancel() }
}
