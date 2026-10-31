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
        Toggle(isOn: settings.isEnabled) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Automatically Sign In")
                if showsDescription {
                    Text("Sign in to the last-used profile automatically on this device.")
                        .font(.footnote)
                        .settingsRowSecondary()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
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
