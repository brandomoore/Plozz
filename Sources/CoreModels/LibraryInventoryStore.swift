import CryptoKit
import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// Library names are shared by profiles using the same authorized server viewer,
/// not by profiles using different users on the same server. This is a display
/// cache; callers must resolve current authorization before reading it.
public final class LibraryInventoryStore: @unchecked Sendable {
    public static let shared = LibraryInventoryStore()

    private struct Entry: Codable {
        let libraries: [MediaLibrary]
        let updatedAt: Date
        // Live publication order only; an entry restored from disk cannot validate a handoff.
        var sequence: Int?
        private enum CodingKeys: String, CodingKey { case libraries, updatedAt }
    }

    fileprivate struct Request: Sendable {
        let scope: String
        let sequence: Int
    }

    package struct Publication: Sendable {
        fileprivate let store: LibraryInventoryStore
        fileprivate let request: Request
        fileprivate let libraries: [MediaLibrary]

        package var currentLibraries: [MediaLibrary]? {
            store.lock.withLock {
                store.entries?[request.scope]?.sequence == request.sequence ? libraries : nil
            }
        }
    }

    private static let maximumBytes = 2 * 1_024 * 1_024
    #if canImport(OSLog)
    private static let logger = Logger(subsystem: "com.plozz.app", category: "library-inventory")
    #endif
    private let url: URL?
    private let lock = NSLock()
    private var entries: [String: Entry]?
    private var nextRequest = 0
    private var inFlight: [String: Set<Int>] = [:]
    private var published: [String: Int] = [:]

    public init(directory: URL? = LibraryInventoryStore.defaultDirectory()) {
        url = directory?.appendingPathComponent("library-inventory-v1.json")
    }

    public static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Plozz", isDirectory: true)
    }

    public func load(for account: ResolvedAccount) -> [MediaLibrary]? {
        guard account.provider.sharesLibraryInventoryAcrossProfiles else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return readEntries()[scope(account)]?.libraries
    }

    /// Always contacts the provider. A newer completed answer wins, but merely
    /// starting (and then cancelling) a refresh does not discard an older one.
    public func refresh(
        for account: ResolvedAccount,
        load: @Sendable () async throws -> [MediaLibrary]
    ) async throws -> [MediaLibrary] {
        try await refresh(for: account, inventory: { $0 }, load: load).value
    }

    /// Start ordering at the actual provider read, not later when Home consumes it.
    package func refresh<Value: Sendable>(
        for account: ResolvedAccount, inventory: @Sendable (Value) -> [MediaLibrary],
        load: @Sendable () async throws -> Value
    ) async throws -> (value: Value, publication: Publication?) {
        try Task.checkCancellation()
        guard account.provider.sharesLibraryInventoryAcrossProfiles else {
            let value = try await load()
            try Task.checkCancellation()
            return (value, nil)
        }
        let request = beginRefresh(for: account)
        do {
            let value = try await load()
            try Task.checkCancellation()
            let libraries = inventory(value)
            finishRefresh(request, libraries: libraries)
            return (value, Publication(store: self, request: request, libraries: libraries))
        } catch {
            finishRefresh(request, error: Task.isCancelled ? .cancelled : error as? AppError)
            throw error
        }
    }

    private func beginRefresh(for account: ResolvedAccount) -> Request {
        lock.lock()
        defer { lock.unlock() }
        nextRequest += 1
        let request = Request(scope: scope(account), sequence: nextRequest)
        inFlight[request.scope, default: []].insert(request.sequence)
        return request
    }

    private func finishRefresh(_ request: Request, libraries: [MediaLibrary]? = nil, error: AppError? = nil) {
        lock.lock()
        defer { lock.unlock() }
        defer {
            inFlight[request.scope]?.remove(request.sequence)
            if inFlight[request.scope]?.isEmpty == true {
                inFlight[request.scope] = nil
                published[request.scope] = nil
            }
        }
        guard request.sequence > (published[request.scope] ?? 0) else { return }
        let denied = error?.requiresSignIn == true || error == .accessRestricted
        guard denied || libraries != nil else { return }
        published[request.scope] = request.sequence
        // Retire the prior witness even if encoding the replacement display entry fails.
        entries?[request.scope]?.sequence = nil
        var values = readEntries()
        if denied {
            values[request.scope] = nil
            persist(values)
            return
        }
        guard let libraries else { return }
        // Do not persist artwork URLs, credentials, or merged cross-account routes.
        let names = libraries.prefix(512).map {
            MediaLibrary(
                id: $0.id, title: $0.title, kind: $0.kind,
                synthesizedName: $0.synthesizedName, collectionSourceTitle: $0.collectionSourceTitle,
                hasCollections: $0.hasCollections, isMusic: $0.isMusic
            )
        }
        let unchanged = values[request.scope]?.libraries == names
        values[request.scope] = Entry(libraries: names, updatedAt: Date(), sequence: request.sequence)
        if unchanged {
            entries = values
            return
        }
        let retained = values.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(128)
        persist(Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) }))
    }

    private func scope(_ resolved: ResolvedAccount) -> String {
        let account = resolved.account
        // A Plex Home token is reissued on profile activation. Its verified
        // viewer ID plus the persisted login revision is the reusable identity.
        let revision = account.server.provider == .plex && resolved.plexHomeUserID != nil
            ? account.credentialRevision : resolved.credentialRevision
        let fields = [
            account.connectionScopeKey, account.server.provider.rawValue, account.server.id,
            account.userID, revision.rawValue.uuidString,
            resolved.plexHomeUserID ?? ""
        ]
        let identity = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func readEntries() -> [String: Entry] {
        if let entries { return entries }
        entries = [:]
        guard let url else { return [:] }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
            guard data.count <= Self.maximumBytes else {
                #if canImport(OSLog)
                Self.logger.error("Library inventory cache exceeds its size limit")
                #endif
                return [:]
            }
            let decoded = try JSONDecoder().decode([String: Entry].self, from: data)
            entries = decoded
            return decoded
        } catch {
            if (error as NSError).code != NSFileReadNoSuchFileError {
                #if canImport(OSLog)
                Self.logger.error("Could not restore the library inventory cache")
                #endif
            }
            return [:]
        }
    }

    private func persist(_ values: [String: Entry]) {
        do {
            var bounded = values
            var data = try JSONEncoder().encode(bounded)
            for entry in values.sorted(by: { $0.value.updatedAt < $1.value.updatedAt })
                where data.count > Self.maximumBytes {
                bounded[entry.key] = nil
                data = try JSONEncoder().encode(bounded)
            }
            entries = bounded
            guard let url else { return }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            #if canImport(OSLog)
            Self.logger.error("Could not save the library inventory cache")
            #endif
        }
    }
}
