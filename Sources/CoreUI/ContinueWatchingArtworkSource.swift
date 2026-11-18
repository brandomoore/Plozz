#if canImport(UIKit)
import CoreModels
import Foundation
import MetadataKit
import UIKit

/// Shared logo/background composition for Continue Watching and opt-in landscape rows.
public struct ContinueWatchingArtworkSource: Sendable {
    let item: MediaItem
    let style: PosterCardView.Style
    let cardPolicy: CardArtworkPolicy
    let allowsFallback: Bool
    let router: ArtworkRouter
    let policy: ArtworkPresentationPolicy
    let titleLogo: LandscapeTitleLogo?

    public init(
        item: MediaItem, style: PosterCardView.Style,
        policy: ArtworkPresentationPolicy, cardPolicy: CardArtworkPolicy = .standard,
        enablesAsyncArtworkFallback: Bool = true, router: ArtworkRouter = .shared,
        titleLogo: LandscapeTitleLogo? = nil
    ) {
        self.item = item
        self.style = style
        self.policy = titleLogo == nil ? policy.forArea(.continueWatching) : policy
        self.titleLogo = titleLogo
        self.cardPolicy = cardPolicy
        self.allowsFallback = enablesAsyncArtworkFallback && cardPolicy.allowsOnlineFallback
        self.router = router
    }

    var pinIdentity: String {
        cardPolicy.pinIdentity(for: item) + (titleLogo.map { "|title-logo:\($0.rawValue)" } ?? "")
    }
    var variant: ArtworkImageVariant { style == .poster ? .posterCard : .landscapeCard }
    var aspectGuard: CGFloat? { style == .poster ? 0.9 : nil }
    var logoReferences: [ArtworkReference] { item.artworkReferences(for: .logo) }
    var prefersTextlessBackdrop: Bool {
        guard style == .landscape else { return false }
        guard let titleLogo else { return policy.prefersTextlessArtwork }
        return titleLogo == .on && policy.settings.preference(in: policy.area) != .library
    }

    func suppressesLogo(
        artworkAlreadyCarriesTitle: Bool, hasCurrentArtwork: Bool, textlessBackdropSuppressesLogo: Bool
    ) -> Bool {
        if let titleLogo {
            return titleLogo == .off || style != .landscape || !hasCurrentArtwork
        }
        return style == .poster || artworkAlreadyCarriesTitle
            || (prefersTextlessBackdrop && textlessBackdropSuppressesLogo)
    }

    public var identity: String {
        [
            pinIdentity, style == .poster ? "poster" : "landscape",
            policy.forPlacement(.logo).identity, policy.settings.preference(in: policy.area).rawValue,
            allowsFallback ? "fallback" : "local-only",
            MetadataQuery(item.kind == .episode ? ArtworkRouter.seriesArtworkItem(for: item) : item).cacheKey(for: .hero),
            references(textlessBackdrop: nil).map(\.privacySafeIdentity).joined(separator: "\n"),
            logoReferences.map(\.privacySafeIdentity).joined(separator: "\n"),
        ].joined(separator: "|")
    }

    func primaryReference(textlessBackdrop: URL?) -> ArtworkReference? {
        guard style == .landscape else { return nil }
        if titleLogo != nil {
            return prefersTextlessBackdrop ? textlessBackdrop.map(ArtworkReference.remote) : nil
        }
        return PosterCardPresentation.continueWatchingPrimaryReference(
            for: item, policy: policy,
            textlessBackdrop: policy.prefersTextlessArtwork ? textlessBackdrop : nil
        )
    }

    func references(textlessBackdrop: URL?) -> [ArtworkReference] {
        var ladder = item.kind == .episode
            ? item.seriesArtworkReferences(prefersPortrait: style == .poster)
            : cardPolicy.references(for: item, style: style, prefersLandscapeKeyArt: false)
        if titleLogo != nil {
            let titled = PosterCardPresentation.titleBearingArtwork(for: item)
            let candidates = item.artworkReferences(for: .homeHero, preferringLibrarySelection: true)
                + item.artworkReferences(for: .landscapeCard) + ladder
            var seen = Set<ArtworkReference>()
            ladder = (candidates.filter { !titled.contains($0) } + candidates)
                .filter { seen.insert($0).inserted }
        }
        guard let primary = primaryReference(textlessBackdrop: textlessBackdrop) else { return ladder }
        return [primary] + ladder.filter { $0 != primary }
    }

    func fallback(background: Bool = false) -> (@Sendable () async -> URL?)? {
        guard allowsFallback else { return nil }
        let lookup: (@Sendable () async -> URL?)?
        if titleLogo != nil {
            lookup = { await router.artworkURL(.hero, for: item) }
        } else if item.kind == .episode {
            let placements: [ArtworkPlacement] = style == .poster
                ? [.seriesPoster] : [.detailBackdrop, .seriesPoster]
            lookup = { await router.artworkURL(for: item, placements: placements) }
        } else {
            lookup = cardPolicy.artworkFallback(
                for: item, style: style, router: router, prefersLandscapeKeyArt: false
            )
        }
        guard let lookup else { return nil }
        return { await ArtworkSession.resolveArtwork(background: background, lookup) }
    }

    func logoFallback(background: Bool = false) -> HeroLogoFallback? {
        guard allowsFallback else { return nil }
        let target = item.kind == .episode ? ArtworkRouter.seriesArtworkItem(for: item) : item
        return HeroLogoFallback(for: target, localizedResolve: { language in
            await ArtworkSession.resolveArtwork(background: background) {
                await router.artworkURL(.logo, for: target, language: language)
            }
        })
    }

    @MainActor
    public func prepare(store: TextlessBackdropStore = .shared) async {
        guard style == .landscape else {
            await prepareBackground(store: store)
            return
        }
        async let logo: Void = HeroLogoPreloader.prepare(
            references: logoReferences, fallback: logoFallback(background: true), policy: policy
        )
        await prepareBackground(store: store)
        await logo
    }

    @MainActor
    private func prepareBackground(store: TextlessBackdropStore) async {
        if allowsFallback, prefersTextlessBackdrop {
            await store.prepare(for: item, variant: variant, background: true)
        }
        guard !Task.isCancelled else { return }
        let textless = prefersTextlessBackdrop ? store.backdrop(for: item) : nil
        await ArtworkFirstPaintResolver.prepare(
            references: references(textlessBackdrop: textless),
            prefersPrimaryReference: primaryReference(textlessBackdrop: textless) != nil,
            variant: variant, maxAspectRatio: aspectGuard,
            asyncOnlineURL: fallback(background: true),
            pinIdentity: pinIdentity, policy: policy
        )
    }
}
#endif
