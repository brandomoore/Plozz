import CoreModels
import CoreNetworking
import CryptoKit
import Foundation

/// The rows and category counts that were on screen when Live TV was last used.
///
/// Opening Live TV shows these at once and reads the lineup behind them. The rows are real
/// channels: each is re-admitted under the current account authorization before it is shown.
public struct LiveTVLastSeenSnapshot: Codable, Equatable, Sendable {
    public static let maximumChannels = 150

    public struct Entry: Codable, Equatable, Sendable {
        /// The provider's own channel identifier, from which the published identifier is re-derived.
        public let nativeID: String
        public let channel: LiveTVPrototypeChannel
    }

    public struct Source: Codable, Equatable, Sendable {
        public let sourceID: String
        public let accountID: String
        public let kind: LiveTVPrototypeSource
        /// Absent in legacy documents, which cannot prove whose lineup was saved.
        public let viewerScopeID: String?
        public let entries: [Entry]

        public init(
            sourceID: String, accountID: String, kind: LiveTVPrototypeSource,
            entries: [Entry], viewerScopeID: String? = nil
        ) {
            self.sourceID = sourceID
            self.accountID = accountID
            self.kind = kind
            self.entries = entries
            self.viewerScopeID = viewerScopeID
        }
    }

    public let sources: [Source]
    public let browse: LiveTVBrowseSummary
}

/// Category names and channel counts for the browsing filters in effect.
public struct LiveTVBrowseSummary: Codable, Equatable, Sendable {
    public let categories: [String]
    public let categoryCounts: [String: Int]
    public let totalCount: Int
}

public typealias LiveTVLastSeenSaveOperation = @Sendable (LiveTVLastSeenSnapshot?) async -> Void

public protocol LiveTVLastSeenStoring: Sendable {
    func load() async -> LiveTVLastSeenSnapshot?
    func save(_ snapshot: LiveTVLastSeenSnapshot?) async
    /// Capture write admission before scheduling any asynchronous snapshot preparation.
    func prepareSave() -> LiveTVLastSeenSaveOperation
}

public extension LiveTVLastSeenStoring {
    func prepareSave() -> LiveTVLastSeenSaveOperation {
        { snapshot in await self.save(snapshot) }
    }
}

/// A local, disposable, sealed file per profile. Anything unreadable is treated as absent.
public actor LiveTVLastSeenStore: LiveTVLastSeenStoring {
    public static let maximumBytes = 1_024 * 1_024
    private let profileID: String
    private let url: URL?
    private let secureStore: any SecureStoring
    private let keyName: String
    private let beforeSave: (@Sendable () async -> Void)?
    private static let access = Access()
    private static let header = Data("PLS1".utf8)
    private enum CacheError: Error { case missingKey, invalidKey, invalidCiphertext }

    /// All instances share file/key serialization and directory-scoped erasure epochs.
    /// No suspension is allowed while holding this lock, including during Keychain I/O.
    private final class Access: @unchecked Sendable {
        let lock = NSLock()
        private var generations: [String: UUID] = [:]

        private func key(for directory: URL) -> String {
            // A parent URL carries a trailing slash even if the caller's directory URL didn't.
            directory.standardizedFileURL.pathComponents.joined(separator: "/")
        }

        func generation(for directory: URL) -> UUID {
            lock.withLock {
                let directoryKey = key(for: directory)
                if let generation = generations[directoryKey] { return generation }
                let generation = UUID()
                generations[directoryKey] = generation
                return generation
            }
        }

        func withGeneration<T>(for directory: URL, _ generation: UUID, body: () throws -> T) rethrows -> T? {
            try lock.withLock {
                guard generations[key(for: directory)] == generation else { return nil }
                return try body()
            }
        }

        func erase<T>(directory: URL?, body: () throws -> T) rethrows -> T {
            try lock.withLock {
                if let directory { generations[key(for: directory)] = UUID() }
                return try body()
            }
        }
    }

    private struct Document: Codable {
        var version = 1
        let profileID: String
        let snapshot: LiveTVLastSeenSnapshot
    }

    public init(
        profileID: String, directory: URL? = LiveTVLastSeenStore.defaultDirectory(),
        secureStore: any SecureStoring,
        beforeSave: (@Sendable () async -> Void)? = nil
    ) {
        self.beforeSave = beforeSave
        self.profileID = profileID
        self.secureStore = secureStore
        let name = SHA256.hash(data: Data(profileID.utf8)).map { String(format: "%02x", $0) }.joined()
        keyName = "liveTV.lastSeen." + name + ".key"
        url = directory?.standardizedFileURL.appendingPathComponent(name).appendingPathExtension("bin")
    }

    public static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Plozz/LiveTVLastSeen-v1", isDirectory: true)
    }

    /// Erases last-seen files and keys, preserving other catalog secrets.
    public static func erase(
        profileIDs: [String], directory: URL? = defaultDirectory(), secureStore: any SecureStoring
    ) throws {
        let directory = directory?.standardizedFileURL
        try access.erase(directory: directory) {
            try eraseFilesAndKeys(profileIDs: profileIDs, directory: directory, secureStore: secureStore)
        }
    }

    private static func eraseFilesAndKeys(
        profileIDs: [String], directory: URL?, secureStore: any SecureStoring
    ) throws {
        var names = Set(profileIDs.map { profileID in
            SHA256.hash(data: Data(profileID.utf8)).map { String(format: "%02x", $0) }.joined()
        })
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "bin" {
                let name = file.deletingPathExtension().lastPathComponent
                if name.count == 64 && name.allSatisfy({ "0123456789abcdef".contains($0) }) {
                    names.insert(name)
                }
            }
            try FileManager.default.removeItem(at: directory)
        }
        for name in names {
            try secureStore.removeValue(for: "liveTV.lastSeen." + name + ".key")
        }
    }

    public func load() async -> LiveTVLastSeenSnapshot? {
        Self.access.lock.withLock { loadRows() }
    }

    private func loadRows() -> LiveTVLastSeenSnapshot? {
        guard let url, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
            guard data.count <= Self.maximumBytes, data.starts(with: Self.header) else { return nil }
            let plaintext = try AES.GCM.open(
                AES.GCM.SealedBox(combined: Data(data.dropFirst(Self.header.count))),
                using: encryptionKey(create: false), authenticating: Data(keyName.utf8)
            )
            let document = try JSONDecoder().decode(Document.self, from: plaintext)
            guard document.version == 1, document.profileID == profileID,
                  Self.isValid(document.snapshot) else { return nil }
            return document.snapshot
        } catch {
            PlozzLog.app.info("Live TV last-seen rows could not be restored")
            return nil
        }
    }

    public nonisolated func prepareSave() -> LiveTVLastSeenSaveOperation {
        guard let url else { return { _ in } }
        let generation = Self.access.generation(for: url.deletingLastPathComponent())
        return { snapshot in await self.save(snapshot, generation: generation) }
    }

    public nonisolated func save(_ snapshot: LiveTVLastSeenSnapshot?) async {
        let write = prepareSave()
        await write(snapshot)
    }

    private func save(_ snapshot: LiveTVLastSeenSnapshot?, generation: UUID) async {
        guard let url, !Task.isCancelled else { return }
        await beforeSave?()
        _ = Self.access.withGeneration(for: url.deletingLastPathComponent(), generation) {
            guard !Task.isCancelled else { return }
            saveRows(snapshot, to: url)
        }
    }

    private func saveRows(_ snapshot: LiveTVLastSeenSnapshot?, to url: URL) {
        guard let snapshot, Self.isValid(snapshot) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            let plaintext = try JSONEncoder().encode(Document(profileID: profileID, snapshot: snapshot))
            guard let sealed = try AES.GCM.seal(
                plaintext, using: encryptionKey(create: true), authenticating: Data(keyName.utf8)
            ).combined else { throw CacheError.invalidCiphertext }
            let data = Self.header + sealed
            guard data.count <= Self.maximumBytes else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            PlozzLog.app.error("Live TV last-seen rows could not be saved")
        }
    }

    private func encryptionKey(create: Bool) throws -> SymmetricKey {
        if let stored = try secureStore.readString(for: keyName) {
            guard let data = Data(base64Encoded: stored), data.count == 32 else { throw CacheError.invalidKey }
            return SymmetricKey(data: data)
        }
        guard create else { throw CacheError.missingKey }
        let key = SymmetricKey(size: .bits256)
        try secureStore.setString(key.withUnsafeBytes { Data($0) }.base64EncodedString(), for: keyName)
        return key
    }

    private static func isValid(_ snapshot: LiveTVLastSeenSnapshot) -> Bool {
        let entries = snapshot.sources.flatMap(\.entries)
        return !entries.isEmpty && entries.count <= LiveTVLastSeenSnapshot.maximumChannels
            && Set(snapshot.sources.map(\.sourceID)).count == snapshot.sources.count
            && Set(entries.map(\.channel.id)).count == entries.count
            && snapshot.sources.allSatisfy {
                !$0.sourceID.isEmpty && !$0.accountID.isEmpty && !($0.viewerScopeID?.isEmpty ?? true)
            }
            // Server lineups carry no stream address; a row that does is not one of ours.
            && entries.allSatisfy {
                !$0.nativeID.isEmpty && $0.channel.streamURL == nil && $0.channel.httpHeaders.isEmpty
            }
            && snapshot.browse.totalCount >= 0 && snapshot.browse.categoryCounts.values.allSatisfy { $0 >= 0 }
    }
}
