import CoreModels

public enum HeroDiscoveryStatus {
    public static func clearingRequestStatus(in items: [MediaItem]) -> [MediaItem] {
        items.map { item in
            guard !item.locallyValidatedPlayableSource, item.availability != nil else { return item }
            var item = item
            item.availability = .unknown
            item.downloadProgress = nil
            item.hasRequestDownloadActivity = nil
            return item
        }
    }

    public static func retainingRequestStatus(
        in items: [MediaItem], from previous: [MediaItem], sameRequestContext: Bool
    ) -> [MediaItem] {
        guard sameRequestContext else { return clearingRequestStatus(in: items) }
        return items.map { item in
            guard let prior = previous.first(where: {
                HeroDiscoveryIdentityVerification.matches($0, item)
            }) else { return item }
            return retainingRequestStatus(in: item, from: prior)
        }
    }

    static func retainingRequestStatus(in item: MediaItem, from previous: MediaItem) -> MediaItem {
        guard !item.discoverySources.isEmpty, !item.locallyValidatedPlayableSource,
              !previous.locallyValidatedPlayableSource, item.availability == .unknown,
              HeroDiscoveryIdentityVerification.matches(previous, item) else { return item }
        var item = item
        item.availability = previous.availability ?? .unknown
        item.downloadProgress = previous.downloadProgress
        item.hasRequestDownloadActivity = previous.hasRequestDownloadActivity
        return item
    }

    /// Availability also appears on Watchlist titles; only discovery attribution
    /// can classify an item from a mixed carousel as a Featured fallback.
    public static func attributedFeaturedCandidates(
        _ items: [MediaItem], sources: [HeroDiscoverySource]
    ) -> [MediaItem] {
        items.filter { $0.discoverySources.contains(where: sources.contains) }
    }

    public static func cachedCandidates(
        _ items: [MediaItem],
        configuration: HeroConfigurationKey?,
        disabledLibraryKeys: Set<String>,
        matching requested: HeroConfigurationKey,
        currentDisabledKeys: Set<String>
    ) -> [MediaItem]? {
        guard configuration == requested, disabledLibraryKeys == currentDisabledKeys else { return nil }
        return items
    }

    public static func merging(_ updates: [MediaItem], into items: [MediaItem]) -> [MediaItem] {
        let byID = Dictionary(updates.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return items.map { item in
            guard let update = byID[item.id] else { return item }
            var item = item
            item.availability = update.availability
            item.downloadProgress = update.downloadProgress
            item.hasRequestDownloadActivity = update.hasRequestDownloadActivity
            return item
        }
    }
}
