import Foundation

/// Local ordering of already-fetched items by the same ``SortDescriptor`` a
/// provider was asked to sort by.
///
/// Needed by the **combined** library browse. A grid stitched from many servers'
/// pages can only claim to be sorted if the pages are merged on the sort key —
/// round-robin interleaving produces "Alien, Amélie, Arrival, Alien 3, Anatomy…",
/// which reads as broken under a menu that says "Name A–Z".
///
/// Original server inputs are carried separately from enriched display metadata.
/// Random has no merge order. Other fields can be compared locally, but callers
/// still need matching source ordering; an inventory provides exact global
/// ordering when native source comparators or null placement differ.
public enum MediaItemSortOrder {
    public static func alphabetBucket(for item: MediaItem) -> String {
        LibraryLetterIndex.bucket(forPrefix: sortName(item))
    }

    /// Whether items can be ordered locally for `field` — i.e. whether a combined
    /// browse can merge on it rather than interleave.
    public static func supportsLocalOrdering(_ field: SortField) -> Bool {
        switch field {
        case .random: return false
        default: return true
        }
    }

    /// Whether `lhs` should be placed before `rhs` under `sort`.
    ///
    /// Ties break on the sort name so the order is total and therefore stable:
    /// without a tiebreak, two items with the same year would swap depending on
    /// which page they arrived in.
    public static func isOrderedBefore(
        _ lhs: MediaItem,
        _ rhs: MediaItem,
        sort: SortDescriptor,
        identityTieBreak: Bool = true
    ) -> Bool {
        let ascending = sort.direction == .ascending
        let order: Bool?
        switch sort.field {
        case .name, .random:
            order = compareNames(lhs, rhs, ascending: ascending)
        case .dateAdded:
            order = compare(lhs.librarySortValues?.dateAdded, rhs.librarySortValues?.dateAdded, ascending: ascending)
        case .communityRating:
            order = compare(lhs.librarySortValues?.audienceRating, rhs.librarySortValues?.audienceRating, ascending: ascending)
        case .year:
            order = compare(lhs.productionYear, rhs.productionYear, ascending: ascending)
        case .criticRating:
            order = compare(lhs.librarySortValues?.criticRating, rhs.librarySortValues?.criticRating, ascending: ascending)
        case .userRating:
            order = compare(lhs.librarySortValues?.userRating, rhs.librarySortValues?.userRating, ascending: ascending)
        case .contentRating:
            order = compare(lhs.officialRating, rhs.officialRating, ascending: ascending)
        case .progress:
            order = compare(lhs.playedPercentage ?? 0, rhs.playedPercentage ?? 0, ascending: ascending)
        case .plays:
            order = compare(lhs.librarySortValues?.playCount, rhs.librarySortValues?.playCount, ascending: ascending)
        case .lastPlayed:
            order = compare(lhs.lastPlayedAt, rhs.lastPlayedAt, ascending: ascending)
        case .releaseDate:
            if let result = compare(lhs.releaseDate, rhs.releaseDate, ascending: ascending) {
                return result
            }
            if let result = compare(lhs.productionYear, rhs.productionYear, ascending: ascending) {
                return result
            }
            order = compareNames(lhs, rhs, ascending: true)
        case .runtime:
            if let result = compare(lhs.runtime, rhs.runtime, ascending: ascending) {
                return result
            }
            order = compareNames(lhs, rhs, ascending: true)
        }
        if let order { return order }
        if let names = compareNames(lhs, rhs, ascending: true) { return names }
        guard identityTieBreak else { return false }
        if lhs.sourceAccountID != rhs.sourceAccountID {
            return (lhs.sourceAccountID ?? "") < (rhs.sourceAccountID ?? "")
        }
        return lhs.id < rhs.id
    }

    /// The name a server would sort by: lower-cased, diacritic-folded, with a
    /// leading English article dropped ("The Matrix" files under M).
    public static func sortName(_ item: MediaItem) -> String {
        if let name = item.librarySortValues?.sortName, !name.isEmpty {
            return name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        let folded = item.title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for article in ["the ", "a ", "an "] where folded.hasPrefix(article) {
            return String(folded.dropFirst(article.count))
        }
        return folded
    }

    private static func compareNames(
        _ lhs: MediaItem,
        _ rhs: MediaItem,
        ascending: Bool
    ) -> Bool? {
        let result = sortName(lhs).compare(sortName(rhs), options: [.numeric])
        guard result != .orderedSame else { return nil }
        return ascending ? result == .orderedAscending : result == .orderedDescending
    }

    /// Orders two optionals, always sinking `nil` to the end regardless of
    /// direction — an item with no year is "unknown", not "oldest", and floating it
    /// to the top of a descending sort would bury the newest releases.
    /// Returns `nil` when the two are equal, so the caller can apply a tiebreak.
    private static func compare<Value: Comparable>(
        _ lhs: Value?,
        _ rhs: Value?,
        ascending: Bool
    ) -> Bool? {
        switch (lhs, rhs) {
        case let (left?, right?):
            guard left != right else { return nil }
            return ascending ? left < right : left > right
        case (nil, .some): return false
        case (.some, nil): return true
        case (nil, nil): return nil
        }
    }
}
