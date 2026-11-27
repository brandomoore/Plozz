#if os(iOS)
import MediaDownloads
import Observation

@MainActor
@Observable
final class PlozziOSDownloadRecordIndex {
    @MainActor
    @Observable
    final class Entry {
        var record: DownloadedMediaRecord

        init(_ record: DownloadedMediaRecord) {
            self.record = record
        }
    }

    private var entries: [String: Entry] = [:]
    private(set) var library = PlozziOSDownloadLibrary(movies: [], shows: [])
    @ObservationIgnored private var keysBySourceID: [String: [String]] = [:]

    // Lookup routing observes membership; only the selected entry observes progress.
    var isEmpty: Bool { entries.isEmpty }

    func fallbackKeys(forSourceID id: String) -> [String] {
        _ = entries
        return keysBySourceID[id] ?? []
    }

    func record(forKey key: String) -> DownloadedMediaRecord? {
        entries[key]?.record
    }

    func update(_ records: [DownloadedMediaRecord]) {
        library = PlozziOSDownloadLibrary.make(from: records)
        var next = entries
        let keys = Set(records.map(\.identityKey))
        var membershipChanged = keys != Set(entries.keys)
        for record in records {
            if let entry = next[record.identityKey] {
                let previous = entry.record
                membershipChanged = membershipChanged
                    || previous.identity != record.identity
                    || previous.versionID != record.versionID
                    || previous.snapshot.sourceItemID != record.snapshot.sourceItemID
                    || previous.snapshot.sourceAccountID != record.snapshot.sourceAccountID
                    || previous.snapshot.kind != record.snapshot.kind
                entry.record = record
            } else {
                next[record.identityKey] = Entry(record)
            }
        }
        if membershipChanged {
            var routes: [String: [String]] = [:]
            for record in records {
                if let id = record.snapshot.sourceItemID {
                    routes[id, default: []].append(record.identityKey)
                }
                // An old account-scoped key can survive missing or repaired snapshot metadata.
                if case let .external(source, id) = record.identity,
                   source.hasPrefix(DownloadMediaIdentity.accountSourcePrefix), id != record.snapshot.sourceItemID {
                    routes[id, default: []].append(record.identityKey)
                }
            }
            keysBySourceID = routes
            entries = next.filter { keys.contains($0.key) }
        }
    }
}
#endif
