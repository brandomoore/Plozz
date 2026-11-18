import CoreUI
import SwiftUI

public struct AutomaticSignInSettings {
    public let isEnabled: Binding<Bool>
    public let error: LocalizedStringResource?

    public init(
        isEnabled: Binding<Bool>,
        error: LocalizedStringResource? = nil
    ) {
        self.isEnabled = isEnabled
        self.error = error
    }
}

public struct AutomaticSignInToggle: View {
    private let settings: AutomaticSignInSettings
    private let showsDescription: Bool

    public init(settings: AutomaticSignInSettings, showsDescription: Bool = true) {
        self.settings = settings
        self.showsDescription = showsDescription
    }

    public var body: some View {
        Group {
            if showsDescription {
                SettingsDescribedControl {
                    toggle
                } description: {
                    Text("Sign in to the last-used profile automatically on this device.")
                }
            } else {
                toggle
            }
        }
        .settingsSearchAnchor("automatic-sign-in")
    }

    private var toggle: some View {
        Toggle("Automatically Sign In", isOn: settings.isEnabled)
            .accessibilityIdentifier("profiles.automaticallySignIn")
    }
}

public struct AutomaticSignInErrorMessage: View {
    private let settings: AutomaticSignInSettings

    public init(settings: AutomaticSignInSettings) {
        self.settings = settings
    }

    public var body: some View {
        if let error = settings.error {
            Text(error)
                .foregroundStyle(.red)
        }
    }
}
