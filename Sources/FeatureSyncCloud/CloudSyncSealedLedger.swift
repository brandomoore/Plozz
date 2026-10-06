import CoreModels
import CryptoKit
import Foundation

/// Entry files avoid repeatedly serializing large imported playlists on each
/// CloudKit acknowledgement. The sealed index is the atomic commit point.
enum CloudSyncSealedLedger {
    private struct Reference: Codable {
        let file: UUID
        let digest: Data
        let bytes: Int
    }
    private struct Index: Codable {
        let format: Int
        let checkpoint: SyncLedger.Checkpoint
        let records: [String: Reference]
        let authority: String?
    }
    private struct LegacyWrapper: Decodable {
        let ledger: SyncLedger
    }
    private static let maximumEntryBytes = 4 * 1_024 * 1_024
    private static let maximumTotalBytes = 768 * 1_024 * 1_024

    static func load(from url: URL, codec: CloudSyncStateCodec, authority: String? = nil) throws -> SyncLedger? {
        guard let data = try readIfPresent(url, maximumBytes: CloudSyncStateCodec.maximumBytes + 1_024) else {
            return nil
        }
        let plaintext = CloudSyncStateCodec.isSealed(data) ? try codec.decode(data) : data
        if let index = try? JSONDecoder().decode(Index.self, from: plaintext) {
            guard CloudSyncStateCodec.isSealed(data), index.format == 1, index.records.count <= 50_000,
                  index.records.values.allSatisfy({ (1...maximumEntryBytes).contains($0.bytes) }),
                  index.records.values.reduce(0, { $0 + $1.bytes }) <= maximumTotalBytes else {
                throw CloudSyncStateCodec.Failure.tooLarge
            }
            guard index.authority == authority else { return nil }
            var entries: [String: SyncLedgerEntry] = [:]
            for (name, reference) in index.records {
                let file = directory(url).appendingPathComponent(reference.file.uuidString + ".sealed")
                guard let sealed = try readIfPresent(file, maximumBytes: maximumEntryBytes + 1_024) else {
                    throw CloudSyncStateCodec.Failure.invalidEnvelope
                }
                let entryData = try codec.decode(sealed)
                guard entryData.count == reference.bytes, Data(SHA256.hash(data: entryData)) == reference.digest else {
                    throw CloudSyncStateCodec.Failure.invalidEnvelope
                }
                var entry = try JSONDecoder().decode(SyncLedgerEntry.self, from: entryData)
                if entry.syncedValue == entry.localValue { entry.syncedValue = entry.localValue }
                entries[name] = entry
            }
            return SyncLedger(checkpoint: index.checkpoint, entries: entries)
        }
        guard authority == nil else { return nil }
        let ledger: SyncLedger
        if let wrapped = try? JSONDecoder().decode(LegacyWrapper.self, from: plaintext) {
            ledger = wrapped.ledger
        } else {
            ledger = try JSONDecoder().decode(SyncLedger.self, from: plaintext)
        }
        try save(ledger, to: url, codec: codec)
        return ledger
    }

    static func save(_ ledger: SyncLedger, to url: URL, codec: CloudSyncStateCodec, authority: String? = nil) throws {
        var previous: Index?
        if let data = try readIfPresent(url, maximumBytes: CloudSyncStateCodec.maximumBytes + 1_024),
           CloudSyncStateCodec.isSealed(data) {
            let plaintext = try codec.decode(data)
            previous = try? JSONDecoder().decode(Index.self, from: plaintext)
        }
        var folder = directory(url)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try folder.setResourceValues(attributes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var records: [String: Reference] = [:]
        var total = 0
        for (name, entry) in ledger.entries {
            let data = try encoder.encode(entry)
            total += data.count
            guard data.count <= maximumEntryBytes, total <= maximumTotalBytes,
                  ledger.entries.count <= 50_000 else { throw CloudSyncStateCodec.Failure.tooLarge }
            let digest = Data(SHA256.hash(data: data))
            if let reference = previous?.records[name], reference.digest == digest {
                records[name] = reference
            } else {
                let reference = Reference(file: UUID(), digest: digest, bytes: data.count)
                try write(codec.encode(data), to: folder.appendingPathComponent(reference.file.uuidString + ".sealed"))
                records[name] = reference
            }
        }
        try write(codec.encode(encoder.encode(Index(
            format: 1, checkpoint: ledger.checkpoint, records: records, authority: authority
        ))), to: url)
        // Only remove files positively retired by the successfully committed index.
        let retained = Set(records.values.map(\.file))
        for reference in previous?.records.values ?? Dictionary<String, Reference>().values
        where !retained.contains(reference.file) {
            try FileManager.default.removeItem(at: folder.appendingPathComponent(reference.file.uuidString + ".sealed"))
        }
    }

    private static func directory(_ url: URL) -> URL { url.appendingPathExtension("entries") }

    private static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var file = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try file.setResourceValues(values)
    }

    private static func readIfPresent(_ url: URL, maximumBytes: Int) throws -> Data? {
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= maximumBytes else { throw CloudSyncStateCodec.Failure.tooLarge }
            return try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }
}
