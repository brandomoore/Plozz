#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import CoreModels
import CoreUI
import MetadataKit

/// The Home hero's external-art fallbacks, shared by the carousel and the hero
/// that follows focus so both show the same art for the same title. Each mirrors
/// `DetailHeroView`; the renderer applies the active profile's source preference.
enum HomeHeroArtwork {
    /// The same candidates, with the picture a card beside the hero is showing
    /// moved to the back: when the planner has another backdrop for the title,
    /// the hero and the card no longer show the same picture. A title with only
    /// one keeps it.
    static func backdropReferences(
        for item: MediaItem,
        avoiding shown: [ArtworkReference],
        policy: ArtworkPresentationPolicy = .init(area: .home)
    ) -> [ArtworkReference] {
        let references = backdropReferences(for: item, policy: policy)
        guard policy.prefersOnlineArtwork else { return references }
        guard let first = references.first, shown.contains(first) else { return references }
        return references.filter { !shown.contains($0) } + references.filter { shown.contains($0) }
    }

    /// The ordered backdrop candidates for a title with nothing resolved yet.
    static func backdropReferences(
        for item: MediaItem, policy: ArtworkPresentationPolicy = .init(area: .home)
    ) -> [ArtworkReference] {
        let explicit = item.artworkReferences(
            for: .homeHero, preferringLibrarySelection: !policy.prefersOnlineArtwork
        )
        let local = explicit.filter {
            if case .networkFile = $0 { return true }
            return false
        }
        let remote = explicit.filter {
            if case .remote = $0 { return true }
            return false
        }
        var seen = Set<ArtworkReference>()
        return (local + remote).filter { seen.insert($0).inserted }
    }

    static func backdropFallback(for item: MediaItem) -> (@Sendable () async -> URL?)? {
        switch item.kind {
        case .folder, .collection, .unknown: return nil
        default: break
        }
        // art → TMDb hero → the item's own poster. Some titles (e.g. a Plex movie
        // with a poster but no fanart/`art`) have no landscape backdrop anywhere;
        // rather than leave the hero blank, fall back to the poster so the user
        // still sees the artwork the server does have. Only reached when the
        // primary backdrop URLs fail, so a title with real backdrop art is
        // unaffected.
        return {
            await ArtworkRouter.shared.heroArtworkURL(
                for: item,
                placement: .homeHero
            )
        }
    }

    static func logoFallback(for item: MediaItem) -> HeroLogoFallback? {
        switch item.kind {
        case .folder, .collection, .unknown: return nil
        default: break
        }
        return HeroLogoFallback(for: item) { await ArtworkRouter.shared.artworkURL(.logo, for: item) }
    }

}
#endif
