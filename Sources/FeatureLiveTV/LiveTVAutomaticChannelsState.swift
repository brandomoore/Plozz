import CoreModels
import CoreUI
import FeatureLiveTVCore
import Observation
import SwiftUI

public struct LiveTVAutomaticChannelsState {
    public let enabled: Bool
    public let isWorking: Bool
    public let issue: LibraryChannelError?
    public let channelCount: Int
    public let skippedItemCount: Int
    public let unavailableSources: [LibraryChannelSourceFailure]
    public let preparation: LibraryChannelPreparationProgress?
    public let setEnabled: @MainActor (Bool) async -> Void
    public let retry: @MainActor () -> Void

    public init(
        enabled: Bool, isWorking: Bool, issue: LibraryChannelError?,
        channelCount: Int, skippedItemCount: Int,
        setEnabled: @escaping @MainActor (Bool) async -> Void,
        retry: @escaping @MainActor () -> Void,
        unavailableSources: [LibraryChannelSourceFailure] = [],
        preparation: LibraryChannelPreparationProgress? = nil
    ) {
        self.enabled = enabled
        self.isWorking = isWorking
        self.issue = issue
        self.channelCount = channelCount
        self.skippedItemCount = skippedItemCount
        self.setEnabled = setEnabled
        self.retry = retry
        self.unavailableSources = unavailableSources
        self.preparation = preparation
    }

    var needsEmptyState: Bool { enabled || isWorking || issue != nil }

    var status: LiveTVAutomaticChannelsStatus {
        if isWorking { return .preparing }
        if let issue { return .failed(issue) }
        if !enabled { return .disabled }
        return channelCount > 0 ? .ready : .empty
    }
}

enum LiveTVAutomaticChannelsStatus: Equatable {
    case disabled, preparing, ready, empty, failed(LibraryChannelError)

    var title: LocalizedStringResource {
        switch self {
        case .disabled: "Your library, on TV"
        case .preparing: "Preparing Plozz channels"
        case .ready: "Your automatic lineup"
        case .empty: "No Plozz channels yet"
        case .failed: "Plozz channels need attention"
        }
    }

    var detail: LocalizedStringResource {
        switch self {
        case .disabled:
            "Create channels from your libraries."
        case .preparing:
            "Building channels from your movies and shows."
        case .ready:
            "Your lineup updates automatically."
        case .empty, .failed(.emptyCatalog):
            "No playable movies or episodes with known durations."
        case .failed(.sourceUnavailable):
            "Couldn't load your libraries."
        case .failed(.catalogChanged):
            "Your library changed. Retry to update the lineup."
        case .failed(let issue):
            issue.message
        }
    }
}

@MainActor
@Observable
final class LiveTVAutomaticChannelsAction {
    private(set) var isUpdating = false

    func setEnabled(
        _ enabled: Bool, state: LiveTVAutomaticChannelsState,
        canManage: @MainActor () -> Bool
    ) async {
        guard !Task.isCancelled, canManage(), !isUpdating,
              !state.isWorking || !enabled, enabled != state.enabled else { return }
        isUpdating = true
        defer { isUpdating = false }
        await state.setEnabled(enabled)
    }

    func retry(state: LiveTVAutomaticChannelsState, canManage: @MainActor () -> Bool) {
        guard canManage(), !isUpdating, !state.isWorking, state.enabled || state.issue != nil else { return }
        state.retry()
    }
}

struct LiveTVAutomaticChannelsSection: View {
    let state: LiveTVAutomaticChannelsState
    let canManage: @MainActor () -> Bool
    @State private var action = LiveTVAutomaticChannelsAction()
    @State private var update: Task<Void, Never>?

    var body: some View {
        SettingsSectionGroup("Automatic lineup") {
            Toggle(isOn: Binding(
                get: { state.enabled },
                set: { enabled in
                    update = Task {
                        await action.setEnabled(enabled, state: state, canManage: canManage)
                    }
                }
            )) {
                Text("Enable Plozz channels")
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(action.isUpdating || (state.isWorking && !state.enabled))
            .accessibilityIdentifier("live-tv-automatic-enabled")
            LiveTVAutomaticChannelsStatusView(state: state)
            if (state.enabled || state.issue != nil), !state.isWorking {
                Button {
                    action.retry(state: state, canManage: canManage)
                } label: {
                    if state.status == .ready {
                        SettingsRowLabel(icon: nil, title: "Refresh Plozz channels")
                    } else {
                        SettingsRowLabel(icon: nil, title: "Retry Plozz channels")
                    }
                }
                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                .disabled(action.isUpdating)
                .accessibilityIdentifier("live-tv-automatic-retry")
            }
        }
        .onDisappear { update?.cancel(); update = nil }
    }
}

struct LiveTVAutomaticChannelsStatusView: View {
    let state: LiveTVAutomaticChannelsState

    var body: some View {
        VStack(alignment: .leading, spacing: PlozzTheme.Spacing.small) {
            if state.isWorking {
                if let preparation = state.preparation {
                    LiveTVPreparationProgressView(progress: preparation)
                } else {
                    ProgressView("Preparing Plozz channels")
                        .accessibilityIdentifier("live-tv-automatic-progress")
                }
            } else {
                Text(state.status.title).font(.headline)
                if state.status != .ready {
                    Text(state.status.detail).settingsRowSecondary()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if state.enabled, state.channelCount > 0 {
                Text("\(state.channelCount) automatic channels")
            }
            if state.skippedItemCount > 0 {
                Text("\(state.skippedItemCount) items skipped: missing duration or metadata.")
                    .settingsRowSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
            LiveTVAutomaticSourceFailures(sources: state.unavailableSources)
        }
    }
}

private struct LiveTVAutomaticSourceFailures: View {
    let sources: [LibraryChannelSourceFailure]

    var body: some View {
        if !sources.isEmpty {
            VStack(alignment: .leading, spacing: PlozzTheme.Spacing.small) {
                ForEach(sources) { source in
                    VStack(alignment: .leading, spacing: PlozzTheme.Spacing.xSmall) {
                        Text(source.serverName).font(.headline)
                        Text(source.reason.compactMessage).settingsRowSecondary()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

struct LiveTVAutomaticChannelsEmptyView: View {
    let state: LiveTVAutomaticChannelsState
    let manage: () -> Void

    var body: some View {
        ContentUnavailableView {
            if state.status == .ready {
                Label("Preparing your guide", systemImage: "calendar")
            } else {
                Label {
                    Text(state.status.title)
                } icon: {
                    Image(systemName: "calendar")
                }
            }
        } description: {
            if state.isWorking, let preparation = state.preparation {
                LiveTVPreparationProgressView(progress: preparation)
                    .frame(maxWidth: 680, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .padding(.top, PlozzTheme.Spacing.medium)
            } else if state.status == .ready {
                Text("Your Plozz channels are enabled. Their programs will appear here when the guide is ready.")
            } else {
                VStack(spacing: PlozzTheme.Spacing.medium) {
                    Text(state.status.detail)
                    LiveTVAutomaticSourceFailures(sources: state.unavailableSources)
                    .frame(maxWidth: 680, alignment: .leading)
                }

            }
        } actions: {
            if state.isWorking, state.preparation == nil {
                ProgressView().accessibilityLabel("Preparing Plozz channels")
            }
            Button(action: manage) {
                Text("Manage Plozz channels")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, PlozzTheme.Spacing.large)
                    .padding(.vertical, PlozzTheme.Spacing.medium)
            }
            .buttonStyle(SettingsFocusButtonStyle(size: .contained))
            .accessibilityIdentifier("live-tv-automatic-manage")
        }
    }
}

private extension LibraryChannelSourceFailure.Reason {
    var compactMessage: LocalizedStringResource {
        switch self {
        case .unreachable: "Couldn't connect. Check the server address."
        case .authorization: "Library access denied. Check your sign-in."
        case .invalidResponse: "Couldn't read the library response."
        case .unknown: "Couldn't load libraries."
        }
    }
}
