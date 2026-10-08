#if os(iOS)
import CoreModels
import CoreUI
import Foundation
import MetadataKit
import UIKit

enum PlozziOSDownloadArtwork {
    enum Failure: Error {
        case unavailable
        case invalidImage
    }

    static func references(
        for item: MediaItem, policy: ArtworkPresentationPolicy = .init(area: .downloads)
    ) -> [ArtworkReference] {
        let policy = policy.forArea(.downloads)
        var seen = Set<ArtworkReference>()
        return placements(for: item).flatMap { policy.references(for: item, placement: $0) }
            .filter { seen.insert($0).inserted }
    }

    static func placements(for item: MediaItem) -> [ArtworkPlacement] {
        switch item.kind {
        case .episode: [.detailBackdrop, .episodeThumbnail, .poster, .seriesPoster]
        case .season: [.detailBackdrop, .poster, .seriesPoster]
        default: [.detailBackdrop, .poster]
        }
    }

    static func lookup(for item: MediaItem, router: ArtworkRouter = .shared) async -> URL? {
        await ArtworkSession.artworkResolveLimiter.run {
            guard !Task.isCancelled else { return nil }
            return await router.artworkURL(for: item, placements: placements(for: item))
        }
    }

    static func load(
        for item: MediaItem, policy: ArtworkPresentationPolicy = .init(area: .downloads),
        router: ArtworkRouter = .shared
    ) async throws -> Data {
        let policy = policy.forArea(.downloads)
        try Task.checkCancellation()
        guard let artwork = await ArtworkFirstPaintResolver.resolve(
            references: references(for: item, policy: policy),
            variant: .landscapeCard,
            asyncOnlineURL: { await lookup(for: item, router: router) },
            prefersOnlineArtwork: policy.prefersOnlineArtwork,
            background: true
        ) else { throw Failure.unavailable }
        let data = await Task.detached(priority: .utility) {
            artwork.image.jpegData(compressionQuality: 0.85)
        }.value
        try Task.checkCancellation()
        guard let data, !data.isEmpty, data.count <= 15_000_000 else { throw Failure.invalidImage }
        return data
    }

    static func isValid(_ data: Data) -> Bool {
        !data.isEmpty && data.count <= 15_000_000
            && ArtworkImageCache.downsample(data, maxPixelSize: 64) != nil
    }

    static func isValidFile(at url: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, size <= 15_000_000,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
            return isValid(data)
        }.value
    }
}
#endif
