#if os(iOS)
import Foundation
import CoreModels
import MediaDownloads
import ProviderSilo

enum SiloOfflineDownload {
    static func preset(_ quality: DownloadQuality) throws -> (name: String, height: Int?) {
        guard case .constrained(let constraint) = quality else { return ("original", nil) }
        let choices = [(20_000_000, "20mbps"), (10_000_000, "10mbps"), (5_000_000, "5mbps"),
                       (2_000_000, "2mbps"), (1_000_000, "1mbps")]
        guard let match = choices.first(where: { $0.0 <= constraint.maximumVideoBitrateBps }) else {
            throw PlozziOSDownloadError.nativeServer("Silo cannot prepare a download at this bitrate.")
        }
        return (match.1, constraint.maximumHeight)
    }

    static func prepare(
        provider: SiloProvider, source: ManagedHTTPDownloadSource,
        updateSource: @escaping PlozziOSBackgroundHTTPDownloadEngine.SourceUpdater
    ) async throws -> PlozziOSBackgroundHTTPDownloadEngine.Resolution {
        let preset = try preset(source.quality)
        guard let fileID = source.mediaSourceID else { throw AppError.invalidResponse }
        let reference: SiloDownloadReference?
        if let saved = source.preparationReference {
            guard saved.queueIdentifier.hasPrefix("silo:"),
                  let revision = Int(saved.queueIdentifier.dropFirst(5)), revision > 0 else {
                throw AppError.invalidResponse
            }
            reference = SiloDownloadReference(id: saved.itemIdentifier, revision: revision)
        } else { reference = nil }
        let result = try await provider.prepareDownload(
            itemID: source.itemID, fileID: fileID, quality: preset.name, maximumHeight: preset.height,
            reference: reference, requiresAllAudioTracks: source.includesAllAudioTracks, persistReference: { reference in
                try await updateSource(ManagedHTTPDownloadSource(
                    provider: .silo, accountID: source.accountID, itemID: source.itemID,
                    mediaSourceID: fileID, quality: source.quality,
                    includesAllAudioTracks: source.includesAllAudioTracks,
                    includesTextSubtitleTracks: source.includesTextSubtitleTracks,
                    preferredAudioLanguages: source.preferredAudioLanguages,
                    preparationReference: .init(queueIdentifier: "silo:\(reference.revision)", itemIdentifier: reference.id)))
            })
        return .init(
            url: result.url, expectedDuration: result.duration, cleanupURL: nil,
            headers: result.headers, singleFile: true, expectedBytes: result.expectedBytes,
            didComplete: { destination in
                try await provider.validateDownloadCompletion(result.reference, manifest: result.manifest)
                try result.manifest.write(to: destination.appendingPathExtension("silo-manifest.json"), options: .atomic)
                try JSONEncoder().encode(result.metadata).write(to: destination.appendingPathExtension("metadata.json"), options: .atomic)
                if source.includesTextSubtitleTracks {
                    let assets = try await provider.downloadSubtitleAssets(manifest: result.manifest, reference: result.reference)
                    for asset in assets {
                        try asset.bytes.write(to: destination.deletingLastPathComponent().appendingPathComponent(asset.file.fileName), options: .atomic)
                    }
                    try JSONEncoder().encode(assets.map(\.file)).write(to: destination.appendingPathExtension("subtitles.json"), options: .atomic)
                }
            })
    }
}
#endif
