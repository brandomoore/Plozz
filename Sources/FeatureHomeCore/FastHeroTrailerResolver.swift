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
        authenticatedHTTPResolver: any AuthenticatedHTTPResourceResolving
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
            guard !Task.isCancelled,
                  let provider = providerForAccountID(source.accountID) else {
                continue
            }
            let trailers = (try? await provider.trailers(for: source.itemID)) ?? []
            guard !Task.isCancelled else { return nil }
            guard let local = trailers.first(where: \.isServerItemTrailer),
                  let request = try? await provider.playbackInfo(for: local.id)
            else {
                // No local file: a direct remote URL (AIOMetadata / Trailer.io)
                // is just as playable, with no provider lookup needed.
                if let direct = await directSource(from: trailers, ownerItemID: item.id) {
                    return direct
                }
                continue
            }
            guard !Task.isCancelled else { return nil }

            let url: URL?
            if let streamURL = request.streamURL {
                url = streamURL
            } else if case .some(.authenticatedHTTP(let locator)) =
                request.playbackSource {
                url = try? await authenticatedHTTPResolver.resolve(locator)
            } else {
                url = request.playbackSource?.publicURL
            }

            if !Task.isCancelled, let url,
               let duration = await HeroTrailerController.resolvedDuration(of: url),
               !Task.isCancelled {
                return HeroTrailerSource(
                    ownerItemID: item.id,
                    trailerItemID: local.id,
                    url: url,
                    duration: duration
                )
            }
        }
        return nil
    }

    /// Hero source for the first direct remote trailer in `trailers`, or `nil`
    /// when there is none or its duration can't be read (unreachable/unplayable).
    /// The URL carries no server credentials, so no auth resolution is needed.
    public static func directSource(
        from trailers: [MediaItem],
        ownerItemID: String,
        duration resolveDuration: (URL) async -> TimeInterval? = { await HeroTrailerController.resolvedDuration(of: $0) }
    ) async -> HeroTrailerSource? {
        guard let direct = trailers.first(where: \.isDirectTrailer),
              let url = direct.directTrailerURL,
              let duration = await resolveDuration(url),
              !Task.isCancelled else { return nil }
        return HeroTrailerSource(
            ownerItemID: ownerItemID,
            trailerItemID: direct.id,
            url: url,
            duration: duration
        )
    }
}
