import Foundation

/// Display-ready attribution for a single external metadata source: its name, the
/// notice a Settings screen must show to credit it, its homepage, and whether that
/// notice is *contractually required* (TheTVDB and TMDB both require visible
/// attribution when their APIs are used).
///
/// Shared by the metadata settings screens. ``PlozzAttributions`` also credits
/// these services alongside app dependencies and fonts; coverage tests keep the
/// lists aligned. `nil` from ``for(source:)`` means the source is internal (server /
/// local NFO / filename / embedded / generated) and needs no third-party credit.
public struct MetadataSourceAttribution: Sendable, Equatable, Identifiable {
    public var source: MetadataSource
    /// Human-facing display name (e.g. "TheTVDB").
    public var name: String
    /// The credit notice to render.
    public var notice: String
    /// The source's homepage, if any.
    public var url: URL?
    /// Whether the notice must be shown whenever the source is used (TheTVDB, TMDB).
    /// Required sources are always listed even if the user disabled them, because
    /// cached data they previously supplied may still be on screen.
    public var isRequired: Bool

    public var id: String { source.rawValue }

    public init(
        source: MetadataSource,
        name: String,
        notice: String,
        url: URL? = nil,
        isRequired: Bool = false
    ) {
        self.source = source
        self.name = name
        self.notice = notice
        self.url = url
        self.isRequired = isRequired
    }

    /// The attribution for `source`, or `nil` for internal (non-third-party) sources.
    public static func `for`(_ source: MetadataSource) -> MetadataSourceAttribution? {
        table[source]
    }

    /// Every external source's attribution, in a stable display order (required
    /// credits first). Used to render the Settings "Attribution" section.
    public static let all: [MetadataSourceAttribution] = orderedSources.compactMap { table[$0] }

    private static let orderedSources: [MetadataSource] = [
        .tvdb, .tmdb, .anilist, .mal, .tvmaze, .kitsu, .omdb,
        .wikidata, .wikipedia, .musicbrainz, .deezer,
    ]

    private static let table: [MetadataSource: MetadataSourceAttribution] = {
        var map: [MetadataSource: MetadataSourceAttribution] = [:]
        func add(_ attribution: MetadataSourceAttribution) { map[attribution.source] = attribution }
        add(.init(
            source: .tvdb,
            name: "TheTVDB",
            notice: "Metadata and artwork are provided by TheTVDB. Please consider adding missing information or subscribing at thetvdb.com. Plozz uses the TheTVDB API but is not endorsed or certified by TheTVDB.",
            url: URL(string: "https://thetvdb.com"),
            isRequired: true
        ))
        add(.init(
            source: .tmdb,
            name: "TMDB",
            notice: "This product uses the TMDB API but is not endorsed or certified by TMDB. Artwork and metadata are provided by TMDB (themoviedb.org).",
            url: URL(string: "https://www.themoviedb.org"),
            isRequired: true
        ))
        add(.init(
            source: .anilist,
            name: "AniList",
            notice: "Anime metadata and artwork are sourced from AniList (anilist.co), which does not endorse or affiliate with Plozz.",
            url: URL(string: "https://anilist.co")
        ))
        add(.init(
            source: .mal,
            name: "MyAnimeList",
            notice: "Anime identifiers are sourced from MyAnimeList (myanimelist.net), which does not endorse or affiliate with Plozz.",
            url: URL(string: "https://myanimelist.net")
        ))
        add(.init(
            source: .tvmaze,
            name: "TVmaze",
            notice: "TV series metadata is sourced from TVmaze (tvmaze.com) under CC BY-SA 4.0 (https://creativecommons.org/licenses/by-sa/4.0/). Plozz filters and combines this data. TVmaze does not endorse or affiliate with Plozz.",
            url: URL(string: "https://www.tvmaze.com")
        ))
        add(.init(
            source: .kitsu,
            name: "Kitsu",
            notice: "Anime artwork is sourced from Kitsu (kitsu.io), which does not endorse or affiliate with Plozz.",
            url: URL(string: "https://kitsu.io")
        ))
        add(.init(
            source: .omdb,
            name: "OMDb",
            notice: "Additional ratings are sourced from the OMDb API (omdbapi.com), which does not endorse or affiliate with Plozz.",
            url: URL(string: "https://www.omdbapi.com")
        ))
        add(.init(
            source: .wikidata,
            name: "Wikidata",
            notice: "Entity data and artwork lookups use Wikidata (wikidata.org) under CC0. Images linked from Wikidata retain their own licenses and copyright.",
            url: URL(string: "https://www.wikidata.org")
        ))
        add(.init(
            source: .wikipedia,
            name: "Wikipedia",
            notice: "Text and biography lookups use Wikipedia (wikipedia.org) under CC BY-SA; see each page's terms. Artwork from Wikipedia and Wikimedia Commons retains its per-file license and copyright.",
            url: URL(string: "https://www.wikipedia.org")
        ))
        add(.init(
            source: .musicbrainz,
            name: "MusicBrainz",
            notice: "Music metadata is sourced from MusicBrainz (musicbrainz.org), which does not endorse or affiliate with Plozz.",
            url: URL(string: "https://musicbrainz.org")
        ))
        add(.init(
            source: .deezer,
            name: "Deezer",
            notice: "Music artwork is sourced from the Deezer API (deezer.com), which does not endorse or affiliate with Plozz.",
            url: URL(string: "https://www.deezer.com")
        ))
        return map
    }()
}
