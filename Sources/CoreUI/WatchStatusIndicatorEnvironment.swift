#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// The active profile's `WatchStatusIndicator`, injected into the SwiftUI
/// environment at the app root (see `RootView`) alongside `\.plozzCardStyle`.
/// Media cards read this so switching the "Watched Indicator" setting (or
/// switching to a profile with a different choice) restyles the corner badge
/// live, with no view rebuild — exactly like the card style and density metrics.
private struct PlozzWatchStatusIndicatorKey: EnvironmentKey {
    static let defaultValue: WatchStatusIndicator = .default
}

private struct PlozzUnwatchedEpisodeCountKey: EnvironmentKey {
    static let defaultValue = WatchStatusIndicatorSettingsStore.defaultShowsUnwatchedEpisodeCount
}

public extension EnvironmentValues {
    var plozzShowsUnwatchedEpisodeCount: Bool {
        get { self[PlozzUnwatchedEpisodeCountKey.self] }
        set { self[PlozzUnwatchedEpisodeCountKey.self] = newValue }
    }

    /// The live, per-profile watch-status indicator (a "watched" check badge vs
    /// an "unwatched" corner flag). Set once at the app root; read by
    /// `PosterCardView`.
    var plozzWatchStatusIndicator: WatchStatusIndicator {
        get { self[PlozzWatchStatusIndicatorKey.self] }
        set { self[PlozzWatchStatusIndicatorKey.self] = newValue }
    }
}
#endif
