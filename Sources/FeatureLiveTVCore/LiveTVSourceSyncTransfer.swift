import CoreModels
import CryptoKit
import Foundation

public struct LiveTVImportedPlaylistTransfer: Sendable {
    public let chunks: [Data]
    public let baseURL: URL?
    public let digest: Data

    public init(chunks: [Data], baseURL: URL?) throws {
        guard !chunks.isEmpty, chunks.count <= 8_192,
              chunks.allSatisfy({ !$0.isEmpty && $0.count <= LiveTVImportedPlaylistArchive.chunkBytes }),
              chunks.reduce(0, { $0 + $1.count }) <= LiveTVPlaylistParser.maximumBytes,
              baseURL.map(LiveTVPlaylistSource.isSupportedURL) ?? true else {
            throw LiveTVPortableStateError.invalidRecord
        }
        self.chunks = chunks
        self.baseURL = baseURL
        var hash = SHA256()
        for chunk in chunks { hash.update(data: chunk) }
        digest = Data(hash.finalize())
    }

    public var byteCount: Int { chunks.reduce(0) { $0 + $1.count } }
}

/// Only used by the encrypted source channel; never the portable metadata journal.
public struct LiveTVSourceSyncManifest: Codable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public let chunks: Int
        public let bytes: Int
        public let digest: Data
        public let baseURL: URL?

        public init(_ transfer: LiveTVImportedPlaylistTransfer) {
            chunks = transfer.chunks.count
            bytes = transfer.byteCount
            digest = transfer.digest
            baseURL = transfer.baseURL
        }
    }

    public let version: Int
    public let source: LiveTVPlaylistSource?
    public let file: File?

    public init(source: LiveTVPlaylistSource?, file: File? = nil) {
        version = 1
        self.source = source
        self.file = file
    }

    public func validate(id: String) throws {
        guard version == 1 else { throw LiveTVPortableStateError.unsupportedVersion }
        guard let source else {
            guard file == nil else { throw LiveTVPortableStateError.invalidRecord }
            return
        }
        try source.validate()
        guard source.id == id, (source.importedPlaylistID != nil) == (file != nil) else {
            throw LiveTVPortableStateError.invalidRecord
        }
        if let file {
            guard (1...8_192).contains(file.chunks), (1...LiveTVPlaylistParser.maximumBytes).contains(file.bytes),
                  file.digest.count == 32, file.baseURL.map(LiveTVPlaylistSource.isSupportedURL) ?? true else {
                throw LiveTVPortableStateError.invalidRecord
            }
        }
    }

    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 512 * 1_024 else { throw LiveTVPortableStateError.tooLarge }
        return data
    }

    public func fileFingerprint() throws -> Data? {
        guard let file else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(file)))
    }

    public static func sourceDigest(_ source: LiveTVPlaylistSource?) throws -> Data {
        guard let source else { return Data() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(source)))
    }
}
