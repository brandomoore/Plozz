import Foundation
import CoreModels

/// Owns movie audio, series tracks and movie/series zoom memory for a playback session:
/// key derivation (cross-server identity first, per-server fallback), gated
/// reads, gated writes fanned out to every key, and the cross-server
/// reconciliation that runs once a series' external ids resolve.
///
/// Extracted from `PlayerViewModel` so this cohesive slice — which servers a
/// remembered choice sticks across, and how audio/subtitle are reconciled
/// independently — is unit-testable with a fake store, without a running engine.
/// It performs no engine/UI side effects itself: ``reconcile`` returns a
/// ``ReconcileOutcome`` describing what the caller should apply to playback, so
/// the engine work stays on the `@MainActor` view model.
///
/// Provider-agnostic by design: the whole point is that a choice made on Plex
/// follows the show to Jellyfin (and back) via the shared external-id keys.
struct SeriesTrackMemory {
    /// The backing preference store, or `nil` for standalone/test players that
    /// don't persist title memory.
    let store: (any SeriesTrackPreferenceStoring)?
    /// Account id used for the per-server fallback key when the item itself has no
    /// `sourceAccountID` (e.g. a lightweight episode row).
    let accountFallbackID: String?
    /// Whether per-series audio memory is enabled (profile toggle).
    let rememberAudio: Bool
    /// Whether per-series subtitle memory is enabled (profile toggle).
    let rememberSubtitle: Bool

    /// The side effects the caller should apply to live playback after a
    /// cross-server reconcile. Fields default to "nothing to do".
    struct ReconcileOutcome: Equatable {
        /// A remembered audio language imported from another server that should be
        /// applied to the engine once its audio tracks are known. `nil` = no import.
        var importedAudioLanguage: String?
        /// `true` when the load-time subtitle selection should be re-applied
        /// because a remembered subtitle decision was imported from another server.
        var shouldReapplyInitialSubtitle: Bool = false
        var importedVideoZoom: VideoZoomPreference?
    }

    // MARK: Key derivation

    func supportsTitlePreferences(for item: MediaItem) -> Bool {
        !item.isExtra && !item.isTrailer && (item.kind == .movie || item.kind == .episode)
    }

    /// Movie keys are kind-qualified; series keys preserve existing stored choices.
    func localKey(for item: MediaItem) -> String? {
        guard supportsTitlePreferences(for: item) else { return nil }
        if item.kind == .movie {
            let parts = [item.sourceAccountID ?? accountFallbackID ?? "_", item.id]
            return "movie:local:" + parts.map { "\($0.utf8.count):\($0)" }.joined()
        }
        guard item.kind == .episode, let seriesID = item.seriesID else { return nil }
        return SeriesTrackPreferenceKey.make(
            sourceAccountID: item.sourceAccountID ?? accountFallbackID,
            seriesID: seriesID
        )
    }

    /// Strong movie identities or series-level episode identities. Never title matching.
    func crossServerKeys(for item: MediaItem) -> [String] {
        guard supportsTitlePreferences(for: item) else { return [] }
        if item.kind == .movie {
            return MediaItemIdentity.identities(for: item).compactMap {
                guard case let .external(source, value) = $0 else { return nil }
                return "movie:\(source):\(value)"
            }
        }
        guard item.kind == .episode else { return [] }
        return SeriesTrackPreferenceKey.crossServerKeys(providerIDs: item.providerIDs)
    }

    /// Ordered keys to read/write remembered preferences: cross-server identity
    /// first (so a choice transfers between servers) then the per-server fallback.
    func preferenceKeys(for item: MediaItem) -> [String] {
        crossServerKeys(for: item) + [localKey(for: item)].compactMap { $0 }
    }

    // MARK: Reads (gated on the toggles)

    /// Movie audio is always remembered; the audio toggle applies only to series.
    func rememberedAudioLanguage(for item: MediaItem) -> String? {
        guard item.kind == .movie || rememberAudio else { return nil }
        return firstAudioLanguage(preferenceKeys(for: item))
    }

    /// The remembered subtitle decision for this item's series, or `nil` when the
    /// toggle is off or nothing is remembered.
    func rememberedSubtitle(for item: MediaItem) -> RememberedSubtitleSelection? {
        guard item.kind == .episode, rememberSubtitle else { return nil }
        return firstSubtitle(preferenceKeys(for: item))
    }

    // MARK: Writes (gated on the toggles)

    /// Records the viewer's manual audio-language pick for the movie or series,
    /// fanned out to every key so it follows the title to any server. Only a
    /// language-tagged, non-empty track is remembered; the language is normalized
    /// (`eng` → `en`) so a code that differs in form between servers still matches.
    func recordAudioSelection(language: String?, for item: MediaItem) {
        guard item.kind == .movie || rememberAudio, let store,
              let language, !language.isEmpty else { return }
        let normalized = LanguageMatch.normalized(language) ?? language
        for key in preferenceKeys(for: item) {
            store.setAudioLanguage(normalized, forKey: key)
        }
    }

    /// Records the viewer's manual subtitle pick (a language, or Off) for the
    /// item's series, fanned out to every key. A concrete language is normalized so
    /// it matches cross-server; Off is always remembered as-is.
    func recordSubtitleSelection(_ selection: RememberedSubtitleSelection?, for item: MediaItem) {
        guard item.kind == .episode, rememberSubtitle, let store, let selection else { return }
        let normalized: RememberedSubtitleSelection
        switch selection {
        case .off:
            normalized = .off
        case .language(let code):
            normalized = .language(LanguageMatch.normalized(code) ?? code)
        }
        for key in preferenceKeys(for: item) {
            store.setSubtitle(normalized, forKey: key)
        }
    }

    // MARK: Title zoom

    func rememberedVideoZoom(for item: MediaItem) -> VideoZoomPreference? {
        firstVideoZoom(preferenceKeys(for: item))
    }

    func recordVideoZoom(_ zoom: VideoZoomPreference, for item: MediaItem) {
        for key in preferenceKeys(for: item) {
            store?.setVideoZoom(zoom, forKey: key)
        }
    }

    // MARK: Cross-server reconciliation

    /// Reconciles per-series memory across servers once the cross-server keys are
    /// resolvable (external ids folded onto the item). Audio, subtitle and zoom are
    /// reconciled **independently** — the viewer may have changed only one this
    /// session, and the fields can live under different keys when servers
    /// expose different external-id subsets:
    /// - Viewer changed this dimension this session → their pick is the newest
    ///   truth; mirror it onto every key.
    /// - Otherwise → if a cross-server key carries a value that differs from the
    ///   per-server key, import it: backfill the per-server key and report the
    ///   import so the caller applies it to live playback.
    func reconcile(
        item: MediaItem,
        viewerChangedAudio: Bool,
        viewerChangedSubtitle: Bool,
        viewerChangedVideoZoom: Bool = false
    ) -> ReconcileOutcome {
        var outcome = ReconcileOutcome()
        guard let store, item.kind == .episode else { return outcome }
        let crossKeys = crossServerKeys(for: item)
        guard !crossKeys.isEmpty else { return outcome }
        let localKeys = [localKey(for: item)].compactMap { $0 }
        let allKeys = crossKeys + localKeys

        if rememberAudio {
            if viewerChangedAudio {
                if let language = firstAudioLanguage(localKeys) {
                    for key in allKeys { store.setAudioLanguage(language, forKey: key) }
                }
            } else {
                let localLanguage = firstAudioLanguage(localKeys)
                if let crossLanguage = firstAudioLanguage(crossKeys),
                   crossLanguage != localLanguage {
                    for key in localKeys { store.setAudioLanguage(crossLanguage, forKey: key) }
                    outcome.importedAudioLanguage = crossLanguage
                }
            }
        }

        if rememberSubtitle {
            if viewerChangedSubtitle {
                if let subtitle = firstSubtitle(localKeys) {
                    for key in allKeys { store.setSubtitle(subtitle, forKey: key) }
                }
            } else {
                let localSubtitle = firstSubtitle(localKeys)
                if let crossSubtitle = firstSubtitle(crossKeys),
                   crossSubtitle != localSubtitle {
                    for key in localKeys { store.setSubtitle(crossSubtitle, forKey: key) }
                    outcome.shouldReapplyInitialSubtitle = true
                }
            }
        }

        if viewerChangedVideoZoom {
            if let zoom = firstVideoZoom(localKeys) {
                for key in allKeys { store.setVideoZoom(zoom, forKey: key) }
            }
        } else if let zoom = firstVideoZoom(crossKeys), zoom != firstVideoZoom(localKeys) {
            for key in localKeys { store.setVideoZoom(zoom, forKey: key) }
            outcome.importedVideoZoom = zoom
        }

        return outcome
    }

    // MARK: Per-field lookups

    private func firstVideoZoom(_ keys: [String]) -> VideoZoomPreference? {
        for key in keys {
            if let zoom = store?.preference(forKey: key)?.videoZoom { return zoom }
        }
        return nil
    }

    /// First remembered audio language across `keys`, in order. Resolved per field
    /// (not per stored object) so a show whose external-id coverage differs across
    /// servers can hold audio under one key and subtitle under another.
    private func firstAudioLanguage(_ keys: [String]) -> String? {
        guard let store else { return nil }
        for key in keys {
            if let language = store.preference(forKey: key)?.audioLanguage { return language }
        }
        return nil
    }

    /// First remembered subtitle decision across `keys`, in order. Resolved per
    /// field for the same reason as ``firstAudioLanguage``.
    private func firstSubtitle(_ keys: [String]) -> RememberedSubtitleSelection? {
        guard let store else { return nil }
        for key in keys {
            if let subtitle = store.preference(forKey: key)?.subtitle { return subtitle }
        }
        return nil
    }
}
