import CoreUI
import FeatureSyncCloud

@MainActor
public enum CloudSyncRecoveryFeedback {
    public static func run(
        _ action: CloudSyncRecoveryAction,
        status: CloudSyncStatus,
        presenter: TransientStatusPresenter,
        operation: @Sendable () async -> CloudSyncRecoveryResult
    ) async {
        guard !status.isRecovering else { return }
        presenter.present(
            icon: "icloud",
            text: action.progressMessage,
            isProgress: true
        )
        guard let result = await status.recover(operation: operation) else { return }
        presenter.present(
            icon: result == .completed ? "checkmark.circle" : "exclamationmark.triangle",
            text: action.message(for: result)
        )
    }
}
