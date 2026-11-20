import Foundation

/// Which child a detail page should load first.
///
/// Every detail page is the same shape: a subject, optionally a list of children,
/// and optionally content *inside* the chosen child. Opening a series therefore
/// costs three server round-trips — the item, its seasons, then the chosen season's
/// episodes — and the third does not have to wait for the view to publish a
/// selection. Deciding "which child first" is a page-level rule, not a series-level
/// one, so it lives here and every container kind calls it:
///
/// | page kind | first child to load |
/// |---|---|
/// | series, folder, collection | resume season when present, else first season |
/// | season | none — its children already *are* the rail content |
/// | movie, episode, video | none — leaf pages have no children |
public enum DetailOpeningSelection {
    /// The season whose episodes a container page will show first.
    ///
    /// `nil` when the page has no season level. A resume season that the server no
    /// longer lists is ignored rather than trusted: the page must open on something
    /// that exists, and prefetching a missing id would cost a request that cannot
    /// populate the rail.
    public static func openingSeasonID(
        children: [MediaItem],
        resumeSeasonID: String?
    ) -> String? {
        let seasonIDs = children.filter { $0.kind == .season }.map(\.id)
        guard !seasonIDs.isEmpty else { return nil }
        if let resumeSeasonID, seasonIDs.contains(resumeSeasonID) {
            return resumeSeasonID
        }
        return seasonIDs.first
    }
}
