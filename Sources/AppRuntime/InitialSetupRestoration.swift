import Observation
import CoreModels

/// First-run routing stays gated until essential setup is known or sync has paused for manual setup.
@MainActor
@Observable
public final class InitialSetupRestoration {
    public typealias Phase = InitialSetupRestorationPhase

    public private(set) var phase: Phase = .hidden
    public private(set) var activity: InitialSetupRestorationActivity?
    public private(set) var isManualSetupPending: Bool
    public private(set) var completedManualSetupProfileID: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var presentationTask: Task<Void, Never>?
    @ObservationIgnored private var inactivityTask: Task<Void, Never>?
    @ObservationIgnored private var manualSetupTask: Task<Void, Never>?
    @ObservationIgnored private let flag: SyncSetupFeatureFlag
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    @ObservationIgnored private var lastProgress: ContinuousClock.Instant?
    @ObservationIgnored private var generation = 0

    static let progressDelay: Duration = .milliseconds(250)
    static let inactivityDelay: Duration = .seconds(60)
    public var needsRestoration: Bool { flag.isInitialRestorationPending }

    public convenience init(flag: SyncSetupFeatureFlag = .init()) {
        self.init(flag: flag, now: { .now })
    }

    init(flag: SyncSetupFeatureFlag, now: @escaping () -> ContinuousClock.Instant) {
        self.flag = flag
        self.now = now
        self.isManualSetupPending = flag.isManualSetupPending
        self.completedManualSetupProfileID = flag.completedManualSetupProfileID
        if flag.isInitialRestorationPending && !flag.isManualSetupPending {
            phase = .checking
            activity = .checkingICloud
            recordProgress()
        }
    }

    public func start(
        operation: @escaping @MainActor () async -> Bool,
        onRestored: @escaping @MainActor () -> Void = {}
    ) {
        guard task == nil, !isManualSetupPending else { return }
        flag.isInitialRestorationPending = true
        generation += 1
        let current = generation
        phase = .checking
        activity = .checkingICloud
        recordProgress()
        presentationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.progressDelay)
                guard self?.generation == current else { return }
                self?.showProgress()
            } catch is CancellationError {
                return
            } catch {
                assertionFailure("Unexpected restoration clock failure: \(error)")
            }
        }
        task = Task { [weak self] in
            let completed = await operation()
            guard let self, generation == current else { return }
            task = nil
            presentationTask?.cancel()
            presentationTask = nil
            inactivityTask?.cancel()
            inactivityTask = nil
            phase = completed ? .hidden : .unavailable
            activity = nil
            if completed {
                flag.isInitialRestorationPending = false
                onRestored()
            }
        }
    }

    func showProgress() {
        guard phase == .checking else { return }
        phase = .restoring
    }

    func offerManualSetup() {
        guard phase == .checking || phase == .restoring,
              let lastProgress, lastProgress.duration(to: now()) >= Self.inactivityDelay else { return }
        phase = .slow
    }

    /// Only call for observed work, not a spinner, timer, or repeated view update.
    public func recordProgress() {
        guard phase == .checking || phase == .restoring || phase == .slow else { return }
        lastProgress = now()
        if phase == .slow { phase = .restoring }
        inactivityTask?.cancel()
        let current = generation
        inactivityTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.inactivityDelay)
                guard !Task.isCancelled, self?.generation == current else { return }
                self?.offerManualSetup()
            } catch is CancellationError {
                return
            } catch {
                assertionFailure("Unexpected restoration inactivity clock failure: \(error)")
            }
        }
    }

    /// Retained callbacks cannot overwrite a retry, a manual handoff, or normal app content.
    public func activityReporter() -> @MainActor @Sendable (InitialSetupRestorationActivity?) -> Void {
        let current = generation
        return { [weak self] activity in
            guard let self, generation == current,
                  phase == .checking || phase == .restoring || phase == .slow else { return }
            self.activity = activity
            self.recordProgress()
        }
    }

    public func setUpManually(
        pause: @escaping @MainActor () async -> Void,
        onReady: @escaping @MainActor () -> Void = {}
    ) {
        guard phase == .slow || phase == .unavailable else { return }
        flag.isManualSetupPending = true
        flag.isInitialRestorationPending = false
        flag.completedManualSetupProfileID = nil
        completedManualSetupProfileID = nil
        isManualSetupPending = true
        generation += 1
        let current = generation
        let restorationTask = task
        task?.cancel()
        task = nil
        presentationTask?.cancel()
        presentationTask = nil
        inactivityTask?.cancel()
        inactivityTask = nil
        phase = .stopping
        activity = nil
        manualSetupTask = Task { [weak self] in
            await pause()
            await restorationTask?.value
            guard let self, generation == current else { return }
            manualSetupTask = nil
            phase = .hidden
            activity = nil
            onReady()
        }
    }

    public func completeManualSetup(for profileID: String) {
        guard isManualSetupPending, phase == .hidden else { return }
        flag.completedManualSetupProfileID = profileID
        completedManualSetupProfileID = profileID
    }

    @discardableResult
    public func resumeAfterManualSetup(for profileID: String) -> Bool {
        guard isManualSetupPending, phase == .hidden,
              completedManualSetupProfileID == profileID else { return false }
        flag.isManualSetupPending = false
        isManualSetupPending = false
        completedManualSetupProfileID = nil
        return true
    }

    public func cancel() {
        flag.isInitialRestorationPending = false
        generation += 1
        task?.cancel()
        task = nil
        presentationTask?.cancel()
        presentationTask = nil
        inactivityTask?.cancel()
        inactivityTask = nil
        isManualSetupPending = flag.isManualSetupPending
        completedManualSetupProfileID = flag.completedManualSetupProfileID
        phase = .hidden
        activity = nil
    }

    func waitForCompletion() async {
        await task?.value
    }

    func waitForManualSetup() async {
        await manualSetupTask?.value
    }
}
