import Darwin
import Foundation

/// Detects replacement, eviction and in-place edits without reading large sync payloads.
public struct LiveTVSyncFileRevision: Equatable, Sendable {
    private let device: Int32
    private let inode: UInt64
    private let size: Int64
    private let modifiedSeconds: Int
    private let modifiedNanoseconds: Int
    private let changedSeconds: Int
    private let changedNanoseconds: Int

    public func isSameFile(as other: Self) -> Bool {
        device == other.device && inode == other.inode
    }

    public static func read(_ url: URL) throws -> Self? {
        var value = stat()
        guard url.path.withCString({ fstatat(AT_FDCWD, $0, &value, 0) }) == 0 else {
            let code = errno
            if code == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return Self(
            device: value.st_dev, inode: value.st_ino, size: value.st_size,
            modifiedSeconds: value.st_mtimespec.tv_sec,
            modifiedNanoseconds: value.st_mtimespec.tv_nsec,
            changedSeconds: value.st_ctimespec.tv_sec,
            changedNanoseconds: value.st_ctimespec.tv_nsec
        )
    }
}
