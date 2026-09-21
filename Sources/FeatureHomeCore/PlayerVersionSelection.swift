import CoreModels

public enum PlayerVersionSelection {
    public static func item(opened: MediaItem, resolved: MediaItem?) -> MediaItem {
        guard let resolved, resolved.id == opened.id, resolved.kind == opened.kind,
              resolved.sourceAccountID == nil || resolved.sourceAccountID == opened.sourceAccountID else { return opened }
        var item = opened
        if !resolved.versions.isEmpty { item.versions = resolved.versions }
        return item
    }

    public static func versions(for item: MediaItem) -> [MediaVersion] {
        DetailPlaybackSelection.versions(
            for: item, sources: item.sources, activeAccountID: item.sourceAccountID
        ).filter { $0.sourceAccountID == nil || $0.sourceAccountID == item.sourceAccountID }
    }

    public static func isSelected(_ version: MediaVersion, item: MediaItem, mediaSourceID: String?) -> Bool {
        (version.sourceItemID == nil || version.sourceItemID == item.id)
            && (version.sourceAccountID == nil || version.sourceAccountID == item.sourceAccountID)
            && (version.playbackMediaSourceID == mediaSourceID
                || (mediaSourceID == nil && version.isDefault))
    }

    public static func selecting(_ id: String, in item: MediaItem) -> MediaItem? {
        guard versions(for: item).contains(where: { $0.id == id }) else { return nil }
        return DetailPlaybackSelection.playItem(
            for: item, sources: item.sources, activeAccountID: item.sourceAccountID,
            versionID: id, explicit: true
        )
    }
}
