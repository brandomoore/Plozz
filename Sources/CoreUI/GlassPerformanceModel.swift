#if canImport(SwiftUI)
import CoreModels
import Foundation
import Observation

/// Retained playback classification for overlapping HDR presentation.
/// The root no longer uses this historical budget to turn Liquid Glass off.
@MainActor
@Observable
public final class GlassPerformanceModel {
    public private(set) var budget: GlassPerformanceBudget

    /// How many players currently consider their content demanding.
    ///
    /// A count rather than a flag. Playback can overlap — a new item loading
    /// while the previous one tears down — and with a flag the departing player
    /// clears a suspension the arriving one just set, restoring glass over
    /// exactly the content that asked for it to go.
    private var demandingSources = 0
    /// Counted alongside, and for the same reason: overlapping playback must not
    /// let a departing player clear a state the arriving one just set.
    private var hdrSources = 0

    public init(physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        budget = .forHardware(physicalMemoryBytes: physicalMemoryBytes)
    }

    /// Registers a demanding player for presentation tracking, balanced on exit.
    public func beginDemandingPlayback(isHDR: Bool = false) {
        demandingSources += 1
        if isHDR { hdrSources += 1 }
        refresh()
    }

    public func endDemandingPlayback(isHDR: Bool = false) {
        guard demandingSources > 0 else { return }
        demandingSources -= 1
        if isHDR, hdrSources > 0 { hdrSources -= 1 }
        refresh()
    }

    /// Clears every suspension. For a player tearing down on a path that cannot
    /// guarantee its balance — the alternative to a leak here is glass that
    /// never comes back until the app is relaunched.
    public func resetPlaybackDemand() {
        guard demandingSources != 0 || hdrSources != 0 else { return }
        demandingSources = 0
        hdrSources = 0
        refresh()
    }

    private func refresh() {
        budget.contentIsDemanding = demandingSources > 0
        budget.contentIsHDR = hdrSources > 0
    }
}
#endif
