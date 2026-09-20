#if os(tvOS)
import AVFoundation
import AVKit
import CoreNetworking
import UIKit

@MainActor
protocol NativeDisplayCriteriaTarget: AnyObject {
    var playbackDisplayCriteria: AVDisplayCriteria? { get set }
}

extension UIWindow: NativeDisplayCriteriaTarget {
    var playbackDisplayCriteria: AVDisplayCriteria? {
        get { avDisplayManager.preferredDisplayCriteria }
        set { avDisplayManager.preferredDisplayCriteria = newValue }
    }
}

/// The native player owns only its own writes; Aether and other players may use the same window.
@MainActor
final class NativeDisplayCriteriaController {
    typealias Loader = @MainActor (AVAsset) async throws -> AVDisplayCriteria

    private let loadCriteria: Loader
    private var task: Task<Void, Never>?
    private var generation: UInt = 0
    private var isConfigured = false
    private var pendingCriteria: AVDisplayCriteria?
    private weak var target: (any NativeDisplayCriteriaTarget)?
    private weak var appliedTarget: (any NativeDisplayCriteriaTarget)?
    private var appliedCriteria: AVDisplayCriteria?

    init(loadCriteria: @escaping Loader = { try await $0.load(.preferredDisplayCriteria) }) {
        self.loadCriteria = loadCriteria
    }

    deinit { task?.cancel() }

    func configure(asset: AVAsset, fallback: AVDisplayCriteria?) {
        generation &+= 1
        let expectedGeneration = generation
        task?.cancel()
        isConfigured = true
        pendingCriteria = fallback
        apply()

        let loadCriteria = loadCriteria
        task = Task { @MainActor [weak self] in
            do {
                let criteria = try await loadCriteria(asset)
                guard let self, !Task.isCancelled, self.generation == expectedGeneration else { return }
                if let appliedTarget = self.appliedTarget, let appliedCriteria = self.appliedCriteria,
                   appliedTarget.playbackDisplayCriteria?.isEqual(appliedCriteria) != true {
                    // Another player took the window while AVFoundation was loading.
                    self.isConfigured = false
                    return
                }
                self.pendingCriteria = criteria
                self.apply()
                PlozzLog.playback.debug("Native display criteria resolved from the playback asset")
            } catch is CancellationError {
                // Stop or a replacement load owns the next display request.
            } catch {
                guard let self, !Task.isCancelled, self.generation == expectedGeneration else { return }
                PlozzLog.playback.error("Native asset display criteria unavailable; retaining the source-hint fallback")
            }
        }
    }

    func attach(to target: (any NativeDisplayCriteriaTarget)?) {
        self.target = target
        apply()
    }

    func stop() {
        invalidatePendingLoad()
        clearOwnedCriteria()
    }

    func invalidatePendingLoad() {
        generation &+= 1
        task?.cancel()
        task = nil
        isConfigured = false
        pendingCriteria = nil
    }

    private func apply() {
        guard isConfigured, let target else { return }
        if let appliedTarget, appliedTarget !== target {
            clearOwnedCriteria()
        }
        guard let pendingCriteria else {
            clearOwnedCriteria()
            return
        }
        // Reparenting the same surface must not trigger another HDMI handshake.
        if target.playbackDisplayCriteria?.isEqual(pendingCriteria) != true {
            target.playbackDisplayCriteria = pendingCriteria
            appliedTarget = target
            appliedCriteria = pendingCriteria
        }
    }

    private func clearOwnedCriteria() {
        if let appliedTarget, let appliedCriteria,
           appliedTarget.playbackDisplayCriteria?.isEqual(appliedCriteria) == true {
            appliedTarget.playbackDisplayCriteria = nil
        }
        appliedTarget = nil
        appliedCriteria = nil
    }
}
#endif
