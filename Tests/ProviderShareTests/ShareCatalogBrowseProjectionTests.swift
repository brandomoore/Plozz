import XCTest
import CoreModels
import SQLite3
@testable import ProviderShare

final class ShareCatalogBrowseProjectionTests: XCTestCase {
    private var createdCatalogDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in createdCatalogDirectories {
            try FileManager.default.removeItem(at: directory)
        }
        createdCatalogDirectories.removeAll()
        try super.tearDownWithError()
    }

    private func catalogDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-browse-projection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        createdCatalogDirectories.append(directory)
        return directory
    }

    private func episode(
        _ path: String,
        series: String,
        season: Int,
        number: Int,
        metadataRoot: String
    ) -> CatalogAsset {
        CatalogAsset(
            relPath: path,
            basename: (path as NSString).lastPathComponent,
            size: 1_000,
            modifiedAt: Date(),
            kind: .episode,
            library: .tv,
            title: "Episode \(number)",
            year: nil,
            seriesTitle: series,
            seriesKey: ShareCatalogID.seriesKey(fromTitle: series),
            season: season,
            episode: number,
            metadataRoot: metadataRoot
        )
    }

    private func movie(
        _ path: String,
        title: String,
        year: Int,
        size: Int64 = 1_000
    ) -> CatalogAsset {
        let grouping = ShareMediaParser.movieGrouping(
            relPath: path,
            parsedTitle: title,
            parsedYear: year
        )
        return CatalogAsset(
            relPath: path,
            basename: (path as NSString).lastPathComponent,
            size: size,
            modifiedAt: Date(),
            kind: .movie,
            library: .movies,
            title: grouping.title,
            year: grouping.year,
            seriesTitle: nil,
            seriesKey: nil,
            season: nil,
            episode: nil,
            movieKey: ShareCatalogID.movieKey(fromTitle: grouping.title, year: grouping.year),
            movieTitleKey: ShareCatalogID.movieKey(fromTitle: grouping.title, year: nil)
        )
    }

    private func folder(_ path: String) -> MediaItem {
        MediaItem(id: "d:\(path)", title: (path as NSString).lastPathComponent, kind: .folder)
    }

    private func file(_ path: String) -> MediaItem {
        MediaItem(id: "f:\(path)", title: (path as NSString).lastPathComponent, kind: .video)
    }

    private func completeScan(
        _ store: ShareCatalogStore,
        directories: [String],
        scanID: Int64 = 1
    ) async {
        for path in directories {
            await store.recordDirectory(relPath: path, modifiedAt: Date(), scanID: scanID)
        }
        let finalized = await store.finalizePlayableInventory(inScan: scanID)
        XCTAssertTrue(finalized)
        await store.markDirectoryStateComplete(scanID: scanID)
    }

    func testAnimeContextIsIndependentOfMovieLibraryAndPersists() async throws {
        let directory = try catalogDirectory()
        let store = ShareCatalogStore(accountKey: "anime-movies", directory: directory)
        await store.upsert([
            movie("Movies/Akira (1988).mkv", title: "Akira", year: 1988)
        ], scanID: 1)
        await store.setLibraryAnimeContext(true)

        let liveContext = await store.libraryAnimeContext()
        let liveMovies = await store.movies(offset: 0, limit: 10)
        XCTAssertTrue(liveContext)
        XCTAssertEqual(liveMovies.first?.title, "Akira")

        let reopened = ShareCatalogStore(accountKey: "anime-movies", directory: directory)
        let reopenedContext = await reopened.libraryAnimeContext()
        let reopenedMovies = await reopened.movies(offset: 0, limit: 10)
        XCTAssertTrue(reopenedContext)
        XCTAssertEqual(reopenedMovies.first?.kind, .movie)
    }

    func testResetExternalEnrichmentRequeuesItemsAndPreservesLocalState() async throws {
        let store = ShareCatalogStore(accountKey: "reset-enrichment", directory: try catalogDirectory())
        let path = "Movies/Akira (1988).mkv"
        let itemID = ShareCatalogID.file(path)
        var asset = movie(path, title: "Akira", year: 1988)
        asset.explicitProviderIDs = ["imdb": "tt0094625"]
        await store.upsert([asset], scanID: 1)
        await store.materializeFilenameProviderIDs()

        var external = EnrichmentRecord()
        external.title = "Externally Resolved Akira"
        external.posterURL = URL(string: "https://example.com/akira.jpg")
        let savedExternal = await store.saveEnrichment(itemID: itemID, external, version: 18)
        let savedLocalState = await store.writeLocalEnrichmentState(
            itemID: itemID,
            version: 7,
            attempts: 2
        )
        XCTAssertTrue(savedExternal)
        XCTAssertTrue(savedLocalState)

        let settledBefore = await store.pendingEnrichment(forItemID: itemID, version: 18)
        let projectedBefore = await store.item(id: itemID)
        let localIDsBefore = await store.localProviderIDs(forItemID: itemID)
        XCTAssertNil(settledBefore)
        XCTAssertEqual(projectedBefore?.posterURL, external.posterURL)
        XCTAssertEqual(localIDsBefore["imdb"], "tt0094625")

        let reset = await store.resetExternalEnrichment()
        XCTAssertTrue(reset)

        let pendingAfter = await store.pendingEnrichment(forItemID: itemID, version: 18)
        let projectedAfter = await store.item(id: itemID)
        let localStateAfter = await store.localEnrichmentState(itemID: itemID)
        let localIDsAfter = await store.localProviderIDs(forItemID: itemID)
        XCTAssertNotNil(pendingAfter)
        XCTAssertEqual(projectedAfter?.title, "Akira")
        XCTAssertNil(projectedAfter?.posterURL)
        XCTAssertEqual(localStateAfter?.version, 7)
        XCTAssertEqual(localStateAfter?.attempts, 2)
        XCTAssertEqual(localIDsAfter["imdb"], "tt0094625")
    }

    func testFilenameIDsUseEachGroupsRepresentativeEvenWithoutItsOwnExplicitIDs() async throws {
        let store = ShareCatalogStore(accountKey: "filename-representatives", directory: try catalogDirectory())
        var assets: [CatalogAsset] = []
        for index in 0..<100 {
            let title = "Movie \(index)"
            let plain = movie("Movies/\(title)/A.mkv", title: title, year: 2000)
            var tagged = movie("Movies/\(title)/Z.mkv", title: title, year: 2000)
            tagged.explicitProviderIDs = ["tmdb": "\(index + 1)"]
            assets.append(contentsOf: [tagged, plain])
        }
        await store.upsert(assets, scanID: 1)
        await store.materializeFilenameProviderIDs()
        for index in 0..<100 {
            let ids = await store.localProviderIDs(forItemID: ShareCatalogID.file("Movies/Movie \(index)/A.mkv"))
            XCTAssertEqual(ids["tmdb"], "\(index + 1)")
        }
    }

    func testLibraryContainerStaysFolderWhileAuthoritativeShowRootPromotes() async throws {
        let store = ShareCatalogStore(accountKey: "series-root", directory: try catalogDirectory())
        let showRoot = "TV Shows/Animanimals"
        await store.upsert([
            episode(
                "\(showRoot)/Season 01/Animanimals.S01E01.mkv",
                series: "Animanimals",
                season: 1,
                number: 1,
                metadataRoot: showRoot
            )
        ], scanID: 1)
        await completeScan(store, directories: ["TV Shows", showRoot])

        let projected = await store.browseItems([
            folder("TV Shows"),
            folder(showRoot),
        ])

        XCTAssertEqual(projected.map(\.id), [
            "d:TV Shows",
            ShareCatalogID.series("animanimals"),
        ])
        XCTAssertEqual(projected[0].kind, .folder, "one-show library must remain a physical container")
        XCTAssertEqual(projected[1].kind, .series)
        XCTAssertEqual(projected.count, 2, "a recognized show must not also appear as a duplicate folder")
        let reader: any ShareCatalogReading = store
        let throughCapability = await reader.browseItems([folder(showRoot)])
        XCTAssertEqual(throughCapability.map(\.id), [ShareCatalogID.series("animanimals")])
    }

    func testSortAwareCatalogCapabilityUsesStoreImplementation() async throws {
        let store = ShareCatalogStore(accountKey: "sorted-capability", directory: try catalogDirectory())
        await store.upsert([
            movie("Movies/Alien (1979).mkv", title: "Alien", year: 1979),
            movie("Movies/Dune (2021).mkv", title: "Dune", year: 2021),
            episode("TV/Alpha/S01E01.mkv", series: "Alpha", season: 1, number: 1, metadataRoot: "TV/Alpha"),
            episode("TV/Zeta/S01E01.mkv", series: "Zeta", season: 1, number: 1, metadataRoot: "TV/Zeta"),
        ], scanID: 1)
        let reader: any ShareCatalogReading = store
        let sort = CoreModels.SortDescriptor(field: .name, direction: .descending)
        let directMovies = await store.movies(offset: 0, limit: 10, sort: sort)
        let movies = await reader.movies(offset: 0, limit: 10, sort: sort)
        let directSeries = await store.series(in: .tv, offset: 0, limit: 10, sort: sort)
        let series = await reader.series(in: .tv, offset: 0, limit: 10, sort: sort)
        XCTAssertEqual(movies.map(\.title), ["Dune", "Alien"])
        XCTAssertEqual(directMovies, movies)
        XCTAssertEqual(series.map(\.title), ["Zeta", "Alpha"])
        XCTAssertEqual(directSeries, series)
    }

    func testSeriesProjectionIsScopedToExactMetadataRoot() async throws {
        let store = ShareCatalogStore(accountKey: "series-scope", directory: try catalogDirectory())
        await store.upsert([
            episode(
                "TV Shows/Animanimals/Season 01/E01.mkv",
                series: "Animanimals",
                season: 1,
                number: 1,
                metadataRoot: "TV Shows/Animanimals"
            ),
            episode(
                "Archive/Animanimals/Season 02/E01.mkv",
                series: "Animanimals",
                season: 2,
                number: 1,
                metadataRoot: "Archive/Animanimals"
            ),
        ], scanID: 1)
        await completeScan(
            store,
            directories: ["TV Shows", "TV Shows/Animanimals", "Archive"]
        )

        let projected = await store.browseItems([
            folder("TV Shows"),
            folder("TV Shows/Animanimals"),
            folder("Archive"),
        ])

        XCTAssertEqual(projected.map(\.id), [
            "d:TV Shows",
            ShareCatalogID.series("animanimals"),
            "d:Archive",
        ])
    }

    func testCompleteDirectSeasonFolderPromotesToCatalogSeason() async throws {
        let store = ShareCatalogStore(accountKey: "season-root", directory: try catalogDirectory())
        let showRoot = "TV Shows/Animanimals"
        let seasonRoot = "\(showRoot)/Season 01"
        await store.upsert([
            episode(
                "\(seasonRoot)/E01.mkv",
                series: "Animanimals",
                season: 1,
                number: 1,
                metadataRoot: showRoot
            ),
            episode(
                "\(seasonRoot)/E02.mkv",
                series: "Animanimals",
                season: 1,
                number: 2,
                metadataRoot: showRoot
            ),
        ], scanID: 1)
        await completeScan(store, directories: [seasonRoot])

        let projected = await store.browseItems([folder(seasonRoot)])

        XCTAssertEqual(projected.map(\.id), [
            ShareCatalogID.season("animanimals", 1),
        ])
        XCTAssertEqual(projected.first?.kind, .season)
        XCTAssertEqual(projected.first?.seriesID, ShareCatalogID.series("animanimals"))
    }

    func testPartialSeasonSubfolderDoesNotPromote() async throws {
        let store = ShareCatalogStore(accountKey: "partial-season", directory: try catalogDirectory())
        let showRoot = "TV Shows/Animanimals"
        await store.upsert([
            episode(
                "\(showRoot)/Season 01/Disc A/E01.mkv",
                series: "Animanimals",
                season: 1,
                number: 1,
                metadataRoot: showRoot
            ),
            episode(
                "\(showRoot)/Season 01/Disc B/E02.mkv",
                series: "Animanimals",
                season: 1,
                number: 2,
                metadataRoot: showRoot
            ),
        ], scanID: 1)
        await completeScan(store, directories: ["\(showRoot)/Season 01/Disc A"])

        let projected = await store.browseItems([folder("\(showRoot)/Season 01/Disc A")])

        XCTAssertEqual(projected.first?.id, "d:\(showRoot)/Season 01/Disc A")
        XCTAssertEqual(projected.first?.kind, .folder)
    }

    func testDedicatedMovieFolderPromotesOneLogicalMovieWithVersions() async throws {
        let store = ShareCatalogStore(accountKey: "movie-folder", directory: try catalogDirectory())
        let root = "Movies/Dune (2021)"
        await store.upsert([
            movie("\(root)/Dune.2021.1080p.mkv", title: "Dune", year: 2021, size: 1_000),
            movie("\(root)/Dune.2021.2160p.mkv", title: "Dune", year: 2021, size: 2_000),
        ], scanID: 1)
        await completeScan(store, directories: [root])

        let projected = await store.browseItems([folder(root)])

        XCTAssertEqual(projected.count, 1)
        XCTAssertEqual(projected.first?.id, ShareCatalogID.movie("dune-2021"))
        XCTAssertEqual(projected.first?.kind, .movie)
        XCTAssertEqual(projected.first?.versions.count, 2)
    }

    func testTitleMatchedMovieFolderNeedsStructuralMembershipEvidence() async throws {
        let store = ShareCatalogStore(accountKey: "movie-title-folder", directory: try catalogDirectory())
        let root = "Movies/Arrival"
        await store.upsert([
            movie("\(root)/Arrival.2016.mkv", title: "Arrival", year: 2016)
        ], scanID: 1)
        await completeScan(store, directories: [root])

        let projected = await store.browseItems([folder(root)])

        XCTAssertEqual(projected.first?.id, ShareCatalogID.movie("arrival-2016"))
        XCTAssertEqual(projected.first?.kind, .movie)
        XCTAssertEqual(projected.count, 1)
    }

    func testMovieFolderPromotesWhenAnotherLibraryContainsTheSameMovie() async throws {
        let store = ShareCatalogStore(accountKey: "movie-other-copy", directory: try catalogDirectory())
        let root = "Movies/Arrival (2016)"
        let paths = [
            "\(root)/Arrival.2016.2160p.mkv",
            "Other Library/Movies/Arrival.2016.1080p/Arrival.2016.1080p.mkv",
        ]
        await store.upsert(paths.map { movie($0, title: "Arrival", year: 2016) }, scanID: 1)
        var metadata = EnrichmentRecord()
        metadata.posterURL = URL(string: "https://example.com/arrival.jpg")
        for path in paths {
            let saved = await store.saveEnrichment(
                itemID: ShareCatalogID.file(path), metadata, version: 18
            )
            XCTAssertTrue(saved)
        }

        let projected = await store.browseItems([folder(root).taggingSource("share-account")])
        let item = try XCTUnwrap(projected.first)

        XCTAssertEqual(projected.count, 1)
        XCTAssertEqual(item.id, ShareCatalogID.movie("arrival-2016"))
        XCTAssertEqual(item.kind, .movie)
        XCTAssertEqual(item.posterURL, metadata.posterURL)
        XCTAssertEqual(item.versions.count, 2)
        XCTAssertEqual(item.sourceAccountID, "share-account")
        XCTAssertEqual(item.fileBrowserContainerID, "share:files:d:\(root)")
    }

    func testNumericMovieFoldersUseTheirIndexedTitlesDespiteDifferentFolderYears() async throws {
        let store = ShareCatalogStore(accountKey: "numeric-movie-folders", directory: try catalogDirectory())
        for (title, folderYear, fileYear) in [("300", 2006, 2007), ("2050", 2019, 2019), ("1917", 2019, 2019)] {
            let root = "Movies/\(title) (\(folderYear))"
            let path = "\(root)/\(title).\(fileYear).mkv"
            await store.upsert([movie(path, title: title, year: fileYear)], scanID: 1)
            var metadata = EnrichmentRecord()
            metadata.posterURL = URL(string: "https://example.com/\(title).jpg")
            let saved = await store.saveEnrichment(
                itemID: ShareCatalogID.file(path), metadata, version: 18
            )
            XCTAssertTrue(saved)

            let projected = await store.browseItems([folder(root)])

            XCTAssertEqual(projected.first?.id, ShareCatalogID.movie("\(title)-\(fileYear)"))
            XCTAssertEqual(projected.first?.kind, .movie)
            XCTAssertEqual(projected.first?.posterURL, metadata.posterURL)
            XCTAssertEqual(projected.first?.fileBrowserContainerID, "share:files:d:\(root)")
        }
    }

    func testYearBucketDoesNotPromoteWhenItsOnlyMovieHasANumericTitle() async throws {
        let store = ShareCatalogStore(accountKey: "movie-year-bucket", directory: try catalogDirectory())
        await store.upsert([
            movie("Movies/2024/2024.2020.mkv", title: "2024", year: 2020)
        ], scanID: 1)

        let projected = await store.browseItems([folder("Movies/2024")])

        XCTAssertEqual(projected.first?.id, "d:Movies/2024")
        XCTAssertEqual(projected.first?.kind, .folder)
    }

    func testMovieTitlesContainingYearsStillMatchYearlessFolders() async throws {
        let store = ShareCatalogStore(accountKey: "movie-year-in-title", directory: try catalogDirectory())
        for (title, year) in [("2001 A Space Odyssey", 1968), ("Blade Runner 2049", 2017)] {
            let root = "Movies/\(title)"
            let name = "\(title).\(year).mkv"
            let key = ShareCatalogID.movieKey(fromTitle: title, year: year)
            await store.upsert([CatalogAsset(
                relPath: "\(root)/\(name)", basename: name,
                size: 1_000, modifiedAt: Date(), kind: .movie, library: .movies,
                title: title, year: year, seriesTitle: nil, seriesKey: nil,
                season: nil, episode: nil,
                movieKey: key, movieTitleKey: ShareCatalogID.movieKey(fromTitle: title, year: nil)
            )], scanID: 1)

            let projected = await store.browseItems([folder(root)])

            XCTAssertEqual(projected.first?.id, ShareCatalogID.movie(key))
            XCTAssertEqual(projected.first?.kind, .movie)
        }
    }

    func testLooseSingleMovieDoesNotTurnLibraryContainerIntoMovie() async throws {
        let store = ShareCatalogStore(accountKey: "movie-library", directory: try catalogDirectory())
        await store.upsert([
            movie("Movies/Dune (2021).mkv", title: "Dune", year: 2021)
        ], scanID: 1)
        await completeScan(store, directories: ["Movies"])

        let projected = await store.browseItems([folder("Movies")])

        XCTAssertEqual(projected.first?.id, "d:Movies")
        XCTAssertEqual(projected.first?.kind, .folder)
    }

    func testSingleMovieInArbitraryMismatchedFolderDoesNotPromote() async throws {
        let store = ShareCatalogStore(accountKey: "movie-arbitrary", directory: try catalogDirectory())
        await store.upsert([
            movie("Incoming/Arrival.2016.mkv", title: "Arrival", year: 2016)
        ], scanID: 1)
        await completeScan(store, directories: ["Incoming"])

        let projected = await store.browseItems([folder("Incoming")])

        XCTAssertEqual(projected.first?.id, "d:Incoming")
        XCTAssertEqual(projected.first?.kind, .folder)
    }

    func testMixedCatalogEntitiesDoNotReplaceFolder() async throws {
        let store = ShareCatalogStore(accountKey: "mixed-folder", directory: try catalogDirectory())
        let root = "Mixed/Dune (2021)"
        await store.upsert([
            movie("\(root)/Dune.mkv", title: "Dune", year: 2021),
            episode(
                "\(root)/Show/Season 01/E01.mkv",
                series: "Show",
                season: 1,
                number: 1,
                metadataRoot: "\(root)/Show"
            ),
        ], scanID: 1)
        await completeScan(store, directories: [root])

        let projected = await store.browseItems([folder(root)])

        XCTAssertEqual(projected.first?.id, "d:\(root)")
        XCTAssertEqual(projected.first?.kind, .folder)
    }

    func testIndexedFilesUseCatalogIdentityAndMetadataWhileUnindexedFilesSurvive() async throws {
        let store = ShareCatalogStore(accountKey: "files", directory: try catalogDirectory())
        let first = "Movies/Dune (2021)/Dune.1080p.mkv"
        let second = "Movies/Dune (2021)/Dune.2160p.mkv"
        await store.upsert([
            movie(first, title: "Dune", year: 2021, size: 1_000),
            movie(second, title: "Dune", year: 2021, size: 2_000),
        ], scanID: 1)
        var enrichment = EnrichmentRecord()
        enrichment.title = "Dune: Part One"
        enrichment.posterURL = URL(string: "https://example.com/dune.jpg")
        _ = await store.saveEnrichment(
            itemID: ShareCatalogID.file(first),
            enrichment,
            version: 1
        )

        let unindexed = file("Movies/Dune (2021)/Notes from camera.mp4")
        let projected = await store.browseItems([file(first), file(second), unindexed])

        XCTAssertEqual(projected.count, 2, "two indexed versions collapse, unrelated live file remains")
        XCTAssertEqual(projected[0].id, ShareCatalogID.movie("dune-2021"))
        XCTAssertEqual(projected[0].title, "Dune: Part One")
        XCTAssertEqual(projected[0].posterURL, URL(string: "https://example.com/dune.jpg"))
        XCTAssertEqual(projected[1], unindexed)
    }

    func testKnownShowOpensDetailsBeforeInventoryCompletesWithFilesStillReachable() async throws {
        let store = ShareCatalogStore(accountKey: "incomplete-folder", directory: try catalogDirectory())
        let showRoot = "TV Shows/Animanimals"
        await store.upsert([
            episode(
                "\(showRoot)/Season 01/E01.mkv",
                series: "Animanimals",
                season: 1,
                number: 1,
                metadataRoot: showRoot
            )
        ], scanID: 1)
        let projected = await store.browseItems([folder(showRoot)])

        XCTAssertEqual(projected.first?.id, ShareCatalogID.series("animanimals"))
        XCTAssertEqual(projected.first?.kind, .series)
        XCTAssertEqual(projected.first?.fileBrowserContainerID, "share:files:d:\(showRoot)")

        let reopened = ShareCatalogStore(accountKey: "incomplete-folder", directory: createdCatalogDirectories[0])
        let afterReopen = await reopened.browseItems([folder(showRoot)])
        XCTAssertEqual(afterReopen, projected, "a partial scan must not invalidate retained identity")
    }

    func testRecognizedMovieKeepsDetailsAndPosterDuringRescan() async throws {
        let store = ShareCatalogStore(accountKey: "rescan-poster", directory: try catalogDirectory())
        let root = "Movies/Arrival (2016)"
        let path = "\(root)/Arrival.2016.mkv"
        await store.upsert([movie(path, title: "Arrival", year: 2016)], scanID: 1)
        var metadata = EnrichmentRecord()
        metadata.posterURL = URL(string: "https://example.com/arrival.jpg")
        let saved = await store.saveEnrichment(itemID: ShareCatalogID.file(path), metadata, version: 18)
        XCTAssertTrue(saved)
        await completeScan(store, directories: [root])
        let completed = await store.browseItems([folder(root)])
        XCTAssertEqual(completed.first?.kind, .movie)

        await store.invalidateCompletedDirectoryState()
        var live = folder(root)
        live.sourceAccountID = "local-share"
        live.isFavorite = true
        let duringScanItems = await store.browseItems([live])
        let duringScan = try XCTUnwrap(duringScanItems.first)
        XCTAssertEqual(duringScan.id, completed.first?.id)
        XCTAssertEqual(duringScan.kind, .movie)
        XCTAssertEqual(duringScan.title, completed.first?.title)
        XCTAssertEqual(duringScan.fileBrowserContainerID, "share:files:d:\(root)")
        XCTAssertEqual(duringScan.sourceAccountID, live.sourceAccountID)
        XCTAssertTrue(duringScan.isFavorite)
        XCTAssertEqual(duringScan.posterURL, metadata.posterURL)
        XCTAssertEqual(duringScan.productionYear, 2016)
        XCTAssertEqual(duringScan.providerIDs, completed.first?.providerIDs)
    }

    func testRecognizedShowWithUnclassifiedContentKeepsPosterWithoutHidingFiles() async throws {
        let directory = try catalogDirectory()
        let store = ShareCatalogStore(
            accountKey: "extra-poster", directory: directory,
            metadataConfig: { .init(order: [.tvdb], usesGlobalOrder: true) }
        )
        let root = "TV Shows/Animanimals"
        let path = "\(root)/Season 01/E01.mkv"
        await store.upsert([
            episode(path, series: "Animanimals", season: 1, number: 1, metadataRoot: root)
        ], scanID: 1)
        let posterURL = try XCTUnwrap(URL(string: "https://example.com/animanimals.jpg"))
        let metadata = EnrichmentRecord.sourced(posterURL: .init(value: posterURL, source: .tvdb))
        let saved = await store.saveEnrichment(
            itemID: ShareCatalogID.series("animanimals"), metadata, version: 18
        )
        XCTAssertTrue(saved)
        let inventorySaved = await store.upsertPlayablePaths(
            [path, "\(root)/unclassified.mp4"], scanID: 1
        )
        XCTAssertTrue(inventorySaved)
        await completeScan(store, directories: ["TV Shows", root])

        let projected = await store.browseItems([folder("TV Shows"), folder(root)])
        XCTAssertEqual(projected[0], folder("TV Shows"), "a library must not inherit one show's poster")
        XCTAssertEqual(projected[1].id, "d:\(root)")
        XCTAssertEqual(projected[1].kind, .folder)
        XCTAssertEqual(projected[1].posterURL, metadata.posterURL)
        XCTAssertEqual(projected[1].artworkMetadataSource(for: posterURL), .tvdb)
        XCTAssertTrue(projected[1].artworkReferences(for: .poster).isEmpty,
                      "A recognized folder must not relabel external art as a library selection.")
        XCTAssertEqual(projected[1].metadataArtworkURLs(for: .poster), [.init(value: posterURL, source: .tvdb)])
        XCTAssertEqual(projected[1].artworkLookupSubject?.id, ShareCatalogID.series("animanimals"))
        XCTAssertEqual(projected[1].artworkLookupSubject?.kind, .series)
        XCTAssertEqual(projected[1].artworkLookupItem.title, "Animanimals")

        let disabledStore = ShareCatalogStore(
            accountKey: "extra-poster", directory: directory,
            metadataConfig: { .init(disabledSources: [.tvdb], order: [.tvdb], usesGlobalOrder: true) }
        )
        let disabled = await disabledStore.browseItems([folder(root)])
        XCTAssertEqual(disabled.first?.id, folder(root).id)
        XCTAssertEqual(disabled.first?.kind, .folder)
        XCTAssertNil(disabled.first?.posterURL, "Disabled artwork cannot decorate the folder.")
        XCTAssertEqual(disabled.first?.artworkLookupSubject, projected[1].artworkLookupSubject,
                       "The recognized identity can still query other enabled providers.")

        let savedLegacy = await store.saveEnrichment(
            itemID: ShareCatalogID.series("animanimals"),
            .init(posterURL: posterURL), version: 19
        )
        XCTAssertTrue(savedLegacy)
        let legacy = await store.browseItems([folder(root)])
        XCTAssertEqual(legacy.first?.id, folder(root).id)
        XCTAssertEqual(legacy.first?.kind, .folder)
        XCTAssertNil(legacy.first?.posterURL, "Unattributed legacy artwork must not bypass provider policy.")
        XCTAssertTrue(legacy.first?.metadataArtworkURLs(for: .poster).isEmpty == true)
    }

    func testUnpromotedSeasonRetainsExplicitArtworkAndItsSource() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        let root = "TV Shows/Animanimals/Season 01"
        await store.upsert([
            episode("\(root)/E01.mkv", series: "Animanimals", season: 1,
                    number: 1, metadataRoot: "TV Shows/Animanimals")
        ], scanID: 1)
        let savedInventory = await store.upsertPlayablePaths(["\(root)/unknown.mp4"], scanID: 1)
        XCTAssertTrue(savedInventory)
        let url = try XCTUnwrap(URL(string: "https://example.com/season.jpg"))
        var season = MediaItem(
            id: ShareCatalogID.season("animanimals", 1), title: "Season 1", kind: .season,
            artworkSelections: [.init(placement: .seasonPoster, references: [.remote(url)])]
        )
        season.recordArtworkSource(accountID: "art-owner", for: [url])
        let connection = CatalogConnection(url: fixture.catalogURL)
        XCTAssertTrue(connection.ensureOpen(legacyMetadataMigration: { _ in true }))

        let projected = ShareCatalogBrowseProjection(connection: connection)
            .project([folder(root)], resolve: { ids in
                Dictionary(uniqueKeysWithValues: ids.map { ($0, season) })
            })
        let decorated = try XCTUnwrap(projected.first)
        XCTAssertEqual(decorated.id, "d:\(root)")
        XCTAssertEqual(decorated.kind, .folder)
        XCTAssertEqual(decorated.artworkReferences(for: .poster), [.remote(url)])
        XCTAssertEqual(decorated.artworkSourceAccountID(for: url), "art-owner")
        XCTAssertEqual(decorated.artworkLookupSubject?.kind, .season)

        season.recordArtworkMetadataSource(.tvdb, for: url)
        let externalProjection = ShareCatalogBrowseProjection(connection: connection)
            .project([folder(root)], resolve: { ids in
                Dictionary(uniqueKeysWithValues: ids.map { ($0, season) })
            })
        let external = try XCTUnwrap(externalProjection.first)
        XCTAssertEqual(external.id, decorated.id)
        XCTAssertEqual(external.kind, .folder)
        XCTAssertTrue(external.artworkReferences(for: .poster).isEmpty)
        XCTAssertEqual(external.metadataArtworkURLs(for: .poster), [.init(value: url, source: .tvdb)])
        XCTAssertEqual(external.artworkSourceAccountID(for: url), "art-owner")
    }

    func testProjectionHydratesEachLogicalTargetOnceInOneBatch() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        let paths = ["Movies/Dune (2021)/Dune.1080p.mkv", "Movies/Dune (2021)/Dune.2160p.mkv"]
        await store.upsert(paths.map { movie($0, title: "Dune", year: 2021) }, scanID: 1)
        let connection = CatalogConnection(url: fixture.catalogURL)
        XCTAssertTrue(connection.ensureOpen(legacyMetadataMigration: { _ in true }))
        var requests: [[String]] = []
        let target = ShareCatalogID.movie("dune-2021")
        let projected = ShareCatalogBrowseProjection(connection: connection).project(
            paths.map(file), resolve: { ids in
                requests.append(ids)
                return [target: MediaItem(id: target, title: "Dune", kind: .movie)]
            }
        )
        XCTAssertEqual(requests, [[target]])
        XCTAssertEqual(projected.map(\.id), [target])
    }

    func testFolderSafetyProofUsesBoundedInventoryLookupsInLargeCatalog() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        _ = await store.movieCount()
        try fixture.execute("""
        WITH RECURSIVE numbers(i) AS (
          SELECT 0 UNION ALL SELECT i+1 FROM numbers WHERE i<14999
        )
        INSERT INTO assets(rel_path,basename,size,modified_at,first_seen_at,last_scan,
                           kind,library,title,sort_title,year,movie_key,movie_title_key)
        SELECT 'Movies/Film '||i||' (2020)/film.mkv','film.mkv',1000,0,0,1,
               'movie','movies','Film '||i,'Film '||i,2020,'film-'||i||'-2020','film-'||i
        FROM numbers;
        INSERT INTO playable_inventory(rel_path,parent_dir,last_scan)
        SELECT rel_path,substr(rel_path,1,length(rel_path)-length(basename)-1),last_scan FROM assets;
        INSERT INTO dir_state(rel_path,modified_at,last_scan)
        SELECT parent_dir,0,1 FROM playable_inventory;
        """)
        let inventoryComplete = await store.finalizePlayableInventory(inScan: 1)
        XCTAssertTrue(inventoryComplete)
        await store.markDirectoryStateComplete(scanID: 1)
        try fixture.execute("""
        CREATE INDEX IF NOT EXISTS idx_playable_inventory_scan ON playable_inventory(last_scan);
        DROP INDEX IF EXISTS idx_playable_inventory_scan_path;
        """)

        let connection = CatalogConnection(url: fixture.catalogURL)
        XCTAssertTrue(connection.ensureOpen(legacyMetadataMigration: { _ in true }))
        XCTAssertEqual(try fixture.integer(
            "SELECT COUNT(*) FROM sqlite_master WHERE name='idx_playable_inventory_scan';"
        ), 0, "opening an existing catalog must replace its scan-only index")
        let db = try XCTUnwrap(connection.db)
        let work = BrowseSQLWork()
        sqlite3_trace_v2(db, UInt32(SQLITE_TRACE_PROFILE), { _, context, statement, _ in
            guard let context, let statement else { return 0 }
            let work = Unmanaged<BrowseSQLWork>.fromOpaque(context).takeUnretainedValue()
            work.steps += Int(sqlite3_stmt_status(OpaquePointer(statement), SQLITE_STMTSTATUS_VM_STEP, 0))
            return 0
        }, Unmanaged.passUnretained(work).toOpaque())
        defer { sqlite3_trace_v2(db, 0, nil, nil) }
        let projected = ShareCatalogBrowseProjection(connection: connection).project(
            (0..<150).map { folder("Movies/Film \($0) (2020)") },
            resolve: { ids in
                Dictionary(uniqueKeysWithValues: ids.map {
                    ($0, MediaItem(id: $0, title: $0, kind: .movie))
                })
            }
        )
        XCTAssertEqual(projected.count, 150)
        XCTAssertTrue(projected.allSatisfy { $0.kind == .movie })
        XCTAssertLessThan(work.steps, 200_000, "each folder must not rescan the entire playable inventory")
    }

    func testMovieSidecarLookupUsesExactParentIncludingRootAndSpecialCharacters() async throws {
        let store = ShareCatalogStore(accountKey: "movie-parent", directory: try catalogDirectory())
        let root = "Movies/100%_Director's Cut (2020)"
        let direct = "\(root)/film.mkv"
        await store.upsert([
            movie(direct, title: "Director's Cut", year: 2020),
            movie("\(root)/Nested/Other (2021).mkv", title: "Other", year: 2021),
            movie("Movies/100XADirector's Cut (2020)/Different.mkv", title: "Different", year: 2020),
            movie("Root Film (2001).mkv", title: "Root Film", year: 2001),
        ], scanID: 1)
        let directRepresentative = await store.unambiguousMovieGroupRepresentative(inDirectory: root)
        let rootRepresentative = await store.unambiguousMovieGroupRepresentative(inDirectory: "")
        let absentRepresentative = await store.unambiguousMovieGroupRepresentative(inDirectory: "Absent")
        XCTAssertEqual(directRepresentative, direct)
        XCTAssertEqual(rootRepresentative, "Root Film (2001).mkv")
        XCTAssertNil(absentRepresentative)
    }

    func testCompletedScanWithUnclassifiedPlayableDescendantDoesNotPromoteFolder() async throws {
        let store = ShareCatalogStore(accountKey: "excluded-playable", directory: try catalogDirectory())
        let showRoot = "TV Shows/Animanimals"
        let episodePath = "\(showRoot)/Season 01/E01.mkv"
        let unmatchedPath = "\(showRoot)/Behind the curtain.mp4"
        await store.upsert([
            episode(
                episodePath,
                series: "Animanimals",
                season: 1,
                number: 1,
                metadataRoot: showRoot
            )
        ], scanID: 1)
        let inventorySaved = await store.upsertPlayablePaths(
            [episodePath, unmatchedPath],
            scanID: 1
        )
        XCTAssertTrue(inventorySaved)
        await completeScan(store, directories: [showRoot])

        let projected = await store.browseItems([folder(showRoot)])

        let live = folder(showRoot)
        var expected = live
        let seriesID = ShareCatalogID.series("animanimals")
        expected.artworkLookupSubject = try XCTUnwrap(ArtworkLookupSubject(catalog: MediaItem(
            id: seriesID, title: "Animanimals", kind: .series, seriesID: seriesID
        )))
        XCTAssertEqual(projected, [expected])
        XCTAssertEqual(projected.first?.id, live.id)
        XCTAssertEqual(projected.first?.kind, .folder)
        XCTAssertEqual(projected.first?.fileBrowserContainerID, live.fileBrowserContainerID)
    }

    private final class BrowseSQLWork {
        var steps = 0
    }

    func testFolderPromotionKeepsIndependentlyOwnedCollectionsReachable() async throws {
        for isCollection in [false, true] {
            let store = ShareCatalogStore(accountKey: "extra-owner", directory: try catalogDirectory())
            let showRoot = "TV Shows/Animanimals"
            let ownerPath = isCollection ? "\(showRoot)/Collections/Clips" : showRoot
            let extraPath = "\(ownerPath)/featurettes/Interview.mkv"
            await store.upsert([
                episode(
                    "\(showRoot)/Animanimals.S01E01.mkv",
                    series: "Animanimals",
                    season: 1,
                    number: 1,
                    metadataRoot: showRoot
                )
            ], scanID: 1)
            await store.upsertExtras([
                CatalogExtraCandidate(
                    relPath: extraPath,
                    parentDir: "\(ownerPath)/featurettes",
                    basename: "Interview.mkv",
                    size: 1_000,
                    modifiedAt: Date(),
                    kind: .featurette,
                    title: "Interview",
                    ownerPath: ownerPath
                )
            ], scanID: 1)
            await store.resolveExtraOwners()
            let extras = await store.extras(
                ownerID: isCollection ? "d:\(ownerPath)" : ShareCatalogID.series("animanimals")
            )
            XCTAssertEqual(extras.count, 1)
            await completeScan(store, directories: [showRoot])

            let projected = await store.browseItems([folder(showRoot)])
            XCTAssertEqual(projected.count, 1)
            XCTAssertEqual(projected.first?.kind, isCollection ? .folder : .series)
        }
    }

    func testUnchangedIncrementalSkipRetainsCompletedFolderPromotion() async throws {
        let store = ShareCatalogStore(accountKey: "incremental-folder", directory: try catalogDirectory())
        let showRoot = "TV Shows/Animanimals"
        await store.upsert([
            episode(
                "\(showRoot)/Animanimals.S01E01.mkv",
                series: "Animanimals",
                season: 1,
                number: 1,
                metadataRoot: showRoot
            )
        ], scanID: 1)
        await completeScan(store, directories: [showRoot], scanID: 1)
        let baseline = await store.browseItems([folder(showRoot)])
        XCTAssertEqual(baseline.first?.kind, .series)

        await store.invalidateCompletedDirectoryState()
        await store.touchDirectoryContents(relPaths: [showRoot], scanID: 2)
        let duringScan = await store.browseItems([folder(showRoot)])
        XCTAssertEqual(duringScan, baseline)

        let inventoryFinalized = await store.finalizePlayableInventory(inScan: 2)
        XCTAssertTrue(inventoryFinalized)
        await store.markDirectoryStateComplete(scanID: 2)
        let afterSkip = await store.browseItems([folder(showRoot)])
        let recordedDirectories = await store.recordedDirectoryPaths()
        XCTAssertEqual(afterSkip.map(\.id), [
            ShareCatalogID.series("animanimals"),
        ])
        XCTAssertEqual(afterSkip.first?.kind, .series)
        XCTAssertTrue(recordedDirectories.contains(showRoot))
    }

    func testDetailFileBrowserRoutesResolveShowSeasonMovieAndFileParents() async throws {
        let store = ShareCatalogStore(accountKey: "detail-files", directory: try catalogDirectory())
        let showRoot = "TV 100%_O'Brien/Animanimals"
        let episodePath = "\(showRoot)/Season 01/E01.mkv"
        let movieRoot = "Movies/Arrival (2016)"
        let moviePath = "\(movieRoot)/Arrival.2016.mkv"
        await store.upsert([
            episode(episodePath, series: "Animanimals", season: 1, number: 1, metadataRoot: showRoot),
            movie(moviePath, title: "Arrival", year: 2016),
            movie("Akira (1988).mkv", title: "Akira", year: 1988),
        ], scanID: 1)
        let routes = [
            (ShareCatalogID.series("animanimals"), "share:files:d:\(showRoot)"),
            (ShareCatalogID.season("animanimals", 1), "share:files:d:\(showRoot)/Season 01"),
            (ShareCatalogID.file(episodePath), "share:files:d:\(showRoot)/Season 01"),
            (ShareCatalogID.movie("arrival-2016"), "share:files:d:\(movieRoot)"),
            (ShareCatalogID.file(moviePath), "share:files:d:\(movieRoot)"),
            (ShareCatalogID.movie("akira-1988"), "share:files:share:root"),
        ]
        for (id, expected) in routes {
            let item = await store.item(id: id)
            XCTAssertEqual(item?.fileBrowserContainerID, expected, id)
        }

        await store.invalidateCompletedDirectoryState()
        let duringScan = await store.item(id: ShareCatalogID.series("animanimals"))
        XCTAssertEqual(duringScan?.fileBrowserContainerID, "share:files:d:\(showRoot)")
    }

    func testDetailFileBrowserIncludesAllPhysicalCopiesOfSeries() async throws {
        let store = ShareCatalogStore(accountKey: "multiple-show-roots", directory: try catalogDirectory())
        await store.upsert([
            episode("TV/Current/Animanimals/E01.mkv", series: "Animanimals", season: 1,
                    number: 1, metadataRoot: "TV/Current/Animanimals"),
            episode("TV/Archive/Animanimals/E02.mkv", series: "Animanimals", season: 1,
                    number: 2, metadataRoot: "TV/Archive/Animanimals"),
        ], scanID: 1)
        let series = await store.item(id: ShareCatalogID.series("animanimals"))
        XCTAssertEqual(series?.fileBrowserContainerID, "share:files:d:TV")
    }

    func testIndexedEpisodeKeepsFileWatchIdentity() async throws {
        let store = ShareCatalogStore(accountKey: "episode-file", directory: try catalogDirectory())
        let showRoot = "TV Shows/Animanimals"
        let path = "\(showRoot)/Season 01/E01.mkv"
        await store.upsert([
            episode(
                path,
                series: "Animanimals",
                season: 1,
                number: 1,
                metadataRoot: showRoot
            )
        ], scanID: 1)

        let projected = await store.browseItems([file(path)])

        XCTAssertEqual(projected.first?.id, ShareCatalogID.file(path))
        XCTAssertEqual(projected.first?.kind, .episode)
        XCTAssertEqual(projected.first?.seriesID, ShareCatalogID.series("animanimals"))
        XCTAssertEqual(projected.first?.seasonID, ShareCatalogID.season("animanimals", 1))
    }

    func testProjectionPreservesLiveWatchAndSourceState() async throws {
        let store = ShareCatalogStore(accountKey: "state", directory: try catalogDirectory())
        let path = "Movies/Dune (2021)/Dune.mkv"
        await store.upsert([movie(path, title: "Dune", year: 2021)], scanID: 1)
        let live = MediaItem(
            id: ShareCatalogID.file(path),
            title: "Dune.mkv",
            kind: .video,
            resumePosition: 321,
            playedPercentage: 0.4,
            isPlayed: true,
            sourceAccountID: "share-account",
            additionalSourceAccountIDs: ["backup-account"],
            lastPlayedAt: Date(timeIntervalSince1970: 123)
        )

        let items = await store.browseItems([live])
        guard let projected = items.first else {
            return XCTFail("expected projected catalog item")
        }

        XCTAssertEqual(projected.id, ShareCatalogID.movie("dune-2021"))
        XCTAssertEqual(projected.resumePosition, 321)
        XCTAssertEqual(projected.playedPercentage, 0.4)
        XCTAssertTrue(projected.isPlayed)
        XCTAssertEqual(projected.sourceAccountID, "share-account")
        XCTAssertEqual(projected.additionalSourceAccountIDs, ["backup-account"])
        XCTAssertEqual(projected.lastPlayedAt, Date(timeIntervalSince1970: 123))
    }

    func testSpecialPathCharactersRemainExactlyScoped() async throws {
        let store = ShareCatalogStore(accountKey: "special-paths", directory: try catalogDirectory())
        let showRoot = "TV_%/O'Brien [tvdb-42]"
        await store.upsert([
            episode(
                "\(showRoot)/Season 01/E01.mkv",
                series: "O'Brien",
                season: 1,
                number: 1,
                metadataRoot: showRoot
            ),
            episode(
                "TV_AX/O'Brien [tvdb-42]/Season 01/E02.mkv",
                series: "O'Brien",
                season: 1,
                number: 2,
                metadataRoot: "TV_AX/O'Brien [tvdb-42]"
            ),
        ], scanID: 1)
        await completeScan(store, directories: [showRoot])

        let projected = await store.browseItems([folder(showRoot)])

        XCTAssertEqual(projected.map(\.id), [
            ShareCatalogID.series("obrien"),
        ])
        XCTAssertEqual(projected.first?.kind, .series)
    }
}
