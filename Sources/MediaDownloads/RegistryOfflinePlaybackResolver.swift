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
    private let authorizesRecord: @Sendable (DownloadedMediaRecord) async -> Bool

    public init(
        registry: DownloadedMediaRegistry,
        storage: any DownloadStorageLocating,
        fileManager: FileManager = .default,
        authorizesRecord: @escaping @Sendable (DownloadedMediaRecord) async -> Bool = { _ in true }
    ) {
        self.registry = registry
        self.storage = storage
        self.fileManager = fileManager
        self.authorizesRecord = authorizesRecord
    }

    public func localSubtitleTracks(for item: MediaItem, versionID: String?) async -> [MediaTrack] {
        guard let mediaURL = await localPlaybackURL(for: item, versionID: versionID) else { return [] }
        return subtitleTracks(at: mediaURL)
    }

    func subtitleTracks(at mediaURL: URL) -> [MediaTrack] {
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
        guard let url = await localPlaybackURL(for: item, versionID: versionID) else { return nil }
        return metadata(at: url)
    }

    func metadata(at url: URL) -> MediaSourceMetadata? {
        guard let data = try? Data(contentsOf: url.appendingPathExtension("metadata.json")),
              data.count <= 1_048_576 else { return nil }
        return try? JSONDecoder().decode(MediaSourceMetadata.self, from: data)
    }

    public func localPlaybackAsset(for item: MediaItem, versionID: String?) async -> OfflinePlaybackAsset? {
        guard let url = await localPlaybackURL(for: item, versionID: versionID) else { return nil }
        return OfflinePlaybackAsset(
            fileURL: url, subtitleTracks: subtitleTracks(at: url), metadata: metadata(at: url)
        )
    }

    public func localPlaybackURL(for item: MediaItem, versionID: String?) async -> URL? {
        for record in await registry.playbackRecords(for: item, preferring: versionID) {
            if OfflineMode.shared.isEnabled, let versionID, !versionID.isEmpty,
               record.versionID != versionID { continue }
            guard await authorizesRecord(record), !Task.isCancelled else { continue }
            if let url = localPlaybackURL(for: record) {
                return url
            }
        }
        return nil
    }

    public func localPlaybackURL(for record: DownloadedMediaRecord) -> URL? {
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
              backupRecord.identityKey == record.identityKey,
              backupRecord.snapshot.sourceUserID == record.snapshot.sourceUserID,
              backupRecord.snapshot.sourceAccountID == record.snapshot.sourceAccountID,
              backupRecord.status == .completed,
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
