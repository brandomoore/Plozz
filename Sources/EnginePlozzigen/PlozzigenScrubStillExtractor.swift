#if canImport(UIKit)
import CoreGraphics
import CoreModels
import CoreNetworking
import FeaturePlayback
import Foundation
@preconcurrency import AetherEngine

/// On-device scrub previews for titles whose server has none, decoded from the
/// original file with AetherEngine's `FrameExtractor` (the Infuse approach).
///
/// Each still seeks the extractor's own demuxer to the nearest keyframe and
/// decodes one low-res frame, so it costs a small ranged read rather than a
/// pre-generated BIF on the server's disk. The extractor opens lazily on the
/// first scrub, never at load, so it can't compete with startup buffering:
///  * When Plozzigen is the playing engine, the extractor is session-coupled and
///    yields while playback is starved; a network share reuses a clone of the
///    engine's leased reader (the only way to read it).
///  * When AVPlayer is playing (e.g. a natively playable MP4), a standalone
///    extractor reads the original over HTTP.
@MainActor
public final class PlozzigenScrubStillExtractor: ScrubStillExtracting {
    private let source: PlaybackSource
    private let activeEngine: @MainActor () -> (any VideoEngine)?
    private let authenticatedHTTPResolver: (any AuthenticatedHTTPResourceResolving)?
    private var extractor: FrameExtractor?
    private var openTask: Task<FrameExtractor?, Never>?

    public init(
        source: PlaybackSource,
        activeEngine: @escaping @MainActor () -> (any VideoEngine)?,
        authenticatedHTTPResolver: (any AuthenticatedHTTPResourceResolving)?
    ) {
        self.source = source
        self.activeEngine = activeEngine
        self.authenticatedHTTPResolver = authenticatedHTTPResolver
    }

    public func thumbnail(atSeconds seconds: TimeInterval, maxWidth: Int) async -> CGImage? {
        guard let extractor = await openExtractor() else { return nil }
        return await extractor.thumbnail(at: seconds, maxWidth: maxWidth)
    }

    /// Opens the extractor once, coalescing concurrent first requests. A failed
    /// open isn't cached: a network share can't clone its reader until the engine
    /// has loaded, so the next scrub sample tries again.
    private func openExtractor() async -> FrameExtractor? {
        if let extractor { return extractor }
        if let openTask { return await openTask.value }
        let task = Task { await self.makeExtractor() }
        openTask = task
        let opened = await task.value
        openTask = nil
        extractor = opened
        return opened
    }

    private func makeExtractor() async -> FrameExtractor? {
        let plozzigen = activeEngine() as? PlozzigenVideoEngine
        let url: URL
        switch source {
        case .networkFile:
            return plozzigen?.makeLoadedSourceFrameExtractor()
        case .publicURL(let publicSource):
            url = publicSource.url
        case .authenticatedHTTP(let locator):
            guard let authenticatedHTTPResolver,
                  let resolved = try? await authenticatedHTTPResolver.resolve(locator)
            else {
                return nil
            }
            url = resolved
        case .dlnaResource:
            return nil
        }
        if let plozzigen {
            return plozzigen.makeScrubFrameExtractor(url: url)
        }
        return FrameExtractor(url: url)
    }
}
#endif
