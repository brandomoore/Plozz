import CoreModels

extension HomeViewModel.Content {
    /// The content without the episodes of dropped shows on the rows a drop
    /// clears: Continue Watching and Next Up (Upcoming is filtered by `UpcomingFeedModel`), including a server's own
    /// and a library's own versions of them. Discovery rows are left alone —
    /// dropping a show is about what Home suggests watching next, not about
    /// hiding that the show exists.
    @MainActor
    func excludingDroppedShows(_ dropped: DroppedShowsModel) -> Self {
        guard !dropped.isEmpty else { return self }
        var content = self
        content.continueWatching = dropped.excludingDropped(continueWatching)
        content.librarySections = librarySections.map { group in
            var group = group
            group.sections = group.sections.map { section in
                guard section.id == "continueWatching" || section.id == "nextUp" else { return section }
                var section = section
                section.items = dropped.excludingDropped(section.items)
                return section
            }
            return group
        }
        content.serverRows = serverRows.map { row in
            guard row.definition.section.kind == .continueWatching
                || row.definition.section.kind == .nextUp else { return row }
            var row = row
            row.items = dropped.excludingDropped(row.items)
            return row
        }
        return content
    }
}
