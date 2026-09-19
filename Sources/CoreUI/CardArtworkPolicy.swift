#if canImport(SwiftUI)
import CoreModels
import Foundation

/// Presentation context that must not change a media item's provider or playback identity.
public enum CardArtworkPolicy: Hashable, Sendable {
    case standard
    case extra

    var allowsOnlineFallback: Bool { self == .standard }

    func pinIdentity(for item: MediaItem) -> String {
        switch self {
        case .standard:
            item.stablePresentationID
        case .extra:
            // A generic card may have pinned an online winner for the same item
            // and references. Extras must never inherit that title-level image.
            "\(item.stablePresentationID)|extra-artwork"
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
            return unique(primary + fallback)
        }
        switch style {
        case .poster:
            return item.artworkReferences(for: item.kind == .episode ? .seriesPoster : .poster)
        case .landscape:
            if item.kind == .episode {
                return item.artworkReferences(for: .episodeThumbnail)
            }
            return unique(
                explicit(.detailBackdrop, for: item)
                    + remote([item.backdropURL, item.posterURL, item.fallbackArtworkURL])
            )
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
