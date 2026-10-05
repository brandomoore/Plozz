#if canImport(UIKit)
import CoreGraphics
import CoreModels
import CoreNetworking
import Foundation
import Observation

/// Shared presentation coordinator for Jellyfin/Emby trickplay tiles, Plex BIF
/// previews, and on-device stills for servers with neither. Platform-specific
/// controls only provide the scrub position.
@MainActor
@Observable
public final class ScrubPreviewCoordinator {
    public private(set) var image: CGImage?
    /// `false` once the source has proven it can never yield previews, so hosts
    /// can drop the preview frame instead of showing an endless spinner.
    public private(set) var isAvailable = true

    @ObservationIgnored
    private let loader: any ScrubThumbnailProviding
    @ObservationIgnored
    private var thumbnailTask: Task<Void, Never>?
    @ObservationIgnored
    var onImageChange: ((CGImage?) -> Void)?

    public init?(
        source: ScrubPreviewSource?,
        authenticatedHTTPResolver:
            (any AuthenticatedHTTPResourceResolving)? = nil,
        generatedStills: (any ScrubStillExtracting)? = nil
    ) {
        switch source {
        case .tiled(let manifest) where manifest.isUsable:
            loader = TrickplayThumbnailLoader(
                manifest: manifest,
                authenticatedHTTPResolver: authenticatedHTTPResolver
            )
        case .plexBIF(let resource):
            let bif = PlexBIFThumbnailLoader(
                resource: resource,
                authenticatedHTTPResolver: authenticatedHTTPResolver
            )
            if let generatedStills {
                loader = FallbackScrubThumbnailLoader(
                    primary: bif,
                    fallback: GeneratedScrubThumbnailLoader(extractor: generatedStills)
                )
            } else {
                loader = bif
            }
        default:
            // Server-generated previews always win; on-device stills are only
            // the fallback for a server that has none.
            guard let generatedStills else { return nil }
            loader = GeneratedScrubThumbnailLoader(extractor: generatedStills)
        }
    }

    public func prefetch() {
        loader.prefetch()
    }

    /// Updates the visible frame and returns whether it was already in memory.
    @discardableResult
    public func update(for seconds: TimeInterval) -> Bool {
        if let cached = loader.cachedThumbnail(forSeconds: seconds) {
            thumbnailTask?.cancel()
            setImage(cached)
            return true
        }

        thumbnailTask?.cancel()
        thumbnailTask = Task { [weak self] in
            guard let self else { return }
            let requestedImage = await loader.thumbnail(forSeconds: seconds)
            isAvailable = !loader.isPermanentlyUnavailable
            guard !Task.isCancelled else { return }
            setImage(requestedImage)
        }
        return false
    }

    public func clear() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        setImage(nil)
    }

    private func setImage(_ image: CGImage?) {
        self.image = image
        onImageChange?(image)
    }
}
#endif
