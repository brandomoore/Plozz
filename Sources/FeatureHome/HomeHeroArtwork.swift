#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import CoreModels
import CoreUI
import HeroUI
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
        // The resolver keeps an online poster as a last resort, after checking
        // library backdrops even when online artwork is preferred.
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
        return HeroLogoFallback(for: item, localizedResolve: { language in
            await ArtworkRouter.shared.artworkURL(.logo, for: item, language: language)
        })
    }

    @MainActor
    static func prepare(
        item: MediaItem, logoItem: MediaItem, references: [ArtworkReference],
        policy: ArtworkPresentationPolicy
    ) async {
        let backdropLookup = backdropFallback(for: item)
        let logoLookup = logoFallback(for: logoItem)
        let fallback = logoLookup.map { lookup in
            HeroLogoFallback(for: logoItem, localizedResolve: { language in
                await ArtworkSession.resolveArtwork(background: true, lookup.localized(to: language).resolve)
            })
        }
        async let logo: Void = HeroLogoPreloader.prepare(
            references: logoItem.artworkReferences(for: .logo), fallback: fallback, policy: policy
        )
        _ = await ArtworkFirstPaintResolver.resolve(
            references: references, variant: .heroPreview, maxAspectRatio: HeroBackdropArtworkPolicy.maxAspectRatio,
            prefersLandscape: true,
            asyncOnlineURL: backdropLookup.map { lookup in
                { await ArtworkSession.resolveArtwork(background: true, lookup) }
            },
            prefersOnlineArtwork: policy.prefersOnlineArtwork, background: true
        )
        await logo
    }

}
#endif
