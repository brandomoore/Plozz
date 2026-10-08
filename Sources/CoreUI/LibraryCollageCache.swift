#if canImport(UIKit)
import CoreModels
import CoreNetworking
import CryptoKit
import MetadataKit
import Synchronization
import UIKit

actor LibraryCollageCache {
    static let shared = LibraryCollageCache()
    private nonisolated let memory: Mutex<NSCache<NSString, UIImage>>
    private let disk: LocalArtworkDerivedCache?
    private let limiter = ConcurrencyLimiter(limit: 2)
    private let imageLimiter = ConcurrencyLimiter(limit: 3)
    private let imageLoader: @Sendable (ArtworkReference) async -> UIImage?
    private let artworkRouter: ArtworkRouter
    private var pending: [String: Task<UIImage?, Never>] = [:]
    private var retryAfter: [String: Date] = [:]
    private static let renderQueue = DispatchQueue(
        label: "com.plozz.library-collage", qos: .utility
    )

    init(
        directory: URL? = nil,
        usesDiskCache: Bool = true,
        artworkRouter: ArtworkRouter = .shared,
        imageLoader: @escaping @Sendable (ArtworkReference) async -> UIImage? = {
            await ArtworkImageCache.shared.image(for: $0, variant: .posterPreview)
        }
    ) {
        self.imageLoader = imageLoader
        self.artworkRouter = artworkRouter
        let directory = directory ?? FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        )[0].appendingPathComponent("plozz-library-collages", isDirectory: true)
        disk = usesDiskCache ? LocalArtworkDerivedCache(
            directory: directory,
            byteCap: 8 * 1024 * 1024,
            warningByteCap: 4 * 1024 * 1024,
            maximumAge: 30 * 24 * 60 * 60,
            now: { Date() }
        ) : nil
        let images = NSCache<NSString, UIImage>()
        images.totalCostLimit = 16 * 1024 * 1024
        images.countLimit = 24
        memory = Mutex(images)
    }

    nonisolated static func identity(
        for source: LibraryArtworkSource, policy: ArtworkPresentationPolicy
    ) -> String {
        "library-collage-v2|\(source.cacheIdentity)|\(policy.identity)"
    }

    nonisolated func cachedImage(
        for source: LibraryArtworkSource, policy: ArtworkPresentationPolicy = .init()
    ) -> UIImage? {
        memory.withLock { $0.object(forKey: Self.identity(for: source, policy: policy) as NSString) }
    }

    func image(
        for source: LibraryArtworkSource, policy: ArtworkPresentationPolicy = .init()
    ) async -> UIImage? {
        if let image = cachedImage(for: source, policy: policy) { return image }
        let identity = Self.identity(for: source, policy: policy)
        let key = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }.joined()
        if let task = pending[key] { return await task.value }
        if let retry = retryAfter[key], retry > Date() { return nil }
        let task = Task(priority: .utility) { [disk, limiter, imageLimiter, imageLoader, artworkRouter] in
            await limiter.run { () async -> UIImage? in
                if let data = await disk?.data(
                    for: key, accountID: source.accountID,
                    credentialRevision: source.credentialRevision,
                    sourceFingerprint: key
                ), let image = await Self.decode(data) {
                    return image
                }
                do {
                    let candidates = try await source.artworkCandidates()
                    let images = await withTaskGroup(of: (Int, UIImage?).self) { group in
                        for (index, candidate) in candidates.enumerated() {
                            group.addTask {
                                let image = await imageLimiter.run { () async -> UIImage? in
                                    await ArtworkFirstPaintResolver.resolve(
                                        references: candidate.references, variant: .posterPreview,
                                        maxAspectRatio: 1,
                                        asyncOnlineURL: {
                                            await artworkRouter.artworkURL(
                                                for: candidate.item, placements: [.poster]
                                            )
                                        },
                                        prefersOnlineArtwork: policy.prefersOnlineArtwork,
                                        background: true, imageLoader: imageLoader
                                    )?.image
                                }
                                return (index, image)
                            }
                        }
                        var loaded: [(Int, UIImage)] = []
                        for await (index, image) in group {
                            if let image { loaded.append((index, image)) }
                        }
                        return loaded.sorted { $0.0 < $1.0 }.map(\.1)
                    }
                    guard !images.isEmpty else {
                        if !candidates.isEmpty {
                            PlozzLog.boot("Library collage: no usable poster artwork")
                        }
                        return nil
                    }
                    let image = await Self.compose(images)
                    await disk?.store(
                        image, key: key, accountID: source.accountID,
                        credentialRevision: source.credentialRevision,
                        sourceFingerprint: key, variant: .landscapeCard
                    )
                    return image
                } catch is CancellationError {
                    return nil
                } catch {
                    // Provider errors can embed authenticated URLs; do not log them.
                    PlozzLog.boot("Library collage: library artwork lookup failed")
                    return nil
                }
            }
        }
        pending[key] = task
        let image = await task.value
        pending[key] = nil
        if let image {
            memory.withLock {
                $0.setObject(image, forKey: identity as NSString, cost: 720 * 405 * 4)
            }
            retryAfter[key] = nil
        } else {
            retryAfter = retryAfter.filter { $0.value > Date() }
            retryAfter[key] = Date().addingTimeInterval(60)
        }
        return image
    }

    private static func decode(_ data: Data) async -> UIImage? {
        await withCheckedContinuation { continuation in
            renderQueue.async {
                continuation.resume(returning: UIImage(data: data)?.preparingForDisplay())
            }
        }
    }

    private static func compose(_ images: [UIImage]) async -> UIImage {
        await withCheckedContinuation { continuation in
            renderQueue.async {
                continuation.resume(returning: render(images))
            }
        }
    }

    /// One opaque texture, not a stack of live image views during native focus.
    static func render(_ images: [UIImage]) -> UIImage {
        let size = CGSize(width: 720, height: 405)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            UIColor(red: 0.08, green: 0.10, blue: 0.15, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            guard !images.isEmpty else { return }
            context.saveGState()
            context.translateBy(x: -75, y: -170)
            context.rotate(by: -.pi / 24)
            let width: CGFloat = 222
            let height = width * 1.5
            for row in 0..<3 {
                for column in 0..<5 {
                    let image = images[(row * 5 + column) % images.count]
                    let rect = CGRect(
                        x: CGFloat(column) * (width + 6),
                        y: CGFloat(row) * (height + 6) + (column.isMultiple(of: 2) ? 0 : -65),
                        width: width, height: height
                    )
                    context.saveGState()
                    context.clip(to: rect)
                    let scale = max(rect.width / image.size.width, rect.height / image.size.height)
                    image.draw(in: CGRect(
                        x: rect.midX - image.size.width * scale / 2,
                        y: rect.midY - image.size.height * scale / 2,
                        width: image.size.width * scale, height: image.size.height * scale
                    ))
                    context.restoreGState()
                }
            }
            context.restoreGState()
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    UIColor.black.withAlphaComponent(0.12).cgColor,
                    UIColor.black.withAlphaComponent(0.25).cgColor,
                    UIColor.black.withAlphaComponent(0.70).cgColor
                ] as CFArray, locations: [0, 0.45, 1]
            ) {
                context.drawLinearGradient(
                    gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: []
                )
            }
        }
    }
}
#endif
