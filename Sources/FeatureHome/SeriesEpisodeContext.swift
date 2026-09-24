import CoreModels
import MetadataKit

/// Series-level context that should be propagated onto episode items so fallback
/// artwork/routing stays accurate without per-focus remapping.
struct SeriesEpisodeContext: Sendable {
    let seriesTMDbID: String?
    let animeIDs: [String: String]

    init(series: MediaItem) {
        seriesTMDbID = series.providerIDs["Tmdb"]
        animeIDs = series.providerIDs.filter {
            ContentClassifier.isAnimeProviderIDKey($0.key)
        }
    }

    init(seriesTMDbID: String?, animeIDs: [String: String]) {
        self.seriesTMDbID = seriesTMDbID
        self.animeIDs = animeIDs
    }

    var isEmpty: Bool {
        (seriesTMDbID?.isEmpty != false) && animeIDs.isEmpty
    }

    /// Stamps this context into each episode:
    ///  * parent TMDb id under `SeriesTmdb` when missing;
    ///  * authoritative anime provider ids (AniList/AniDB/MAL/...) when missing.
    ///
    /// Never copy a visible "Anime" genre from the series. Besides changing UI
    /// metadata, a weak genre-only match can poison playback language policy and
    /// artwork routing for every episode (as happened when a live-action series
    /// inherited metadata from an unrelated anime title). Real anime database IDs
    /// are strong enough to propagate and already classify the episode as anime.
    func stamping(_ episodes: [MediaItem]) -> [MediaItem] {
        guard !isEmpty else { return episodes }
        return episodes.map { episode in
            var copy = episode
            if let seriesTMDbID, !seriesTMDbID.isEmpty, copy.providerIDs["SeriesTmdb"] == nil {
                copy.providerIDs["SeriesTmdb"] = seriesTMDbID
            }
            for (key, value) in animeIDs where copy.providerIDs[key] == nil {
                copy.providerIDs[key] = value
            }
            return copy
        }
    }
}
