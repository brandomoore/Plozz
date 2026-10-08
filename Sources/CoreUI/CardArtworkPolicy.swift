#if canImport(SwiftUI)
import CoreModels
import Foundation
import MetadataKit

/// Presentation context that must not change a media item's provider or playback identity.
public enum CardArtworkPolicy: Hashable, Sendable {
    case standard
    case extra

    var allowsOnlineFallback: Bool { self == .standard }

    func posterFallback(for item: MediaItem) -> (@Sendable () async -> URL?)? {
        artworkFallback(for: item, style: .poster)
    }

    func artworkFallback(
        for item: MediaItem, style: PosterCardView.Style, router: ArtworkRouter = .shared
    ) -> (@Sendable () async -> URL?)? {
        guard allowsOnlineFallback, item.supportsExternalArtworkLookup else { return nil }
        let placements: [ArtworkPlacement]
        switch style {
        case .poster:
            placements = [item.kind == .episode ? .seriesPoster : .poster]
        case .landscape:
            if item.kind == .episode {
                placements = item.seasonNumber != nil && item.episodeNumber != nil
                    ? [.episodeThumbnail, .detailBackdrop, .seriesPoster] : [.detailBackdrop, .seriesPoster]
            } else {
                placements = [.detailBackdrop, .poster]
            }
        }
        let nativeFallback = style == .landscape && item.kind == .episode
            ? item.libraryArtworkURL(item.fallbackArtworkURL) : nil
        return {
            await router.artworkURL(for: item, placements: placements) ?? nativeFallback
        }
    }

    func pinIdentity(for item: MediaItem) -> String {
        let identity: String
        if let subject = item.artworkLookupSubject {
            let ids = subject.providerIDs.sorted { $0.key < $1.key }
                .map { "\($0.key.utf8.count):\($0.key)\($0.value.utf8.count):\($0.value)" }.joined()
            identity = "\(item.stablePresentationID)|catalog:\(subject.kind.rawValue):\(subject.id)|\(ids)"
                + "|\(MetadataQuery(item.artworkLookupItem).cacheKey(for: .poster))"
        } else {
            identity = item.stablePresentationID
        }
        switch self {
        case .standard:
            return identity
        case .extra:
            // A generic card may have pinned an online winner for the same item
            // and references. Extras must never inherit that title-level image.
            return "\(identity)|extra-artwork"
        }
    }

    func references(for item: MediaItem, style: PosterCardView.Style) -> [ArtworkReference] {
        if self == .extra {
            // Primary belongs to this clip; detail/backdrop art can belong to its
            // parent movie. Keep every native fallback, but only after primary.
            let primary = explicit(.poster, for: item)
                + remote([item.posterURL])
            let fallback = explicit(.detailBackdrop, for: item)
                + remote([item.backdropURL, item.fallbackArtworkURL])
            return unique(item.libraryArtworkReferences(primary + fallback))
        }
        switch style {
        case .poster:
            return item.artworkReferences(for: item.kind == .episode ? .seriesPoster : .poster)
        case .landscape:
            if item.kind == .episode {
                return unique(item.artworkReferences(for: .episodeThumbnail) + item.seriesArtworkReferences())
            }
            return unique(item.libraryArtworkReferences(
                explicit(.detailBackdrop, for: item)
                    + remote([item.backdropURL, item.posterURL, item.fallbackArtworkURL])
                    + item.artworkReferences(for: .poster)
            ))
        }
    }

    private func explicit(_ placement: ArtworkPlacement, for item: MediaItem) -> [ArtworkReference] {
        item.artworkSelections.first(where: { $0.placement == placement })?.references ?? []
    }

    private func remote(_ urls: [URL?]) -> [ArtworkReference] {
        urls.compactMap { $0.map(ArtworkReference.remote) }
    }

    private func unique(_ references: [ArtworkReference]) -> [ArtworkReference] {
        var seen = Set<ArtworkReference>()
        return references.filter { seen.insert($0).inserted }
    }
}
#endif
