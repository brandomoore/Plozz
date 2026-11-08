#if os(iOS)
import CoreModels
import CoreNetworking
import Foundation
import MediaDownloads
import ProviderSilo

enum PlozziOSOfflineSubtitles {
    static func save(
        record: DownloadedMediaRecord, destination: URL, policy: DownloadNetworkPolicy,
        provider: any MediaProvider,
        authorize: @escaping @Sendable () async throws -> Void,
        resolve: @escaping @Sendable (AuthenticatedHTTPPlaybackLocator) async throws -> URL
    ) async throws -> DownloadSubtitleStatus {
        try await authorize()
        guard record.managedHTTPSource?.includesTextSubtitleTracks != false else { return .saved }
        if let silo = provider as? SiloProvider {
            guard let reference = record.managedHTTPSource?.preparationReference,
                  reference.queueIdentifier.hasPrefix("silo:"),
                  let revision = Int(reference.queueIdentifier.dropFirst(5)) else { throw AppError.invalidResponse }
            let manifest = try Data(contentsOf: destination.appendingPathExtension("silo-manifest.json"))
            let assets = try await silo.downloadSubtitleAssets(
                manifest: manifest, reference: .init(id: reference.itemIdentifier, revision: revision)
            )
            try await authorize()
            try Task.checkCancellation()
            try OfflineSubtitleStore.save(assets.enumerated().map { index, asset in
                OfflineSubtitleAsset(
                    track: MediaTrack(
                        id: index, kind: .subtitle, displayTitle: asset.file.language ?? asset.file.codec,
                        language: asset.file.language, codec: asset.file.codec, isForced: asset.file.forced,
                        isHearingImpaired: asset.file.hearingImpaired, isExternal: true
                    ),
                    data: asset.bytes, format: asset.file.codec
                )
            }, beside: destination)
            return .saved
        }
        guard let itemID = record.managedHTTPSource?.itemID ?? record.snapshot.sourceItemID,
              let sourceID = record.managedHTTPSource?.mediaSourceID ?? record.directShareSource?.relativePath else {
            throw AppError.notFound
        }
        let source = record.managedHTTPSource
        let extractsEmbeddedText = source.map {
            $0.quality != .original && ($0.provider == .jellyfin || $0.provider == .emby)
        } ?? false
        let tracks = try await provider.subtitleTracks(context: .init(itemID: itemID, mediaSourceID: sourceID))
            .filter {
                $0.kind == .subtitle
                    && ($0.isExternal || (extractsEmbeddedText && !$0.isImageBasedSubtitle && $0.deliverySource != nil))
            }
        try await authorize()
        var unavailable = tracks.count > OfflineSubtitleStore.maximumTracks
        var assets: [OfflineSubtitleAsset] = []
        var bytes = 0
        let limiter = TransportCursorDownloadEngine.DownloadRateLimiter()
        await limiter.update(maximumBytesPerSecond: policy.maximumBytesPerSecond)
        for track in tracks.prefix(OfflineSubtitleStore.maximumTracks) {
            try Task.checkCancellation()
            try await authorize()
            do {
                let url: URL
                let format: String?
                switch track.deliverySource {
                case .localFile(let file):
                    url = file
                    format = OfflineSubtitleStore.supportedFormat(file.pathExtension)
                case .authenticatedHTTP(let locator):
                    guard locator.accountID == record.managedHTTPSource?.accountID,
                          locator.itemID == itemID, locator.mediaSourceID == sourceID,
                          locator.purpose == .subtitle else { throw AppError.unauthorized }
                    url = try await resolve(locator)
                    format = OfflineSubtitleStore.supportedFormat(locator.formatHint.container)
                case nil:
                    throw AppError.invalidResponse
                }
                guard !track.isImageBasedSubtitle, let format else { throw AppError.invalidResponse }
                let loader = SubtitleFileLoader(allowsExtractionDelay: extractsEmbeddedText && !track.isExternal)
                let data = try await loader.load(
                    url,
                    maximumBytes: min(OfflineSubtitleStore.maximumFileBytes, OfflineSubtitleStore.maximumTotalBytes - bytes),
                    allowsCellular: policy.allowsExpensiveNetwork,
                    allowsConstrained: !policy.pausesOnConstrainedNetwork,
                    onChunk: { try await limiter.waitToTransfer(byteCount: $0) }
                )
                guard let text = SubtitleCueParser.decodeText(data),
                      !SubtitleCueParser.parseCues(text).isEmpty else { throw AppError.invalidResponse }
                bytes += data.count
                assets.append(.init(track: track, data: data, format: format))
            } catch {
                try Task.checkCancellation()
                if error is CancellationError || (error as? AppError) == .cancelled
                    || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                unavailable = true
                PlozzLog.playback.error("download.subtitle unavailable")
            }
        }
        try await authorize()
        try Task.checkCancellation()
        try OfflineSubtitleStore.save(assets, beside: destination, preservingExisting: unavailable)
        return unavailable ? .unavailable : .saved
    }
}
#endif
