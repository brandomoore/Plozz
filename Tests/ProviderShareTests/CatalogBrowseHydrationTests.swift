import XCTest
import CoreModels
import MetadataKit
@testable import ProviderShare

final class CatalogBrowseHydrationTests: XCTestCase {
    func testFilteredReleaseDateOrderMatchesNativeMovieAndSeriesOrder() throws {
        for library in [CatalogLibrary.movies, .tv, .anime] {
            let connection = openConnection()
            for (title, date) in [("Alpha", "2024-01-01"), ("Zulu", "2024-12-01")] {
                let itemID: String
                if library == .movies {
                    seedMovie(connection, relPath: "\(title).mkv", basename: "\(title).mkv",
                              title: title, year: 2024, movieKey: title)
                    itemID = ShareCatalogID.file("\(title).mkv")
                } else {
                    seedEpisode(connection, relPath: "\(title)/S01E01.mkv", seriesKey: title,
                                seriesTitle: title, season: 1, episode: 1, library: library)
                    itemID = ShareCatalogID.series(title)
                }
                insertMetadataValue(connection, itemID: itemID, field: "premiereDate",
                                    source: "localNFO", valueJSON: "\"\(date)\"")
            }
            let queries = makeQueries(connection)
            for direction in [SortDirection.ascending, .descending] {
                let sort = SortDescriptor(field: .releaseDate, direction: direction)
                let native = library == .movies
                    ? queries.movies(offset: 0, limit: 20, sort: sort)
                    : queries.series(in: library, offset: 0, limit: 20, sort: sort)
                XCTAssertEqual(native.map(\.title), direction == .ascending ? ["Alpha", "Zulu"] : ["Zulu", "Alpha"])
                let filtered = native.map { LibraryQueryRecord($0) }
                    .filter { $0.matches(.init(filter: .unwatched)) }
                    .sorted { $0.isOrdered(before: $1, by: sort) }
                XCTAssertEqual(filtered.map(\.title), native.map(\.title))
                for summary in native {
                    let date = try XCTUnwrap(summary.releaseDate)
                    let detail = try XCTUnwrap(queries.item(id: summary.id))
                    XCTAssertEqual(detail.releaseDate, date)
                    XCTAssertEqual(detail.metadataProvenance[.premiereDate]?.source, .localNFO)
                }
            }
        }
    }

    func testLocalPremiereDateUsesUTCAndInvalidValuesPreserveTheBase() {
        let base = MediaItem(id: "movie", title: "Movie", kind: .movie,
                             releaseDate: Date(timeIntervalSince1970: 1_609_459_200))
        let projected = ShareCatalogReadProjection.applyLocalMetadata(base, [
            .premiereDate: .init(source: .localNFO, valueJSON: #""2024-02-29""#)
        ])
        XCTAssertEqual(projected.releaseDate, Date(timeIntervalSince1970: 1_709_164_800))
        XCTAssertEqual(projected.metadataProvenance[.premiereDate]?.source, .localNFO)
        for value in [#""not-a-date""#, #""""#, "null", "2024"] {
            let invalid = ShareCatalogReadProjection.applyLocalMetadata(base, [
                .premiereDate: .init(source: .localNFO, valueJSON: value)
            ])
            XCTAssertEqual(invalid.releaseDate, base.releaseDate)
            XCTAssertNil(invalid.metadataProvenance[.premiereDate])
        }
    }

    func testSeparateEpisodeFilesRetainTheirLogicalCoordinatesDuringHydration() throws {
        let connection = openConnection()
        for resolution in ["1080p", "2160p"] {
            seedEpisode(connection, relPath: "Show/S01E01.\(resolution).mkv", seriesKey: "show",
                        seriesTitle: "Show", season: 1, episode: 1)
        }
        let queries = makeQueries(connection)
        let inventory = queries.libraryQueryEpisodes(in: .tv, offset: 0, limit: 20)
        XCTAssertEqual(inventory.items.count, 2)
        for summary in inventory.items {
            let detail = try XCTUnwrap(queries.item(id: summary.id))
            XCTAssertEqual(detail.seriesID, ShareCatalogID.series("show"))
            XCTAssertEqual(detail.seasonNumber, 1)
            XCTAssertEqual(detail.episodeNumber, 1)
            XCTAssertLessThanOrEqual(detail.versions.count, 1)
            XCTAssertFalse(LibraryQueryRecord(detail).duplicates)
        }
    }

    func testMovieInventoryPreservesNativeSortInputs() throws {
        let connection = openConnection()
        seedMovie(connection, relPath: "Zebra.mkv", basename: "Zebra.mkv",
                  title: "Zebra", year: 2024, movieKey: "zebra")
        seedMovie(connection, relPath: "Apple.mkv", basename: "Apple.mkv",
                  title: "Apple", year: 2024, movieKey: "apple")
        insertMetadataValue(connection, itemID: ShareCatalogID.file("Zebra.mkv"),
                            field: "sortTitle", source: "localNFO", valueJSON: #""A First""#)
        XCTAssertTrue(connection.exec("UPDATE assets SET first_seen_at=2 WHERE rel_path='Zebra.mkv';"))
        let native = makeQueries(connection).movies(offset: 0, limit: 20)
        XCTAssertEqual(native.map(\.title), ["Zebra", "Apple"])
        let filtered = native.map { LibraryQueryRecord($0) }
            .filter { $0.matches(.init(filter: .unwatched)) }
        XCTAssertEqual(filtered.sorted { $0.isOrdered(before: $1, by: .default) }.map(\.title), native.map(\.title))
        XCTAssertEqual(filtered.sorted {
            $0.isOrdered(before: $1, by: .init(field: .dateAdded, direction: .descending))
        }.map(\.title), ["Zebra", "Apple"])
        XCTAssertEqual(native.first?.librarySortValues?.dateAdded, Date(timeIntervalSince1970: 2))
        XCTAssertEqual(native.first?.librarySortValues?.sortName, "A First")
    }

    func testFacetsUseRepresentativeMovieMetadataWithoutRequiringEnrichment() throws {
        let connection = openConnection()
        for path in ["Feature.mkv", "ZFeature.mkv"] {
            seedMovie(connection, relPath: path, basename: path,
                      title: "Feature", year: 2024, movieKey: "feature")
        }
        let itemID = ShareCatalogID.file("Feature.mkv")
        insertMetadataValue(connection, itemID: itemID, field: "productionYear",
                            source: "filename", valueJSON: "2020")
        insertMetadataValue(connection, itemID: itemID, field: "genres",
                            source: "filename", valueJSON: #"["Comedy"]"#)
        insertMetadataValue(connection, itemID: itemID, field: "productionYear",
                            source: "localNFO", valueJSON: "2021")
        insertMetadataValue(connection, itemID: itemID, field: "genres",
                            source: "localNFO", valueJSON: #"["Drama"]"#)
        insertMetadataValue(connection, itemID: ShareCatalogID.file("ZFeature.mkv"), field: "genres",
                            source: "localNFO", valueJSON: #"["Thriller"]"#)
        let queries = makeQueries(connection)
        let item = try XCTUnwrap(queries.movies(offset: 0, limit: 20).first)
        XCTAssertEqual(item.productionYear, 2021)
        XCTAssertEqual(item.genres, ["Drama"])
        XCTAssertEqual(queries.libraryQueryFacets(in: .movies), .init(genres: item.genres, years: [2021]))
    }

    func testSeriesFacetsUseSeriesMetadataRatherThanEpisodeMetadata() throws {
        let connection = openConnection()
        for library in [CatalogLibrary.tv, .anime] {
            let key = "show-\(library.rawValue)"
            let path = "\(library.rawValue)/S01E01.mkv"
            seedEpisode(connection, relPath: path, seriesKey: key,
                        seriesTitle: "Show", season: 1, episode: 1, library: library)
            insertMetadataValue(connection, itemID: ShareCatalogID.series(key), field: "productionYear",
                                source: "localNFO", valueJSON: "2010")
            insertMetadataValue(connection, itemID: ShareCatalogID.series(key), field: "genres",
                                source: "localNFO", valueJSON: #"["Drama"]"#)
            insertMetadataValue(connection, itemID: ShareCatalogID.file(path), field: "genres",
                                source: "localNFO", valueJSON: #"["Comedy"]"#)
            let queries = makeQueries(connection)
            let item = try XCTUnwrap(queries.series(in: library, offset: 0, limit: 20).first)
            XCTAssertEqual(item.productionYear, 2010)
            XCTAssertEqual(item.genres, ["Drama"])
            XCTAssertEqual(queries.libraryQueryFacets(in: library), .init(genres: item.genres, years: [2010]))
        }
    }

    func testFacetsMatchFilenameAndEmptyNFOFallbacks() throws {
        let connection = openConnection()
        seedMovie(connection, relPath: "Feature.mkv", basename: "Feature.mkv",
                  title: "Feature", year: 2024, movieKey: "feature")
        let itemID = ShareCatalogID.file("Feature.mkv")
        insertEnrichment(connection, itemID: itemID, title: "Feature",
                         posterURL: try XCTUnwrap(URL(string: "https://example.invalid/poster.jpg")))
        insertMetadataValue(connection, itemID: itemID, field: "productionYear",
                            source: "filename", valueJSON: "2020")
        insertMetadataValue(connection, itemID: itemID, field: "genres",
                            source: "filename", valueJSON: #"["Comedy"]"#)
        let queries = makeQueries(connection)
        XCTAssertEqual(queries.libraryQueryFacets(in: .movies), .init(genres: ["Comedy"], years: [2020]))
        insertMetadataValue(connection, itemID: itemID, field: "genres",
                            source: "localNFO", valueJSON: "[]")
        let item = try XCTUnwrap(queries.movies(offset: 0, limit: 20).first)
        XCTAssertEqual(item.genres, ["Drama"])
        XCTAssertEqual(queries.libraryQueryFacets(in: .movies), .init(genres: item.genres, years: [2020]))
    }

    func testLibraryEpisodeInventoryPreservesEpisodeCoordinatesAndLibrary() throws {
        let connection = openConnection()
        for library in [CatalogLibrary.tv, .anime] {
            let seriesKey = "show-\(library.rawValue)"
            seedEpisode(connection, relPath: "\(library.rawValue)/S02E03.mkv", seriesKey: seriesKey,
                        seriesTitle: "Show", season: 2, episode: 3, library: library)
            let page = makeQueries(connection).libraryQueryEpisodes(in: library, offset: 0, limit: 20)
            let item = try XCTUnwrap(page.items.first)
            XCTAssertEqual(page.totalCount, 1)
            XCTAssertEqual(item.parentTitle, "Show")
            XCTAssertEqual(item.seasonNumber, 2)
            XCTAssertEqual(item.episodeNumber, 3)
            XCTAssertEqual(item.seasonID, ShareCatalogID.season(seriesKey, 2))
            XCTAssertEqual(item.libraryID, ShareCatalogID.library(library))
        }
    }

    private var fixtures: [ShareCatalogSQLiteFixture] = []

    override func tearDownWithError() throws {
        for fixture in fixtures {
            try FileManager.default.removeItem(at: fixture.directory)
        }
        fixtures.removeAll()
        try super.tearDownWithError()
    }

    private func openConnection() -> CatalogConnection {
        let fixture = ShareCatalogSQLiteFixture()
        fixtures.append(fixture)
        let connection = CatalogConnection(url: fixture.catalogURL)
        XCTAssertTrue(connection.ensureOpen(legacyMetadataMigration: { _ in true }))
        return connection
    }

    private func makeQueries(
        _ connection: CatalogConnection,
        preferOnlineArtwork: Bool = false
    ) -> CatalogReadQueries {
        CatalogReadQueries(
            connection: connection,
            normalizedMetadataReady: true,
            metadataConfig: MetadataEnrichmentConfig(
                preferOnlineArtwork: preferOnlineArtwork
            ),
            localMetadataPresence: LocalMetadataPresence()
        )
    }

    private func seedMovie(
        _ connection: CatalogConnection,
        relPath: String,
        basename: String,
        title: String,
        year: Int,
        movieKey: String
    ) {
        XCTAssertTrue(connection.exec("""
        INSERT INTO assets(
          rel_path, basename, size, modified_at, first_seen_at, last_scan,
          kind, library, title, sort_title, year, movie_key)
        VALUES(
          '\(relPath)', '\(basename)', 100, 1, 1, 1,
          'movie', 'movies', '\(title)', '\(title.lowercased())', \(year), '\(movieKey)'
        );
        """))
    }

    private func seedEpisode(
        _ connection: CatalogConnection,
        relPath: String,
        seriesKey: String,
        seriesTitle: String,
        season: Int,
        episode: Int,
        library: CatalogLibrary = .tv
    ) {
        XCTAssertTrue(connection.exec("""
        INSERT INTO assets(
          rel_path, basename, size, modified_at, first_seen_at, last_scan,
          kind, library, title, sort_title, year, series_title, series_key, season, episode)
        VALUES(
          '\(relPath)', 'episode.mkv', 100, 1, 1, 1,
          'episode', '\(library.rawValue)', 'Episode \(episode)', 'episode \(episode)', 2024,
          '\(seriesTitle)', '\(seriesKey)', \(season), \(episode)
        );
        """))
    }

    private func insertEnrichment(
        _ connection: CatalogConnection,
        itemID: String,
        title: String,
        posterURL: URL
    ) {
        XCTAssertTrue(connection.exec("""
        INSERT INTO enrichment(
          item_id, provider_ids_json, overview, genres_json, runtime,
          poster_url, enriched_at, enrich_version, title)
        VALUES(
          '\(itemID)', '{"Tmdb":"42"}', 'External overview', '["Drama"]', 7200,
          '\(posterURL.absoluteString)', 1, 1, '\(title)'
        );
        """))
    }

    private func insertLocalArtwork(
        _ connection: CatalogConnection,
        itemID: String,
        url: URL
    ) throws {
        let selection = ArtworkSelection(
            placement: .poster,
            references: [.remote(url)]
        )
        let json = String(
            decoding: try JSONEncoder().encode(selection),
            as: UTF8.self
        ).replacingOccurrences(of: "'", with: "''")
        XCTAssertTrue(connection.exec("""
        INSERT INTO metadata_values(item_id, field, source, value_json)
        VALUES('\(itemID)', 'artwork.poster', 'localArtwork', '\(json)');
        """))
    }

    private func insertMetadataValue(
        _ connection: CatalogConnection,
        itemID: String,
        field: String,
        source: String,
        valueJSON: String
    ) {
        let escaped = valueJSON.replacingOccurrences(of: "'", with: "''")
        XCTAssertTrue(connection.exec("""
        INSERT INTO metadata_values(item_id, field, source, value_json)
        VALUES('\(itemID)', '\(field)', '\(source)', '\(escaped)');
        """))
    }

    func testBatchMatchesIndividualHydrationForMixedIDsAliasesAndDuplicates() throws {
        let connection = openConnection()
        let movieKey = "feature-2024"
        seedMovie(
            connection,
            relPath: "Movies/Feature.1080p.mkv",
            basename: "Feature.1080p.mkv",
            title: "Feature",
            year: 2024,
            movieKey: movieKey
        )
        seedMovie(
            connection,
            relPath: "Movies/Feature.2160p.DV.mkv",
            basename: "Feature.2160p.DV.mkv",
            title: "Feature",
            year: 2024,
            movieKey: movieKey
        )
        seedEpisode(
            connection,
            relPath: "TV/Show/S01E01.mkv",
            seriesKey: "show",
            seriesTitle: "Show",
            season: 1,
            episode: 1
        )
        XCTAssertTrue(connection.exec("""
        INSERT INTO movie_alias(alias_id, group_key)
        VALUES
          ('former-feature', '\(movieKey)'),
          ('f:Movies/Retired Feature.mkv', '\(movieKey)');
        """))

        let representativeID = ShareCatalogID.file("Movies/Feature.1080p.mkv")
        insertEnrichment(
            connection,
            itemID: representativeID,
            title: "Feature Film",
            posterURL: try XCTUnwrap(URL(string: "https://example.invalid/feature.jpg"))
        )
        insertMetadataValue(
            connection,
            itemID: representativeID,
            field: "title",
            source: "localNFO",
            valueJSON: #""Local Feature""#
        )
        insertMetadataValue(
            connection,
            itemID: representativeID,
            field: "ratings",
            source: "localNFO",
            valueJSON: #"[{"source":"imdb","value":8.4,"max":10,"votes":250,"isDefault":true}]"#
        )
        insertMetadataValue(
            connection,
            itemID: representativeID,
            field: "providerID.imdb",
            source: "localNFO",
            valueJSON: #""tt0042""#
        )
        let queries = makeQueries(connection)
        let logicalMovieID = ShareCatalogID.movie(movieKey)
        let aliasedMovieID = ShareCatalogID.movie("former-feature")
        let aliasedFileID = ShareCatalogID.file("Movies/Retired Feature.mkv")
        let episodeID = ShareCatalogID.file("TV/Show/S01E01.mkv")
        let paddedSeasonID = "season:show:01"
        let ids = [
            logicalMovieID,
            ShareCatalogID.file("Movies/Feature.2160p.DV.mkv"),
            ShareCatalogID.series("show"),
            ShareCatalogID.season("show", 1),
            paddedSeasonID,
            episodeID,
            aliasedMovieID,
            aliasedFileID,
            logicalMovieID,
            "share:missing",
            ShareCatalogID.file("Movies/Missing.mkv"),
        ]

        let batch = queries.browseItems(ids: ids)

        XCTAssertEqual(batch.count, 8)
        for id in Set(ids) {
            XCTAssertEqual(batch[id], queries.browseItems(ids: [id])[id], "parity failed for \(id)")
        }
        XCTAssertEqual(batch[logicalMovieID]?.versions.count, 2)
        XCTAssertEqual(batch[logicalMovieID]?.versions.filter(\.isDefault).count, 1)
        XCTAssertEqual(batch[logicalMovieID]?.title, "Local Feature")
        XCTAssertEqual(batch[logicalMovieID]?.overview, "External overview")
        XCTAssertEqual(batch[logicalMovieID]?.genres, ["Drama"])
        XCTAssertEqual(batch[logicalMovieID]?.runtime, 7200)
        XCTAssertEqual(batch[logicalMovieID]?.providerIDs["Tmdb"], "42")
        XCTAssertEqual(batch[logicalMovieID]?.providerIDs["Imdb"], "tt0042")
        XCTAssertEqual(batch[logicalMovieID]?.ratings.first?.value, 8.4)
        XCTAssertEqual(batch[logicalMovieID]?.metadataProvenance[.title]?.source, .localNFO)
        XCTAssertEqual(
            batch[logicalMovieID]?.metadataProvenance[.providerID("imdb")]?.source,
            .localNFO
        )
        XCTAssertEqual(batch[aliasedMovieID]?.id, logicalMovieID)
        XCTAssertEqual(batch[aliasedFileID]?.id, logicalMovieID)
        XCTAssertEqual(batch[paddedSeasonID]?.id, ShareCatalogID.season("show", 1))
        XCTAssertEqual(batch[episodeID]?.seriesID, ShareCatalogID.series("show"))
        XCTAssertNil(batch["share:missing"])
        XCTAssertNil(batch[ShareCatalogID.file("Movies/Missing.mkv")])
    }

    func testBatchPreservesLocalAndExternalPosterPrecedence() throws {
        let connection = openConnection()
        seedMovie(
            connection,
            relPath: "Movies/Poster.mkv",
            basename: "Poster.mkv",
            title: "Poster",
            year: 2024,
            movieKey: "poster-2024"
        )
        let itemID = ShareCatalogID.movie("poster-2024")
        let representativeID = ShareCatalogID.file("Movies/Poster.mkv")
        let onlineURL = try XCTUnwrap(URL(string: "https://example.invalid/online.jpg"))
        let localURL = try XCTUnwrap(URL(string: "https://example.invalid/local.jpg"))
        insertEnrichment(
            connection,
            itemID: representativeID,
            title: "Poster",
            posterURL: onlineURL
        )
        insertMetadataValue(
            connection,
            itemID: representativeID,
            field: "posterURL",
            source: "tmdb",
            valueJSON: String(
                decoding: try JSONEncoder().encode(onlineURL),
                as: UTF8.self
            )
        )
        try insertLocalArtwork(connection, itemID: representativeID, url: localURL)

        let localFirst = makeQueries(connection)
            .browseItems(ids: [itemID])[itemID]
        let onlineFirst = makeQueries(connection, preferOnlineArtwork: true)
            .browseItems(ids: [itemID])[itemID]

        XCTAssertEqual(
            localFirst?.artworkReferences(for: .poster),
            [.remote(localURL), .remote(onlineURL)]
        )
        XCTAssertEqual(localFirst?.metadataProvenance[.posterURL]?.source, .localArtwork)
        XCTAssertEqual(
            onlineFirst?.artworkReferences(for: .poster),
            [.remote(localURL), .remote(onlineURL)]
        )
        XCTAssertEqual(onlineFirst?.metadataProvenance[.posterURL]?.source, .localArtwork)
    }

    func testBatchBoundsLargeInputAndOmitsUnknownIDs() {
        let connection = openConnection()
        let count = 450
        for index in 0..<count {
            seedMovie(
                connection,
                relPath: "Movies/Batch-\(index).mkv",
                basename: "Batch-\(index).mkv",
                title: "Batch \(index)",
                year: 2024,
                movieKey: "batch-\(index)"
            )
        }
        let ids = (0..<count).map { ShareCatalogID.file("Movies/Batch-\($0).mkv") }
            + [ShareCatalogID.file("Movies/Unknown.mkv")]

        let batch = makeQueries(connection).browseItems(ids: ids)

        XCTAssertEqual(batch.count, count)
        XCTAssertEqual(batch[ids[count - 1]]?.title, "Batch \(count - 1)")
        XCTAssertNil(batch[ShareCatalogID.file("Movies/Unknown.mkv")])
    }
}
