import Observation

/// Presentation for the first opt-in only; dismissing it leaves automatic sync running.
@MainActor
@Observable
public final class InitialSetupRestoration {
    public enum Phase: Equatable {
        case hidden
        case restoring
        case unavailable
    }

    public private(set) var phase: Phase = .hidden
    @ObservationIgnored private var task: Task<Void, Never>?

    public init() {}

    public func start(operation: @escaping @MainActor () async -> Bool) {
        guard task == nil else { return }
        phase = .restoring
        task = Task { [weak self] in
            let completed = await operation()
            guard let self else { return }
            task = nil
            guard phase == .restoring else { return }
            phase = completed ? .hidden : .unavailable
        }
    }

    public func dismiss() {
        phase = .hidden
    }

    func waitForCompletion() async {
        await task?.value
    }
}
