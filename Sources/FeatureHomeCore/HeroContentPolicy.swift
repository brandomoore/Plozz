import CoreModels
import Foundation

/// Hero curation must not consume stale rows while their live replacements load.
public enum HomeHeroLaunchPolicy {
    public static func content(
        _ content: HomeViewModel.Content,
        awaitingLiveContinueWatching: Bool,
        loadingRows: Set<HomeRowKind> = []
    ) -> HomeViewModel.Content {
        var live = content
        if awaitingLiveContinueWatching || loadingRows.contains(.continueWatching) {
            live.continueWatching = []
        }
        if loadingRows.contains(.recentlyAdded) { live.latest = [] }
        if loadingRows.contains(.watchlist) { live.watchlist = [] }
        if loadingRows.contains(.libraries) { live.libraries = [] }
        return live
    }
}

/// Canonical text/facts/credits policy shared by Home and detail heroes.
public enum HeroContentPolicy {
    /// Browsing a show's children changes playback, not the subject of its page.
    public static func detailSubject(focused: MediaItem, root: MediaItem) -> MediaItem {
        root.kind == .series ? root : focused
    }

    public static func homeDescription(
        for item: HeroPresentation
    ) -> String? {
        item.tagline ?? item.overview
    }

    public static func detailDescription(
        focused: HeroPresentation,
        root: HeroPresentation
    ) -> String? {
        focused.overview ?? root.overview ?? root.tagline
    }

    public static func ratingBadge(
        focused: HeroPresentation,
        root: HeroPresentation
    ) -> MediaBadge? {
        focused.ratingBadge ?? root.ratingBadge
    }

    public static func genres(
        focused: HeroPresentation,
        root: HeroPresentation
    ) -> [String] {
        GenreDisplayFormatter.displayNames(
            for: focused.genres.isEmpty ? root.genres : focused.genres
        )
    }

    public static func ratings(
        focused: HeroPresentation,
        root: HeroPresentation
    ) -> [ExternalRating] {
        focused.ratings.isEmpty ? root.ratings : focused.ratings
    }

    /// Common Sense guidance covers the show, not an individual focused episode.
    public static func familyGuidanceAge(
        focused: HeroPresentation,
        root: HeroPresentation
    ) -> Double? {
        if root.kind == .series { return root.familyGuidanceAge }
        return focused.familyGuidanceAge ?? root.familyGuidanceAge
    }

    /// The hero is a preview; the complete genre list remains in the title's details.
    public static func compactDetailGenres(
        focused: HeroPresentation,
        root: HeroPresentation
    ) -> [String] {
        Array(genres(focused: focused, root: root).prefix(2))
    }

    public static func detailFacts(
        focused: HeroPresentation
    ) -> [String] {
        let genres = Set(
            GenreDisplayFormatter.displayNames(for: focused.genres)
        )
        return focused.metadataComponents.filter { !genres.contains($0) }
    }

    public static func technicalBadges(
        focused: HeroPresentation,
        root: HeroPresentation,
        override: [MediaBadge]? = nil
    ) -> [MediaBadge] {
        if let override, !override.isEmpty {
            return override
        }
        return focused.technicalBadges.isEmpty
            ? root.technicalBadges
            : focused.technicalBadges
    }
}
