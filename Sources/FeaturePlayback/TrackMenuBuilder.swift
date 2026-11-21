import CoreModels
import SwiftUI

/// Pure construction of the audio / subtitle / secondary-subtitle picker menus
/// shown in `PlayerControls`, plus the small selection/eligibility decisions
/// that feed them.
///
/// This is deliberately a value-only, side-effect-free collaborator: given the
/// engine's demuxed tracks, the provider's probe, the current selection, and the
/// viewer's preferred languages, it returns the `PlayerTrackOption` arrays and
/// the derived facts (which audio id is selected, which tracks are eligible as a
/// second subtitle line, whether the primary is an un-positionable bitmap). The
/// `PlayerViewModel` keeps ownership of the mutable state and all engine/overlay
/// side effects; it simply asks this builder what the menus should contain. That
/// split makes the fiddly labelling/sort/pinning rules directly unit-testable
/// without standing up an engine.
enum TrackMenuBuilder {

    /// The "selected audio" indicator must reflect the track the engine is
    /// *actually* decoding, not a re-derived default-flag guess (those can
    /// disagree: e.g. a dual-audio anime whose container defaults to Japanese
    /// while the engine starts English per the viewer's preference). Priority:
    /// an in-flight pick (optimistic) → the engine's resolved active track
    /// (ground truth) → the default-flag heuristic only before either is known.
    ///
    /// Returns the id to mark selected and whether the caller should clear its
    /// `pendingAudioTrackID` (an optimistic pick is only cleared once the engine
    /// confirms it, or when we fall through to the engine's own active track).
    static func resolveSelectedAudioTrackID(
        current: Int?,
        pending: Int?,
        engineActive: Int?,
        tracks: [MediaTrack]
    ) -> (selected: Int?, clearPending: Bool) {
        if let pending, tracks.contains(where: { $0.id == pending }) {
            return (pending, engineActive == pending)
        }
        if let active = engineActive, tracks.contains(where: { $0.id == active }) {
            return (active, true)
        }
        if current == nil {
            return (tracks.first(where: { $0.isDefault })?.id ?? tracks.first?.id, false)
        }
        return (current, false)
    }

    /// Audio picker rows, preferred-language-first.
    static func audioOptions(
        tracks: [MediaTrack],
        selectedID: Int?,
        preferred: [String?],
        locale: Locale = .current
    ) -> [PlayerTrackOption] {
        let options = tracks.sortedByPreferredLanguage(preferred).map { track in
            let label = presentation(for: TrackLabeling.audioLabel(
                displayTitle: track.displayTitle, sourceTitle: track.sourceTitle, language: track.language,
                codec: track.codec, profile: track.profile, channels: track.channels,
                isAtmos: track.isAtmos, isDTSX: track.isDTSX, isCommentary: track.isCommentary,
                isVisualImpaired: track.isVisualImpaired, trackID: track.id, locale: locale
            ), locale: locale)
            return PlayerTrackOption(
                id: track.id, title: label.text,
                isSelected: track.id == selectedID, nativeTitle: label.nativeTitle
            )
        }
        return disambiguatedOptions(options, locale: locale)
    }

    /// Primary subtitle picker rows: "Off" pinned first, real tracks
    /// preferred-language-first. An empty track list yields an empty menu (no
    /// bare "Off" row).
    static func subtitleOptions(
        tracks: [MediaTrack],
        selectedID: Int?,
        preferred: [String?],
        detectedLanguages: [Int: String],
        locale: Locale = .current
    ) -> [PlayerTrackOption] {
        guard !tracks.isEmpty else { return [] }
        var options = [subtitleOffOption(isSelected: selectedID == nil, locale: locale)]
        options.append(contentsOf: subtitlePresentations(
            tracks.sortedByPreferredLanguage(preferred), detectedLanguages: detectedLanguages, locale: locale
        ).map { track, label in
            return PlayerTrackOption(
                id: track.id,
                title: label.text,
                isSelected: track.id == selectedID,
                isExternal: track.isExternal, nativeTitle: label.nativeTitle
            )
        })
        return disambiguatedOptions(options, locale: locale)
    }

    /// Second-line (dual) subtitle picker rows: "Off" pinned first, eligible
    /// tracks preferred-language-first. No `isExternal` flag — the secondary line
    /// always renders through Plozz's overlay.
    static func secondaryOptions(
        eligible: [MediaTrack],
        providerTracks: [MediaTrack] = [],
        selectedID: Int?,
        preferred: [String?],
        detectedLanguages: [Int: String],
        locale: Locale = .current
    ) -> [PlayerTrackOption] {
        guard !eligible.isEmpty else { return [] }
        var options = [subtitleOffOption(isSelected: selectedID == nil, locale: locale)]
        let tracks = eligible.sortedByPreferredLanguage(preferred).map { track in
            track.enriched(withProvider: providerTracks.first { $0.id == track.id })
        }
        options.append(contentsOf: subtitlePresentations(
            tracks, detectedLanguages: detectedLanguages, locale: locale
        ).map { track, label in
            return PlayerTrackOption(
                id: track.id,
                title: label.text,
                isSelected: track.id == selectedID, nativeTitle: label.nativeTitle
            )
        })
        return disambiguatedOptions(options, locale: locale)
    }

    /// The tracks a second subtitle line can show.
    ///
    /// Sourced from the PROVIDER's subtitle probe for the sidecar (native) path
    /// and from the ENGINE's own tracks when the engine decodes a second stream
    /// itself (`.dualSubtitleDecode`, e.g. Plozzigen). Bitmap (PGS/DVD/DVB/VOBSUB)
    /// tracks are **never** eligible as a second line (a bitmap cue is drawn at
    /// its own authored position we can't move), and when the **primary** itself
    /// is a bitmap subtitle, dual mode is disabled entirely (no eligible seconds).
    static func eligibleSecondaryTracks(
        selectedPrimaryID: Int?,
        engineTracks: [MediaTrack],
        providerTracks: [MediaTrack],
        engineSupportsDualDecode: Bool
    ) -> [MediaTrack] {
        if bitmapPrimary(selectedPrimaryID: selectedPrimaryID, engineTracks: engineTracks, providerTracks: providerTracks) != nil {
            return []
        }
        // Engine-dual: source from the engine's own tracks (embedded tracks with
        // no fetchable sidecar are selectable — the engine demuxes them).
        if engineSupportsDualDecode {
            return engineTracks.filter { $0.id != selectedPrimaryID && !$0.isBitmapSubtitle }
        }
        // Sidecar (native): only text tracks with a fetchable URL, excluding the
        // primary. (`isBitmapSubtitle` is redundant with the URL requirement here
        // but kept for symmetry / defence in depth.)
        return providerTracks.filter {
            !$0.isBitmapSubtitle && $0.deliverySource != nil && $0.id != selectedPrimaryID
        }
    }

    /// A short format hint ("PGS", "VOBSUB", "Image", …) when the current primary
    /// subtitle is a bitmap track — used to explain why the dual picker is empty
    /// ("Unavailable with PGS subtitles") rather than "None available". `nil` when
    /// the primary is off or a text track.
    static func imagePrimaryFormat(
        selectedPrimaryID: Int?,
        engineTracks: [MediaTrack],
        providerTracks: [MediaTrack]
    ) -> String? {
        guard let primary = bitmapPrimary(
            selectedPrimaryID: selectedPrimaryID,
            engineTracks: engineTracks,
            providerTracks: providerTracks
        ) else { return nil }
        return TrackLabeling.subtitleFormatHint(codec: primary.codec, isImageBased: true) ?? "Image"
    }

    // MARK: - Private

    private static func disambiguatedOptions(_ options: [PlayerTrackOption], locale: Locale) -> [PlayerTrackOption] {
        let counts = Dictionary(grouping: options, by: \.nativeTitle).mapValues(\.count)
        // Reserve authored labels too: a numbered fallback must not copy another track's title.
        var occupied = Set(options.map(\.nativeTitle))
        return options.map { option in
            guard option.id != PlayerTrackOption.offID, counts[option.nativeTitle, default: 0] > 1 else {
                return option
            }
            let number = presentation(for: TrackLabel(base: .trackNumber(option.id)), locale: locale)
            let suffix = LabelPresentation(content: " (") + number + .init(content: ")")
            var result = option
            repeat {
                result.title = result.title + suffix.text
                result.nativeTitle += suffix.nativeTitle
            } while occupied.contains(result.nativeTitle)
            occupied.insert(result.nativeTitle)
            return result
        }
    }

    private static func bitmapPrimary(
        selectedPrimaryID: Int?,
        engineTracks: [MediaTrack],
        providerTracks: [MediaTrack]
    ) -> MediaTrack? {
        guard let primaryID = selectedPrimaryID,
              let primary = engineTracks.first(where: { $0.id == primaryID })
                ?? providerTracks.first(where: { $0.id == primaryID }),
              primary.isBitmapSubtitle
        else { return nil }
        return primary
    }

    private static func subtitleOffOption(isSelected: Bool, locale: Locale) -> PlayerTrackOption {
        let label = LabelPresentation(resource: LocalizedStringResource(
            "subtitlePicker.option.off", defaultValue: "Off",
            comment: "The row in the subtitle track picker that shows no subtitles. Sits in a list of track names, not next to a switch, so it may need to agree with 'subtitles' rather than read as a generic on/off state."
        ), locale: locale)
        return PlayerTrackOption(id: PlayerTrackOption.offID, title: label.text, isSelected: isSelected, nativeTitle: label.nativeTitle)
    }

    private static func subtitlePresentations(
        _ tracks: [MediaTrack], detectedLanguages: [Int: String], locale: Locale
    ) -> [(MediaTrack, LabelPresentation)] {
        var labels = tracks.map { subtitleLabel($0, detectedLanguages: detectedLanguages, locale: locale) }
        let titles = labels.map { presentation(for: $0, locale: locale).nativeTitle }
        let groups = Dictionary(grouping: tracks.indices, by: { titles[$0] })
        for indices in groups.values where indices.count > 1 {
            let formats = indices.map {
                TrackLabeling.subtitleFormatHint(
                    codec: tracks[$0].codec, isImageBased: tracks[$0].isImageBasedSubtitle,
                    includesTextFormats: true
                )
            }
            // Use known format differences before resorting to arbitrary track numbers.
            guard Set(formats).count > 1 else { continue }
            for (index, format) in zip(indices, formats) {
                guard let format, !labels[index].qualifiers.contains(.format(format)) else { continue }
                labels[index].qualifiers.append(.format(format))
            }
        }
        return zip(tracks, labels).map { ($0, presentation(for: $1, locale: locale)) }
    }

    private static func subtitleLabel(_ track: MediaTrack, detectedLanguages: [Int: String],
                                      locale: Locale) -> TrackLabel {
        TrackLabeling.subtitleLabel(
            displayTitle: track.displayTitle,
            sourceTitle: track.sourceTitle,
            language: track.language,
            codec: track.codec,
            isForced: track.isForced,
            isImageBased: track.isImageBasedSubtitle,
            isHearingImpaired: track.isHearingImpaired,
            isCommentary: track.isCommentary,
            detectedLanguage: detectedLanguages[track.id],
            trackID: track.id,
            locale: locale
        )
    }

    /// Composes a structured ``TrackLabel`` (base + qualifiers) into the final
    /// menu-row `Text`: base, then `" ("`, the qualifiers joined with `", "`,
    /// then `")"`. The separators are punctuation, not copy, so they're kept
    /// verbatim; each qualifier is resolved to either a real localized `Text`
    /// (Plozz's own words) or `Text(verbatim:)` (content — a codec/format
    /// token). `base`/qualifiers are never joined into a plain `String` first,
    /// which is exactly what would hide the copy from the catalog.
    private static func presentation(for label: TrackLabel, locale: Locale) -> LabelPresentation {
        let base: LabelPresentation
        switch label.base {
        case .content(let value):
            base = .init(content: value)
        case .trackNumber(let number):
            base = .init(resource: LocalizedStringResource(
                "Track \(number)",
                comment: "Fallback label for an audio/subtitle track with no resolved language or meaningful provider title, showing its index."
            ), locale: locale)
        }
        guard !label.qualifiers.isEmpty else { return base }
        let qualifiers = label.qualifiers.map { qualifierPresentation($0, locale: locale) }
        let joined = qualifiers.dropFirst().reduce(qualifiers[0]) { accumulated, next in
            accumulated + .init(content: ", ") + next
        }
        return base + .init(content: " (") + joined + .init(content: ")")
    }

    private static func qualifierPresentation(_ qualifier: TrackLabel.Qualifier, locale: Locale) -> LabelPresentation {
        let resource: LocalizedStringResource
        switch qualifier {
        case .forced:
            resource = .init("Forced", comment: "Subtitle track qualifier — the track only shows forced (foreign-language-passage) lines.")
        case .hearingImpaired:
            resource = .init("SDH", comment: "Subtitle/audio track qualifier for a hearing-impaired (SDH) track.")
        case .commentary:
            resource = .init("Commentary", comment: "Audio/subtitle track qualifier for a commentary track.")
        case .audioDescription:
            resource = .init("Audio Description", comment: "Audio track with narration describing visual content.")
        case .autoDetected:
            resource = .init("auto", comment: "Subtitle track qualifier appended when the shown language was guessed from the file's content rather than tagged by the provider.")
        case .format(let value), .version(let value), .title(let value):
            return .init(content: value)
        case .channelCount(let channels):
            resource = .init(
                "\(channels) channels",
                comment: "Fallback wording for an audio track's channel count when it doesn't match a named layout convention (e.g. Stereo, 5.1, 7.1)."
            )
        }
        return .init(resource: resource, locale: locale)
    }

    private struct LabelPresentation {
        var text: Text
        var nativeTitle: String

        init(content: String) {
            text = Text(verbatim: content)
            nativeTitle = content
        }

        init(resource: LocalizedStringResource, locale: Locale) {
            var localized = resource
            localized.locale = locale
            text = Text(localized)
            nativeTitle = String(localized: localized) // l10n:content - UIKit track label; rebuilt when the app locale changes.
        }

        private init(text: Text, nativeTitle: String) {
            self.text = text
            self.nativeTitle = nativeTitle
        }

        static func + (lhs: Self, rhs: Self) -> Self {
            .init(text: lhs.text + rhs.text, nativeTitle: lhs.nativeTitle + rhs.nativeTitle)
        }
    }
}
