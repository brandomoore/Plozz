import Foundation

public enum GenreDisplayFormatter {
    public static func displayName(for genre: String) -> String {  // l10n:content — provider genre passthrough; only normalizes one synonym's casing into a fixed label (see report)
        let trimmed = genre.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed.lowercased().unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
        switch key {
        case "sciencefiction", "scifi", "scifiction":
            return "Sci-Fi"
        case "sciencefictionfantasy", "sciencefictionandfantasy",
             "scififantasy", "scifiandfantasy",
             "scifictionfantasy", "scifictionandfantasy":
            return "Sci-Fi & Fantasy"
        default:
            return trimmed
        }
    }

    public static func displayNames(for genres: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = genres.compactMap { genre -> String? in
            let displayName = displayName(for: genre)
            guard !displayName.isEmpty,
                  seen.insert(displayName.lowercased()).inserted else {
                return nil
            }
            return displayName
        }
        let compoundKey = "sci-fi & fantasy"
        if result.contains(where: { $0.lowercased() == compoundKey }) {
            result.removeAll {
                let key = $0.lowercased()
                return key == "sci-fi" || key == "fantasy"
            }
        }
        return result
    }
}

/// A small, provider-agnostic capability badge shown on a detail hero, e.g.
/// `4K`, `Dolby Vision`, `Dolby Atmos`, `5.1`, or a content rating like `TV-14`.
///
/// Derived from `MediaItem`/`MediaSourceMetadata` so the decision of *what* to
/// show is one pure, testable place; the UI layer only decides *how* to paint
/// each `Style`.
public struct MediaBadge: Hashable, Sendable, Identifiable {
    /// Metadata families retain their identity independently of the shared visual treatment.
    public enum Style: String, Sendable, Hashable {
        /// Content certification, separate from picture and audio capabilities.
        case rating
        /// Other technical facts, including video codecs.
        case spec
        /// Resolution.
        case prominent
        /// HDR signal metadata.
        case hdr
        /// Explicit standard dynamic range.
        case sdr
        /// Dolby Vision or Dolby audio, rendered as text rather than a vendor logo.
        case dolby
        /// DTS audio.
        case dts
        /// Other audio formats, audio languages, or a standalone channel layout.
        case audio
    }

    public var label: String  // l10n:content — technical spec/brand name (e.g. "4K", "Dolby Vision"), never translated
    public var style: Style
    /// Attached detail: an audio channel layout or Dolby Vision's compatible range.
    public var detail: String?  // l10n:content — technical spec (e.g. channel layout), never translated

    public var id: String { "\(style.rawValue):\(label):\(detail ?? "")" }

    public var isAudio: Bool {
        switch style {
        case .audio, .dts: true
        case .dolby: label != "Dolby Vision"
        default: false
        }
    }

    public init(_ label: String, style: Style = .spec, detail: String? = nil) {  // l10n:content — technical spec/brand name, never translated
        self.label = label
        self.style = style
        self.detail = detail
    }

    /// A spoken/described form combining the label with any trailing detail
    /// (e.g. `Dolby Digital+ 5.1`).
    public var accessibilityText: String {  // l10n:content — composed from brand/spec labels, never translated
        guard let detail, !detail.isEmpty else { return label }
        return "\(label) \(detail)"
    }

    /// For `.dolby` badges, the format word(s) after the leading "Dolby " (e.g.
    /// `Vision`, `Atmos`, `Digital+`). For any
    /// other style this is just the full label.
    public var dolbyFormatWord: String {  // l10n:content — brand/format name, never translated
        guard style == .dolby else { return label }
        let prefix = "Dolby "
        if label.hasPrefix(prefix) {
            return String(label.dropFirst(prefix.count))
        }
        return label
    }
}

// MARK: - Technical badges from stream metadata

public extension MediaSourceMetadata {
    /// A single resolution-tier badge (`4K`, `1080p`, `720p`, `SD`) from the
    /// video stream's pixel dimensions, or `nil` when no dimensions are known.
    var resolutionBadge: MediaBadge? {
        guard let video else { return nil }
        // Classify by effective lines (max of true height and the height this
        // width implies at 16:9) so letterboxed cinematic content — e.g. a
        // 1920×804 movie — reads by its real width (1080p) rather than its
        // cropped height (which would wrongly read 720p).
        guard let lines = PlaybackDiagnostics.effectiveResolutionLines(
            width: video.width,
            height: video.height
        ) else {
            return nil
        }
        let label: String  // l10n:content — technical spec (resolution tier), never translated
        switch lines {
        case 4320...: label = "8K"
        case 2000...: label = "4K"
        case 1400..<2000: label = "1440p"
        case 1000..<1400: label = "1080p"
        case 700..<1000: label = "720p"
        default: label = "SD"
        }
        return MediaBadge(label, style: .prominent)
    }

    /// Dynamic-range badge(s) describing the HDR/Dolby Vision signal. A pure
    /// Dolby Vision stream reads `Dolby Vision` alone; a Dolby Vision stream that
    /// also carries an HDR10 base layer (Jellyfin's `DOVIWithHDR10`, Plex's
    /// "DoVi/HDR10") reads `Dolby Vision` **and** `HDR10` so the badge row
    /// advertises both. Otherwise a single `HDR10+`, `HDR10`, `HLG`, or generic
    /// `HDR` badge, or `SDR` for standard-range content. Empty only when there's
    /// nothing to classify. HDR badges use the `.hdr` metadata family; Dolby
    /// Vision uses `.dolby`, and standard dynamic range uses `.sdr`.
    var dynamicRangeBadges: [MediaBadge] {
        guard let video else { return [] }
        func normalized(_ token: String?) -> String {
            (token ?? "").uppercased()
                .replacingOccurrences(of: "+", with: "PLUS")
                .filter { $0.isLetter || $0.isNumber }
        }
        let rangeType = normalized(video.videoRangeType)
        let range = normalized(video.videoRange)
        let transfer = video.colorTransfer?.lowercased()

        if rangeType.hasPrefix("DOVI") || rangeType.hasPrefix("DOLBYVISION")
            || range.hasPrefix("DOVI") || range.hasPrefix("DOLBYVISION")
            || (video.dolbyVisionProfile ?? 0) > 0 {
            var badges = [MediaBadge("Dolby Vision", style: .dolby)]
            // Only explicit compatibility facts establish a base layer, not
            // the Dolby Vision profile number or its PQ transfer function.
            let compatibility = rangeType.isEmpty ? range : rangeType
            if compatibility.contains("HDR10PLUS") {
                badges.append(MediaBadge("HDR10+", style: .hdr))
            } else if compatibility.contains("HDR10") {
                badges.append(MediaBadge("HDR10", style: .hdr))
            } else if compatibility.contains("HLG") {
                badges.append(MediaBadge("HLG", style: .hdr))
            }
            return badges
        }
        if rangeType == "HDR10PLUS" || range == "HDR10PLUS"
            || (rangeType == "HDR10" && transfer == "smpte2094-40") {
            return [MediaBadge("HDR10+", style: .hdr)]
        }
        if rangeType.hasPrefix("HDR10") {
            return [MediaBadge("HDR10", style: .hdr)]
        }
        if rangeType == "HLG" || rangeType == "HYPERLOGGAMMA" {
            return [MediaBadge("HLG", style: .hdr)]
        }
        if rangeType == "SDR" { return [MediaBadge("SDR", style: .sdr)] }
        if let hint = SourceDynamicRange.classify(
            videoRangeType: rangeType.isEmpty ? range : rangeType,
            videoRange: video.videoRange,
            colorTransfer: transfer
        ) {
            switch hint {
            case .hdr10Plus: return [MediaBadge("HDR10+", style: .hdr)]
            case .hdr10: break
            case .hlg: return [MediaBadge("HLG", style: .hdr)]
            case .sdr: return [MediaBadge("SDR", style: .sdr)]
            case .dolbyVision: return [MediaBadge("Dolby Vision", style: .dolby)]
            }
            if range == "HDR10" || transfer == "smpte2084" {
                return [MediaBadge("HDR10", style: .hdr)]
            }
        }
        if rangeType.hasPrefix("HDR") || range == "HDR" {
            return [MediaBadge("HDR", style: .hdr)]
        }
        // No HDR signal → standard dynamic range. Only assert SDR when we have
        // an explicit range token to back it up. Providers like Jellyfin emit a
        // literal `SDR` token; Plex's coarse media-level fallback emits nothing,
        // and in that case dimensions alone don't prove SDR — a 4K HEVC episode
        // may still be DoVi/HDR even when the trimmed children response strips
        // the HDR display-title hint. Staying silent then lets us show
        // "4K · Dolby Atmos" rather than a misleading "4K · SDR" pill.
        return []
    }

    /// A badge naming the video codec family (`HEVC`, `H.264`, `AV1`, `VP9`, …),
    /// or `nil` when the source reports no codec. This is the "(HEVC)" / "(H.264)"
    /// detail Plex shows alongside the resolution; the full codec profile lives in
    /// the playback-diagnostics overlay.
    var videoCodecBadge: MediaBadge? {
        guard let video,
              let name = PlaybackDiagnostics.friendlyCodecName(video.codec),
              !name.isEmpty,
              // The Dolby Vision case is already conveyed by the dynamic-range
              // badge, so don't repeat it here if a codec *tag* folded to it.
              name != "Dolby Vision" else {
            return nil
        }
        return MediaBadge(name, style: .spec)
    }

    /// The source's codec and spatial capability are separate facts. Channels
    /// attach to the codec, not to an inferred Atmos/DTS:X speaker configuration.
    var audioBadges: [MediaBadge] {
        guard let audio else { return [] }
        return Self.audioBadges(
            codec: audio.codec, profile: audio.profile,
            channels: audio.channels, channelLayout: audio.channelLayout
        )
    }

    /// Preserve the selected track's profile and explicit format hints. File
    /// names and other tracks must never supply this track's spatial format.
    static func audioProfile(_ profile: String?, displayTitles: [String?]) -> String? { // l10n:content - normalized audio-format tokens, not translatable prose.
        let hints = displayTitles.compactMap { $0?.lowercased() }.joined(separator: " ")
        var parts = [profile].compactMap { $0 }.filter { !$0.isEmpty }
        let formats: [(String, Bool)] = [
            ("Atmos", hints.contains("atmos")),
            ("JOC", hints.split(whereSeparator: { !$0.isLetter }).contains("joc")),
            ("DTS:X", ["dts:x", "dts-x", "dtsx", "dts x"].contains { hints.contains($0) })
        ]
        for (label, present) in formats where present {
            if !parts.contains(where: { $0.localizedCaseInsensitiveContains(label) }) {
                parts.append(label)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    static func audioBadges(
        codec: String?, profile: String?, channels: Int?, channelLayout: String? = nil
    ) -> [MediaBadge] {
        let profile = (profile ?? "").lowercased()
        let codec = PlaybackDiagnostics.friendlyCodecName(codec)
        let layout = surroundLabel(channelLayout: channelLayout, channels: channels)
        var format: MediaBadge?
        if codec == "Dolby TrueHD" {
            format = MediaBadge("Dolby TrueHD", style: .dolby)
        } else if codec == "DTS-HD" || codec == "DTS-HD MA" {
            format = MediaBadge("DTS-HD", style: .dts)
        } else if codec == "DTS" {
            let tokens = profile.split(whereSeparator: { !$0.isLetter })
            let highDefinition = tokens.contains("hd") || tokens.contains("ma")
                || tokens.contains("hra") || profile.contains("master audio")
            format = MediaBadge(highDefinition ? "DTS-HD" : "DTS", style: .dts)
        } else if codec == "Dolby Digital+" {
            format = MediaBadge("Dolby Digital+", style: .dolby)
        } else if codec == "Dolby Digital" {
            format = MediaBadge("Dolby Digital", style: .dolby)
        }
        var result: [MediaBadge] = []
        if var format {
            format.detail = layout
            result.append(format)
        }
        if profile.contains("atmos")
            || (codec == "Dolby Digital+" && profile.split(whereSeparator: { !$0.isLetter }).contains("joc")) {
            result.append(MediaBadge("Dolby Atmos", style: .dolby, detail: format == nil ? layout : nil))
        } else if profile.contains("dts:x") || profile.contains("dtsx") || profile.contains("dts x")
            || profile.contains("dts-x") {
            result.append(MediaBadge("DTS:X", style: .dts, detail: format == nil ? layout : nil))
        }
        if result.isEmpty, let layout { result.append(MediaBadge(layout, style: .audio)) }
        return result
    }

    /// Resolution, picture, then audio. Video codecs remain in the detailed picker
    /// and playback diagnostics rather than the hero's headline row.
    var technicalBadges: [MediaBadge] {
        Self.orderedTechnicalBadges(
            resolution: resolutionBadge,
            range: dynamicRangeBadges,
            audio: audioBadges
        )
    }

    static func orderedTechnicalBadges(
        resolution: MediaBadge?,
        range: [MediaBadge],
        audio: [MediaBadge]
    ) -> [MediaBadge] {
        var badges: [MediaBadge] = []
        if let resolution { badges.append(resolution) }
        if var vision = range.first, vision.label == "Dolby Vision",
           range.count == 2, range[1].style == .hdr {
            vision.detail = range[1].label
            badges.append(vision)
        } else {
            badges.append(contentsOf: range)
        }
        badges.append(contentsOf: audio)
        return badges
    }
    /// A surround-channel label (`7.1`, `5.1`) from a layout string or channel
    /// count. Returns `nil` for stereo/mono (not a highlight) or unknown.
    private static func surroundLabel(channelLayout: String?, channels: Int?) -> String? {
        if let layout = channelLayout?.lowercased() {
            if layout.contains("7.1") { return "7.1" }
            if layout.contains("5.1") { return "5.1" }
        }
        switch channels {
        case .some(let c) where c >= 8: return "7.1"
        case .some(let c) where c >= 6: return "5.1"
        default: return nil
        }
    }
}

// MARK: - Per-version badges

public extension MediaVersion {
    /// Technical badges for this version. When the version carries the backing
    /// file's real ``MediaVersion/sourceMetadata`` (the same-account-duplicate
    /// case), they come straight from `MediaSourceMetadata.technicalBadges` —
    /// the authoritative path that correctly renders HDR10+, DoVi-with-HDR10 and
    /// channel-layout audio. Otherwise they're composed from this version's own
    /// flattened facts (resolution from width/height, HDR/DoVi from `videoRange`,
    /// audio from `audioProfile`/`audioCodec`/`audioChannels`), via the same
    /// category ordering helper so a per-version row reads identically to
    /// the per-item one.
    ///
    /// The hero's badge row uses this when the user picks a non-default version
    /// from the picker, so switching from a 4K HDR Atmos Remux to a 720p SDR
    /// WEB-DL flips the badges to match the *selected* file rather than the
    /// default's media-info snapshot.
    var technicalBadges: [MediaBadge] {
        (sourceMetadata ?? flattenedSourceMetadata).technicalBadges
    }
}

// MARK: - Item-level badges & metadata line

public extension MediaItem {
    /// The content-rating badge (e.g. `TV-14`, `PG-13`) when the provider reports
    /// a non-empty certificate. Always `.outlined`.
    var ratingBadge: MediaBadge? {
        guard let officialRating = officialRating?.trimmingCharacters(in: .whitespacesAndNewlines),
              !officialRating.isEmpty else { return nil }
        return MediaBadge(officialRating, style: .rating)
    }

    /// Technical (resolution/HDR/audio) badges, gated to playable single-file
    /// kinds — a series/season/collection has no single media file, so these are
    /// only meaningful for movies, episodes and standalone videos.
    var technicalBadges: [MediaBadge] {
        switch kind {
        case .movie, .episode, .video:
            return mediaInfo?.technicalBadges ?? []
        default:
            return []
        }
    }

    /// Runtime text for poster/landscape cards:
    /// - overall runtime for movies/TV when not started;
    /// - remaining runtime while in progress.
    ///
    /// Bare duration only (e.g. `20m`) — this is a formatted quantity, not copy.
    /// When ``cardRuntimeIsRemaining`` is `true`, callers compose their own
    /// localized "… left" suffix (e.g. `Text("\(text) left")`); CoreModels
    /// cannot own that composition without importing SwiftUI.
    ///
    /// Hidden for non-video kinds and when runtime is unknown.
    /// When an unaired episode is expected, for the card slot that would otherwise
    /// show a runtime. `nil` for every ordinary item.
    ///
    /// The card's release label, e.g. "Releases Friday" — spelled out so it can't
    /// read as an air date that has already passed.
    var upcomingReleaseText: LocalizedStringResource? {
        guard let date = scheduledAirDate else { return nil }
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: Date()),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        switch days {
        case ..<0: return nil
        case 0:
            if scheduledAirDateHasTime, showsScheduledReleaseTime {
                return "Releases today at \(date, format: .dateTime.hour().minute())"
            }
            return "Releases today"
        case 1:
            if scheduledAirDateHasTime, showsScheduledReleaseTime {
                return "Releases tomorrow at \(date, format: .dateTime.hour().minute())"
            }
            return "Releases tomorrow"
        case 2...6:
            if scheduledAirDateHasTime, showsScheduledReleaseTime {
                return "Releases \(date, format: .dateTime.weekday(.wide)) at \(date, format: .dateTime.hour().minute())"
            }
            return "Releases \(date, format: .dateTime.weekday(.wide))"
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
            if scheduledAirDateHasTime, showsScheduledReleaseTime {
                if sameYear {
                    return "Releases \(date, format: .dateTime.month(.abbreviated).day().hour().minute())"
                }
                return "Releases \(date, format: .dateTime.month(.abbreviated).day().year().hour().minute())"
            }
            if sameYear {
                return "Releases \(date, format: .dateTime.month(.abbreviated).day())"
            }
            return "Releases \(date, format: .dateTime.month(.abbreviated).day().year())"
        }
    }

    var cardRuntimeText: String? {  // l10n:content — formatted duration, not copy
        guard cardRuntimeEligible, let runtime = resolvedRuntime, runtime > 0 else { return nil }
        if let remaining = remainingRuntimeLabel(for: runtime) {
            return remaining
        }
        return runtime.runtimeBadgeText
    }

    /// The item's runtime, recovered when the provider never stated one.
    ///
    /// A Continue Watching card was showing its progress bar with no time beside
    /// it. The bar only needs a *fraction* — which a provider can report directly —
    /// while the label needs a duration in seconds, and some titles arrive with the
    /// first and not the second. A share file has no runtime until it has been
    /// played once, and a server whose media was never probed reports none either.
    /// The card then said a film was part-watched without saying how much was left,
    /// which is the one thing that row exists to answer.
    ///
    /// Two recoveries, both from data already on the item:
    ///
    /// 1. **The chosen file's own duration.** `MediaVersion.duration` comes from
    ///    the file, so it is the true length whenever the item-level field is
    ///    merely absent.
    /// 2. **Position ÷ fraction.** Both come from the same provider and describe
    ///    the same playback, so their ratio is that playback's length. Floored at a
    ///    1% fraction: dividing by a smaller one multiplies its rounding error into
    ///    a wild duration, and a confidently wrong "3h 40m left" is worse than the
    ///    blank this replaces.
    private var resolvedRuntime: TimeInterval? {
        if let runtime, runtime > 0 { return runtime }
        if let versionDuration = selectedVersion?.duration ?? versions.first?.duration,
           versionDuration > 0 {
            return versionDuration
        }
        guard let resume = resumePosition, resume > 0,
              let fraction = playedPercentage, fraction >= 0.01, fraction < 1
        else { return nil }
        return resume / fraction
    }

    /// Whether ``cardRuntimeText`` holds a REMAINING duration (in-progress item)
    /// rather than the full runtime. Callers append their own localized "left"
    /// suffix when this is `true`.
    var cardRuntimeIsRemaining: Bool {
        guard cardRuntimeEligible, let runtime = resolvedRuntime, runtime > 0 else { return false }
        return remainingRuntimeLabel(for: runtime) != nil
    }

    /// In-progress fraction (`0..<1`) for a resumable item, or `nil` when it has
    /// not been started or is already finished. Drives the detail Play button's
    /// small progress bar.
    var resumeProgressFraction: Double? { cardProgressFraction }

    /// Bare remaining-time text for an in-progress item (e.g. `20m`), or `nil`
    /// when it is not resumable. Shown inside the detail Play button (the cards
    /// use the longer "… left" form composed by the caller from
    /// ``cardRuntimeText``/``cardRuntimeIsRemaining``).
    var resumeRemainingText: String? {  // l10n:content — formatted duration, not copy
        guard let runtime = resolvedRuntime, runtime > 0 else { return nil }
        return remainingRuntimeLabel(for: runtime)
    }

    /// The dotted metadata line components for the detail hero, in order:
    /// production year, formatted runtime, then up to `maxGenres` genres. The UI
    /// joins these with a `·` separator. Empty entries are omitted.
    func metadataComponents(maxGenres: Int = 3) -> [String] {  // l10n:content — production year + formatted duration + provider genre text, not copy
        var parts: [String] = []
        if let productionYear { parts.append(String(productionYear)) }
        if let runtimeText = runtime?.runtimeBadgeText { parts.append(runtimeText) }
        parts.append(
            contentsOf: GenreDisplayFormatter.displayNames(
                for: Array(genres.prefix(maxGenres))
            )
        )
        return parts
    }

    private var cardRuntimeEligible: Bool {
        switch kind {
        case .movie, .series, .season, .episode:
            return true
        default:
            return false
        }
    }

    /// Both branches require progress to be *strictly* between 0 and 1, because
    /// "in progress" means there is something left to resume. The resume branch
    /// must not clamp to 1: providers hand back stale or rounded positions where
    /// `resumePosition >= runtime`, and clamping would render those as a
    /// permanently full progress bar with no remaining time. When the resume
    /// position is degenerate we fall through to `playedPercentage`, which also
    /// recovers the case where the provider's runtime is simply wrong.
    ///
    /// A **saved resume point outranks having seen the title before.** Someone
    /// starting a film again has somewhere to come back to, and that is what the
    /// card is for; treating "watched" as proof of no progress left a rewatch
    /// showing its full runtime as though it had never been opened. Only the
    /// percentage fallback still defers to it, because a watched title reports a
    /// percentage of 1 that describes the *previous* viewing, not this one.
    private var cardProgressFraction: Double? {
        if let runtime, runtime > 0, let resume = resumePosition, resume > 0 {
            let fraction = resume / runtime
            if fraction < 1 { return fraction }
        }
        guard !isPlayed else { return nil }
        if let percentage = playedPercentage, percentage > 0, percentage < 1 {
            return percentage
        }
        return nil
    }

    /// The bare rounded remaining-time label (e.g. `20m`) for an in-progress item,
    /// or `nil` when it is not partially watched. The shared basis for both the
    /// card's remaining text and the Play button's compact remaining time.
    private func remainingRuntimeLabel(for runtime: TimeInterval) -> String? {  // l10n:content — formatted duration, not copy
        guard let progress = cardProgressFraction, progress > 0, progress < 1 else {
            return nil
        }
        let remainingSeconds = max(0, runtime * (1 - progress))
        guard remainingSeconds > 0 else { return nil }
        // Round up so in-progress cards don't show "0m" near completion.
        let roundedUpMinutes = max(1, Int(ceil(remainingSeconds / 60)))
        let roundedRemaining = TimeInterval(roundedUpMinutes * 60)
        return roundedRemaining.runtimeBadgeText
    }
}

// MARK: - Representative badges for a collection (series ← episodes)

public extension Sequence where Element == MediaItem {
    /// A representative technical-badge summary for a group of items — typically
    /// every loaded episode of a series or season. It reports the single best
    /// resolution, dynamic range and audio capabilities found anywhere in the
    /// group, mirroring how Apple TV summarises a show's top capabilities on its
    /// detail page (e.g. a show with one Dolby Vision / Atmos episode reads as
    /// "4K · Dolby Vision · Dolby Atmos"). Empty when no item carries stream
    /// metadata, so a series whose episodes lack media info shows nothing.
    var representativeTechnicalBadges: [MediaBadge] {
        MediaSourceMetadata.representativeTechnicalBadges(from: compactMap(\.mediaInfo))
    }
}

public extension MediaSourceMetadata {
    /// The best-of-each-category technical badge set across many sources. Unlike
    /// a single item's `technicalBadges`, this maximises resolution, dynamic
    /// range and audio independently so the summary reflects the group's peak
    /// capabilities rather than any one file's. Output order matches
    /// `MediaSourceMetadata.technicalBadges`: resolution, picture, then audio.
    /// Codec, channels, and spatial capability always come from the same source.
    static func representativeTechnicalBadges(from sources: [MediaSourceMetadata]) -> [MediaBadge] {
        guard !sources.isEmpty else { return [] }
        var resolution: MediaBadge?

        if let r = sources
            .compactMap(\.resolutionBadge)
            .max(by: { resolutionRank($0.label) < resolutionRank($1.label) }) {
            resolution = r
        }

        // Pick the source whose dynamic-range set contains the best-ranked badge
        // and adopt that source's FULL range list, so a DoVi/HDR10 source
        // contributes both `Dolby Vision` AND `HDR10` rather than just the top
        // rank. Falls back to flat-max when no source has a non-empty set.
        let rangeArrays = sources.map(\.dynamicRangeBadges).filter { !$0.isEmpty }
        var rangeBadges: [MediaBadge] = []
        if let best = rangeArrays.max(by: { topRank(of: $0) < topRank(of: $1) }) {
            rangeBadges = best
        }

        let audio = sources.map(\.audioBadges).max { lhs, rhs in
            let leftFormat = lhs.map { audioFormatRank($0.label) }.max() ?? 0
            let rightFormat = rhs.map { audioFormatRank($0.label) }.max() ?? 0
            if leftFormat != rightFormat { return leftFormat < rightFormat }
            let leftChannels = lhs.map { channelRank($0.detail ?? $0.label) }.max() ?? 0
            let rightChannels = rhs.map { channelRank($0.detail ?? $0.label) }.max() ?? 0
            return leftChannels < rightChannels
        } ?? []
        return orderedTechnicalBadges(
            resolution: resolution,
            range: rangeBadges,
            audio: audio
        )
    }

    /// Keep the confirmed compatibility layer when primary formats tie.
    private static func topRank(of badges: [MediaBadge]) -> (Int, Int) {
        (badges.map { dynamicRangeRank($0.label) }.max() ?? 0,
         badges.dropFirst().map { dynamicRangeRank($0.label) }.max() ?? 0)
    }

    private static func resolutionRank(_ label: String) -> Int {  // l10n:content — technical spec label, never translated
        switch label {
        case "8K": return 6
        case "4K": return 5
        case "1440p": return 4
        case "1080p": return 3
        case "720p": return 2
        case "SD": return 1
        default: return 0
        }
    }

    private static func dynamicRangeRank(_ label: String) -> Int {  // l10n:content — brand/format name, never translated
        switch label {
        case "Dolby Vision": return 5
        case "HDR10+": return 4
        case "HDR10": return 3
        case "HLG": return 2
        case "HDR": return 1
        default: return 0
        }
    }

    private static func audioFormatRank(_ label: String) -> Int {  // l10n:content — brand/format name, never translated
        switch label {
        case "Dolby Atmos": return 7
        case "DTS:X": return 6
        case "Dolby TrueHD": return 5
        case "DTS-HD": return 4
        case "Dolby Digital+": return 3
        case "Dolby Digital": return 2
        case "DTS": return 1
        default: return 0
        }
    }

    private static func channelRank(_ label: String) -> Int {  // l10n:content — technical spec label, never translated
        switch label {
        case "7.1": return 2
        case "5.1": return 1
        default: return 0
        }
    }

}

public extension TimeInterval {
    /// A compact human runtime label, e.g. `2h 28m`, `47m`, or `1h`. Returns
    /// `nil` for non-positive durations (unknown runtime).
    var runtimeBadgeText: String? {  // l10n:content — hand-built duration format, not copy (see report re: Duration.formatted)
        guard self > 0 else { return nil }
        let totalMinutes = Int((self / 60).rounded())
        guard totalMinutes > 0 else { return nil }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        switch (hours, minutes) {
        case (0, let m): return "\(m)m"
        case (let h, 0): return "\(h)h"
        case (let h, let m): return "\(h)h \(m)m"
        }
    }
}
