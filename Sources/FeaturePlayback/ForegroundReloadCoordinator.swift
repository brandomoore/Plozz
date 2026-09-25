#if canImport(AVFoundation)
import Foundation
import Observation
import CoreModels
import CoreNetworking

// MARK: - Host seam

/// Everything the ``ForegroundReloadCoordinator`` needs to read from / drive on
/// its owner during a background → foreground recovery. Kept read-mostly so the
/// coordinator owns the *generation bookkeeping* while the view model retains
/// ownership of the engine, controls, and subtitle collaborator.
@MainActor
protocol ForegroundReloadCoordinatorHost: AnyObject {
    /// Current bring-up phase. The recovery loop waits out `.loading` and only
    /// rebuilds once `.ready`.
    var reloadPhase: PlayerViewModel.Phase { get }
    /// Whether playback has been torn down (view dismissed). Aborts recovery.
    var reloadDidStop: Bool { get }
    /// The engine to rebuild. Captured once at the start of a recovery.
    var reloadEngine: any VideoEngine { get }
    /// Live token identifying the active engine; re-read at each guard so a
    /// mid-flight engine swap (retry/handoff) cancels a stale recovery.
    var reloadEngineToken: UUID { get }
    /// Whether the active engine is Plozzigen (needs track re-application after a
    /// rebuild; native AVPlayer restores its own selections).
    var reloadIsPlozzigenEngine: Bool { get }
    /// The user's play/pause *intent* (not the mirror-polluted engine flag).
    var reloadIntendsPlayback: Bool { get }
    /// The speed to re-program on the rebuilt engine.
    var reloadPlaybackSpeed: Double { get }
    var reloadPlaybackIdentity: UInt { get }
    var reloadPosition: TimeInterval { get }
    func reloadRestorePosition(_ position: TimeInterval) async throws

    /// Re-applies the remembered audio/subtitle selections to a freshly rebuilt
    /// Plozzigen engine.
    func reloadReapplyTrackSelections(to engine: any VideoEngine)
    /// Rebuilds the track-options menu after the engine came back.
    func reloadLoadTrackOptions()
    /// Mirrors the reconciled paused state onto the controls model.
    func reloadReconcilePaused(_ paused: Bool)
    /// Surfaces a failed rebuild as a terminal phase.
    func reloadFail(_ error: AppError)
}

// MARK: - Coordinator

/// Owns the background/foreground lifecycle reconciliation for a single playback
/// session.
///
/// tvOS can suspend the app (Home button, sleep, app switcher) without ever
/// firing the view's `onDisappear`/`stop()`. AetherEngine/Plozzigen tears down
/// its AVPlayer item, loopback HLS server, demuxer, and decode session on that
/// transition, so a later `.active` phase has to **rebuild** the pipeline rather
/// than call `play()` on an empty shell. The native engine remains valid and
/// no-ops its reload.
///
/// The single tricky invariant is *generation bookkeeping*: a background entry
/// bumps a generation and a foreground recovery consumes exactly that one, so
/// duplicate `.active` callbacks (which tvOS does emit) can't rebuild the same
/// session twice, and an engine swap that races the async rebuild (retry /
/// handoff) is detected and the stale recovery bails without touching the new
/// engine. Those guards are what break silently on device, so they're pinned by
/// ``ForegroundReloadCoordinatorTests``.
@MainActor
@Observable
final class ForegroundReloadCoordinator {
    private weak var host: ForegroundReloadCoordinatorHost?

    /// Incremented for each real tvOS background entry. A foreground recovery
    /// consumes exactly one generation, preventing duplicate `.active` callbacks
    /// from rebuilding the same playback session more than once.
    private var backgroundGeneration = 0
    private var pendingForegroundReloadGeneration: Int?
    private struct Suspension {
        let engine: UUID
        let playback: UInt
        var position: TimeInterval
        var recoveryArmed = false
    }
    private var suspension: Suspension?

    var preservedPosition: TimeInterval? {
        guard let host, let suspension,
              host.reloadEngineToken == suspension.engine,
              host.reloadPlaybackIdentity == suspension.playback else { return nil }
        return suspension.position
    }

    /// Keeps the full-screen loading indicator visible while a suspended engine
    /// rebuilds its media pipeline at the preserved position.
    private(set) var isRecovering = false

    init(host: ForegroundReloadCoordinatorHost) {
        self.host = host
    }

    /// Marks a genuine tvOS background entry, arming exactly one pending
    /// foreground recovery.
    func markEnteredBackground() {
        if preservedPosition != nil { suspension?.recoveryArmed = true }
        if pendingForegroundReloadGeneration == nil {
            backgroundGeneration += 1
            pendingForegroundReloadGeneration = backgroundGeneration
        }
    }

    /// Capture before pausing/teardown can erase the engine's clock. A continuing
    /// PiP/background-audio session deliberately never enters this path.
    func captureBeforeSuspension() {
        guard let host, !host.reloadDidStop, host.reloadPhase == .ready else { return }
        if preservedPosition != nil { return }
        let position = host.reloadPosition
        guard position.isFinite, position >= 0 else {
            PlozzLog.playback.error("Cannot preserve an invalid playback position before suspension.")
            return
        }
        suspension = .init(engine: host.reloadEngineToken, playback: host.reloadPlaybackIdentity, position: position)
        HandoffDiagnostics.emit("foreground CHECKPOINT position=\(String(format: "%.3f", position)) playback=\(host.reloadPlaybackIdentity)")
    }

    func noteUserSeek(to position: TimeInterval) {
        guard preservedPosition != nil, position.isFinite, position >= 0 else { return }
        suspension?.position = position
    }

    /// Restores the engine after a real background round-trip while preserving
    /// the user's paused state. No provider re-resolve or lifecycle report is
    /// emitted: Plex, Jellyfin, and file-share sources all recover through the
    /// same engine seam at their existing position and session URL.
    func resume() async {
        guard let host else { return }
        if pendingForegroundReloadGeneration == nil {
            guard !isRecovering else { return }
            // Scene delivery can coalesce inactive -> background -> active.
            // Only a demonstrated clock reset may recover without a background
            // notification; an ordinary inactive-only pause stays a no-op.
            if suspension?.recoveryArmed != true,
               host.reloadPhase == .ready, !host.reloadDidStop,
               let position = preservedPosition, position > 2,
               host.reloadEngine.currentTime.isFinite,
               (0...1).contains(host.reloadEngine.currentTime) {
                markEnteredBackground()
                HandoffDiagnostics.emit("foreground CLOCK_RESET_WITHOUT_BACKGROUND saved=\(String(format: "%.3f", position))")
            } else {
                if suspension?.recoveryArmed != true { suspension = nil }
                return
            }
        }
        guard let generation = pendingForegroundReloadGeneration else { return }

        // Background can interrupt initial bring-up. Wait for that load to settle,
        // then rebuild the pipeline that tvOS invalidated before returning active.
        while host.reloadPhase == .loading,
              pendingForegroundReloadGeneration == generation,
              !host.reloadDidStop {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        guard pendingForegroundReloadGeneration == generation,
              host.reloadPhase == .ready,
              !host.reloadDidStop else { return }

        pendingForegroundReloadGeneration = nil
        let recoveringEngine = host.reloadEngine
        let needsReload = recoveringEngine.needsBackgroundReload
        guard needsReload || preservedPosition != nil else { return }
        let recoveringEngineToken = host.reloadEngineToken
        let playbackIdentity = host.reloadPlaybackIdentity
        isRecovering = true
        defer {
            if backgroundGeneration == generation {
                isRecovering = false
            }
        }

        do {
            if needsReload { try await recoveringEngine.reloadAfterForeground() }
            guard backgroundGeneration == generation,
                  host.reloadEngineToken == recoveringEngineToken,
                  host.reloadPlaybackIdentity == playbackIdentity else { return }
            guard !host.reloadDidStop else {
                recoveringEngine.stop()
                return
            }
            recoveringEngine.setPlaybackSpeed(host.reloadPlaybackSpeed)
            if host.reloadIsPlozzigenEngine {
                host.reloadReapplyTrackSelections(to: recoveringEngine)
            }
            if let position = preservedPosition {
                try await host.reloadRestorePosition(position)
            }
        } catch {
            guard backgroundGeneration == generation,
                  host.reloadEngineToken == recoveringEngineToken,
                  host.reloadPlaybackIdentity == playbackIdentity,
                  !host.reloadDidStop else { return }
            recoveringEngine.pause()
            HandoffDiagnostics.emit("foreground RESTORE_FAILED position=\(preservedPosition.map { String(format: "%.3f", $0) } ?? "unknown")")
            let appError = (error as? AppError) ?? .unknown(String(describing: error))
            host.reloadFail(appError)
            return
        }

        guard backgroundGeneration == generation,
              host.reloadEngineToken == recoveringEngineToken,
              host.reloadPlaybackIdentity == playbackIdentity else { return }
        guard !host.reloadDidStop else {
            recoveringEngine.stop()
            return
        }

        // A play press can arrive while the async rebuild is in flight. Reconcile
        // last, after restoring speed/tracks that may restart AVPlayer, and avoid a
        // duplicate pause/unpause report; the genuine user action already sent it.
        if host.reloadIntendsPlayback {
            recoveringEngine.play()
        } else {
            recoveringEngine.pause()
        }
        host.reloadReconcilePaused(!host.reloadIntendsPlayback)
        host.reloadLoadTrackOptions()
        HandoffDiagnostics.emit("foreground RESTORED position=\(String(format: "%.3f", recoveringEngine.currentTime)) paused=\(!host.reloadIntendsPlayback)")
        suspension = nil
    }
}

#endif
