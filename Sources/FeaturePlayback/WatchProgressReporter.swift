import CoreModels
import CoreNetworking
import Foundation
import TraktService

/// Seam back to ``PlayerViewModel`` for the live playback signals the reporter
/// samples. Held **weakly** so the reporter never retains the view model.
///
/// The engine is read through the host (not captured) on purpose: it can be
/// swapped mid-session (native ⇆ Plozzigen handoff, retry), and every report /
/// checkpoint must sample the *current* engine.
@MainActor
protocol WatchProgressReporterHost: AnyObject {
    var reporterEngineCurrentTime: TimeInterval { get }
    var reporterEngineDuration: TimeInterval { get }
    var reporterEngineIsPaused: Bool { get }
    var reporterControlsDuration: TimeInterval { get }
    var reporterRequest: PlaybackRequest? { get }
    /// The position a checkpoint should record — the view model's resume-position
    /// policy (current time, or the furthest observed point when the clock has
    /// been zeroed by a natural EOF).
    var reporterResumePosition: TimeInterval { get }
}

/// Owns progress reporting + the convergence-checkpoint loop extracted from
/// ``PlayerViewModel``: fanning the play/pause/progress/stop lifecycle out to
/// the provider and Trakt, and periodically writing the live position back so
/// progress converges across servers without waiting for the user to press Back.
///
/// Responsibilities that were fragile inline and are now in one testable place:
/// - the **defer-until-started** rule for a pause/unpause that arrives before
///   the `.start` report has been sent (``reportStateChange`` / ``reportStart``)
/// - the checkpoint **dedup + paused/stall guard** so a paused or stuck player
///   never re-writes the same position to N servers (``emitCheckpoint``)
@MainActor
final class WatchProgressReporter {
    private weak var host: WatchProgressReporterHost?
    private let provider: any MediaProvider
    private let itemID: String
    private let scrobbler: any TraktScrobbling
    private let checkpointInterval: TimeInterval
    private let onCheckpoint: @Sendable (_ position: TimeInterval, _ watchedPercent: Double) -> Void
    private let onTrackerPlayback: @Sendable (TrackerPlaybackSample) -> Void
    private let trackerSessionID = UUID()
    private var trackerStartedAt: Date?
    private var trackerDuration: TimeInterval?

    private var checkpointTask: Task<Void, Never>?
    private var lastCheckpointPosition: TimeInterval = 0

    private var hasEnqueuedPlaybackStart = false
    private var pendingPlaybackStateReport: Bool?
    private var isEndingSession = false
    private var reportTail: Task<Void, Never>?
    private var terminalReport: Task<Void, Never>?
    private var pendingProgress: (entry: PendingProgress, task: Task<Void, Never>)?

    private struct Report {
        let progress: PlaybackProgress
        let event: PlaybackEvent
        let item: MediaItem
        let percent: Double
        let scrobble: Bool
    }

    private final class PendingProgress {
        var report: Report?

        init(_ report: Report) {
            self.report = report
        }
    }

    init(
        host: WatchProgressReporterHost,
        provider: any MediaProvider,
        itemID: String,
        scrobbler: any TraktScrobbling,
        checkpointInterval: TimeInterval,
        onCheckpoint: @escaping @Sendable (_ position: TimeInterval, _ watchedPercent: Double) -> Void,
        onTrackerPlayback: @escaping @Sendable (TrackerPlaybackSample) -> Void = { _ in }
    ) {
        self.host = host
        self.provider = provider
        self.itemID = itemID
        self.scrobbler = scrobbler
        self.checkpointInterval = checkpointInterval
        self.onCheckpoint = onCheckpoint
        self.onTrackerPlayback = onTrackerPlayback
    }

    // MARK: - Reporting

    func beginSession() {
        discardPendingProgress()
        hasEnqueuedPlaybackStart = false
        pendingPlaybackStateReport = nil
        isEndingSession = false
        terminalReport = nil
    }

    func report(
        event: PlaybackEvent,
        isPaused: Bool,
        positionOverride: TimeInterval? = nil,
        durationOverride: TimeInterval? = nil
    ) async {
        await enqueueReport(
            event: event, isPaused: isPaused,
            positionOverride: positionOverride, durationOverride: durationOverride
        )?.value
    }

    /// Closes admission synchronously, before a rendition clears its request or
    /// tears down the clock. The returned task is not cancelled with its waiter.
    func finishSession(
        position: TimeInterval, duration: TimeInterval?, scrobble: Bool = true
    ) -> Task<Void, Never>? {
        enqueueReport(
            event: .stop, isPaused: true, positionOverride: position,
            durationOverride: duration, scrobble: scrobble
        )
    }

    @discardableResult
    private func enqueueReport(
        event: PlaybackEvent,
        isPaused: Bool,
        positionOverride: TimeInterval? = nil,
        durationOverride: TimeInterval? = nil,
        scrobble: Bool = true
    ) -> Task<Void, Never>? {
        if event == .stop {
            if let terminalReport { return terminalReport }
            cancel()
        } else if isEndingSession {
            return nil
        }
        guard let host, let request = host.reporterRequest,
              !request.suppressOrdinaryWatchReporting else { return nil }
        if event == .start, trackerStartedAt == nil { trackerStartedAt = Date() }
        captureTrackerDuration()
        let position = positionOverride ?? host.reporterEngineCurrentTime
        if event == .stop, scrobble {
            emitTrackerSample(item: request.item, position: position, isFinal: true)
        }
        let knownDuration = WatchProgressMath.knownDuration(
            engineDuration: durationOverride ?? 0,
            controlsDuration: knownPlaybackDuration() ?? 0,
            itemRuntime: nil
        )
        let progress = PlaybackProgress(
            itemID: itemID,
            playSessionID: request.playSessionID,
            positionSeconds: position,
            isPaused: isPaused,
            durationSeconds: knownDuration
        )
        let percent = WatchProgressMath.watchedPercent(
            position: position, engineDuration: knownDuration ?? 0, itemRuntime: nil
        )
        let report = Report(
            progress: progress, event: event, item: request.item, percent: percent, scrobble: scrobble
        )
        if event == .progress, let pendingProgress {
            pendingProgress.entry.report = report
            return pendingProgress.task
        }
        // Lifecycle events supersede any unsent heartbeat. An in-flight report
        // still finishes first, but slow servers cannot accumulate stale ticks.
        if event != .progress { discardPendingProgress() }
        let progressEntry = event == .progress ? PendingProgress(report) : nil
        let previous = reportTail
        let provider = provider
        let scrobbler = scrobbler
        // Capture the request and timing before suspension. A later engine or
        // request replacement must not relabel an already queued event.
        let task = Task { [weak self] in
            await previous?.value
            let delivery: Report
            if let progressEntry {
                guard let latest = progressEntry.report else { return }
                delivery = latest
                progressEntry.report = nil
                if self?.pendingProgress?.entry === progressEntry {
                    self?.pendingProgress = nil
                }
            } else {
                delivery = report
            }
            let progress = delivery.progress
            let event = delivery.event
            HandoffDiagnostics.emit(
                "session REPORT_INTENT origin=watch-progress provider=\(provider.kind.rawValue)"
                    + " item=\(HandoffDiagnostics.correlationID(progress.itemID))"
                    + " session=\(HandoffDiagnostics.correlationID(progress.playSessionID)) event=\(event)"
            )
            do {
                try await provider.reportPlayback(progress, event: event)
            } catch {
                if event == .stop {
                    PlozzLog.playback.error("Final playback report failed.")
                } else {
                    PlozzLog.playback.debug("Progress report failed (non-fatal)")
                }
            }
            if delivery.scrobble {
                await scrobbler.scrobble(item: delivery.item, progress: delivery.percent, event: event)
            }
        }
        if let progressEntry { pendingProgress = (progressEntry, task) }
        reportTail = task
        if event == .stop { terminalReport = task }
        return task
    }

    private func discardPendingProgress() {
        pendingProgress?.entry.report = nil
        pendingProgress = nil
    }

    /// Queues start and any deferred state in the same actor turn. Later state
    /// changes join that queue even while the start request is still in flight.
    func reportStart(isPaused: Bool, positionOverride: TimeInterval?) async {
        guard let start = enqueueReport(
            event: .start, isPaused: isPaused, positionOverride: positionOverride
        ) else { return }
        hasEnqueuedPlaybackStart = true
        var completion = start
        if let pendingPaused = pendingPlaybackStateReport {
            pendingPlaybackStateReport = nil
            if pendingPaused != isPaused, let deferred = enqueueReport(
                event: pendingPaused ? .pause : .unpause, isPaused: pendingPaused
            ) {
                completion = deferred
            }
        }
        await completion.value
    }

    /// Defers state changes until start has entered the ordered reporting queue.
    func reportStateChange(paused: Bool) {
        guard !isEndingSession else { return }
        if hasEnqueuedPlaybackStart {
            enqueueReport(event: paused ? .pause : .unpause, isPaused: paused)
        } else {
            pendingPlaybackStateReport = paused
        }
    }

    /// Reports a mid-play progress heartbeat (from the engine's onProgress).
    func reportProgress() {
        guard hasEnqueuedPlaybackStart, host?.reporterEngineIsPaused == false else { return }
        enqueueReport(event: .progress, isPaused: false)
    }

    // MARK: - Duration / percent

    func knownPlaybackDuration() -> TimeInterval? {
        guard let host else { return nil }
        return WatchProgressMath.knownDuration(
            engineDuration: host.reporterEngineDuration,
            controlsDuration: host.reporterControlsDuration,
            itemRuntime: host.reporterRequest?.item.runtime
        )
    }

    /// Watched percentage using the same best-known duration as server reports.
    func watchedPercentNow() -> Double {
        watchedPercent(at: host?.reporterEngineCurrentTime ?? 0)
    }

    /// Returns zero when neither the playback clock nor metadata knows duration.
    func watchedPercent(at position: TimeInterval) -> Double {
        WatchProgressMath.watchedPercent(
            position: position,
            engineDuration: knownPlaybackDuration() ?? 0,
            itemRuntime: nil
        )
    }

    // MARK: - Convergence checkpoints

    /// Starts the periodic mid-play convergence loop. Each tick fires a checkpoint
    /// (see ``emitCheckpoint``) so progress fans out to other servers roughly every
    /// ``checkpointInterval`` seconds without the user pressing Back. Cancelled and
    /// restarted defensively; `stop()` tears it down. A non-positive interval (or a
    /// default no-op hook) leaves the loop off so standalone/test players are
    /// unaffected.
    func startCheckpointLoop(seedPosition: TimeInterval) {
        guard !isEndingSession else { return }
        lastCheckpointPosition = max(0, seedPosition)
        checkpointTask?.cancel()
        guard checkpointInterval > 0 else { return }
        let interval = checkpointInterval
        checkpointTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                self?.emitCheckpoint()
            }
        }
    }

    /// Enqueues a convergence checkpoint for the current position **iff** the player
    /// has made real forward progress since the last one and isn't paused/stalled —
    /// so a paused or stuck player never re-writes the same position to N servers.
    /// Pure enqueue (no network on this path); safe to call from the timer or, on
    /// app background, from `checkpointNow()`.
    func emitCheckpoint(includingPaused: Bool = false) {
        guard let host, let request = host.reporterRequest,
              !isEndingSession,
              !request.suppressOrdinaryWatchReporting,
              includingPaused || !host.reporterEngineIsPaused else { return }
        let position = host.reporterResumePosition
        guard position > 1, abs(position - lastCheckpointPosition) >= 1 else { return }
        lastCheckpointPosition = position
        onCheckpoint(position, watchedPercent(at: position))
        emitTrackerSample(item: request.item, position: position, isFinal: false)
    }

    private func captureTrackerDuration() {
        if let duration = host?.reporterEngineDuration, duration.isFinite, duration > 0 {
            trackerDuration = duration
        }
    }

    private func emitTrackerSample(item: MediaItem, position: TimeInterval, isFinal: Bool) {
        captureTrackerDuration()
        guard item.kind == .movie || item.kind == .episode,
              let trackerStartedAt, let trackerDuration, position > 1 else { return }
        do {
            onTrackerPlayback(try TrackerPlaybackSample(
                sessionID: trackerSessionID, startedAt: trackerStartedAt, item: item,
                position: position, duration: trackerDuration, isFinal: isFinal
            ))
        } catch {
            PlozzLog.playback.error("Invalid player-clock evidence could not be queued for tracker reporting")
        }
    }

    /// Forces an immediate convergence checkpoint regardless of the timer — used
    /// when the app is about to be backgrounded/suspended (the TV Home button or
    /// sleep path, which never fires the view's `onDisappear`/`stop()`), so the
    /// latest position is durably captured before the process can be killed.
    func checkpointNow() {
        emitCheckpoint(includingPaused: true)
    }

    /// Stops checkpoints and rejects new nonterminal reports. Already admitted
    /// events still drain before the one allowed stop report.
    func cancel() {
        isEndingSession = true
        pendingPlaybackStateReport = nil
        discardPendingProgress()
        checkpointTask?.cancel()
        checkpointTask = nil
    }
}
