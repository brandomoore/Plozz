import CoreModels

public enum HeroDiscoveryStatus {
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
            return item
        }
    }
}
