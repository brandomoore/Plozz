import CoreModels
import XCTest
@testable import MediaDownloads

final class DownloadStoragePolicyTests: XCTestCase {

    func testLongPhysicalFileIdentitiesUseBoundedStableFoldersAndCanBeWritten() throws {
        let locator = PlatformDownloadStorageLocator(
            platform: .caches, subdirectory: "PlozzLongDownload-\(UUID())"
        )
        defer { try? FileManager.default.removeItem(at: try locator.pinnedMediaDirectory()) }
        let longPath = String(repeating: "long-episode-name/", count: 30) + "episode.mkv"
        let identity = MediaIdentity.external(source: "plozz-account:fixture", value: "f:\(longPath)")
        let record = try DownloadTestFactory.record(identity: identity)
        let folder = try locator.pinnedFolderURL(forKey: record.identityKey)
        XCTAssertLessThanOrEqual(folder.lastPathComponent.utf8.count, 255)
        XCTAssertEqual(folder.lastPathComponent, MediaIdentityKey.folderName(forKey: record.identityKey))
        XCTAssertNotEqual(folder.lastPathComponent, MediaIdentityKey.folderName(forKey: record.identityKey + "other"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = try locator.pinnedFileURL(for: record)
        let bytes = Data("downloaded episode".utf8)
        try bytes.write(to: file)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let backup = try locator.replacementBackupFolderURL(forKey: record.identityKey)
        try FileManager.default.moveItem(at: folder, to: backup)
        try FileManager.default.moveItem(at: backup, to: folder)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testExistingFilesystemSizedDownloadFoldersKeepTheirNames() {
        for length in [1, 50, 190, 191] {
            let key = String(repeating: "a", count: length)
            let legacy = Data(key.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
            XCTAssertLessThanOrEqual(legacy.count, 255)
            XCTAssertEqual(MediaIdentityKey.folderName(forKey: key), legacy)
        }
        XCTAssertTrue(MediaIdentityKey.folderName(forKey: String(repeating: "a", count: 192)).hasPrefix("sha256."))
    }

    func testReplacementBackupsFitWithoutRenamingExistingDownloadFolders() throws {
        let locator = PlatformDownloadStorageLocator(platform: .caches, subdirectory: "PlozzBackup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: try locator.pinnedMediaDirectory()) }
        for length in [177, 178, 191, 192] {
            let key = String(repeating: "a", count: length)
            let folder = try locator.pinnedFolderURL(forKey: key)
            let backup = try locator.replacementBackupFolderURL(forKey: key)
            XCTAssertLessThanOrEqual(backup.lastPathComponent.utf8.count, 255)
            if folder.lastPathComponent.utf8.count + ".replacement-backup".utf8.count <= 255 {
                XCTAssertEqual(backup.lastPathComponent, folder.lastPathComponent + ".replacement-backup")
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: folder, to: backup)
            try FileManager.default.moveItem(at: backup, to: folder)
        }
    }

    func testCapacityRequestsThePlatformAppropriateResource() throws {
        let directory = DownloadTestFactory.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capacity = DownloadStorageCapacity { url, key in
            XCTAssertEqual(url, directory)
            #if os(tvOS)
            XCTAssertEqual(key, .volumeAvailableCapacityKey)
            #else
            XCTAssertEqual(key, .volumeAvailableCapacityForImportantUsageKey)
            #endif
            return 96_080_000_000
        }

        XCTAssertEqual(try capacity.availableBytes(at: directory), 96_080_000_000)
    }

    func testCapacityUnavailableRemainsUnknown() throws {
        let capacity = DownloadStorageCapacity { _, _ in nil }
        XCTAssertNil(try capacity.availableBytes(at: URL.documentsDirectory))
    }

    func testCapacityReadErrorsArePropagated() {
        let capacity = DownloadStorageCapacity { _, _ in
            throw CocoaError(.fileReadNoPermission)
        }
        XCTAssertThrowsError(try capacity.availableBytes(at: URL.documentsDirectory)) {
            XCTAssertEqual(($0 as? CocoaError)?.code, .fileReadNoPermission)
        }
    }

    func testIOSPolicyUsesBackupExcludedPersistentDirectory() throws {
        let sub = "PlozzDownloadsTest-\(UUID().uuidString)"
        let locator = PlatformDownloadStorageLocator(
            platform: .backupExcludedPersistent, subdirectory: sub
        )
        let dir = try locator.pinnedMediaDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        // Under Application Support or Documents (never Caches).
        XCTAssertFalse(dir.path.contains("/Caches/"))
        let values = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testTVOSPolicyUsesCachesDirectory() throws {
        let sub = "PlozzDownloadsTest-\(UUID().uuidString)"
        let locator = PlatformDownloadStorageLocator(platform: .caches, subdirectory: sub)
        let dir = try locator.pinnedMediaDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertTrue(dir.path.contains("/Caches/"))
        // tvOS does not mark Caches excluded-from-backup.
        let values = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertNotEqual(values.isExcludedFromBackup, true)
    }

    func testPinnedFileURLComposition() throws {
        let sub = "PlozzDownloadsTest-\(UUID().uuidString)"
        let locator = PlatformDownloadStorageLocator(platform: .caches, subdirectory: sub)
        let record = try DownloadTestFactory.record(localFileName: "media.mkv")
        defer { try? FileManager.default.removeItem(at: try locator.pinnedMediaDirectory()) }

        let url = try locator.pinnedFileURL(for: record)
        XCTAssertEqual(url.lastPathComponent, "media.mkv")
        XCTAssertEqual(
            url.deletingLastPathComponent().lastPathComponent,
            MediaIdentityKey.folderName(forKey: record.identityKey)
        )
    }
}
