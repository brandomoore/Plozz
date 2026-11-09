import CoreModels
import Foundation
#if os(iOS) && !targetEnvironment(macCatalyst)
import BackgroundTasks
#endif

@MainActor
protocol ExternalPlaybackExecutionLease: AnyObject {
    var isValid: Bool { get }
    func onExpiration(_ handler: @escaping @MainActor () -> Void)
    func update(deliveredBytes: Int64)
    func finish(success: Bool)
}

@MainActor
enum ExternalPlaybackExecution {
    static var isSupported: Bool {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }

    static func acquire(title: String, player: ExternalPlayer, bytes: Int64) async throws -> any ExternalPlaybackExecutionLease {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            return try await SystemExternalPlaybackExecution.acquire(title: title, player: player, bytes: bytes)
        }
        #endif
        throw ExternalPlayerError.unsupportedSource
    }
}

/// Admission is not submission: never leave Plozz until the OS actually starts
/// the work. Late grants after timeout/cancellation are completed immediately.
@MainActor
final class ExternalPlaybackAdmission {
    private var result: Result<any ExternalPlaybackExecutionLease, Error>?
    private var continuation: CheckedContinuation<any ExternalPlaybackExecutionLease, Error>?

    func receiver() -> @MainActor (Result<any ExternalPlaybackExecutionLease, Error>) -> Void {
        { [weak self] result in
            if let self { self.resolve(result) }
            else if case .success(let lease) = result { lease.finish(success: false) }
        }
    }

    func resolve(_ result: Result<any ExternalPlaybackExecutionLease, Error>) {
        guard self.result == nil else {
            if case .success(let lease) = result { lease.finish(success: false) }
            return
        }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }

    func cancel() {
        if case .success(let lease) = result { lease.finish(success: false) }
        resolve(.failure(CancellationError()))
    }

    func wait() async throws -> any ExternalPlaybackExecutionLease {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
}

#if os(iOS) && !targetEnvironment(macCatalyst)
@available(iOS 26.0, *)
@MainActor
private final class SystemExternalPlaybackExecution: ExternalPlaybackExecutionLease {
    private let task: BGContinuedProcessingTask
    private var expiration: (@MainActor () -> Void)?
    private var deadline: Task<Void, Never>?
    private(set) var isValid = true

    init(task: BGContinuedProcessingTask, bytes: Int64) {
        self.task = task
        task.progress.totalUnitCount = bytes
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.expire() }
        }
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(86_400)) } catch { return }
            self?.expire()
        }
    }

    func onExpiration(_ handler: @escaping @MainActor () -> Void) {
        expiration = handler
        if !isValid { handler() }
    }

    func update(deliveredBytes: Int64) {
        guard isValid else { return }
        task.progress.completedUnitCount = min(task.progress.totalUnitCount, max(0, deliveredBytes))
    }

    private func expire() {
        guard isValid else { return }
        let callback = expiration
        finish(success: false)
        callback?()
    }

    func finish(success: Bool) {
        guard isValid else { return }
        isValid = false
        deadline?.cancel()
        deadline = nil
        expiration = nil
        task.expirationHandler = nil
        task.setTaskCompleted(success: success)
    }

    static func acquire(title: String, player: ExternalPlayer, bytes: Int64) async throws -> any ExternalPlaybackExecutionLease {
        let identifier = "\(Bundle.main.bundleIdentifier ?? "com.thatcube.Plozz").external-stream.\(UUID().uuidString)"
        let admission = ExternalPlaybackAdmission()
        let receive = admission.receiver()
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    receive(.failure(ExternalPlayerError.unsupportedSource))
                    return
                }
                receive(.success(SystemExternalPlaybackExecution(task: task, bytes: bytes)))
            }
        }
        guard registered else { throw ExternalPlayerError.unsupportedSource }
        let submission = Task {
            do {
                try await Task.detached {
                    let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: player.name)
                    request.strategy = .fail
                    #if compiler(>=6.4)
                    if #available(iOS 27.0, *) {
                        try await BGTaskScheduler.shared.submitTaskRequest(request)
                        return
                    }
                    #endif
                    try BGTaskScheduler.shared.submit(request)
                }.value
                if Task.isCancelled { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
            } catch { admission.resolve(.failure(error)) }
        }
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            admission.resolve(.failure(ExternalPlayerError.unavailable))
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
        defer { timeout.cancel() }
        do {
            let lease = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let lease = try await admission.wait()
                try Task.checkCancellation()
                guard lease.isValid else { throw ExternalPlayerError.unavailable }
                return lease
            } onCancel: {
                Task { @MainActor in
                    admission.cancel()
                    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
                }
            }
            return lease
        } catch {
            submission.cancel()
            admission.cancel()
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            throw error
        }
    }
}
#endif
