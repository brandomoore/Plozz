#if canImport(SwiftUI)
import CoreModels
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
    private let phase: InitialSetupRestorationPhase
    private let activity: InitialSetupRestorationActivity?
    private let onRetry: () -> Void
    private let onSetUpManually: () -> Void
    private var hasFailed: Bool { phase == .unavailable }

    public init(
        phase: InitialSetupRestorationPhase, activity: InitialSetupRestorationActivity? = nil,
        onRetry: @escaping () -> Void,
        onSetUpManually: @escaping () -> Void
    ) {
        self.phase = phase
        self.activity = activity
        self.onRetry = onRetry
        self.onSetUpManually = onSetUpManually
    }

    public var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 32) {
                    if phase != .checking && phase != .hidden {
                        if hasFailed || reduceMotion {
                            Image(systemName: hasFailed ? "icloud.slash" : "icloud")
                                .font(.largeTitle)
                                .accessibilityHidden(true)
                        } else {
                            ProgressView()
                                .controlSize(.large)
                                .accessibilityHidden(true)
                        }
                        OnboardingHeader(heading)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityFocused($headingFocused)
                        if let visibleActivity {
                            Text(visibleActivity.restorationMessage)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("icloud-restoration-activity")
                        }
                        Group {
                            if hasFailed {
                                Text("Check your connection and iCloud sign-in, or set up manually.")
                            } else if phase == .slow {
                                Text("Taking longer than expected. You can wait or set up manually.")
                            }
                        }
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        if hasFailed || phase == .slow {
                            ICloudRestorationActions(
                                hasFailed: hasFailed, onRetry: onRetry, onSetUpManually: onSetUpManually
                            )
                            .id(phase)
                            Text("Manual setup pauses restoration until you're finished. iCloud Sync stays on.")
                                .font(.footnote)
                                .plozzForeground(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                .frame(maxWidth: 760)
                .padding(32)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .background { AppBackground(palette: palette) }
        .accessibilityIdentifier("icloud-restoration")
        .task(id: phase) {
            headingFocused = phase != .checking && phase != .hidden
        }
        .onChange(of: visibleActivity) { previous, current in
            guard previous != nil, let current else { return }
            AccessibilityNotification.Announcement(String(localized: current.restorationMessage)).post()
        }
    }

    private var visibleActivity: InitialSetupRestorationActivity? {
        phase == .restoring || phase == .slow ? activity : nil
    }

    private var heading: Text {
        switch phase {
        case .unavailable: Text("Couldn't restore your setup")
        case .stopping: Text("Preparing manual setup…")
        default: Text("Restoring setup from iCloud…")
        }
    }
}

private extension InitialSetupRestorationActivity {
    var restorationMessage: LocalizedStringResource {
        switch self {
        case .checkingICloud: "Checking iCloud…"
        case .profilesAndSettings: "Restoring profiles and settings…"
        case .servers: "Restoring servers…"
        case .liveTVSources: "Restoring Live TV sources…"
        case .signingInToServers: "Signing in to servers…"
        }
    }
}

private struct ICloudRestorationActions: View {
    let hasFailed: Bool
    let onRetry: () -> Void
    let onSetUpManually: () -> Void
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
            Button("Set up manually", action: onSetUpManually)
                .plozzActionButton(role: .secondary)
                .focused($focusedAction, equals: .proceed)
                .accessibilityIdentifier("icloud-restoration-manual")
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
