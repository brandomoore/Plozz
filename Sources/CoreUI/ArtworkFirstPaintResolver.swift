#if canImport(UIKit)
import CoreModels
import Foundation
import MetadataKit
import UIKit

/// One decoded artwork identity selected before first paint.
public struct FirstPaintArtwork: @unchecked Sendable {
    public let image: UIImage
    public let reference: ArtworkReference
    public let variant: ArtworkImageVariant

    public init(
        image: UIImage,
        reference: ArtworkReference,
        variant: ArtworkImageVariant
    ) {
        self.image = image
        self.reference = reference
        self.variant = variant
    }
}

/// Resolves the preferred source before falling back, without publishing a
/// provisional image. Queueing or downloading slowly is not a missing image;
/// the underlying network and image-cache deadlines bound failed requests.
public enum ArtworkFirstPaintResolver {
    /// Prepares the exact policy-qualified result FallbackAsyncImage can adopt
    /// synchronously, including an online winner absent from its library URLs.
    @MainActor
    public static func prepare(
        references: [ArtworkReference],
        prefersPrimaryReference: Bool = false,
        variant: ArtworkImageVariant,
        asyncOnlineURL: (@Sendable () async -> URL?)?,
        pinIdentity: String,
        policy: ArtworkPresentationPolicy = .init()
    ) async {
        let key = ArtworkResolveKey.make(
            references: references, variant: variant, maxAspectRatio: nil,
            pinIdentity: pinIdentity,
            providerPolicyIdentity: policy.identity,
            prefersPrimaryReference: prefersPrimaryReference
        )
        if ArtworkSeedMemo.prepared(for: key, variant: variant) != nil { return }
        guard let artwork = await resolve(
            references: references, prefersPrimaryReference: prefersPrimaryReference, variant: variant,
            asyncOnlineURL: asyncOnlineURL,
            prefersOnlineArtwork: policy.prefersOnlineArtwork, background: true
        ), !Task.isCancelled else { return }
        ArtworkSeedMemo.store(artwork, for: key)
    }

    public static func resolve(
        references: [ArtworkReference],
        prefersPrimaryReference: Bool = false,
        variant: ArtworkImageVariant,
        maxAspectRatio: CGFloat? = nil,
        asyncOnlineURL: (@Sendable () async -> URL?)?,
        prefersOnlineArtwork: Bool = true,
        sharedKey: String? = nil,
        background: Bool = false,
        imageLoader: (@Sendable (ArtworkReference) async -> UIImage?)? = nil
    ) async -> FirstPaintArtwork? {
        if let sharedKey {
            let key = prefersPrimaryReference
                ? "\(sharedKey)|primary:\(references.first?.privacySafeIdentity ?? "none")" : sharedKey
            return await FirstPaintTaskMemo.shared.value(for: key) {
                await resolve(
                    references: references,
                    prefersPrimaryReference: prefersPrimaryReference,
                    variant: variant,
                    maxAspectRatio: maxAspectRatio,
                    asyncOnlineURL: asyncOnlineURL,
                    prefersOnlineArtwork: prefersOnlineArtwork,
                    sharedKey: nil,
                    background: background,
                    imageLoader: imageLoader
                )
            }
        }
        if prefersPrimaryReference, let primary = references.first,
           let artwork = await loadFirst(
               [primary], variant: variant, maxAspectRatio: maxAspectRatio,
               background: background, imageLoader: imageLoader
           ) {
            return artwork
        }
        guard prefersOnlineArtwork, let asyncOnlineURL else {
            if let local = await loadFirst(
                references,
                variant: variant,
                maxAspectRatio: maxAspectRatio,
                background: background,
                imageLoader: imageLoader
            ) {
                return local
            }
            return await loadOnline(
                asyncOnlineURL,
                variant: variant,
                maxAspectRatio: maxAspectRatio,
                background: background,
                imageLoader: imageLoader
            )
        }

        let race = FirstPaintRace()
        let onlineTask = Task {
            let artwork = await loadOnline(
                asyncOnlineURL,
                variant: variant,
                maxAspectRatio: maxAspectRatio,
                background: background,
                imageLoader: imageLoader
            )
            await race.submit(.resolved(artwork))
        }

        let outcome = await withTaskCancellationHandler {
            await race.value()
        } onCancel: {
            onlineTask.cancel()
            Task { await race.submit(.cancelled) }
        }
        guard !Task.isCancelled else { return nil }
        switch outcome {
        case .resolved(let artwork):
            if let artwork { return artwork }
        case .cancelled:
            return nil
        }

        return await loadFirst(
            references,
            variant: variant,
            maxAspectRatio: maxAspectRatio,
            background: background,
            imageLoader: imageLoader
        )
    }

    private static func loadFirst(
        _ references: [ArtworkReference],
        variant: ArtworkImageVariant,
        maxAspectRatio: CGFloat?,
        background: Bool,
        imageLoader: (@Sendable (ArtworkReference) async -> UIImage?)?
    ) async -> FirstPaintArtwork? {
        for reference in references {
            guard !Task.isCancelled else { return nil }
            guard let image = await loadImage(
                reference, variant: variant, background: background, imageLoader: imageLoader
            ), !Task.isCancelled, isUsable(image, maxAspectRatio: maxAspectRatio) else {
                continue
            }
            return FirstPaintArtwork(
                image: image,
                reference: reference,
                variant: variant
            )
        }
        return nil
    }

    private static func loadOnline(
        _ resolver: (@Sendable () async -> URL?)?,
        variant: ArtworkImageVariant,
        maxAspectRatio: CGFloat?,
        background: Bool,
        imageLoader: (@Sendable (ArtworkReference) async -> UIImage?)?
    ) async -> FirstPaintArtwork? {
        guard !Task.isCancelled,
              let resolver,
              let url = await resolver(),
              !Task.isCancelled,
              let image = await loadImage(
                  .remote(url), variant: variant, background: background, imageLoader: imageLoader
              ),
              !Task.isCancelled, isUsable(image, maxAspectRatio: maxAspectRatio) else {
            return nil
        }
        return FirstPaintArtwork(
            image: image,
            reference: .remote(url),
            variant: variant
        )
    }

    private static func loadImage(
        _ reference: ArtworkReference, variant: ArtworkImageVariant, background: Bool,
        imageLoader: (@Sendable (ArtworkReference) async -> UIImage?)?
    ) async -> UIImage? {
        if let imageLoader { return await imageLoader(reference) }
        return await ArtworkImageCache.shared.image(for: reference, variant: variant, background: background)
    }

    private static func isUsable(
        _ image: UIImage,
        maxAspectRatio: CGFloat?
    ) -> Bool {
        guard image.size.height > 0 else { return false }
        guard let maxAspectRatio else { return true }
        return image.size.width / image.size.height <= maxAspectRatio
    }
}

private enum FirstPaintRaceResult: @unchecked Sendable {
    case resolved(FirstPaintArtwork?)
    case cancelled
}

private actor FirstPaintRace {
    private var result: FirstPaintRaceResult?
    private var continuation: CheckedContinuation<FirstPaintRaceResult, Never>?

    func submit(_ candidate: FirstPaintRaceResult) {
        guard result == nil else { return }
        result = candidate
        continuation?.resume(returning: candidate)
        continuation = nil
    }

    func value() async -> FirstPaintRaceResult {
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }
}

private actor FirstPaintTaskMemo {
    static let shared = FirstPaintTaskMemo()

    private var tasks: [String: Task<FirstPaintArtwork?, Never>] = [:]
    private var order: [String] = []
    private let capacity = 300

    func value(
        for key: String,
        operation: @escaping @Sendable () async -> FirstPaintArtwork?
    ) async -> FirstPaintArtwork? {
        if let task = tasks[key] {
            return await task.value
        }
        let task = Task(operation: operation)
        tasks[key] = task
        order.append(key)
        if order.count > capacity {
            let oldest = order.removeFirst()
            tasks[oldest] = nil
        }
        return await task.value
    }
}
#endif
