import Foundation
import CoreModels
import CoreUI
import MetadataKit

/// Bridges the music UI to MetadataKit's keyless artwork providers via
/// ``ArtworkRouter``. Each factory returns a best-effort `@Sendable` closure that
/// `FallbackAsyncImage` orders according to the profile's Music artwork choice.
/// Recommended keeps library covers first; online providers only fill gaps.
///
/// Resolved URLs are memoized in the router's persistent ``MetadataDiskCache``
/// and the decoded bytes in CoreUI's `ArtworkImageCache`, so there is a single
/// caching path shared with the rest of the app. Returns `nil` (meaning "no
/// fallback to attempt") when there is nothing meaningful to search by.
enum MusicArtworkFallback {
    #if canImport(UIKit)
    static func resolveTrack(_ track: MusicTrack, policy: ArtworkPresentationPolicy) async -> FirstPaintArtwork? {
        await ArtworkFirstPaintResolver.resolve(
            references: track.artworkURL.map { [.remote($0)] } ?? [],
            variant: .heroBackdrop,
            asyncOnlineURL: trackCover(title: track.title, album: track.albumTitle, artist: track.artistName),
            maximumOnlineWait: ArtworkFirstPaintResolver.denseArtworkWait,
            prefersOnlineArtwork: policy.prefersOnlineArtwork
        )
    }
    #endif

    /// Album cover (Deezer → Cover Art Archive), by album title disambiguated by
    /// artist. `nil` when the title is blank.
    static func albumCover(title: String, artist: String?) -> (@Sendable () async -> URL?)? {   // l10n:content — album/track name used for artwork lookup
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return nil }
        let cleanArtist = artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let artistQuery = (cleanArtist?.isEmpty == false) ? cleanArtist : nil
        return {
            await ArtworkRouter.shared.albumCoverURL(artist: artistQuery, album: cleanTitle)
        }
    }

    /// Artist hero image (Deezer `picture_xl`), by artist name. `nil` when blank.
    static func artistImage(name: String) -> (@Sendable () async -> URL?)? {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return nil }
        return {
            await ArtworkRouter.shared.artistImageURL(artist: cleanName)
        }
    }

    /// Album-cover fallback for a single track: prefers the track's album title,
    /// falling back to the track title, disambiguated by artist.
    static func trackCover(title: String, album: String?, artist: String?) -> (@Sendable () async -> URL?)? {   // l10n:content — album/track name used for artwork lookup
        let cleanAlbum = album?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleanAlbum, !cleanAlbum.isEmpty {
            return albumCover(title: cleanAlbum, artist: artist)
        }
        return albumCover(title: title, artist: artist)
    }
}
