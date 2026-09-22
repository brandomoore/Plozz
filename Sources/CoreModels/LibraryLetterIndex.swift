import Foundation

/// A jump target in an alphabetically-sorted library: a rail letter and the
/// 0-based index of the first item that sorts under it, expressed in the grid's
/// *current* sort direction.
///
/// Powers the trailing "A–Z" fast-scroll rail on the library browse grid: the
/// grid is a sparse, full-size wall sized to the whole library, so jumping to a
/// letter is simply scrolling the grid to that letter's `startIndex` (which then
/// lazily loads the page that owns it).
public struct LibraryLetterIndexEntry: Equatable, Sendable {
    /// The rail bucket this entry represents: `"#"` (digits/symbols that sort
    /// before "A") or a single uppercase Latin letter `"A"`…`"Z"`.
    public let letter: String
    /// 0-based index of the first item under `letter`, in the grid's current
    /// sort order. Feeds `ScrollViewReader.scrollTo(_:)`.
    /// Nil for providers that resolve an exact position on demand (for example,
    /// a deduplicated cross-server list). Never substitute a guessed offset.
    public let startIndex: Int?

    public init(letter: String, startIndex: Int? = nil) {
        self.letter = letter
        self.startIndex = startIndex
    }
}

/// Builds a library's alphabet fast-scroll index from per-letter counts. Kept a
/// pure, provider-agnostic value type so both backends (Jellyfin's per-letter
/// `NameLessThan` counts, Plex's `firstCharacter` facet) assemble the same
/// ascending `(letter, count)` buckets and share this offset math — and so the
/// tricky ascending-vs-descending index arithmetic is unit-testable without a
/// network.
public enum LibraryLetterIndex {
    public static func deferredEntries(direction: SortDirection) -> [LibraryLetterIndexEntry] {
        let letters = direction == .ascending ? railLetters : Array(railLetters.reversed())
        return letters.map { LibraryLetterIndexEntry(letter: $0) }
    }

    /// Walks only as far as the requested target, reusing the provider's paging
    /// cache. Cancellation is checked between pages and before returning a target.
    public static func findPosition(
        pageSize: Int = 200,
        fetch: @Sendable (Int, Int) async throws -> MediaPage,
        matches: @Sendable (MediaItem) async throws -> Bool
    ) async throws -> Int? {
        let limit = max(1, min(pageSize, 200))
        var offset = 0
        var previousLastIDs = Set<String>()
        while true {
            try Task.checkCancellation()
            let page = try await fetch(offset, limit)
            try Task.checkCancellation()
            guard page.startIndex == offset, page.totalCount >= 0,
                  page.items.count <= limit else { throw AppError.invalidResponse }
            for (index, item) in page.items.enumerated() {
                try Task.checkCancellation()
                if try await matches(item) {
                    try Task.checkCancellation()
                    return offset + index
                }
            }
            if page.items.isEmpty {
                guard offset >= page.totalCount else { throw AppError.serverUnreachable }
                return nil
            }
            let last = page.items[page.items.count - 1]
            let key = "\(last.sourceAccountID ?? ""):\(last.id)"
            guard previousLastIDs.insert(key).inserted else { throw AppError.invalidResponse }
            let (next, overflow) = offset.addingReportingOverflow(page.items.count)
            guard !overflow else { throw AppError.invalidResponse }
            offset = next
            if page.totalCount > 0, offset >= page.totalCount { return nil }
        }
    }

    /// The canonical rail buckets, in ascending sort order: the `"#"` catch-all
    /// (digits/symbols) first, then `"A"`…`"Z"`. Providers normalise their raw
    /// first-character data onto these buckets.
    public static let railLetters: [String] = {
        let letters = (UnicodeScalar("A").value...UnicodeScalar("Z").value)
            .compactMap { UnicodeScalar($0).map(String.init) }
        return ["#"] + letters
    }()

    /// Maps a raw first-character/sort-name prefix onto a rail bucket: an
    /// A–Z letter (case-insensitive) maps to its uppercase self; anything else
    /// (digits, symbols, non-Latin) folds into the `"#"` bucket.
    public static func bucket(forPrefix prefix: String) -> String {
        guard let first = prefix.uppercased().first else { return "#" }
        return (first >= "A" && first <= "Z") ? String(first) : "#"
    }

    /// Assembles ordered `LibraryLetterIndexEntry`s from ascending-sorted
    /// `(letter, count)` buckets.
    ///
    /// - Parameters:
    ///   - bucketCountsAscending: each rail bucket paired with how many items
    ///     sort into it, ordered by the *ascending* sort (so `"#"` first, then
    ///     `A`…`Z`). Buckets may be omitted or given `0`; both are treated as
    ///     empty and dropped from the result.
    ///   - direction: the grid's active sort direction. Ascending yields
    ///     `#…Z` with cumulative start offsets; descending yields the mirror
    ///     order (`Z…#`) with the start index of each letter's first item in the
    ///     reversed list.
    /// - Returns: entries ordered by `startIndex` ascending (i.e. top-to-bottom
    ///   as they appear in the grid for `direction`), with empty buckets removed.
    public static func entries(
        bucketCountsAscending: [(letter: String, count: Int)],
        direction: SortDirection
    ) -> [LibraryLetterIndexEntry] {
        let ordered = direction == .ascending ? bucketCountsAscending : Array(bucketCountsAscending.reversed())
        var entries: [LibraryLetterIndexEntry] = []
        var seen = Set<String>()
        var cumulativeBefore = 0
        for (letter, rawCount) in ordered {
            let count = max(0, rawCount)
            guard count > 0 else { continue }
            if seen.insert(letter).inserted {
                entries.append(LibraryLetterIndexEntry(letter: letter, startIndex: cumulativeBefore))
            }
            cumulativeBefore += count
        }
        return entries
    }

    /// Assembles the index from *cumulative* "count of items that sort before
    /// this letter" offsets — the shape Jellyfin's `NameLessThan` count queries
    /// naturally produce.
    ///
    /// - Parameters:
    ///   - offsetsByLetter: for each of `A`…`Z`, the number of items whose sort
    ///     name is strictly less than that letter (i.e. `count(SortName < L)`).
    ///     `offsetsByLetter["A"]` therefore equals the size of the `"#"` bucket.
    ///   - totalCount: the library's total item count (the upper bound for the
    ///     final, `Z`-and-beyond bucket).
    ///   - lastLetterCount: when available, separates Z from non-Latin titles
    ///     sorting after it. The first catch-all range in the active direction wins.
    ///   - direction: the grid's active sort direction.
    public static func entries(
        lessThanOffsetsByLetter offsetsByLetter: [String: Int],
        totalCount: Int,
        lastLetterCount: Int? = nil,
        direction: SortDirection
    ) -> [LibraryLetterIndexEntry] {
        guard totalCount > 0 else { return [] }
        let letters = railLetters.filter { $0 != "#" }   // "A"…"Z", ascending.

        // Cumulative offset at the start of each bucket, clamped monotonic and
        // into range so malformed server data can't produce negative counts.
        func offset(before letter: String) -> Int {
            min(max(0, offsetsByLetter[letter] ?? 0), totalCount)
        }

        var buckets: [(letter: String, count: Int)] = []
        // "#" bucket: everything before "A".
        buckets.append((letter: "#", count: offset(before: "A")))
        for (i, letter) in letters.enumerated() {
            let start = offset(before: letter)
            let nextStart: Int = (i + 1 < letters.count)
                ? max(start, offset(before: letters[i + 1]))
                : lastLetterCount.map { min(totalCount, start + max(0, $0)) } ?? totalCount
            buckets.append((letter: letter, count: nextStart - start))
        }
        if let lastLetterCount {
            let end = min(totalCount, offset(before: "Z") + max(0, lastLetterCount))
            buckets.append((letter: "#", count: totalCount - end))
        }
        return entries(bucketCountsAscending: buckets, direction: direction)
    }
}
