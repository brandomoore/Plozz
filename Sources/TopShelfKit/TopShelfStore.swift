import Foundation
import OSLog

/// Shared constants and deep-link helpers that bridge the main app and the Top
/// Shelf extension. Both targets compile this file.
public enum TopShelf {
    /// App Group shared between the app and the Top Shelf extension. Must match
    /// the `com.apple.security.application-groups` entitlement on both targets.
    public static let appGroupID = "group.com.thatcube.Plozz"

    /// File name of the snapshot inside the shared container.
    public static let snapshotFileName = "topshelf-snapshot.json"

    /// Custom URL scheme Plozz registers for deep links.
    public static let deepLinkScheme = "plozz"

    /// Deep-link host used for "play this item" links.
    public static let itemHost = "item"

    /// A title addressed by a deep link: the server's local id plus **which**
    /// server it came from.
    ///
    /// The account matters. A bare item id is unique only within one server — Plex
    /// ratingKeys are small per-server integers — so a link carrying only an id can
    /// open the wrong title, or nothing at all, on a device signed in to more than
    /// one server. The app is multi-account by design, so the account travels with
    /// the link.
    public struct ItemReference: Hashable, Sendable {
        public enum Action: String, Hashable, Sendable {
            case play
            case details
        }

        public let id: String
        public let accountID: String?
        public let action: Action

        public init(id: String, accountID: String? = nil, action: Action = .play) {
            self.id = id
            self.accountID = accountID
            self.action = action
        }
    }

    /// Builds the deep link that launches Plozz straight into an item.
    /// Example: `plozz://item/abc123?account=jf-1`.
    public static func itemDeepLink(
        id: String, accountID: String? = nil, action: ItemReference.Action = .play
    ) -> URL {
        var components = URLComponents()
        components.scheme = deepLinkScheme
        components.host = itemHost
        components.path = "/" + id
        var queryItems: [URLQueryItem] = []
        if let accountID, !accountID.isEmpty {
            queryItems.append(URLQueryItem(name: accountQueryItem, value: accountID))
        }
        if action != .play { queryItems.append(URLQueryItem(name: "action", value: action.rawValue)) }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        return components.url ?? URL(string: "\(deepLinkScheme)://\(itemHost)/\(id)")!
    }

    /// Query-item name carrying the owning account in an item deep link.
    public static let accountQueryItem = "account"

    /// Extracts the title a deep link addresses, or `nil` if the URL is not a
    /// recognised item link. Links written by older builds carry no account and
    /// decode with `accountID == nil`.
    public static func itemReference(from url: URL) -> ItemReference? {
        guard let id = itemID(from: url) else { return nil }
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let actions = queryItems.filter { $0.name == "action" }
        guard actions.count <= 1 else { return nil }
        let action: ItemReference.Action
        if let query = actions.first {
            guard let value = query.value, let parsed = ItemReference.Action(rawValue: value) else { return nil }
            action = parsed
        } else {
            action = .play
        }
        let accounts = queryItems.filter { $0.name == accountQueryItem }
        guard accounts.count <= 1 else { return nil }
        let accountID = accounts.first?.value
        return ItemReference(
            id: id,
            accountID: accountID.flatMap { $0.isEmpty ? nil : $0 },
            action: action
        )
    }

    /// Extracts the item id from a deep link, or `nil` if the URL is not a
    /// recognised item link.
    public static func itemID(from url: URL) -> String? {
        guard url.scheme?.lowercased() == deepLinkScheme,
              url.host?.lowercased() == itemHost
        else { return nil }

        let id = url.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }
}

/// Reads and writes the Top Shelf snapshot in the shared App Group container.
public enum TopShelfStore {
    private static var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: TopShelf.appGroupID
        )
    }

    /// Directory inside the shared container where the snapshot lives.
    ///
    /// tvOS keeps the App Group container *root* read-only — only
    /// subdirectories such as `Library/Caches` are writable. Writing the
    /// snapshot to the root fails with `NSFileWriteNoPermissionError` (513), so
    /// it is stored under `Library/Caches` instead. Both the app and the
    /// extension resolve the same path through this property.
    private static var snapshotDirectoryURL: URL? {
        containerURL?
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
    }

    /// Directory holding composited Continue-Watching posters (poster art with
    /// the progress bar burned in — see `TopShelfPosterComposer`). Lives beside
    /// the snapshot under the writable `Library/Caches` subtree so both the app
    /// (which writes) and the extension (which loads the files referenced by the
    /// snapshot) resolve the same absolute paths.
    public static var artworkDirectoryURL: URL? {
        snapshotDirectoryURL?.appendingPathComponent("topshelf-art", isDirectory: true)
    }

    /// Deletes composited posters whose filenames are no longer referenced by the
    /// freshly published snapshot, so stale/superseded art (old progress buckets,
    /// items that dropped off Continue Watching) doesn't accumulate. A no-op when
    /// the directory doesn't exist yet.
    public static func pruneArtwork(keeping keepFilenames: Set<String>) {
        guard let directory = artworkDirectoryURL else { return }
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where !keepFilenames.contains(file.lastPathComponent) {
            try? fileManager.removeItem(at: file)
        }
    }

    static var files: SnapshotFiles? { snapshotDirectoryURL.map(SnapshotFiles.init) }

    /// The extension never falls back to another user, an unowned legacy snapshot,
    /// or the last readable snapshot when the current viewer's grant is missing.
    public static func load() -> TopShelfSnapshot? { files?.load() }

    public static func isAuthorized(_ snapshot: TopShelfSnapshot) -> Bool {
        files?.isAuthorized(snapshot) == true
    }

    struct SnapshotFiles {
        let directory: URL
        private var snapshotURL: URL { directory.appendingPathComponent(TopShelf.snapshotFileName) }
        private var grantURL: URL { directory.appendingPathComponent("topshelf-authorization") }
        private var grant: Data? { try? Data(contentsOf: grantURL) }

        func isAuthorized(_ snapshot: TopShelfSnapshot) -> Bool {
            guard let id = snapshot.authorizationID else { return false }
            return grant == Data(id.uuidString.utf8)
        }

        func save(_ snapshot: TopShelfSnapshot) throws {
            guard let id = snapshot.authorizationID else { throw CocoaError(.fileWriteInvalidFileName) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: snapshotURL, options: .atomic)
            let authorization = Data(id.uuidString.utf8)
            if grant != authorization { try authorization.write(to: grantURL, options: .atomic) }
        }

        func revoke() {
            // Either removal is enough to deny a subsequent read. Remove the grant
            // first so an extension already constructing native content can recheck it.
            for url in [grantURL, snapshotURL] {
                do { try FileManager.default.removeItem(at: url) }
                catch let error as CocoaError where error.code == .fileNoSuchFile { continue }
                catch {
                    Logger(subsystem: "com.plozz.app", category: "top-shelf")
                        .error("Unable to remove a revoked Top Shelf file.")
                }
            }
        }

        func load() -> TopShelfSnapshot? {
            guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let snapshot = try? decoder.decode(TopShelfSnapshot.self, from: data),
                  isAuthorized(snapshot) else { return nil }
            return snapshot
        }
    }
}
