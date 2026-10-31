#if canImport(SwiftUI)
import CoreModels
import SwiftUI

/// Shared playback chrome. Hosts retain ownership of recovery, navigation and focus.
public struct PlaybackFailureView<Actions: View>: View {
    private let title: LocalizedStringResource
    private let message: LocalizedStringResource
    private let systemImage: String
    private let report: PlaybackDiagnosticReport?
    private let recoveryHint: LocalizedStringResource?
    private let actions: Actions
    @State private var showsDetails = false

    public init(
        title: LocalizedStringResource = "Can’t play this right now",
        message: LocalizedStringResource,
        systemImage: String = "exclamationmark.triangle",
        report: PlaybackDiagnosticReport?,
        recoveryHint: LocalizedStringResource? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.report = report
        self.recoveryHint = recoveryHint
        self.actions = actions()
    }

    public var body: some View {
        RecoveryScreen {
            PlaybackFailureHeading(
                title: title, message: message, systemImage: systemImage, recoveryHint: recoveryHint
            )
        } actions: { _ in
            PlaybackFailureDetailsButton(isAvailable: report != nil, showsDetails: $showsDetails)
            actions
        }
        .accessibilityIdentifier("playback-failure")
        .plozzSheet(isPresented: $showsDetails) {
            if let report { PlaybackDiagnosticDetailsSheet(report: report) }
        }
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark)
    }
}

private struct PlaybackFailureHeading: View {
    let title: LocalizedStringResource
    let message: LocalizedStringResource
    let systemImage: String
    let recoveryHint: LocalizedStringResource?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(.yellow)
                    .fixedSize()
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("playback-failure-message")
            if let recoveryHint {
                Text(recoveryHint)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("playback-failure-hint")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PlaybackFailureDetailsButton: View {
    let isAvailable: Bool
    @Binding var showsDetails: Bool

    var body: some View {
        if isAvailable {
            Button("Details", systemImage: "info.circle") { showsDetails = true }
                .plozzActionButton(role: .secondary)
                .accessibilityIdentifier("playback-failure-details")
        }
    }
}
#endif
