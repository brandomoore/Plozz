import Foundation
import CoreModels

/// Owns the optional tap independently of recognition's background work.
@MainActor
final class SongRecognitionController {
    typealias Report = @MainActor @Sendable (SongMatch?) -> Void
    typealias Watch = @Sendable (AsyncStream<SongTapChunk>, @escaping Report) async -> SongRecognizer.StopReason

    private let install: @MainActor () -> AsyncStream<SongTapChunk>?
    private let remove: @MainActor () -> Void
    private let report: Report
    private let watch: Watch
    private let sleep: @Sendable (Duration) async throws -> Void
    private var task: Task<Void, Never>?
    private final class Lifetime {
        var generation = 0
    }
    private let lifetime = Lifetime()

    init(
        install: @escaping @MainActor () -> AsyncStream<SongTapChunk>?,
        remove: @escaping @MainActor () -> Void,
        report: @escaping Report,
        watch: @escaping Watch = { stream, report in await SongRecognizer.watch(stream, report: report) },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.install = install
        self.remove = remove
        self.report = report
        self.watch = watch
        self.sleep = sleep
    }

    deinit { task?.cancel() }

    func start() {
        guard task == nil else { return }
        lifetime.generation += 1
        let lifetime = lifetime
        let generation = lifetime.generation
        let install = install, remove = remove, watch = watch, sleep = sleep
        task = Task(priority: .utility) { [weak self] in
            defer {
                if lifetime.generation == generation {
                    remove()
                    self?.task = nil
                }
            }
            var misses = 0
            while !Task.isCancelled, lifetime.generation == generation {
                guard let stream = install() else {
                    misses += 1
                    guard misses < 3 else {
                        HandoffDiagnostics.emit("songid TAP_UNAVAILABLE")
                        return
                    }
                    do { try await sleep(.seconds(5)) }
                    catch is CancellationError { return }
                    catch {
                        HandoffDiagnostics.emit("songid RETRY_WAIT_FAILED")
                        return
                    }
                    continue
                }
                misses = 0
                let reason = await watch(stream) { [weak self] song in
                    guard !Task.isCancelled, lifetime.generation == generation else { return }
                    self?.report(song)
                }
                guard !Task.isCancelled, lifetime.generation == generation else { return }
                remove()
                self?.report(nil)
                do {
                    try await sleep(.seconds(reason == .failed ? SongRecognizer.errorRest : 2))
                } catch is CancellationError { return }
                catch {
                    HandoffDiagnostics.emit("songid RETRY_WAIT_FAILED")
                    return
                }
            }
        }
    }

    func stop() {
        lifetime.generation += 1
        task?.cancel()
        task = nil
        remove()
    }
}
