import Foundation
import CoreModels
import MediaTransportCore

struct ShareBluRayFolder: Sendable {
    let directory: String
    let index: RemoteFileEntry
    let entries: [RemoteFileEntry]
    var indexPath: String { directory.isEmpty ? index.name : "\(directory)/\(index.name)" }

    static func discover(
        in directory: String,
        entries: [RemoteFileEntry],
        list: @Sendable (String) async throws -> [RemoteFileEntry]
    ) async throws -> Self? {
        if directory.isEmpty || (directory as NSString).lastPathComponent.lowercased() == "bdmv" {
            if let disc = recognized(directory: directory, entries: entries) { return disc }
        }
        let folders = entries.filter { $0.kind == .directory && $0.name.lowercased() == "bdmv" }
        guard folders.count == 1, let folder = folders.first else { return nil }
        let path = directory.isEmpty ? folder.name : "\(directory)/\(folder.name)"
        return recognized(directory: path, entries: try await list(path))
    }

    private static func recognized(directory: String, entries: [RemoteFileEntry]) -> Self? {
        let indexes = entries.filter { $0.kind == .file && $0.name.lowercased() == "index.bdmv" }
        guard indexes.count == 1, let index = indexes.first,
              ["playlist", "stream"].allSatisfy({ name in
                  entries.filter { $0.kind == .directory && $0.name.lowercased() == name }.count == 1
              }) else { return nil }
        return Self(directory: directory, index: index, entries: entries)
    }

    static func isIndex(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        return components.last?.lowercased() == "index.bdmv"
            && (components.count == 1 || components.dropLast().last?.lowercased() == "bdmv")
    }

    /// Keep the real index path as identity, but classify using the movie folder.
    static func classificationPath(_ path: String) -> String {
        guard isIndex(path) else { return path }
        let root = contentDirectory(path)
        let title = root.isEmpty ? "Disc" : (root as NSString).lastPathComponent
        return root.isEmpty ? "\(title).iso" : "\(root)/\(title).iso"
    }

    static func contentDirectory(_ index: String) -> String {
        let parent = (index as NSString).deletingLastPathComponent
        return (parent as NSString).lastPathComponent.lowercased() == "bdmv"
            ? (parent as NSString).deletingLastPathComponent : parent
    }

    static func metadataDirectory(_ path: String) -> String {
        isIndex(path) ? contentDirectory(path) : (path as NSString).deletingLastPathComponent
    }

    func excludesDirectory(_ path: String) -> Bool {
        path == directory || (directory.isEmpty ? !path.contains("/") : path.hasPrefix(directory + "/"))
    }
}
