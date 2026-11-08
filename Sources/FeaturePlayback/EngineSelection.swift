import CoreModels
import Foundation

/// Choose the playback owner, not its decoder. Aether probes the actual stream
/// and owns native HLS, local remuxing, and software decoding.
enum EngineSelection {
    static func route(
        request: PlaybackRequest,
        plozzigenAvailable: Bool
    ) -> PlaybackEngineKind {
        if request.playbackSource?.requiresNetworkFileResolver == true {
            // Never hand a credential-scoped transport to a native URL loader.
            return .plozzigen
        }
        if request.streamingOptions != nil, request.isTranscoding, request.isManifestStream,
           request.negotiatedStreamingVideoCodec == .hevc {
            // This route owns the provider fMP4 empty-sdtp repair. Its custom
            // AVAsset resource loader cannot be attached to Aether's URL load.
            return .native
        }
        if request.externalAudioURL != nil {
            // Separate trailer audio is an AVComposition, not Aether's single
            // URL/IOReader input.
            return .native
        }
        if let url = request.streamURL, url.isFileURL,
           url.pathExtension.lowercased() == "movpkg" {
            // AVAssetDownload packages are OS-managed assets. Legacy progressive
            // downloads can share this extension but are ordinary media files.
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDirectory || !FileManager.default.fileExists(atPath: url.path) {
                return .native
            }
        }
        return plozzigenAvailable ? .plozzigen : .native
    }
}
