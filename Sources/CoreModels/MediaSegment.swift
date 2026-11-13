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

/// The effective markers for one playback item, after duplicate candidates from a
/// single source have been collapsed. ``postCredits`` is deliberately not a
/// skippable marker: it is the after-credits scene the player should land on, not
/// another section to offer a Skip button for.
public struct MergedSkipMarkers: Sendable, Equatable {
    public var segments: [MediaSegment]
    public var postCredits: MediaSegment?
    public var hasPostCredits: Bool { postCredits != nil }

    public init(segments: [MediaSegment] = [], postCredits: MediaSegment? = nil) {
        self.segments = segments
        self.postCredits = postCredits
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

    /// Collapses multiple candidates for the same kind into one effective marker.
    ///
    /// Credits are intentionally treated as a *later* window: a later start wins
    /// so an early false "outro" cannot trigger before the real credits, and the
    /// later end wins so a later-starting candidate's short end cannot cut the
    /// credits short. Other kinds use the intersection of their candidates
    /// (later start, earlier end), falling back to the earlier candidate when the
    /// candidates do not overlap. Unknown kinds are not skippable and are omitted.
    func squashingDuplicateKinds() -> [MediaSegment] {
        MediaSegment.Kind.skippable.compactMap { kind in
            let candidates = filter {
                $0.kind == kind
                    && $0.start.isFinite && $0.end.isFinite
                    && $0.start >= 0 && $0.end > $0.start
            }
            guard !candidates.isEmpty else { return nil }
            if candidates.count == 1 { return candidates[0] }

            if kind == .credits {
                let start = candidates.map(\.start).max()!
                let end = candidates.map(\.end).max()!
                return candidates.mergedCandidate(start: start, end: end, kind: kind)
            }

            let start = candidates.map(\.start).max()!
            let end = candidates.map(\.end).min()!
            if start < end {
                return candidates.mergedCandidate(start: start, end: end, kind: kind)
            }
            // Disjoint candidates: keep the earlier one, matching the user's
            // "earlier of the two positions" policy for non-credits.
            return candidates.min { $0.start < $1.start }
        }
    }

    /// Builds the effective playback markers for a known duration.
    ///
    /// A source's explicit post-credit marker wins. Otherwise a finite credits end
    /// that leaves a real tail before the duration is treated as post-credits
    /// content. Credits are capped at that post-credit start when one exists, and
    /// extended to the item duration when it does not, so an auto-skip lands on the
    /// next episode rather than on an earlier, partial credits end.
    func mergedForPlayback(
        duration: TimeInterval?,
        explicitPostCredits: MediaSegment? = nil
    ) -> MergedSkipMarkers {
        var segments = squashingDuplicateKinds()
        let creditsIndex = segments.firstIndex { $0.kind == .credits }
        let creditsStart = creditsIndex.map { segments[$0].start }

        var postCredits = explicitPostCredits.flatMap {
            $0.sanitizedPostCredits(duration: duration, creditsStart: creditsStart)
        }

        if postCredits == nil, let creditsIndex, let duration, duration.isFinite {
            let credits = segments[creditsIndex]
            if duration > credits.start, duration - credits.end >= 5 {
                postCredits = MediaSegment(
                    id: "inferred-post-credits",
                    kind: .unknown,
                    start: credits.end,
                    end: duration
                )
            }
        }

        if let postCredits, let creditsIndex {
            let credits = segments[creditsIndex]
            if credits.start < postCredits.start {
                segments[creditsIndex] = MediaSegment(
                    id: credits.id,
                    kind: .credits,
                    start: credits.start,
                    end: postCredits.start
                )
            }
        } else if let creditsIndex, let duration, duration.isFinite, duration > 0,
                  let creditsStart, creditsStart < duration {
            segments[creditsIndex] = MediaSegment(
                id: segments[creditsIndex].id,
                kind: .credits,
                start: creditsStart,
                end: duration
            )
        }

        return MergedSkipMarkers(segments: segments.filter(\.isSkippable), postCredits: postCredits)
    }

    /// The skippable segment whose window currently contains `position`, if any.
    /// Intros win ties over credits since an intro can never overlap credits in
    /// practice; if data is malformed the earliest-starting match is returned.
    func activeSkippable(at position: TimeInterval) -> MediaSegment? {
        self.filter { $0.isSkippable && $0.contains(position) }
            .min { $0.start < $1.start }
    }
}

private extension Array where Element == MediaSegment {
    /// Preserves a candidate's identity when the merged bounds are exactly one of
    /// its own ranges; otherwise synthesises a stable ID for the merged range.
    func mergedCandidate(start: TimeInterval, end: TimeInterval, kind: MediaSegment.Kind) -> MediaSegment {
        if let exact = first(where: {
            abs($0.start - start) < 0.001 && abs($0.end - end) < 0.001
        }) {
            return exact
        }
        return MediaSegment(
            id: "squashed-\(kind.rawValue)-\(Int((start * 1000).rounded()))-\(Int((end * 1000).rounded()))",
            kind: kind,
            start: start,
            end: end
        )
    }
}

private extension MediaSegment {
    /// Validates a post-credit candidate and returns it as a non-skippable marker.
    /// A candidate that starts before the credits, or at/after the duration, is
    /// rejected rather than silently becoming a second skip section.
    func sanitizedPostCredits(
        duration: TimeInterval?,
        creditsStart: TimeInterval?
    ) -> MediaSegment? {
        guard start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
        if let creditsStart, start <= creditsStart { return nil }
        if let duration, duration.isFinite, duration > 0 {
            guard start < duration else { return nil }
            let end = min(end, duration)
            guard end > start else { return nil }
            return MediaSegment(id: id, kind: .unknown, start: start, end: end)
        }
        return MediaSegment(id: id, kind: .unknown, start: start, end: end)
    }
}
