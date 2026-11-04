import CoreModels

/// Chooses the durable registry key used for an offline copy.
public enum DownloadMediaIdentity {
    public static let accountSourcePrefix = "plozz-account:"

    public static func requestIdentity(
        for item: MediaItem,
        existingRecords: [DownloadedMediaRecord]
    ) -> MediaIdentity? {
        guard item.kind == .episode, item.explicitSourceSelection else {
            return primary(for: item)
        }
        // Reuse a legacy key only when its snapshot proves it is this exact file.
        if let existing = selectedRecord(for: item, in: existingRecords) {
            return existing.identity
        }
        guard let accountID = item.sourceAccountID, !accountID.isEmpty else { return nil }
        return .external(source: "\(accountSourcePrefix)\(accountID)", value: item.id)
    }

    public static func selectedRecord(
        for item: MediaItem,
        in records: [DownloadedMediaRecord]
    ) -> DownloadedMediaRecord? {
        guard let accountID = item.sourceAccountID, !accountID.isEmpty else { return nil }
        return records.filter {
            $0.snapshot.kind == item.kind
                && $0.snapshot.sourceAccountID == accountID
                && $0.snapshot.sourceItemID == item.id
                && $0.versionID == item.selectedVersionID
        }.sorted { $0.identityKey < $1.identityKey }.first
    }

    public static func primary(for item: MediaItem) -> MediaIdentity? {
        if let identity = MediaItemIdentity.identities(for: item).first {
            return identity
        }
        guard let accountID = item.sourceAccountID, !accountID.isEmpty else {
            return nil
        }
        return .external(
            source: "\(accountSourcePrefix)\(accountID)",
            value: item.id
        )
    }
}
