import CoreModels
import CryptoKit
import Foundation

/// ETags describe a single page. Never skip another page because page 1 matches.
struct PublicMetaDBHistoryPages: Sendable {
    let watches: Pages<PublicMetaDB.Watch>
    let resumes: Pages<PublicMetaDB.Resume>
    let folder: URL?

    init(connection: UUID, namespace: String?, root: URL?) {
        let scope = WatchlistReconciliationIdentity.credential("\(namespace ?? "")/\(connection.uuidString)")
        folder = root?.appendingPathComponent(scope, isDirectory: true)
        watches = Pages(path: "/watched", scope: scope, folder: folder)
        resumes = Pages(path: "/resume", scope: scope, folder: folder)
    }

    static var appRoot: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PublicMetaDBHistory-v1", isDirectory: true)
    }

    func discard() async {
        await watches.clear()
        await resumes.clear()
        guard let folder else { return }
        do { try FileManager.default.removeItem(at: folder) }
        catch let e as CocoaError where e.code == .fileNoSuchFile { }
        catch { HandoffDiagnostics.emit("PUBLICMETADB_HISTORY cache-removal-failed") }
    }

    actor Pages<Value: Codable & Sendable> {
        typealias Page = PublicMetaDB.Page<PublicMetaDB.Record<Value>>

        private struct Row: Codable {
            let id: String
            let value: Value
            let updated: String?
        }
        private struct Saved: Codable {
            let key: String
            let tag: String
            let page, total, perPage, totalPages: Int
            let rows: [Row]
        }
        private let path, scope: String
        private let folder: URL?
        private var memory: [Int: (tag: String, page: Page)] = [:]
        private var invalidated = false

        init(path: String, scope: String, folder: URL?) {
            self.path = path
            self.scope = scope
            self.folder = folder
        }

        func clear() {
            invalidated = true
            memory.removeAll()
        }

        func read(client: PublicMetaDBClient) async throws -> [PublicMetaDB.Record<Value>] {
            try await client.completePages(maximumPages: 100) { page in try await self.readPage(page, client) }
        }

        private func readPage(_ n: Int, _ client: PublicMetaDBClient) async throws -> Page {
            let key = "\(scope)\(path)?page=\(n)&perPage=500"
            let file = folder?.appendingPathComponent("\(path.dropFirst())-\(n)")
            let cached = memory[n] ?? load(file, key: key, page: n)
            let (data, response) = try await client.historyPageResponse(path: path, page: n, perPage: 500, ifNoneMatch: cached?.tag)
            try Task.checkCancellation()
            guard !invalidated else { throw PublicMetaDB.Failure.connectionChanged }
            HandoffDiagnostics.emit("PUBLICMETADB_HISTORY \(path) page=\(n) status=\(response.statusCode) bodyBytes=\(data.count)")
            let tag = response.value(forHTTPHeaderField: "ETag")
            let page: Page
            if response.statusCode == 304 {
                guard let cached, tag == nil || tag == cached.tag else { throw PublicMetaDB.Failure.incompleteResponse }
                page = cached.page
            } else {
                guard response.statusCode == 200 else { throw PublicMetaDB.Failure.incompleteResponse }
                do { page = try PublicMetaDBClient.decoder().decode(Page.self, from: data) }
                catch { throw AppError.decoding }
                try page.validate(requestedPage: n, maximumPageSize: 500)
            }
            let noStore = response.value(forHTTPHeaderField: "Cache-Control")?.lowercased().contains("no-store") == true
            if noStore || (response.statusCode == 200 && !Self.validTag(tag)) {
                memory[n] = nil
                if let file { Self.remove(file) }
            } else if response.statusCode == 304 {
                memory[n] = cached
            } else if let tag {
                memory[n] = (tag, page)
                if let file {
                    save(.init(key: key, tag: tag, page: n, total: page.total, perPage: page.perPage,
                               totalPages: page.totalPages, rows: page.items.map { Row(id: $0.id, value: $0.value, updated: $0.updated) }), to: file)
                }
            }
            return page
        }

        private static func validTag(_ tag: String?) -> Bool {
            guard let tag, tag.utf8.count <= 512 else { return false }
            let quoted = tag.hasPrefix("W/") ? tag.dropFirst(2) : tag[...]
            return quoted.count >= 2 && quoted.first == "\"" && quoted.last == "\"" &&
                quoted.dropFirst().dropLast().utf8.allSatisfy { $0 == 33 || (35...126).contains($0) }
        }

        private func load(_ url: URL?, key: String, page n: Int) -> (tag: String, page: Page)? {
            guard let url else { return nil }
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let body = data.dropFirst(32)
                guard data.count <= 8 * 1024 * 1024, data.prefix(32).elementsEqual(SHA256.hash(data: body)) else {
                    throw PublicMetaDB.Failure.incompleteResponse
                }
                let saved = try PublicMetaDBClient.decoder().decode(Saved.self, from: body)
                guard saved.key == key, Self.validTag(saved.tag) else { throw PublicMetaDB.Failure.incompleteResponse }
                let page = Page(items: saved.rows.map {
                    .init(id: $0.id, value: $0.value, contributor: nil, created: nil, updated: $0.updated)
                }, total: saved.total, page: saved.page, perPage: saved.perPage, totalPages: saved.totalPages)
                try page.validate(requestedPage: n, maximumPageSize: 500)
                return (saved.tag, page)
            } catch let e as CocoaError where e.code == .fileReadNoSuchFile { return nil }
            catch { HandoffDiagnostics.emit("PUBLICMETADB_HISTORY cache-unusable"); return nil }
        }

        private func save(_ entry: Saved, to url: URL) {
            do {
                let body = try PublicMetaDBClient.encode(entry)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try (Data(SHA256.hash(data: body)) + body).write(to: url, options: [.atomic, .completeFileProtection])
            } catch { HandoffDiagnostics.emit("PUBLICMETADB_HISTORY cache-not-persisted") }
        }

        private static func remove(_ url: URL) {
            do { try FileManager.default.removeItem(at: url) }
            catch let e as CocoaError where e.code == .fileNoSuchFile { }
            catch { HandoffDiagnostics.emit("PUBLICMETADB_HISTORY cache-removal-failed") }
        }
    }
}
