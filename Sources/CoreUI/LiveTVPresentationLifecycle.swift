import Observation

/// A synchronous handoff signal, not a destination or authorization override.
@MainActor @Observable
public final class LiveTVPresentationLifecycle {
    @ObservationIgnored public var isRelocating = false

    public init() {}
}
