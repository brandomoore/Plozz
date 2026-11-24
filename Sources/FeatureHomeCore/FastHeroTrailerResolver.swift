import CoreModels
import Foundation

/// Shared fast-path trailer lookup for rotating heroes. It intentionally accepts
/// only provider-local/server extras and never invokes online YouTube extraction.
@MainActor
public enum FastHeroTrailerResolver {
    public static func resolve(
        item: MediaItem,
        identitySources: [MediaSourceRef],
        providerForAccountID: (String) -> (any MediaProvider)?,
        authenticatedHTTPResolver: any AuthenticatedHTTPResourceResolving,
        resolveDuration: @MainActor (URL) async -> TimeInterval? = { await HeroTrailerController.resolvedDuration(of: $0) }
    ) async -> HeroTrailerSource? {
        var sources = identitySources
        if let accountID = item.sourceAccountID,
           !sources.contains(where: {
               $0.accountID == accountID && $0.itemID == item.id
           }) {
            sources.insert(
                MediaSourceRef(
                    accountID: accountID,
                    itemID: item.id,
                    kind: item.kind
                ),
                at: 0
            )
        }

        for source in sources {
            guard !Task.isCancelled else { return nil }
            guard let provider = providerForAccountID(source.accountID) else { continue }
            let trailers = (try? await provider.trailers(for: source.itemID)) ?? []
            guard !Task.isCancelled else { return nil }
            guard let local = trailers.first(where: { !$0.isYouTubeTrailer }) else { continue }

            let request: PlaybackRequest
            let streaming = provider as? any StreamingQualityProviding
            if provider.kind.playbackInfoIsIdempotent {
                // Preserve the lightweight lookup for direct files (including Plex).
                guard let resolved = try? await provider.playbackInfo(for: local.id) else { continue }
                request = resolved
            } else if let streaming {
                // Negotiate a request with an explicit, watch-neutral release
                // contract. A reporting playSessionID alone does not grant ownership.
                var options = StreamingPlaybackOptions(quality: .original)
                options.subtitlesOff = true
                guard let resolved = try? await streaming.playbackInfo(
                    for: local.id, mediaSourceID: nil, forceTranscode: false, streaming: options
                ) else { continue }
                request = resolved
            } else {
                continue
            }
            let session: HeroTrailerSession?
            if request.streamingSessionID != nil, let streaming {
                session = HeroTrailerSession { await streaming.releaseStreamingSession(request) }
            } else {
                session = nil
            }

            guard !Task.isCancelled else {
                await session?.release()
                return nil
            }
            let url: URL?
            if let streamURL = request.streamURL {
                url = streamURL
            } else if case .some(.authenticatedHTTP(let locator)) =
                request.playbackSource {
                url = try? await authenticatedHTTPResolver.resolve(locator)
            } else {
                url = request.playbackSource?.publicURL
            }

            guard !Task.isCancelled, let url, let duration = await resolveDuration(url), !Task.isCancelled else {
                await session?.release()
                continue
            }
            return HeroTrailerSource(ownerItemID: item.id, trailerItemID: local.id, url: url,
                                     duration: duration, session: session)
        }
        return nil
    }
}
