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

public struct ICloudRestorationView: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var headingFocused: Bool
    private let hasFailed: Bool
    private let onRetry: () -> Void
    private let onContinue: () -> Void

    public init(hasFailed: Bool, onRetry: @escaping () -> Void, onContinue: @escaping () -> Void) {
        self.hasFailed = hasFailed
        self.onRetry = onRetry
        self.onContinue = onContinue
    }

    public var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 32) {
                    if hasFailed || reduceMotion {
                        Image(systemName: hasFailed ? "icloud.slash" : "icloud")
                            .font(.largeTitle)
                            .accessibilityHidden(true)
                    } else {
                        ProgressView()
                            .controlSize(.large)
                            .accessibilityHidden(true)
                    }
                    OnboardingHeader(hasFailed
                        ? Text("Couldn't restore your setup")
                        : Text("Restoring your setup…"))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($headingFocused)
                    Group {
                        if hasFailed {
                            Text("Check your connection and iCloud sign-in, or continue with manual setup.")
                        } else {
                            Text("You can continue while iCloud Sync finishes.")
                        }
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    ICloudRestorationActions(hasFailed: hasFailed, onRetry: onRetry, onContinue: onContinue)
                        .id(hasFailed)
                }
                .frame(maxWidth: 760)
                .padding(32)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .background { AppBackground(palette: palette) }
        .accessibilityIdentifier("icloud-restoration")
        .task(id: hasFailed) {
            headingFocused = true
        }
    }
}

private struct ICloudRestorationActions: View {
    let hasFailed: Bool
    let onRetry: () -> Void
    let onContinue: () -> Void
    private enum Action: Hashable { case retry, proceed }
    @FocusState private var focusedAction: Action?

    var body: some View {
        VStack(spacing: 20) {
            if hasFailed {
                Button("Retry", action: onRetry)
                    .plozzActionButton()
                    .focused($focusedAction, equals: .retry)
                    .accessibilityIdentifier("icloud-restoration-retry")
            }
            Button("Continue", action: onContinue)
                .plozzActionButton(role: .secondary)
                .focused($focusedAction, equals: .proceed)
                .accessibilityIdentifier("icloud-restoration-continue")
        }
        .controlSize(.large)
        #if os(tvOS)
        .focusSection()
        .defaultFocus($focusedAction, hasFailed ? .retry : .proceed)
        .onAppear { focusedAction = hasFailed ? .retry : .proceed }
        #endif
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
