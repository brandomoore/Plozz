#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// Keeps the repaired initialization and VOD playlist in memory. Media
/// segments remain at their original provider URLs and are never remuxed.
final class StreamingInitializationLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let repair: StreamingInitializationRepair
    private let queue = DispatchQueue(label: "com.plozz.streaming-initialization")

    init(repair: StreamingInitializationRepair) {
        self.repair = repair
    }

    func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: repair.playlistURL)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest
    ) -> Bool {
        let data: Data
        let contentType: String
        switch request.request.url {
        case repair.playlistURL:
            data = repair.playlist
            contentType = "public.m3u8-playlist"
        case repair.initializationURL:
            data = repair.initialization
            contentType = "public.mpeg-4"
        default:
            request.finishLoading(with: URLError(.badURL))
            return true
        }
        guard !request.isCancelled else { return true }
        if let information = request.contentInformationRequest {
            information.contentType = contentType
            information.contentLength = Int64(data.count)
            information.isByteRangeAccessSupported = true
        }
        if let target = request.dataRequest {
            let offset = target.currentOffset
            guard offset >= 0, offset <= Int64(data.count), target.requestedOffset >= 0,
                  target.requestedLength >= 0,
                  Int64(target.requestedLength) <= Int64.max - target.requestedOffset else {
                request.finishLoading(with: URLError(.badServerResponse))
                return true
            }
            let end = target.requestsAllDataToEndOfResource ? Int64(data.count)
                : min(Int64(data.count), target.requestedOffset + Int64(target.requestedLength))
            guard end >= offset else {
                request.finishLoading(with: URLError(.badServerResponse))
                return true
            }
            target.respond(with: data.subdata(in: Int(offset)..<Int(end)))
        }
        request.finishLoading()
        return true
    }
}
#endif
