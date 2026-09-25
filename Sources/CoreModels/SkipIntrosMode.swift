import Foundation

/// How the player handles skip markers (intros, credits, recaps, previews,
/// commercials), mirroring the four-way control in Infuse (Off / On / Auto
/// (delay) / Auto (instant)). One mode covers every kind unless the viewer sets
/// kinds separately — see ``SkipMarkerModes``.
///
///  * `.off` — never skip; markers aren't even fetched.
///  * `.on` — show a focusable **Skip** button while inside a marker (manual).
///  * `.autoDelay` — show the Skip button, then skip automatically after a short
///    grace period if the viewer doesn't act (the button is the chance to skip
///    immediately, or swipe-up to cancel the auto-skip).
///  * `.autoInstant` — skip the moment playback enters a marker, with only a
///    brief on-screen "Skipping…" notice.
public enum SkipIntrosMode: String, Codable, CaseIterable, Sendable {
    case off
    case on
    case autoDelay
    case autoInstant

    /// Seconds of playback the Skip button stays before `.autoDelay` jumps. Tied
    /// to playback position (not wall-clock) so it pauses with the video and the
    /// button's countdown ring depletes in lock-step.
    public static let autoSkipDelay: TimeInterval = 5

    /// Short label for the settings picker / summaries.
    public var title: LocalizedStringResource {
        switch self {
        case .off:
            return LocalizedStringResource(
                "skipIntros.off",
                defaultValue: "Off",
                comment: "Skip-intro behaviour option in Settings > Playback."
            )
        case .on:
            return LocalizedStringResource(
                "skipIntros.on",
                defaultValue: "On",
                comment: "Skip-intro behaviour option in Settings > Playback."
            )
        case .autoDelay:
            return LocalizedStringResource(
                "skipIntros.autoDelay",
                defaultValue: "Auto (delay)",
                comment: "Skip-intro behaviour option in Settings > Playback."
            )
        case .autoInstant:
            return LocalizedStringResource(
                "skipIntros.autoInstant",
                defaultValue: "Auto (instant)",
                comment: "Skip-intro behaviour option in Settings > Playback."
            )
        }
    }

    /// One-line explanation shown beneath the focused option in settings. Worded
    /// for any kind of marker, since the same modes apply to each.
    public var detail: LocalizedStringResource {
        switch self {
        case .off:
            return LocalizedStringResource(
                "skipMarkers.detail.off",
                defaultValue: "Never skip.",
                comment: "Explains the Off option of a skip picker (intros, credits, recaps, previews or commercials)."
            )
        case .on:
            return LocalizedStringResource(
                "skipMarkers.detail.on",
                defaultValue: "Show a Skip button while it plays.",
                comment: "Explains the On option of a skip picker (intros, credits, recaps, previews or commercials)."
            )
        case .autoDelay:
            return LocalizedStringResource(
                "skipMarkers.detail.autoDelay",
                defaultValue: "Show a Skip button, then skip automatically after a few seconds.",
                comment: "Explains the Auto (delay) option of a skip picker (intros, credits, recaps, previews or commercials)."
            )
        case .autoInstant:
            return LocalizedStringResource(
                "skipMarkers.detail.autoInstant",
                defaultValue: "Skip automatically, the instant it starts.",
                comment: "Explains the Auto (instant) option of a skip picker (intros, credits, recaps, previews or commercials)."
            )
        }
    }

    /// Whether skip markers should be fetched at all (any mode except Off).
    public var fetchesMarkers: Bool { self != .off }

    /// Whether the player skips without a button press (delay or instant).
    public var isAutomatic: Bool { self == .autoDelay || self == .autoInstant }
}

/// The skip mode for each marker kind, as the player acts on it: one ``base``
/// mode for every kind, except where the viewer chose a kind's mode separately.
public struct SkipMarkerModes: Equatable, Sendable {
    public var base: SkipIntrosMode
    public var overrides: [MediaSegment.Kind: SkipIntrosMode]

    public init(base: SkipIntrosMode, overrides: [MediaSegment.Kind: SkipIntrosMode] = [:]) {
        self.base = base
        self.overrides = overrides
    }

    public static let allOff = SkipMarkerModes(base: .off)

    /// The mode for segments of `kind`. Unknown segments are never offered.
    public func mode(for kind: MediaSegment.Kind) -> SkipIntrosMode {
        guard kind.isSkippable else { return .off }
        return overrides[kind] ?? base
    }

    /// Whether any kind wants markers fetched.
    public var fetchesMarkers: Bool {
        MediaSegment.Kind.skippable.contains { mode(for: $0).fetchesMarkers }
    }
}
