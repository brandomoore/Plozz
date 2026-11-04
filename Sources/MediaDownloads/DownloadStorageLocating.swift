import CoreModels
import Foundation

/// Resolves where pinned downloads live on disk. The base directory and backup
/// policy differ per OS; download orchestration remains platform-neutral.
///
/// - **iOS / iPadOS:** Application Support (falling back to Documents), marked
///   `isExcludedFromBackup` so multi-GB media never bloats iCloud/iTunes backups.
/// - **tvOS:** Caches (tvOS discourages large persistent storage and may purge
///   Caches under pressure — acceptable for a device where offline downloads are
///   a minimal/edge scenario).
public protocol DownloadStorageLocating: Sendable {
    /// The root directory that holds every download's folder. Created on demand.
    func pinnedMediaDirectory() throws -> URL
    /// The absolute pinned file URL for a record (`<root>/<folder>/<localFileName>`).
    func pinnedFileURL(for record: DownloadedMediaRecord) throws -> URL
    /// The per-download folder for an identity key (`<root>/<folder>`).
    func pinnedFolderURL(forKey identityKey: String) throws -> URL
}

public extension DownloadStorageLocating {
    func pinnedFolderURL(forKey identityKey: String) throws -> URL {
        try pinnedMediaDirectory()
            .appendingPathComponent(MediaIdentityKey.folderName(forKey: identityKey), isDirectory: true)
    }

    func pinnedFileURL(for record: DownloadedMediaRecord) throws -> URL {
        try pinnedFolderURL(forKey: record.identityKey)
            .appendingPathComponent(record.localFileName, isDirectory: false)
    }

    func replacementBackupFolderURL(forKey identityKey: String) throws -> URL {
        let suffix = ".replacement-backup"
        let name = MediaIdentityKey.folderName(forKey: identityKey, maximumLength: 255 - suffix.utf8.count)
        return try pinnedMediaDirectory()
            .appendingPathComponent(name + suffix, isDirectory: true)
    }

    func replacementBackupRecordURL(forKey identityKey: String) throws -> URL {
        try replacementBackupFolderURL(forKey: identityKey)
            .appendingPathComponent(".record.json", isDirectory: false)
    }
}

/// The platform selection axis, exposed so tests can exercise BOTH policies on any
/// host (a `#if` alone can't be unit-tested cross-platform).
public enum DownloadStoragePlatform: Sendable {
    /// Excluded-from-backup Application Support / Documents (iOS/iPadOS).
    case backupExcludedPersistent
    /// Caches (tvOS).
    case caches

    /// The platform this build actually runs on.
    public static var current: DownloadStoragePlatform {
        #if os(tvOS)
        return .caches
        #else
        return .backupExcludedPersistent
        #endif
    }
}

/// Concrete locator that selects the base directory per ``DownloadStoragePlatform``
/// and applies the backup-exclusion resource value where required.
public struct PlatformDownloadStorageLocator:
    DownloadStorageLocating,
    @unchecked Sendable
{
    private let platform: DownloadStoragePlatform
    private let subdirectory: String
    private let fileManager: FileManager

    public init(
        platform: DownloadStoragePlatform = .current,
        subdirectory: String = "PlozzDownloads",
        fileManager: FileManager = .default
    ) {
        self.platform = platform
        self.subdirectory = subdirectory
        self.fileManager = fileManager
    }

    public func pinnedMediaDirectory() throws -> URL {
        let base = try baseDirectory()
        var directory = base.appendingPathComponent(subdirectory, isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if platform == .backupExcludedPersistent {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
        }
        return directory
    }

    private func baseDirectory() throws -> URL {
        switch platform {
        case .backupExcludedPersistent:
            if let appSupport = try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ) {
                return appSupport
            }
            return try fileManager.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        case .caches:
            return try fileManager.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
    }
}
