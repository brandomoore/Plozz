import CoreModels
import Foundation
import MetadataKit

public struct MediaArtworkSource: Sendable {
    public let references: [ArtworkReference]
    public let fallbackURL: (@Sendable () async -> URL?)?
    public let policy: ArtworkPresentationPolicy
    public let itemIdentity: String

    public init(item: MediaItem, placement: ArtworkPlacement, policy: ArtworkPresentationPolicy) {
        self.policy = policy
        itemIdentity = item.stablePresentationID
        references = policy.references(for: item, placement: placement)
        guard ![.folder, .collection, .unknown].contains(item.kind) else {
            fallbackURL = nil
            return
        }
        let kind: ArtworkKind
        switch placement {
        case .poster, .seriesPoster, .seasonPoster: kind = .poster
        case .logo: kind = .logo
        case .episodeThumbnail: kind = .thumbnail
        default: kind = .hero
        }
        let subject = placement == .episodeThumbnail ? item : PosterCardView.seriesArtworkItem(for: item)
        fallbackURL = {
            await ArtworkSession.artworkResolveLimiter.run {
                guard !Task.isCancelled else { return nil }
                return await ArtworkRouter.shared.artworkURL(kind, for: subject)
            }
        }
    }

    #if canImport(UIKit)
    @MainActor
    public func resolve(
        variant: ArtworkImageVariant,
        maxAspectRatio: CGFloat? = nil
    ) async -> FirstPaintArtwork? {
        await ArtworkFirstPaintResolver.resolve(
            references: references,
            variant: variant,
            maxAspectRatio: maxAspectRatio,
            asyncOnlineURL: fallbackURL,
            maximumOnlineWait: ArtworkFirstPaintResolver.focalArtworkWait,
            prefersOnlineArtwork: policy.prefersOnlineArtwork
        )
    }
    #endif
}
