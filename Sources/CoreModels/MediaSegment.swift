import Foundation

/// A time range within a playable item that the server has tagged as a
/// structural segment — an intro, the closing credits, a recap, etc.
///
/// Both backends expose server-detected markers, normalised here so the player
/// stays provider-agnostic (the dual-provider mandate):
///  * **Jellyfin** → `GET /MediaSegments/{itemId}` (`Intro`/`Outro`/… with
///    100-nanosecond `StartTicks`/`EndTicks`).
///  * **Plex** → `GET /library/metadata/{id}?includeMarkers=1` (`<Marker
///    type="intro|credits" startTimeOffset endTimeOffset>` in milliseconds).
///
/// Times are stored in **seconds** so the player can compare them directly
/// against the engine's `currentTime` without unit juggling.
public struct MediaSegment: Codable, Equatable, Sendable, Identifiable {
    /// The kind of segment. Every kind except `.unknown` is skippable.
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case intro
        case credits
        case recap
        case preview
        case commercial
        case unknown

        /// The skippable kinds, in the order Settings lists them.
        public static let skippable: [Kind] = [.intro, .credits, .recap, .preview, .commercial]

        public var isSkippable: Bool { self != .unknown }

        /// This kind's name in Settings, where each kind can get its own skip mode.
        public var settingsTitle: LocalizedStringResource {
            switch self {
            case .intro:
                return LocalizedStringResource(
                    "skipMarkers.kind.intro", defaultValue: "Intros",
                    comment: "Settings > Playback > Skip intros, credits & more: row for opening titles."
                )
            case .credits:
                return LocalizedStringResource(
                    "skipMarkers.kind.credits", defaultValue: "Credits",
                    comment: "Settings > Playback > Skip intros, credits & more: row for closing credits."
                )
            case .recap:
                return LocalizedStringResource(
                    "skipMarkers.kind.recap", defaultValue: "Recaps",
                    comment: "Settings > Playback > Skip intros, credits & more: row for 'previously on' recaps."
                )
            case .preview:
                return LocalizedStringResource(
                    "skipMarkers.kind.preview", defaultValue: "Previews",
                    comment: "Settings > Playback > Skip intros, credits & more: row for 'next time on' previews."
                )
            case .commercial:
                return LocalizedStringResource(
                    "skipMarkers.kind.commercial", defaultValue: "Commercials",
                    comment: "Settings > Playback > Skip intros, credits & more: row for ad breaks in TV recordings."
                )
            case .unknown:
                return LocalizedStringResource(
                    "skipMarkers.kind.unknown", defaultValue: "Other",
                    comment: "Settings > Playback > Skip intros, credits & more: unrecognised marker kind (not normally shown)."
                )
            }
        }

        /// What this kind is, for the kinds whose name alone doesn't say.
        public var settingsHint: LocalizedStringResource? {
            switch self {
            case .recap:
                return LocalizedStringResource(
                    "skipMarkers.kind.recap.hint", defaultValue: "“Previously on…”",
                    comment: "Explains the Recaps row in skip settings: the recap at the start of an episode."
                )
            case .preview:
                return LocalizedStringResource(
                    "skipMarkers.kind.preview.hint", defaultValue: "“Next time on…”",
                    comment: "Explains the Previews row in skip settings: the preview of the next episode."
                )
            case .commercial:
                return LocalizedStringResource(
                    "skipMarkers.kind.commercial.hint", defaultValue: "Ad breaks in TV recordings",
                    comment: "Explains the Commercials row in skip settings."
                )
            case .intro, .credits, .unknown:
                return nil
            }
        }

        /// The label shown on the in-player skip button for this kind.
        public var skipActionLabel: LocalizedStringResource {
            switch self {
            case .intro: return "Skip Intro"
            case .credits: return "Skip Credits"
            case .recap: return "Skip Recap"
            case .preview: return "Skip Preview"
            case .commercial: return "Skip Commercial"
            case .unknown: return "Skip"
            }
        }

        /// The transient, past-tense label shown after this kind is skipped
        /// automatically (Auto (instant)) — the skip already happened, so it reads
        /// as a confirmation, e.g. "Intro Skipped".
        public var autoSkippedLabel: LocalizedStringResource {
            switch self {
            case .intro: return "Intro Skipped"
            case .credits: return "Credits Skipped"
            case .recap: return "Recap Skipped"
            case .preview: return "Preview Skipped"
            case .commercial: return "Commercial Skipped"
            case .unknown: return "Skipped"
            }
        }
    }

    public var id: String
    public var kind: Kind
    /// Inclusive start, in seconds from the beginning of the item.
    public var start: TimeInterval
    /// Exclusive end, in seconds — the position the player seeks to on skip.
    public var end: TimeInterval

    public init(id: String = UUID().uuidString, kind: Kind, start: TimeInterval, end: TimeInterval) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
    }

    /// Whether the skip feature can offer a button for this segment.
    public var isSkippable: Bool { kind.isSkippable }

    /// Whether `position` (seconds) falls inside this segment's window. A small
    /// trailing margin is excluded so the button doesn't linger for the final
    /// frame, and a tiny lead-in tolerance is allowed so it appears promptly.
    public func contains(_ position: TimeInterval) -> Bool {
        position >= start - Self.margin && position < end - Self.margin
    }

    /// The visibility margin (seconds) applied at both ends of the window so the
    /// skip button appears just before the segment and clears just before it ends.
    static let margin: TimeInterval = 0.25

    /// How far into a segment a *seek* may land and still be treated as "entering"
    /// it — the opening grace window. A committed seek that lands within this many
    /// seconds of the segment's start still offers a (manual) Skip affordance; a
    /// seek that lands deeper is taken as a deliberate jump *into* the segment and
    /// the affordance is suppressed entirely (the seek is respected). Natural
    /// playback always enters at offset ~0, so it is unaffected by this.
    public static let seekGraceWindow: TimeInterval = 5

    /// The full length of the skip button's on-screen window, in seconds — the
    /// span over which the "time remaining" indicator depletes.
    public var window: TimeInterval { max(0, end - start) }

    /// Seconds remaining until the skip button auto-dismisses, given the live
    /// `position`. Clamped to `0` once the segment's trailing margin is reached.
    public func remaining(at position: TimeInterval) -> TimeInterval {
        max(0, (end - Self.margin) - position)
    }

    /// Fraction (0…1) of the skip window still remaining at `position`. `1` when
    /// the segment has just begun, `0` as it ends. Drives the depleting indicator.
    public func remainingFraction(at position: TimeInterval) -> Double {
        guard window > 0 else { return 0 }
        return min(1, max(0, remaining(at: position) / window))
    }
}

public extension Array where Element == MediaSegment {
    /// This list with `fallback`'s segments added for every kind this list has
    /// none of. Used to layer community markers (IntroDB / TheIntroDB) under the
    /// server's own: the server wins per kind, the fallback fills the gaps.
    func filling(from fallback: [MediaSegment]) -> [MediaSegment] {
        let present = Set(map(\.kind))
        return self + fallback.filter { !present.contains($0.kind) }
    }

    /// Whether this list already has an intro and a credits marker, the two kinds
    /// community markers are looked up for.
    var coversIntroAndCredits: Bool {
        contains { $0.kind == .intro } && contains { $0.kind == .credits }
    }

    /// The skippable segment whose window currently contains `position`, if any.
    /// Intros win ties over credits since an intro can never overlap credits in
    /// practice; if data is malformed the earliest-starting match is returned.
    func activeSkippable(at position: TimeInterval) -> MediaSegment? {
        self.filter { $0.isSkippable && $0.contains(position) }
            .min { $0.start < $1.start }
    }
}
