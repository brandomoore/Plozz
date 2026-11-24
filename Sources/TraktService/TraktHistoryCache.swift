import CoreModels
import CryptoKit
import Foundation

enum TraktHistoryGroup: String, CaseIterable, Codable, Sendable {
    case movieWatches, episodeWatches, moviePauses, episodePauses

    var playback: Bool { self == .moviePauses || self == .episodePauses }
    var movies: Bool { self == .movieWatches || self == .moviePauses }
    var type: String { movies ? "movie" : "episode" }

    func stamp(_ activity: TraktHistoryActivity) -> String {
        let media = movies ? activity.movies : activity.episodes
        return playback ? media.pausedAt : media.watchedAt
    }
}

/// Independent files keep a pause from rewriting years of watches. Never persist
/// authorization, username, or a closure captured by a previous sync.
actor TraktHistoryCache {
    struct Entry: Sendable {
        let stamp: String
        let records: [TraktHistoryRecord]
        let observations: [TrackerHistoryObservation]

        init(_ group: TraktHistoryGroup, stamp: String, records: [TraktHistoryRecord]) throws {
            guard records.count <= 100_000, records.allSatisfy({ $0.type == group.type }) else {
                throw TrackerHistoryError.invalidObservation
            }
            self.stamp = stamp
            self.records = records
            observations = try records.map { try $0.observation(playback: group.playback) }
        }
    }

    private struct FileEntry: Codable {
        let scope: String
        let group: TraktHistoryGroup
        let stamp: String
        let records: [TraktHistoryRecord]
    }

    private let directory: URL?
    private var memoryScope: String?
    private var memory: [TraktHistoryGroup: Entry] = [:]

    init(directory: URL? = nil) { self.directory = directory }

    static var appDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TraktHistory-v1", isDirectory: true)
    }

    func load(scope: String) -> [TraktHistoryGroup: Entry] {
        if memoryScope == scope { return memory }
        memoryScope = scope
        memory = [:]
        guard let directory else { return memory }
        for group in TraktHistoryGroup.allCases {
            let url = directory.appendingPathComponent(scope).appendingPathComponent(group.rawValue)
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count >= 32, data.count <= 64 * 1024 * 1024 else { throw TrackerHistoryError.incompleteSnapshot }
                let body = data.dropFirst(32)
                guard data.prefix(32).elementsEqual(SHA256.hash(data: body)) else { throw TrackerHistoryError.incompleteSnapshot }
                let file = try JSONDecoder().decode(FileEntry.self, from: body)
                guard file.scope == scope, file.group == group, TraktClient.parseTimestamp(file.stamp) != nil else {
                    throw TrackerHistoryError.incompleteSnapshot
                }
                memory[group] = try Entry(group, stamp: file.stamp, records: file.records)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                continue
            } catch {
                HandoffDiagnostics.emit("TRAKT_HISTORY cache-unusable")
            }
        }
        return memory
    }

    func save(_ entries: [TraktHistoryGroup: Entry], scope: String) {
        if memoryScope == scope { memory.merge(entries) { _, new in new } }
        guard let folder = directory?.appendingPathComponent(scope, isDirectory: true), !entries.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (group, entry) in entries {
                let body = try JSONEncoder().encode(FileEntry(scope: scope, group: group, stamp: entry.stamp, records: entry.records))
                var data = Data(SHA256.hash(data: body))
                data.append(body)
                try data.write(to: folder.appendingPathComponent(group.rawValue), options: [.atomic, .completeFileProtection])
            }
        } catch {
            HandoffDiagnostics.emit("TRAKT_HISTORY cache-not-persisted")
        }
    }

    func remove(scope: String) {
        if memoryScope == scope { memoryScope = nil; memory = [:] }
        guard let url = directory?.appendingPathComponent(scope, isDirectory: true) else { return }
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
        catch { HandoffDiagnostics.emit("TRAKT_HISTORY cache-removal-failed") }
    }
}
