#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import CoreModels
import CoreUI
import MetadataKit

/// The Home hero's external-art fallbacks, shared by the carousel and the hero
/// that follows focus so both show the same art for the same title. Each mirrors
/// `DetailHeroView`: server art first, and these only once it fails.
enum HomeHeroArtwork {
    /// The ordered backdrop candidates for a title with nothing resolved yet.
    static func backdropReferences(for item: MediaItem) -> [ArtworkReference] {
        let explicit = item.artworkReferences(for: .homeHero)
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

    static func logoFallback(for item: MediaItem) -> (@Sendable () async -> URL?)? {
        switch item.kind {
        case .folder, .collection, .unknown: return nil
        default: break
        }
        return { await ArtworkRouter.shared.artworkURL(.logo, for: item) }
    }

    static func backgroundSample(
        for item: MediaItem,
        references: [ArtworkReference]
    ) -> (@Sendable () async -> HeroBackgroundSample?)? {
        return {
            if let sample = await HeroBackgroundSampler.sample(references: references) { return sample }
            if let tmdb = await ArtworkRouter.shared.artworkURL(.hero, for: item),
               let sample = await HeroBackgroundSampler.sample(urls: [tmdb]) { return sample }
            if let poster = item.posterURL,
               let sample = await HeroBackgroundSampler.sample(urls: [poster]) { return sample }
            return nil
        }
    }
}
#endif
