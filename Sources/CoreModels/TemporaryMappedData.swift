import Foundation
import os
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Immutable temporary bytes backed by an unlinked file, reclaimed with the last Data owner.
public enum TemporaryMappedData {
    private static let logger = Logger(subsystem: "com.plozz.app", category: "temporary-storage")

    public static func store(_ bytes: Data, in directory: URL = FileManager.default.temporaryDirectory) throws -> Data {
        try Task.checkCancellation()
        guard !bytes.isEmpty else { return bytes }
        let writer = try Writer(maximumBytes: bytes.count, in: directory)
        try writer.append(bytes)
        return try writer.finish()
    }

    /// A single-owner spool. Finishing closes the writer and transfers immutable
    /// mapped storage to Data; partial downloads disappear when the writer dies.
    public final class Writer {
        private var descriptor: Int32
        private let maximumBytes: Int
        public private(set) var count = 0

        public init(
            maximumBytes: Int, in directory: URL = FileManager.default.temporaryDirectory
        ) throws {
            guard maximumBytes >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)) }
            try Task.checkCancellation()
            self.maximumBytes = maximumBytes
            var name = Array(directory.appendingPathComponent(".plozz-data-XXXXXX").path.utf8CString)
            descriptor = mkstemp(&name)
            guard descriptor >= 0 else { throw posixError() }
            guard unlink(name) == 0 else {
                let error = posixError()
                close(descriptor)
                descriptor = -1
                if unlink(name) != 0 { logger.error("Unable to unlink temporary data file errno=\(errno)") }
                throw error
            }
        }

        deinit {
            if descriptor >= 0 { close(descriptor) }
        }

        public func append(_ bytes: Data) throws {
            guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBADF)) }
            guard bytes.count <= maximumBytes - count else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EFBIG))
            }
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    try Task.checkCancellation()
                    let written = write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw posixError() }
                    offset += written
                    count += written
                }
            }
        }

        public func finish() throws -> Data {
            guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBADF)) }
            defer {
                close(descriptor)
                descriptor = -1
            }
            try Task.checkCancellation()
            guard count > 0 else { return Data() }
            let mapping = mmap(nil, count, PROT_READ, MAP_PRIVATE, descriptor, 0)
            guard mapping != MAP_FAILED, let mapping else { throw posixError() }
            return Data(bytesNoCopy: mapping, count: count, deallocator: .unmap)
        }
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
