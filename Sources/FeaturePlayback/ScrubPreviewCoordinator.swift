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
    private var pendingRequest: (seconds: TimeInterval, revision: UInt64)?
    @ObservationIgnored
    private var revision: UInt64 = 0
    @ObservationIgnored
    private var publicationFloor: UInt64 = 0
    @ObservationIgnored
    private var previousSeconds: TimeInterval?
    @ObservationIgnored
    private var direction = 0
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
        revision &+= 1
        if let previousSeconds, seconds != previousSeconds {
            let nextDirection = seconds > previousSeconds ? 1 : -1
            if direction != 0, nextDirection != direction { publicationFloor = revision }
            direction = nextDirection
        }
        previousSeconds = seconds
        if let cached = loader.cachedThumbnail(forSeconds: seconds) {
            pendingRequest = nil
            publicationFloor = revision
            setImage(cached)
            return true
        }

        pendingRequest = (seconds, revision)
        guard thumbnailTask == nil else { return false }
        thumbnailTask = Task { [weak self, loader] in
            while !Task.isCancelled, let request = self?.pendingRequest {
                self?.pendingRequest = nil
                let requestedImage = await loader.thumbnail(forSeconds: request.seconds)
                guard !Task.isCancelled, let self else { return }
                isAvailable = !loader.isPermanentlyUnavailable
                // Finish useful work during motion, but never overwrite a newer
                // cache hit or move the preview back across a direction change.
                if request.revision >= publicationFloor {
                    if let requestedImage { setImage(requestedImage) }
                    else if !isAvailable { setImage(nil) }
                }
            }
            if !Task.isCancelled { self?.thumbnailTask = nil }
        }
        return false
    }

    public func clear() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        pendingRequest = nil
        previousSeconds = nil
        direction = 0
        loader.cancelPendingThumbnail()
        setImage(nil)
    }

    private func setImage(_ image: CGImage?) {
        guard image !== self.image else { return }
        self.image = image
        onImageChange?(image)
    }
}
#endif
