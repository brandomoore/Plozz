import CoreModels
import Foundation

/// Bridges the download registry to the playback layer's ``OfflinePlaybackResolving``
/// seam: answers "play this from disk?" for a `MediaItem`, returning the pinned
/// `file://` URL only for a **completed** download whose file still exists.
public struct RegistryOfflinePlaybackResolver:
    OfflinePlaybackResolving,
    @unchecked Sendable
{
    private let registry: DownloadedMediaRegistry
    private let storage: any DownloadStorageLocating
    private let fileManager: FileManager

    public init(
        registry: DownloadedMediaRegistry,
        storage: any DownloadStorageLocating,
        fileManager: FileManager = .default
    ) {
        self.registry = registry
        self.storage = storage
        self.fileManager = fileManager
    }

    public func localSubtitleTracks(for item: MediaItem, versionID: String?) async -> [MediaTrack] {
        guard let mediaURL = await localPlaybackURL(for: item, versionID: versionID) else { return [] }
        let indexURL = mediaURL.appendingPathExtension("subtitles.json")
        guard fileManager.fileExists(atPath: indexURL.path) else { return [] }
        guard let data = try? Data(contentsOf: indexURL), data.count <= 1_048_576,
              let files = try? JSONDecoder().decode([OfflineSubtitleFile].self, from: data) else { return [] }
        return files.enumerated().compactMap { index, file in
            guard !file.fileName.isEmpty, !file.fileName.contains("/"), !file.fileName.contains("\\"),
                  file.fileName != ".", file.fileName != ".." else { return nil }
            let url = mediaURL.deletingLastPathComponent().appendingPathComponent(file.fileName)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return MediaTrack(id: 100_000 + index, kind: .subtitle,
                              displayTitle: file.language ?? file.codec, language: file.language, codec: file.codec,
                              isForced: file.forced, isHearingImpaired: file.hearingImpaired,
                              deliverySource: .localFile(url), isExternal: true)
        }
    }

    public func localPlaybackMetadata(for item: MediaItem, versionID: String?) async -> MediaSourceMetadata? {
        guard let url = await localPlaybackURL(for: item, versionID: versionID),
              let data = try? Data(contentsOf: url.appendingPathExtension("metadata.json")),
              data.count <= 1_048_576 else { return nil }
        return try? JSONDecoder().decode(MediaSourceMetadata.self, from: data)
    }

    public func localPlaybackURL(for item: MediaItem, versionID: String?) async -> URL? {
        guard let record = await registry.record(
            for: item,
            versionID: versionID
        ) else {
            return nil
        }
        if record.status == .completed,
           let url = try? storage.pinnedFileURL(for: record),
           fileManager.fileExists(atPath: url.path) {
            return url
        }
        guard let recordURL = try? storage.replacementBackupRecordURL(
            forKey: record.identityKey
        ),
              let data = try? Data(contentsOf: recordURL),
              let backupRecord = try? JSONDecoder().decode(
                  DownloadedMediaRecord.self,
                  from: data
              ),
              let backupFolder = try? storage.replacementBackupFolderURL(
                  forKey: record.identityKey
              ) else {
            return nil
        }
        let backupURL = backupFolder.appendingPathComponent(
            backupRecord.localFileName
        )
        return fileManager.fileExists(atPath: backupURL.path)
            ? backupURL
            : nil
    }
}
