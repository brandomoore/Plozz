import CoreModels
import Foundation
import MetadataKit

/// Shared by the episode card and its warmer so source preference, explicit
/// artwork references, and spoiler protection select the same image.
public struct EpisodeArtworkSource: Sendable {
    public let references: [ArtworkReference]
    public let pinIdentity: String
    public let fallbackURL: @Sendable () async -> URL?
    public let policy: ArtworkPresentationPolicy
    #if canImport(UIKit)
    public let requestIdentity: String
    private let prefersOnlineArtwork: Bool
    #endif

    public init(
        item: MediaItem, spoilerSettings: SpoilerSettings,
        policy: ArtworkPresentationPolicy = .init(area: .episodes),
        router: ArtworkRouter = .shared
    ) {
        self.policy = policy
        let hidesStill = spoilerSettings.mode == .placeholder
            && spoilerSettings.shouldHideThumbnail(for: item)
        var seen = Set<ArtworkReference>()
        let seriesReferences = item.seriesArtworkReferences()
        references = (hidesStill ? seriesReferences : item.artworkReferences(for: .episodeThumbnail) + seriesReferences)
            .filter { seen.insert($0).inserted }
        // Posterless episode and spoiler-safe show art otherwise have the same
        // empty reference list. Their prepared images must never share a key.
        pinIdentity = "\(item.stablePresentationID)|\(hidesStill ? "series-artwork" : "episode-artwork")"
        let placements: [ArtworkPlacement] = hidesStill
            ? [.detailBackdrop, .seriesPoster] : [.episodeThumbnail, .detailBackdrop, .seriesPoster]
        fallbackURL = {
            await router.artworkURL(for: item, placements: placements)
                ?? item.libraryArtworkURL(item.fallbackArtworkURL)
        }
        #if canImport(UIKit)
        prefersOnlineArtwork = policy.prefersOnlineArtwork
        requestIdentity = ArtworkResolveKey.make(
            references: references, variant: .landscapeCard, maxAspectRatio: nil,
            pinIdentity: pinIdentity,
            providerPolicyIdentity: policy.identity
        )
        #endif
    }

    #if canImport(UIKit)
    @MainActor
    public var preparedArtwork: FirstPaintArtwork? {
        ArtworkSeedMemo.prepared(for: requestIdentity, variant: .landscapeCard)
    }

    @MainActor
    public func resolve(background: Bool = false) async -> FirstPaintArtwork? {
        if let preparedArtwork { return preparedArtwork }
        guard let artwork = await ArtworkFirstPaintResolver.resolve(
            references: references, variant: .landscapeCard,
            asyncOnlineURL: fallbackURL,
            prefersOnlineArtwork: prefersOnlineArtwork,
            sharedKey: background ? nil : requestIdentity, background: background
        ), !Task.isCancelled else { return nil }
        ArtworkSeedMemo.store(artwork, for: requestIdentity)
        return artwork
    }

    @MainActor
    public func prepare() async {
        _ = await resolve(background: true)
    }
    #endif
}
