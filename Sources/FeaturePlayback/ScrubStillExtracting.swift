import CoreGraphics
import Foundation

/// Decodes scrubbing-preview stills on the device, straight from the playing
/// item's original file.
///
/// This is the fallback for titles whose server has no pre-generated previews
/// (no Plex BIF index, no Jellyfin trickplay), so a server can leave preview
/// generation off and save the disk space. Each still is keyframe-snapped and
/// costs a small ranged read of the source, so it is only used when the server
/// offers nothing better. Implementations live with the on-device decoder
/// (Plozzigen) and are injected through `EngineFactory`.
@MainActor
public protocol ScrubStillExtracting: AnyObject {
    /// A still near `seconds`, at most `maxWidth` pixels wide, or `nil` when the
    /// source can't produce one right now (not loaded yet, playback starved, or a
    /// decode failure). A `nil` simply shows no preview for that position.
    func thumbnail(atSeconds seconds: TimeInterval, maxWidth: Int) async -> CGImage?
}

#if canImport(UIKit)
/// Adapts a `ScrubStillExtracting` source to the player's scrub-preview loader
/// contract.
///
/// Positions are snapped to a fixed grid so dragging across one cell reuses the
/// same frame instead of issuing a new ranged read per pan sample, and decoded
/// frames are kept in a small FIFO for the synchronous fast path.
@MainActor
final class GeneratedScrubThumbnailLoader: ScrubThumbnailProviding {
    /// Matches Plex's default BIF interval, so generated previews feel the same
    /// as server-generated ones.
    static let gridSeconds: TimeInterval = 2
    /// Sized for the tvOS preview card (483pt); decode cost is dominated by the
    /// keyframe itself, not the output size.
    static let maxWidth = 480

    private let extractor: any ScrubStillExtracting
    private var decoded: [Int: CGImage] = [:]
    private var decodeOrder: [Int] = []
    private let maxDecodedFrames = 90

    init(extractor: any ScrubStillExtracting) {
        self.extractor = extractor
    }

    func thumbnail(forSeconds seconds: TimeInterval) async -> CGImage? {
        let cell = Self.cell(forSeconds: seconds)
        if let cached = decoded[cell] { return cached }
        guard let image = await extractor.thumbnail(
            atSeconds: Double(cell) * Self.gridSeconds,
            maxWidth: Self.maxWidth
        ) else {
            return nil
        }
        store(image, at: cell)
        return image
    }

    func cachedThumbnail(forSeconds seconds: TimeInterval) -> CGImage? {
        decoded[Self.cell(forSeconds: seconds)]
    }

    static func cell(forSeconds seconds: TimeInterval) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(seconds / gridSeconds)
    }

    private func store(_ image: CGImage, at cell: Int) {
        if decoded[cell] == nil { decodeOrder.append(cell) }
        decoded[cell] = image
        if decodeOrder.count > maxDecodedFrames {
            decoded[decodeOrder.removeFirst()] = nil
        }
    }
}

/// Uses server-generated previews until they prove permanently unavailable,
/// then hands over to a fallback for the rest of the session. Plex keeps
/// listing a part's BIF `indexes` after the preview files are deleted, so
/// "advertised" is not proof the previews exist.
@MainActor
final class FallbackScrubThumbnailLoader: ScrubThumbnailProviding {
    private let primary: any ScrubThumbnailProviding
    private let fallback: any ScrubThumbnailProviding

    init(primary: any ScrubThumbnailProviding, fallback: any ScrubThumbnailProviding) {
        self.primary = primary
        self.fallback = fallback
    }

    private var active: any ScrubThumbnailProviding {
        primary.isPermanentlyUnavailable ? fallback : primary
    }

    var isPermanentlyUnavailable: Bool {
        primary.isPermanentlyUnavailable && fallback.isPermanentlyUnavailable
    }

    func thumbnail(forSeconds seconds: TimeInterval) async -> CGImage? {
        if !primary.isPermanentlyUnavailable {
            if let image = await primary.thumbnail(forSeconds: seconds) { return image }
            guard primary.isPermanentlyUnavailable else { return nil }
        }
        return await fallback.thumbnail(forSeconds: seconds)
    }

    func cachedThumbnail(forSeconds seconds: TimeInterval) -> CGImage? {
        active.cachedThumbnail(forSeconds: seconds)
    }

    func prefetch() {
        // Only the primary warms ahead of time; a missing BIF is discovered here
        // so the first scrub already goes straight to the fallback.
        primary.prefetch()
    }
}
#endif
