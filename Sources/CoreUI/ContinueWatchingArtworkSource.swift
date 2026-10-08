#if canImport(UIKit)
import CoreModels
import Foundation
import MetadataKit
import UIKit

/// The same reference ladder, lookup subject and policy for cards and lookahead.
public struct ContinueWatchingArtworkSource: Sendable {
    let item: MediaItem
    let style: PosterCardView.Style
    let cardPolicy: CardArtworkPolicy
    let allowsFallback: Bool
    let router: ArtworkRouter
    let policy: ArtworkPresentationPolicy

    public init(
        item: MediaItem, style: PosterCardView.Style,
        policy: ArtworkPresentationPolicy, cardPolicy: CardArtworkPolicy = .standard,
        enablesAsyncArtworkFallback: Bool = true, router: ArtworkRouter = .shared
    ) {
        self.item = item
        self.style = style
        self.policy = policy.forArea(.continueWatching)
        self.cardPolicy = cardPolicy
        self.allowsFallback = enablesAsyncArtworkFallback && cardPolicy.allowsOnlineFallback
        self.router = router
    }

    var pinIdentity: String { cardPolicy.pinIdentity(for: item) }
    var variant: ArtworkImageVariant { style == .poster ? .posterCard : .landscapeCard }
    var aspectGuard: CGFloat? { style == .poster ? 0.9 : nil }
    var logoReferences: [ArtworkReference] { item.artworkReferences(for: .logo) }

    public var identity: String {
        [
            pinIdentity, style == .poster ? "poster" : "landscape",
            policy.identity, policy.settings.preference(in: .continueWatching).rawValue,
            allowsFallback ? "fallback" : "local-only",
            MetadataQuery(item.kind == .episode ? ArtworkRouter.seriesArtworkItem(for: item) : item).cacheKey(for: .hero),
            references(textlessBackdrop: nil).map(\.privacySafeIdentity).joined(separator: "\n"),
            logoReferences.map(\.privacySafeIdentity).joined(separator: "\n"),
        ].joined(separator: "|")
    }

    func primaryReference(textlessBackdrop: URL?) -> ArtworkReference? {
        PosterCardPresentation.continueWatchingPrimaryReference(
            for: item, policy: policy,
            textlessBackdrop: policy.prefersTextlessArtwork ? textlessBackdrop : nil
        )
    }

    func references(textlessBackdrop: URL?) -> [ArtworkReference] {
        let ladder = item.kind == .episode
            ? item.seriesArtworkReferences(prefersPortrait: style == .poster)
            : cardPolicy.references(for: item, style: style)
        guard let primary = primaryReference(textlessBackdrop: textlessBackdrop) else { return ladder }
        return [primary] + ladder.filter { $0 != primary }
    }

    func fallback(background: Bool = false) -> (@Sendable () async -> URL?)? {
        guard allowsFallback else { return nil }
        let lookup: (@Sendable () async -> URL?)?
        if item.kind == .episode {
            let placements: [ArtworkPlacement] = style == .poster
                ? [.seriesPoster] : [.detailBackdrop, .seriesPoster]
            lookup = { await router.artworkURL(for: item, placements: placements) }
        } else {
            lookup = cardPolicy.artworkFallback(for: item, style: style, router: router)
        }
        guard let lookup else { return nil }
        return { await ArtworkSession.resolveArtwork(background: background, lookup) }
    }

    func logoFallback(background: Bool = false) -> HeroLogoFallback? {
        guard allowsFallback else { return nil }
        let target = item.kind == .episode ? ArtworkRouter.seriesArtworkItem(for: item) : item
        return HeroLogoFallback(for: target) {
            await ArtworkSession.resolveArtwork(background: background) {
                await router.artworkURL(.logo, for: target)
            }
        }
    }

    @MainActor
    public func prepare(store: TextlessBackdropStore = .shared) async {
        async let logo: Void = HeroLogoPreloader.prepare(
            references: logoReferences, fallback: logoFallback(background: true), policy: policy
        )
        await prepareBackground(store: store)
        await logo
    }

    @MainActor
    private func prepareBackground(store: TextlessBackdropStore) async {
        if allowsFallback, policy.prefersTextlessArtwork {
            await store.prepare(for: item, variant: variant, background: true)
        }
        guard !Task.isCancelled else { return }
        let textless = policy.prefersTextlessArtwork ? store.backdrop(for: item) : nil
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
