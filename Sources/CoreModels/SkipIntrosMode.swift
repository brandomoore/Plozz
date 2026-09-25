import Foundation

/// How the player handles one kind of skip marker (intro, credits, preview,
/// commercial), mirroring the four-way control in Infuse (Off / On / Auto
/// (delay) / Auto (instant)). Each marker kind has its own mode — see
/// ``SkipMarkerModes``.
///
///  * `.off` — never skip this kind of marker.
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

    /// One-line explanation shown beneath each option in settings. Generic over
    /// the marker kind, since the same four modes apply to intros, credits,
    /// previews and commercials alike.
    public var detail: LocalizedStringResource {
        switch self {
        case .off:
            return LocalizedStringResource(
                "skipMarkers.detail.off",
                defaultValue: "Never skip.",
                comment: "One-line explanation shown under a skip-marker picker (intros, credits, previews or commercials)."
            )
        case .on:
            return LocalizedStringResource(
                "skipMarkers.detail.on",
                defaultValue: "Show a Skip button.",
                comment: "One-line explanation shown under a skip-marker picker (intros, credits, previews or commercials)."
            )
        case .autoDelay:
            return LocalizedStringResource(
                "skipMarkers.detail.autoDelay",
                defaultValue: "Show a Skip button, then skip automatically after a few seconds.",
                comment: "One-line explanation shown under a skip-marker picker (intros, credits, previews or commercials)."
            )
        case .autoInstant:
            return LocalizedStringResource(
                "skipMarkers.detail.autoInstant",
                defaultValue: "Skip automatically, the instant it starts.",
                comment: "One-line explanation shown under a skip-marker picker (intros, credits, previews or commercials)."
            )
        }
    }

    /// Whether markers of this kind should be fetched at all (any mode except Off).
    public var fetchesMarkers: Bool { self != .off }

    /// Whether the player skips without a button press (delay or instant).
    public var isAutomatic: Bool { self == .autoDelay || self == .autoInstant }
}

/// The per-kind skip modes the player acts on — one ``SkipIntrosMode`` for each
/// marker kind the viewer can skip. A snapshot of the relevant
/// ``PlaybackSettings`` fields, handed to the player so it can decide per
/// segment rather than applying one mode to every marker.
public struct SkipMarkerModes: Equatable, Sendable {
    public var intro: SkipIntrosMode
    public var credits: SkipIntrosMode
    public var preview: SkipIntrosMode
    public var commercial: SkipIntrosMode

    public init(
        intro: SkipIntrosMode = .off,
        credits: SkipIntrosMode = .off,
        preview: SkipIntrosMode = .off,
        commercial: SkipIntrosMode = .off
    ) {
        self.intro = intro
        self.credits = credits
        self.preview = preview
        self.commercial = commercial
    }

    public static let allOff = SkipMarkerModes()

    /// The mode governing segments of `kind`. Kinds with no setting of their own
    /// (recaps, unknown) are never offered, so they read as `.off`.
    public func mode(for kind: MediaSegment.Kind) -> SkipIntrosMode {
        switch kind {
        case .intro: return intro
        case .credits: return credits
        case .preview: return preview
        case .commercial: return commercial
        case .recap, .unknown: return .off
        }
    }

    /// Whether any marker kind wants markers fetched.
    public var fetchesMarkers: Bool {
        [intro, credits, preview, commercial].contains(where: \.fetchesMarkers)
    }
}
