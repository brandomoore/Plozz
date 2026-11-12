#if canImport(SwiftUI)
import CoreUI
import SwiftUI

public struct ICloudSetupUnavailableView: View {
    private let onRetry: () -> Void

    public init(onRetry: @escaping () -> Void) {
        self.onRetry = onRetry
    }

    public var body: some View {
        VStack(spacing: 24) {
            OnboardingHeader(Text("Unable to load settings"))
                .accessibilityAddTraits(.isHeader)
            Text("Try again to continue without changing your iCloud preference.")
                .multilineTextAlignment(.center)
            Button("Retry", action: onRetry)
                .plozzActionButton()
        }
        .padding(32)
    }
}

public struct ICloudOnboardingView: View {
    @Environment(\.themePalette) private var palette
    private let onChoice: (Bool) -> Void

    public init(onChoice: @escaping (Bool) -> Void) {
        self.onChoice = onChoice
    }

    public var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 32) {
                    Image(systemName: "icloud")
                        .font(.largeTitle)
                        .accessibilityHidden(true)
                    OnboardingHeader(Text("iCloud Sync"))
                        .accessibilityAddTraits(.isHeader)
                    Text("Keep profiles, settings, watchlist, and supported sign-ins in sync across your devices.")
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    ICloudOnboardingChoices(onChoice: onChoice)
                    Text("You can change this in Settings.")
                        .font(.footnote)
                        .plozzForeground(.secondary)
                }
                .frame(maxWidth: 760)
                .padding(32)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .background { AppBackground(palette: palette) }
        .accessibilityIdentifier("icloud-onboarding")
    }
}

private struct ICloudOnboardingChoices: View {
    let onChoice: (Bool) -> Void
    @FocusState private var useCloudFocused: Bool

    var body: some View {
        VStack(spacing: 20) {
            Button("Enable iCloud Sync") { onChoice(true) }
                .plozzActionButton()
                .focused($useCloudFocused)
                .accessibilityIdentifier("icloud-onboarding-enable")
            Button("Not now") { onChoice(false) }
                .plozzActionButton(role: .secondary)
                .accessibilityIdentifier("icloud-onboarding-decline")
        }
        .controlSize(.large)
        #if os(tvOS)
        .focusSection()
        .defaultFocus($useCloudFocused, true)
        .onAppear { useCloudFocused = true }
        #endif
    }
}
#endif
