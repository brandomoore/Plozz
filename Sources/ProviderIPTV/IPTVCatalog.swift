import CoreModels
import CoreNetworking
import CryptoKit
import Foundation
import SQLite3

struct IPTVRecord: Codable, Sendable {
    var item: MediaItem
    var parentID: String?
    var streamURL: URL?
    var headers: [String: String] = [:]
    var streamID: String?
    var container: String?
    var guideID: String?
    var guideName: String?
    var guideCountry: String?
    var channelNumber: Int?
    var isLive = false
}

/// Confined to IPTVClient. Pages are decoded on demand; credential-bearing
/// delivery URLs are sealed separately from the searchable catalogue columns.
final class IPTVCatalog {
    enum Table: String { case entries, incoming }
    private var db: OpaquePointer?
    private let key: SymmetricKey
    private var writeStatements: [String: OpaquePointer] = [:]
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let indexes = [
        ("catalogue_browse", "library,kind,title,id"),
        ("catalogue_parent", "parent,ordinal,id"),
        ("catalogue_recent", "library,added DESC"),
        ("catalogue_name", "library,kind,title COLLATE NOCASE,id"),
        ("catalogue_year", "library,kind,year,id"),
        ("catalogue_added", "library,kind,added,id"),
        ("catalogue_live", "live,title COLLATE NOCASE,id")
    ]

    init(url: URL, key: Data) throws {
        self.key = SymmetricKey(data: key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
                == SQLITE_OK, let handle else {
            let error = Self.databaseError(sqlite3_extended_errcode(handle))
            if let handle { sqlite3_close(handle) }
            throw error
        }
        db = handle
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=NORMAL")
            try execute("PRAGMA cache_size=-4096")
            try execute("PRAGMA temp_store=FILE")
            try execute("PRAGMA busy_timeout=15000")
            try execute("""
                CREATE TABLE IF NOT EXISTS entries (
                    id TEXT PRIMARY KEY, kind TEXT NOT NULL, library TEXT NOT NULL,
                    parent TEXT, title TEXT NOT NULL, year INTEGER NOT NULL, added REAL NOT NULL,
                    ordinal INTEGER NOT NULL, live INTEGER NOT NULL, payload BLOB NOT NULL
                );
                CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                """)
            try createIndexes()
        } catch {
            sqlite3_close(handle)
            db = nil
            throw error
        }
    }

    deinit {
        for statement in writeStatements.values { sqlite3_finalize(statement) }
        if let db { sqlite3_close(db) }
    }

    func execute(_ sql: String, cancellable: Bool = false) throws {
        if cancellable { sqlite3_progress_handler(db, 1_000, { _ in Task.isCancelled ? 1 : 0 }, nil) }
        defer { if cancellable { sqlite3_progress_handler(db, 0, nil, nil) } }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            let code = sqlite3_extended_errcode(db)
            if code & 0xff == SQLITE_INTERRUPT { try Task.checkCancellation() }
            throw Self.databaseError(code)
        }
    }

    func insert(_ record: IPTVRecord, overwrite: Bool = true, into table: Table = .entries) throws {
        if !overwrite, try contains(record.item.id, in: table) { return }
        let data = try JSONEncoder().encode(record)
        guard let sealed = try AES.GCM.seal(data, using: key).combined else { throw IPTVError.storage }
        let item = record.item
        let sql = """
            INSERT OR \(overwrite ? "REPLACE" : "IGNORE") INTO \(table.rawValue)
            (id,kind,library,parent,title,year,added,ordinal,live,payload) VALUES(?,?,?,?,?,?,?,?,?,?)
            """
        let statement = try writeStatement(sql)
        defer { resetWriteStatement(statement) }
        try bind([item.id, item.kind.rawValue, item.libraryID ?? "", record.parentID, item.title,
                  String(item.productionYear ?? 0), String(item.librarySortValues?.dateAdded?.timeIntervalSince1970 ?? 0),
                  String(item.episodeNumber ?? item.seasonNumber ?? 0),
                  record.isLive ? "1" : "0"], to: statement)
        let status = sealed.withUnsafeBytes {
            sqlite3_bind_blob(statement, 10, $0.baseAddress, Int32($0.count), Self.transient)
        }
        guard status == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
            throw Self.databaseError(sqlite3_extended_errcode(db))
        }
    }

    func record(_ id: String) throws -> IPTVRecord {
        guard let result = try records(where: "id = ?", values: [id], limit: 1).first else {
            throw AppError.notFound
        }
        return result
    }

    func records(
        where predicate: String, values: [String], order: String = "title COLLATE NOCASE, id",
        start: Int = 0, limit: Int = 200
    ) throws -> [IPTVRecord] {
        guard start >= 0, limit > 0 else { throw AppError.invalidResponse }
        let statement = try prepare(
            "SELECT payload FROM entries WHERE \(predicate) ORDER BY \(order) LIMIT ? OFFSET ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind(values + [String(min(limit, 2_000)), String(start)], to: statement)
        var records: [IPTVRecord] = []
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return records }
            guard status == SQLITE_ROW else {
                throw Self.databaseError(sqlite3_extended_errcode(db))
            }
            guard let bytes = sqlite3_column_blob(statement, 0) else { throw IPTVError.storage }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            let decoded = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
            records.append(try JSONDecoder().decode(IPTVRecord.self, from: decoded))
        }
    }

    func count(where predicate: String, values: [String] = [], in table: Table = .entries) throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM \(table.rawValue) WHERE \(predicate)")
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw Self.databaseError(sqlite3_extended_errcode(db)) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func state(_ name: String) throws -> String? {
        let statement = try prepare("SELECT value FROM state WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        try bind([name], to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw Self.databaseError(sqlite3_extended_errcode(db)) }
        guard let value = sqlite3_column_text(statement, 0) else { throw IPTVError.storage }
        return String(cString: value)
    }

    func setState(_ name: String, _ value: String) throws {
        let statement = try prepare("INSERT OR REPLACE INTO state(key,value) VALUES(?,?)")
        defer { sqlite3_finalize(statement) }
        try bind([name, value], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.databaseError(sqlite3_extended_errcode(db)) }
    }

    func remove(library: String) throws {
        let statement = try prepare("DELETE FROM entries WHERE library = ?")
        defer { sqlite3_finalize(statement) }
        try bind([library], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.databaseError(sqlite3_extended_errcode(db)) }
    }

    func beginImport() throws {
        try execute("""
            CREATE TEMP TABLE incoming (
                id TEXT PRIMARY KEY, kind TEXT NOT NULL, library TEXT NOT NULL,
                parent TEXT, title TEXT NOT NULL, year INTEGER NOT NULL, added REAL NOT NULL,
                ordinal INTEGER NOT NULL, live INTEGER NOT NULL, payload BLOB NOT NULL
            )
            """)
    }

    func discardImport() {
        for statement in writeStatements.values { sqlite3_finalize(statement) }
        writeStatements.removeAll()
        do { try execute("DROP TABLE IF EXISTS incoming") }
        catch { PlozzLog.networking.error("IPTV temporary catalogue could not be removed") }
    }

    func commitImport(
        library: String?, scope: String, progress: (Int) throws -> Void = { _ in }
    ) throws {
        try Task.checkCancellation()
        try progress(0)
        try execute("BEGIN IMMEDIATE")
        do {
            if let library { try remove(library: library) }
            else {
                // Rebuild secondary indexes once, inside the same atomic replacement.
                for (name, _) in Self.indexes { try execute("DROP INDEX \(name)") }
                try execute("DELETE FROM entries")
            }
            // Report completed batches without publishing a partially replaced catalogue.
            var lastRowID: Int64 = 0
            var copied = 0
            while let nextRowID = try lastImportRow(after: lastRowID) {
                try Task.checkCancellation()
                try execute("""
                    INSERT INTO entries SELECT * FROM incoming
                    WHERE rowid > \(lastRowID) AND rowid <= \(nextRowID)
                    """)
                copied += Int(sqlite3_changes(db))
                lastRowID = nextRowID
                try progress(copied)
            }
            if library == nil { try createIndexes() }
            try Task.checkCancellation()
            try setState(scope, String(Date().timeIntervalSince1970))
            try execute("COMMIT")
        } catch {
            if sqlite3_get_autocommit(db) == 0 {
                do { try execute("ROLLBACK") }
                catch { PlozzLog.networking.error("IPTV catalogue rollback failed") }
            }
            throw error
        }
    }

    private func createIndexes() throws {
        for (name, columns) in Self.indexes {
            try Task.checkCancellation()
            try execute("CREATE INDEX IF NOT EXISTS \(name) ON entries(\(columns))", cancellable: true)
        }
    }

    private func lastImportRow(after rowID: Int64) throws -> Int64? {
        let statement = try prepare("""
            SELECT MAX(rowid) FROM (
                SELECT rowid FROM incoming WHERE rowid > ? ORDER BY rowid LIMIT 500
            )
            """)
        defer { sqlite3_finalize(statement) }
        try bind([String(rowID)], to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw Self.databaseError(sqlite3_extended_errcode(db)) }
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private func contains(_ id: String, in table: Table) throws -> Bool {
        let statement = try writeStatement("SELECT 1 FROM \(table.rawValue) WHERE id = ?")
        defer { resetWriteStatement(statement) }
        try bind([id], to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw Self.databaseError(sqlite3_extended_errcode(db))
        }
    }

    private func writeStatement(_ sql: String) throws -> OpaquePointer {
        if let statement = writeStatements[sql] { return statement }
        let statement = try prepare(sql)
        writeStatements[sql] = statement
        return statement
    }

    private func resetWriteStatement(_ statement: OpaquePointer) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Self.databaseError(sqlite3_extended_errcode(db))
        }
        return statement
    }

    private func bind(_ values: [String?], to statement: OpaquePointer) throws {
        for (index, value) in values.enumerated() {
            let status: Int32
            if let value { status = sqlite3_bind_text(statement, Int32(index + 1), value, -1, Self.transient) }
            else { status = sqlite3_bind_null(statement, Int32(index + 1)) }
            guard status == SQLITE_OK else { throw Self.databaseError(status) }
        }
    }

    private static func databaseError(_ code: Int32) -> IPTVError {
        // SQLite messages can contain provider-supplied values; retain only the numeric code.
        PlozzLog.networking.error("IPTV catalogue SQLite failure code=\(code)")
        HandoffDiagnostics.emit("IPTV catalogue SQLite failure code=\(code)")
        return .database(code)
    }
}

public enum IPTVError: Error, LocalizedError, Sendable, Equatable {
    case invalidAddress, authentication, expired, unsupported, malformed, storage, oversizedRecord, empty, fileUnavailable
    case database(Int32)
    case httpStatus(Int)

    public var setupFailure: IPTVSetupDiagnostic.Failure {
        switch self {
        case .invalidAddress: .init(.invalidInput)
        case .authentication: .init(.authentication)
        case .expired: .init(.expired)
        case .unsupported: .init(.unsupported)
        case .malformed: .init(.malformed)
        case .storage: .init(.storage)
        case .database(let code): .init(.storage, sqliteCode: Int(code))
        case .httpStatus: .init(.invalidResponse)
        case .oversizedRecord: .init(.tooLarge)
        case .empty: .init(.empty)
        case .fileUnavailable: .init(.fileUnavailable)
        }
    }

    public var errorDescription: String? {
        String(localized: userDescription) // l10n:content - LocalizedError requires resolved text; recomputed on each access.
    }

    public var userDescription: LocalizedStringResource {
        switch self {
        case .invalidAddress: "Enter a complete HTTP or HTTPS provider address."
        case .authentication: "The IPTV provider rejected these credentials."
        case .expired: "This IPTV subscription is expired or disabled. Contact your provider."
        case .unsupported: "This provider did not return a supported IPTV catalogue."
        case .malformed: "The IPTV provider returned an incomplete or invalid catalogue."
        case .database(let code) where code & 0xff == SQLITE_FULL:
            "The IPTV catalogue could not be saved. Check the available device storage."
        case .storage, .database: "The IPTV catalogue could not be saved. Please try again."
        case .httpStatus(451):
            "Your IPTV provider has blocked access to this playlist. Check that your trial or subscription is still active, or contact your provider."
        case .httpStatus:
            "Your IPTV provider couldn't send the playlist. Try again later or contact your provider."
        case .oversizedRecord: "An individual IPTV catalogue entry exceeds the supported size."
        case .empty: "This IPTV source contains no supported channels, movies, or series."
        case .fileUnavailable: "Import this playlist file on this device to use its channels and library."
        }
    }
}
