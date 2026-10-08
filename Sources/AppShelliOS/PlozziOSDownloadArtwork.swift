#if os(iOS)
import CoreModels
import CoreUI
import Foundation
import UIKit

enum PlozziOSDownloadArtwork {
    enum Failure: Error {
        case unavailable
        case invalidImage
    }

    static func references(for item: MediaItem) -> [ArtworkReference] {
        let explicit = item.artworkSelections.first { $0.placement == .detailBackdrop }?.references ?? []
        let remote = [item.backdropURL, item.fallbackArtworkURL].compactMap { $0.map(ArtworkReference.remote) }
        let candidates = explicit + remote
            + item.artworkReferences(for: .poster)
            + item.artworkReferences(for: .seriesPoster)
        var seen = Set<ArtworkReference>()
        return candidates.filter { seen.insert($0).inserted }
    }

    static func load(for item: MediaItem) async throws -> Data {
        for reference in references(for: item) {
            try Task.checkCancellation()
            guard let image = await ArtworkImageCache.shared.image(
                for: reference, variant: .landscapeCard, background: true
            ) else { continue }
            let data = await Task.detached(priority: .utility) {
                image.jpegData(compressionQuality: 0.85)
            }.value
            try Task.checkCancellation()
            if let data, !data.isEmpty, data.count <= 15_000_000 {
                return data
            }
        }
        throw Failure.unavailable
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
