import Foundation

struct CatalogArtworkDirectoryScope {
    static let predicate = "(metadata_root=? OR (rel_path>=? AND rel_path<?))"
    let directory: String

    // SQLite's default binary collation makes this the exact directory prefix,
    // without LIKE wildcard/case rules or a per-row substr() scan.
    var bindings: [String] { [directory, directory + "/", directory + "0"] }
}
