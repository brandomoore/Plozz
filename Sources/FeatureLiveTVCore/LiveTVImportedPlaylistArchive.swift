import CoreModels
import CoreNetworking
import CryptoKit
import Foundation

enum LiveTVImportedPlaylistArchive {
    static let chunkBytes = 256 * 1_024
    private static let magic = Data("Plozz.Import.v2\n".utf8)
    private struct Header: Codable { let baseURL: URL? }
    private struct Legacy: Codable { let data: Data; let baseURL: URL? }

    static func write(
        to destination: URL, key: SymmetricKey, context: String, baseURL: URL?,
        next: () throws -> Data?
    ) throws -> LiveTVPlaylistImport {
        guard baseURL.map(LiveTVPlaylistSource.isSupportedURL) ?? true,
              (baseURL?.absoluteString.utf8.count ?? 0) <= 65_536 else {
            throw LiveTVSourceImportError.invalidPlaylist
        }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + ".partial")
        guard FileManager.default.createFile(
            atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]
        ) else { throw LiveTVCacheError.unavailable }
        defer {
            if FileManager.default.fileExists(atPath: temporary.path) {
                do { try FileManager.default.removeItem(at: temporary) }
                catch { PlozzLog.sync.error("Live TV: failed to remove an encrypted import staging file") }
            }
        }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: magic)
            try writeFrame(
                JSONEncoder().encode(Header(baseURL: baseURL)), to: handle,
                key: key, context: context + ":header"
            )
            var parser = LiveTVPlaylistParser(baseURL: baseURL).makeStream()
            var digest = SHA256()
            var count = 0
            while let chunk = try next(), !chunk.isEmpty {
                guard chunk.count <= chunkBytes else { throw LiveTVCacheError.tooLarge }
                try parser.append(chunk)
                digest.update(data: chunk)
                try handle.write(contentsOf: Data([1]))
                try writeFrame(chunk, to: handle, key: key, context: context + ":chunk:\(count)")
                count += 1
            }
            let playlist = try parser.finish()
            guard !playlist.channels.isEmpty else { throw LiveTVSourceImportError.invalidPlaylist }
            try handle.write(contentsOf: Data([2]))
            try writeFrame(
                Data(digest.finalize()), to: handle, key: key, context: context + ":complete:\(count)"
            )
            try handle.close()
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            return playlist
        } catch {
            try? handle.close()
            throw error
        }
    }

    static func read(
        from url: URL, key: SymmetricKey, context: String,
        consume: (Data, URL?) throws -> Void
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard try handle.read(upToCount: magic.count) == magic else {
            try handle.seek(toOffset: 0)
            let limit = LiveTVPlaylistParser.maximumBytes * 2 + 65_536
            let bytes = try readExactlyBounded(handle, limit: limit)
            let data = try AES.GCM.open(
                AES.GCM.SealedBox(combined: bytes), using: key, authenticating: Data(context.utf8)
            )
            let document = try JSONDecoder().decode(Legacy.self, from: data)
            guard document.data.count <= LiveTVPlaylistParser.maximumBytes,
                  document.baseURL.map(LiveTVPlaylistSource.isSupportedURL) ?? true else {
                throw LiveTVCacheError.invalidRecord
            }
            try consume(document.data, document.baseURL)
            return
        }
        let header = try JSONDecoder().decode(Header.self, from: readFrame(
            handle, key: key, context: context + ":header"
        ))
        guard header.baseURL.map(LiveTVPlaylistSource.isSupportedURL) ?? true else {
            throw LiveTVCacheError.invalidRecord
        }
        var count = 0
        var bytes = 0
        var digest = SHA256()
        while true {
            try Task.checkCancellation()
            guard let tag = try handle.read(upToCount: 1)?.first else { throw LiveTVCacheError.invalidRecord }
            if tag == 2 {
                let expected = try readFrame(handle, key: key, context: context + ":complete:\(count)")
                guard expected == Data(digest.finalize()),
                      try handle.read(upToCount: 1)?.isEmpty != false else {
                    throw LiveTVCacheError.invalidRecord
                }
                return
            }
            guard tag == 1 else { throw LiveTVCacheError.invalidRecord }
            let chunk = try readFrame(handle, key: key, context: context + ":chunk:\(count)")
            guard !chunk.isEmpty, chunk.count <= chunkBytes else { throw LiveTVCacheError.invalidRecord }
            bytes += chunk.count
            guard bytes <= LiveTVPlaylistParser.maximumBytes else { throw LiveTVCacheError.tooLarge }
            digest.update(data: chunk)
            try consume(chunk, header.baseURL)
            count += 1
        }
    }

    private static func writeFrame(
        _ data: Data, to handle: FileHandle, key: SymmetricKey, context: String
    ) throws {
        guard let sealed = try AES.GCM.seal(data, using: key, authenticating: Data(context.utf8)).combined else {
            throw LiveTVCacheError.invalidRecord
        }
        var length = UInt32(sealed.count).bigEndian
        try withUnsafeBytes(of: &length) { try handle.write(contentsOf: Data($0)) }
        try handle.write(contentsOf: sealed)
    }

    private static func readFrame(_ handle: FileHandle, key: SymmetricKey, context: String) throws -> Data {
        guard let length = try handle.read(upToCount: 4), length.count == 4 else {
            throw LiveTVCacheError.invalidRecord
        }
        let count = length.reduce(0) { ($0 << 8) | Int($1) }
        guard (28...(chunkBytes + 28)).contains(count),
              let sealed = try handle.read(upToCount: count), sealed.count == count else {
            throw LiveTVCacheError.invalidRecord
        }
        return try AES.GCM.open(
            AES.GCM.SealedBox(combined: sealed), using: key, authenticating: Data(context.utf8)
        )
    }

    private static func readExactlyBounded(_ handle: FileHandle, limit: Int) throws -> Data {
        var result = Data()
        while let chunk = try handle.read(upToCount: min(chunkBytes, limit - result.count + 1)), !chunk.isEmpty {
            try Task.checkCancellation()
            result.append(chunk)
            guard result.count <= limit else { throw LiveTVCacheError.tooLarge }
        }
        return result
    }
}
