import CoreModels
import Foundation

enum SimklHistoryReadError: Error { case maxItems }

/// On-demand comparison cache. It never writes to Simkl or to a media server.
@MainActor
final class SimklHistoryReader {
    private typealias Entries = [Int: [TrackerHistoryObservation]]

    private struct Cache {
        let connectionID: String
        let activity: SimklHistoryActivity
        let entries: [SimklHistoryKind: Entries]
        let playback: [TrackerHistoryObservation]
        let snapshot: TrackerHistorySnapshot
    }

    private let client: SimklClient
    private let includesListStates: Bool
    private var cache: Cache?
    private var reading = false

    init(client: SimklClient, includesListStates: Bool = false) {
        self.client = client
        self.includesListStates = includesListStates
    }

    func snapshot(
        accessToken: String, connectionID: String,
        validateScope: @MainActor @escaping () throws -> Void
    ) async throws -> TrackerHistorySnapshot {
        try Task.checkCancellation()
        try validateScope()
        guard !reading else { throw TrackerHistoryError.stalePreview }
        reading = true
        defer { reading = false }
        if cache?.connectionID != connectionID { cache = nil }
        let before = try await activity(accessToken: accessToken, validateScope: validateScope)
        if let cache, cache.activity == before { return cache.snapshot }
        var entries = cache?.entries ?? [:]
        var playback = cache?.playback ?? []
        for kind in SimklHistoryKind.allCases {
            let previous = cache?.activity[kind]
            if previous == nil || kind.listFields.contains(where: { previous?[$0] != before[kind][$0] }) {
                let delta = try await readEntries(
                    kind: kind, since: cache?.activity.all, idsOnly: false,
                    accessToken: accessToken, validateScope: validateScope
                )
                for (id, entry) in delta { entries[kind, default: [:]][id] = entry }
            }
            if let previous, previous["removed_from_list"] != before[kind]["removed_from_list"] {
                let remaining = try await readEntries(
                    kind: kind, since: nil, idsOnly: true,
                    accessToken: accessToken, validateScope: validateScope
                )
                // New IDs absent from the delta are evidence of a missed update, not empty history.
                guard Set(remaining.keys).isSubset(of: Set(entries[kind, default: [:]].keys)) else {
                    throw TrackerHistoryError.incompleteSnapshot
                }
                entries[kind] = entries[kind, default: [:]].filter { remaining[$0.key] != nil }
            }
        }
        let refreshPlayback = cache == nil || SimklHistoryKind.allCases.contains { kind in
            (kind.listFields + ["playback", "removed_from_list"]).contains {
                cache?.activity[kind][$0] != before[kind][$0]
            }
        }
        if refreshPlayback {
            // Reconcile the current set: a delta cannot reveal removed/resumed playbacks.
            let data = try await read(
                path: "/sync/playback", query: [.init(name: "limit", value: "10000")],
                accessToken: accessToken, validateScope: validateScope
            )
            let records = try JSONDecoder().decode([SimklHistoryPlayback].self, from: data)
            guard records.count < 10_000, Set(records.map(\.id)).count == records.count else {
                throw TrackerHistoryError.incompleteSnapshot
            }
            playback = try records.map { try $0.observation() }
        }
        let after = try await activity(accessToken: accessToken, validateScope: validateScope)
        guard before == after else { throw TrackerHistoryError.incompleteSnapshot }
        var observations: [TrackerHistoryObservation] = []
        for kind in SimklHistoryKind.allCases {
            for (_, entry) in entries[kind, default: [:]].sorted(by: { $0.key < $1.key }) {
                observations += entry
            }
        }
        observations += playback
        let snapshot = try TrackerHistorySnapshot(
            trackerID: "simkl", connectionID: connectionID, observations: observations, completeness: .completeResponse
        )
        try Task.checkCancellation()
        try validateScope()
        cache = .init(connectionID: connectionID, activity: before, entries: entries, playback: playback, snapshot: snapshot)
        return snapshot
    }

    private func activity(
        accessToken: String, validateScope: @MainActor @escaping () throws -> Void
    ) async throws -> SimklHistoryActivity {
        let data = try await read(path: "/sync/activities", accessToken: accessToken, validateScope: validateScope)
        let result = try JSONDecoder().decode(SimklHistoryActivity.self, from: data)
        try result.validate()
        return result
    }

    private func readEntries(
        kind: SimklHistoryKind, since: String?, idsOnly: Bool,
        accessToken: String, validateScope: @MainActor @escaping () throws -> Void
    ) async throws -> Entries {
        var query: [URLQueryItem] = [.init(name: "extended", value: idsOnly ? "simkl_ids_only" : "full")]
        if let since { query.append(.init(name: "date_from", value: since)) }
        if !idsOnly {
            query += [
                .init(name: "include_all_episodes", value: "original"),
                .init(name: "episode_watched_at", value: "yes"),
                .init(name: "episode_tvdb_id", value: "yes")
            ]
        }
        let path = "/sync/all-items/\(kind.rawValue)"
        func fetch(_ path: String) async throws -> [SimklHistoryEntry] {
            let data = try await read(path: path, query: query, accessToken: accessToken, validateScope: validateScope)
            let response = try JSONDecoder().decode([String: [SimklHistoryEntry]].self, from: data)
            guard response.keys.allSatisfy({ $0 == kind.rawValue }) else { throw TrackerHistoryError.incompleteSnapshot }
            return response[kind.rawValue] ?? []
        }
        var records: [SimklHistoryEntry]
        do {
            records = try await fetch(path)
        } catch SimklHistoryReadError.maxItems {
            records = []
            for status in kind.listFields {
                do { records += try await fetch("\(path)/\(status)") }
                catch SimklHistoryReadError.maxItems { throw TrackerHistoryError.incompleteSnapshot }
            }
        }
        var result: Entries = [:]
        for record in records {
            guard let id = try record.ids(for: kind).simkl, result[id] == nil else {
                throw TrackerHistoryError.incompleteSnapshot
            }
            result[id] = idsOnly ? [] : try record.observations(kind: kind, includesListStates: includesListStates)
        }
        return result
    }

    private func read(
        path: String, query: [URLQueryItem] = [], accessToken: String,
        validateScope: @MainActor @escaping () throws -> Void
    ) async throws -> Data {
        try Task.checkCancellation()
        try validateScope()
        let data = try await client.historyResponse(path: path, query: query, accessToken: accessToken) {
            try await validateScope()
        }
        try Task.checkCancellation()
        try validateScope()
        return data
    }
}
