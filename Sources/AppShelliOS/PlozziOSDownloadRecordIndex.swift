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
    @ObservationIgnored private var snapshot: [DownloadedMediaRecord] = []

    // Lookup routing observes membership; only the selected entry observes progress.
    var records: [DownloadedMediaRecord] {
        _ = entries
        return snapshot
    }

    func record(forKey key: String) -> DownloadedMediaRecord? {
        entries[key]?.record
    }

    func update(_ records: [DownloadedMediaRecord]) {
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
                entry.record = record
            } else {
                next[record.identityKey] = Entry(record)
            }
        }
        snapshot = records
        if membershipChanged {
            entries = next.filter { keys.contains($0.key) }
        }
    }
}
#endif
