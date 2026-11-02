#if canImport(AVFoundation)
import CoreModels
import Foundation
import Observation

/// Retained Live TV players use the same local and root veils as ordinary playback.
@MainActor
@Observable
final class LiveChannelDisplayTransition {
    let veil: HDRTransitionModel
    private(set) var isExiting = false
    private var generation = UUID()
    private var acceptsDisplayEvents = false
    private var pendingRange: EffectiveDynamicRange?

    var hidesControls: Bool { !isExiting && veil.isVeiled }

    init(veil: HDRTransitionModel? = nil) {
        self.veil = veil ?? HDRTransitionModel()
    }

    func beginPlayback(
        isFullscreen: Bool, changesSource: Bool, range: SourceDynamicRange?,
        settings: PlaybackSettings
    ) -> UUID {
        reset()
        veil.isDynamicRangeFadeEnabled = settings.fadeOnDynamicRangeChange
        if isFullscreen, settings.fadeOnDynamicRangeChange,
           changesSource || range == nil || range?.isHDR == true {
            pendingRange = .awaitingEngineProbe(hint: range)
            veil.beginProbeTransition(replacing: changesSource ? range.map(HDRDisplayMode.init) : .sdr)
        }
        return generation
    }

    /// The output policy/load must not run until the existing fade reaches black.
    func preparePlayback(_ token: UUID) async -> Bool {
        if veil.isVeiled { await veil.awaitVeilOpaque() }
        guard token == generation, !Task.isCancelled else { return false }
        acceptsDisplayEvents = true
        return true
    }

    func update(range: SourceDynamicRange?, hasPresentedFrame: Bool, failed: Bool) {
        guard !isExiting, acceptsDisplayEvents else { return }
        if failed {
            reset()
        } else if hasPresentedFrame, let range, let pendingRange {
            self.pendingRange = nil
            veil.reconcile(from: pendingRange, to: .resolved(range, authority: .engineProbe))
        }
    }

    func displayDidSettle() {
        guard acceptsDisplayEvents else { return }
        veil.displayDidSettle()
    }

    static func exitKind(
        range: SourceDynamicRange?, settings: PlaybackSettings
    ) -> DisplayTransitionKind? {
        if (range == nil || range?.isHDR == true), settings.fadeOnDynamicRangeChange {
            return .dynamicRange
        }
        return settings.fadeOnFrameRateChange ? .frameRate : nil
    }

    func beginExit(kind: DisplayTransitionKind?) -> UUID? {
        guard !isExiting else { return nil }
        reset()
        isExiting = true
        veil.beginExit(kind: kind)
        return generation
    }

    func finishExit(
        _ token: UUID, kind: DisplayTransitionKind?, windowVeil: DisplayVeilModel?,
        restoreOutput: @MainActor () -> Void, dismiss: @MainActor () -> Void
    ) async {
        if kind != nil { await veil.awaitVeilOpaque() }
        guard token == generation, !Task.isCancelled else { return }
        acceptsDisplayEvents = true
        // Engage after the local fade, before restoring output or exposing the guide.
        if let kind { windowVeil?.engage(kind: kind) }
        restoreOutput()
        if kind != nil, windowVeil == nil { await veil.waitForExit() }
        guard token == generation, !Task.isCancelled else { return }
        dismiss()
    }

    func reset() {
        generation = UUID()
        acceptsDisplayEvents = false
        pendingRange = nil
        isExiting = false
        veil.cancelTransition()
    }
}
#endif
