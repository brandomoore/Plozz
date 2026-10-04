import XCTest
@testable import ProviderShare
import CoreModels
import CoreNetworking
import MediaTransportCore

/// Batch 12 (E5 valid portion + E7) coverage. Proves `ShareProvider` is a thin
/// facade over injected capabilities: catalog reads flow through
/// `any ShareCatalogReading`, watch-state through `ShareWatchStateService`, and
/// rescan/activity through `any ShareCatalogCoordinating` — with no dependency on
/// the concrete `ShareCatalogStore`. Also exercises the extracted watch-state
/// service directly, and a source-inspection gate confirming the facade never
/// names the concrete store.
final class ShareProviderCapabilityTests: XCTestCase {

    // MARK: Fakes

    /// Fake read-only catalog capability. Every method is answered from injected
    /// values; there is no SQLite store behind it.
    private final class FakeCatalogReader: ShareCatalogReading, @unchecked Sendable {
        var latestItems: [MediaItem] = []
        var searchItems: [MediaItem] = []
        var movieItems: [MediaItem] = []
        var seriesItems: [MediaItem] = []
        var animeSeriesCount = 0
        var indexedItem: [String: MediaItem] = [:]
        var canonicalMap: [String: String] = [:]
        var aliasMap: [String: String] = [:]
        var defaultMoviePaths: [String: String] = [:]
        var browseInputs: [[String]] = []
        var browseResult: [MediaItem]?
        var sortedMovieItems: [SortField: [MediaItem]] = [:]
        var movieSortRequests: [CoreModels.SortDescriptor] = []
        var sortedSeriesItems: [SortField: [MediaItem]] = [:]
        var seriesSortRequests: [CoreModels.SortDescriptor] = []

        func libraryCounts() async -> (movies: Int, tvSeries: Int, animeSeries: Int) {
            (movieItems.count, seriesItems.count, animeSeriesCount)
        }
        func latest(limit: Int) async -> [MediaItem] { Array(latestItems.prefix(limit)) }
        func search(query: String, limit: Int) async -> [MediaItem] { Array(searchItems.prefix(limit)) }
        func movies(offset: Int, limit: Int) async -> [MediaItem] {
            Self.page(movieItems, offset: offset, limit: limit)
        }
        func movies(
            offset: Int,
            limit: Int,
            sort: CoreModels.SortDescriptor
        ) async -> [MediaItem] {
            movieSortRequests.append(sort)
            return Self.page(
                sortedMovieItems[sort.field] ?? movieItems,
                offset: offset,
                limit: limit
            )
        }
        func series(in library: CatalogLibrary, offset: Int, limit: Int) async -> [MediaItem] {
            Self.page(seriesItems, offset: offset, limit: limit)
        }
        func series(
            in library: CatalogLibrary,
            offset: Int,
            limit: Int,
            sort: CoreModels.SortDescriptor
        ) async -> [MediaItem] {
            seriesSortRequests.append(sort)
            return Self.page(
                sortedSeriesItems[sort.field] ?? seriesItems,
                offset: offset,
                limit: limit
            )
        }
        func movieCount() async -> Int { movieItems.count }
        func seriesCount(in library: CatalogLibrary) async -> Int { seriesItems.count }
        func seasons(seriesKey: String) async -> [MediaItem] { [] }
        func episodes(seriesKey: String, season: Int) async -> [MediaItem] { [] }
        func episodeWatchIdentities(
            seriesKey: String
        ) async -> [(season: Int, logicalKey: String, fileID: String)] { [] }
        func item(id: String) async -> MediaItem? { indexedItem[id] }
        func defaultMovieRelPath(forKey key: String) async -> String? {
            defaultMoviePaths[key]
        }
        func canonicalItemID(_ id: String) async -> String { canonicalMap[id] ?? id }
        func watchStateAliases(for itemIDs: [String]) async -> [String: String] {
            var result: [String: String] = [:]
            for id in itemIDs { result[id] = aliasMap[id] ?? id }
            return result
        }
        func containsFileAsset(id: String) async -> Bool { false }
        func browseItems(_ items: [MediaItem]) async -> [MediaItem] {
            browseInputs.append(items.map(\.id))
            return browseResult ?? items
        }

        private static func page(
            _ items: [MediaItem],
            offset: Int,
            limit: Int
        ) -> [MediaItem] {
            let start = min(offset, items.count)
            return Array(items[start..<min(start + limit, items.count)])
        }
    }

    /// Fake coordinating capability. Records rescan/enrich/activity calls and vends
    /// a supplied reader — no concrete `ShareCatalogCoordinator`/store is created.
    private final class FakeCatalogCoordinator: ShareCatalogCoordinating, @unchecked Sendable {
        let reader: FakeCatalogReader
        private(set) var catalogReaderRequests: [String] = []
        private(set) var rescans: [String] = []
        private(set) var enrichCalls: [String] = []
        private(set) var activityCalls: [String] = []

        init(reader: FakeCatalogReader) { self.reader = reader }

        func catalogReader(
            accountKey: String,
            displayName: String,
            credentialRevision: CredentialRevision,
            libraryConfiguration: MediaShareLibraryConfiguration?,
            sessionFactory: @escaping ShareTransportSessionFactory
        ) async -> any ShareCatalogReading {
            catalogReaderRequests.append(accountKey)
            return reader
        }
        func rescan(accountKey: String) async { rescans.append(accountKey) }
        func enrichItem(accountKey: String, itemID: String) async { enrichCalls.append(itemID) }
        func noteInteractiveActivity(accountKey: String) async { activityCalls.append(accountKey) }
    }

    private func makeSession(
        configuration: MediaShareLibraryConfiguration? = nil
    ) -> UserSession {
        let server = MediaServer(
            id: "share:nas.local/Media",
            name: "NAS",
            baseURL: URL(string: "smb://nas.local/Media")!,
            provider: .mediaShare,
            mediaShareLibraryConfiguration: configuration
        )
        return UserSession(
            server: server,
            userID: "guest",
            userName: "guest",
            deviceID: "test-device",
            accessToken: ""
        )
    }

    func testExplicitMovieConfigurationExposesNamedLibraryBeforeScan() async throws {
        let reader = FakeCatalogReader()
        let coordinator = FakeCatalogCoordinator(reader: reader)
        let provider = ShareProvider(
            session: makeSession(
                configuration: MediaShareLibraryConfiguration(
                    name: "Anime Films",
                    contentType: .movies,
                    isAnime: true
                )
            ),
            catalogCoordinator: coordinator
        )

        let libraries = try await provider.libraries()

        XCTAssertEqual(libraries.map(\.id), [ShareCatalogID.moviesLibrary])
        XCTAssertEqual(libraries.map(\.title), ["Anime Films"])
    }

    func testAnimeContentChoiceExposesBothFilmsAndAnimeSeries() async throws {
        let reader = FakeCatalogReader()
        reader.movieItems = [MediaItem(id: "anime-film", title: "Your Name", kind: .movie)]
        reader.animeSeriesCount = 1
        let provider = ShareProvider(
            session: makeSession(configuration: .init(name: "Anime", contentType: .anime)),
            catalogCoordinator: FakeCatalogCoordinator(reader: reader)
        )
        let libraries = try await provider.libraries()
        XCTAssertTrue(libraries.contains { $0.id == ShareCatalogID.moviesLibrary && $0.kind == .movie })
        XCTAssertTrue(libraries.contains { $0.id == ShareCatalogID.animeLibrary && $0.kind == .series })
        XCTAssertFalse(libraries.contains { $0.id == ShareCatalogID.tvLibrary })
    }

    func testAnimeWorkScopeRequiresAnEnabledMovieOrAnimeLibrary() {
        let configuration = MediaShareLibraryConfiguration(name: "Anime", contentType: .anime)
        let movies = "share:\(ShareCatalogID.moviesLibrary)"
        let anime = "share:\(ShareCatalogID.animeLibrary)"
        for disabled in [Set<String>(), [movies], [anime]] {
            XCTAssertTrue(ShareProvider.hasEnabledCatalogLibrary(
                accountID: "share", configuration: configuration,
                visibility: .init(disabledKeys: disabled)
            ))
        }
        XCTAssertFalse(ShareProvider.hasEnabledCatalogLibrary(
            accountID: "share", configuration: configuration,
            visibility: .init(disabledKeys: [movies, anime])
        ), "An enabled ordinary TV or raw-files entry must not keep an Anime root scanning.")
    }

    func testLegacyAutomaticShareKeepsSyntheticIDsAndDistinguishesRawBrowsing() async throws {
        let reader = FakeCatalogReader()
        reader.movieItems = [
            MediaItem(id: "movie:example", title: "Example", kind: .movie),
        ]
        let provider = ShareProvider(
            session: makeSession(),
            catalogCoordinator: FakeCatalogCoordinator(reader: reader)
        )

        let libraries = try await provider.libraries()

        XCTAssertEqual(libraries.map(\.id), [
            ShareCatalogID.moviesLibrary,
            ShareLibraryStore.rootLibraryID,
        ])
        XCTAssertEqual(libraries.map(\.title), [
            "Movies",
            "Browse Files — NAS",
        ])
        XCTAssertEqual(libraries.last?.synthesizedName, .browseFiles)
    }

    func testPersonalVideosExposeOnlyNamedRawLibrary() async throws {
        let coordinator = FakeCatalogCoordinator(reader: FakeCatalogReader())
        let provider = ShareProvider(
            session: makeSession(
                configuration: MediaShareLibraryConfiguration(
                    name: "Family Videos",
                    contentType: .personalVideos
                )
            ),
            catalogCoordinator: coordinator
        )

        let libraries = try await provider.libraries()

        XCTAssertEqual(libraries.map(\.id), [ShareLibraryStore.rootLibraryID])
        XCTAssertEqual(libraries.map(\.title), ["Family Videos"])
        XCTAssertEqual(libraries.map(\.synthesizedName), [nil])
        XCTAssertEqual(coordinator.catalogReaderRequests, ["share:nas.local/Media"])
    }

    func testFileBrowsingCapabilityExposesMediaAwareRootWithoutProviderKnowledge() {
        let provider = ShareProvider(
            session: makeSession(
                configuration: MediaShareLibraryConfiguration(
                    name: "Anime Films",
                    contentType: .movies,
                    isAnime: true
                )
            ),
            catalogCoordinator: FakeCatalogCoordinator(reader: FakeCatalogReader())
        )
        let capability: any MediaFileBrowsing = provider

        XCTAssertEqual(capability.fileBrowserLibrary.id, ShareLibraryStore.rootLibraryID)
        XCTAssertEqual(capability.fileBrowserLibrary.title, "Browse Files — Anime Films")
        XCTAssertEqual(capability.fileBrowserLibrary.kind, .folder)
        XCTAssertEqual(capability.fileBrowserLibrary.synthesizedName, .browseFiles)
    }

    func testMainBrowseFilesThroughMoviesOpensCatalogTitlesButDetailFilesStayRaw() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        let titles = [("Arrival", 2016), ("Alien", 1979)]
        var directories: [String: [RemoteFileEntry]] = ["Movies": []]
        var assets: [CatalogAsset] = []
        for (title, year) in titles {
            let root = "Movies/\(title) (\(year))"
            directories["Movies", default: []].append(
                try RemoteFileEntry(relativePath: root, kind: .directory)
            )
            for quality in ["1080p", "2160p"] {
                let name = "\(title).\(year).\(quality).mkv"
                directories[root, default: []].append(
                    try RemoteFileEntry(relativePath: "\(root)/\(name)", kind: .file)
                )
                assets.append(CatalogAsset(
                    relPath: "\(root)/\(name)", basename: name,
                    size: 1_000, modifiedAt: Date(), kind: .movie, library: .movies,
                    title: title, year: year, seriesTitle: nil, seriesKey: nil,
                    season: nil, episode: nil,
                    movieKey: ShareCatalogID.movieKey(fromTitle: title, year: year),
                    movieTitleKey: ShareCatalogID.movieKey(fromTitle: title, year: nil)
                ))
            }
        }
        await store.upsert(assets, scanID: 1)
        var metadata = EnrichmentRecord()
        metadata.posterURL = URL(string: "https://example.com/arrival.jpg")
        let saved = await store.saveEnrichment(
            itemID: "f:Movies/Arrival (2016)/Arrival.2016.1080p.mkv",
            metadata, version: 18
        )
        XCTAssertTrue(saved)
        await store.invalidateCompletedDirectoryState()

        let fileSystem = CapabilityFakeFileSystem(
            entries: [try RemoteFileEntry(relativePath: "Movies", kind: .directory)],
            directories: directories
        )
        let provider = ShareProvider(
            session: makeSession(),
            sessionFactory: { role in
                try CapabilityFakeSession(fileSystem: fileSystem, role: role)
            },
            catalogCoordinator: FakeCatalogCoordinator(reader: FakeCatalogReader()),
            catalogStore: store
        )
        let browser: any MediaFileBrowsing = provider
        let rootPage = try await provider.items(
            in: browser.fileBrowserLibrary.id, kind: .folder, page: PageRequest(limit: 20)
        )
        let moviesFolder = try XCTUnwrap(rootPage.items.first)
        XCTAssertEqual(moviesFolder.id, "d:Movies")
        XCTAssertEqual(moviesFolder.kind, .folder)

        let moviesPage = try await provider.items(
            in: moviesFolder.id, kind: .folder, page: PageRequest(limit: 20)
        )
        XCTAssertEqual(Set(moviesPage.items.map(\.id)), ["movie:arrival-2016", "movie:alien-1979"])
        XCTAssertTrue(moviesPage.items.allSatisfy { $0.kind == .movie && $0.versions.count == 2 })
        let arrival = try XCTUnwrap(moviesPage.items.first { $0.id == "movie:arrival-2016" })
        XCTAssertEqual(arrival.posterURL, metadata.posterURL)
        let detail = try await provider.item(id: arrival.id)
        XCTAssertEqual(detail.kind, .movie)
        let rawID = try XCTUnwrap(detail.fileBrowserContainerID)
        XCTAssertEqual(rawID, "share:files:d:Movies/Arrival (2016)")

        let filesPage = try await provider.items(
            in: rawID, kind: .folder, page: PageRequest(limit: 20)
        )
        XCTAssertEqual(Set(filesPage.items.map(\.title)), ["Arrival.2016.1080p.mkv", "Arrival.2016.2160p.mkv"])
        XCTAssertTrue(filesPage.items.allSatisfy { $0.kind == .video && $0.id.hasPrefix("f:") })
    }

    func testMediaAwareBrowserSortsFoldersAlongsideMoviesButRawBrowserKeepsFoldersFirst() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        let moviePath = "Movies/Arrival (2016)/Arrival.2016.mkv"
        await store.upsert([CatalogAsset(
            relPath: moviePath, basename: "Arrival.2016.mkv",
            size: 1_000, modifiedAt: Date(), kind: .movie, library: .movies,
            title: "Arrival", year: 2016, seriesTitle: nil, seriesKey: nil,
            season: nil, episode: nil, movieKey: "arrival-2016", movieTitleKey: "arrival"
        )], scanID: 1)
        let fileSystem = CapabilityFakeFileSystem(entries: [], directories: [
            "Movies": [
                try RemoteFileEntry(relativePath: "Movies/Unsorted", kind: .directory),
                try RemoteFileEntry(relativePath: "Movies/Beginning.mp4", kind: .file),
                try RemoteFileEntry(relativePath: "Movies/Arrival (2016)", kind: .directory),
            ]
        ])
        let provider = ShareProvider(
            session: makeSession(),
            sessionFactory: { role in
                try CapabilityFakeSession(fileSystem: fileSystem, role: role)
            },
            catalogCoordinator: FakeCatalogCoordinator(reader: FakeCatalogReader()),
            catalogStore: store
        )

        let mediaPage = try await provider.items(
            in: "d:Movies", kind: .folder, page: PageRequest(limit: 20)
        )
        XCTAssertEqual(
            mediaPage.items.map(\.id),
            ["movie:arrival-2016", "f:Movies/Beginning.mp4", "d:Movies/Unsorted"]
        )
        let descendingPage = try await provider.items(
            in: "d:Movies", kind: .folder,
            page: PageRequest(limit: 20, sort: .init(field: .name, direction: .descending))
        )
        XCTAssertEqual(
            descendingPage.items.map(\.id),
            ["d:Movies/Unsorted", "f:Movies/Beginning.mp4", "movie:arrival-2016"]
        )

        let rawPage = try await provider.items(
            in: "share:files:d:Movies", kind: .folder, page: PageRequest(limit: 20)
        )
        XCTAssertEqual(
            rawPage.items.map(\.id),
            ["share:files:d:Movies/Arrival (2016)", "share:files:d:Movies/Unsorted", "f:Movies/Beginning.mp4"]
        )
    }

    func testShareAdvertisesOnlySortsItsContainerCanHonor() {
        let personalProvider = ShareProvider(
            session: makeSession(
                configuration: MediaShareLibraryConfiguration(
                    name: "Family Videos",
                    contentType: .personalVideos
                )
            ),
            catalogCoordinator: FakeCatalogCoordinator(reader: FakeCatalogReader())
        )
        let capability: any MediaSortFieldProviding = personalProvider

        XCTAssertEqual(
            capability.supportedSortFields(
                in: ShareLibraryStore.rootLibraryID,
                kind: .folder
            ),
            [.name, .dateAdded, .random]
        )
        XCTAssertEqual(
            personalProvider.supportedSortFields(
                in: ShareCatalogID.moviesLibrary,
                kind: .movie
            ),
            [.name, .dateAdded, .random]
        )
    }

    func testIndexedLibraryHonorsDescendingNamePaging() async throws {
        let reader = FakeCatalogReader()
        reader.movieItems = [
            MediaItem(id: "movie:a", title: "Alpha", kind: .movie),
            MediaItem(id: "movie:b", title: "Beta", kind: .movie),
            MediaItem(id: "movie:c", title: "Charlie", kind: .movie),
        ]
        reader.sortedMovieItems[.name] = Array(reader.movieItems.reversed())
        let provider = ShareProvider(
            session: makeSession(),
            catalogCoordinator: FakeCatalogCoordinator(reader: reader)
        )

        let page = try await provider.items(
            in: ShareCatalogID.moviesLibrary,
            kind: .movie,
            page: PageRequest(
                startIndex: 1,
                limit: 1,
                sort: CoreModels.SortDescriptor(field: .name, direction: .descending)
            )
        )

        XCTAssertEqual(page.items.map(\.id), ["movie:b"])
        XCTAssertEqual(page.startIndex, 1)
        XCTAssertEqual(page.totalCount, 3)
        XCTAssertEqual(
            reader.movieSortRequests,
            [CoreModels.SortDescriptor(field: .name, direction: .descending)]
        )
    }

    func testIndexedLibrarySortsByRuntimeBeforePaging() async throws {
        let reader = FakeCatalogReader()
        reader.movieItems = [
            MediaItem(id: "movie:long", title: "Long", kind: .movie, runtime: 7_200),
            MediaItem(id: "movie:short", title: "Short", kind: .movie, runtime: 3_600),
        ]
        reader.sortedMovieItems[.runtime] = [
            reader.movieItems[1],
            reader.movieItems[0],
        ]
        let provider = ShareProvider(
            session: makeSession(),
            catalogCoordinator: FakeCatalogCoordinator(reader: reader)
        )

        let page = try await provider.items(
            in: ShareCatalogID.moviesLibrary,
            kind: .movie,
            page: PageRequest(
                limit: 1,
                sort: CoreModels.SortDescriptor(field: .runtime, direction: .ascending)
            )
        )

        XCTAssertEqual(page.items.map(\.id), ["movie:short"])
        XCTAssertEqual(page.totalCount, 2)
        XCTAssertEqual(
            reader.movieSortRequests,
            [CoreModels.SortDescriptor(field: .runtime, direction: .ascending)]
        )
    }

    func testIndexedLibraryUsesCatalogDiscoveryOrderForDateAdded() async throws {
        let reader = FakeCatalogReader()
        reader.movieItems = [
            MediaItem(id: "movie:old", title: "Old", kind: .movie),
            MediaItem(id: "movie:new", title: "New", kind: .movie),
        ]
        reader.latestItems = [
            MediaItem(
                id: "movie:new",
                title: "New",
                kind: .movie,
                libraryID: ShareCatalogID.moviesLibrary
            ),
            MediaItem(
                id: "movie:old",
                title: "Old",
                kind: .movie,
                libraryID: ShareCatalogID.moviesLibrary
            ),
        ]
        reader.sortedMovieItems[.dateAdded] = reader.latestItems
        let provider = ShareProvider(
            session: makeSession(),
            catalogCoordinator: FakeCatalogCoordinator(reader: reader)
        )

        let page = try await provider.items(
            in: ShareCatalogID.moviesLibrary,
            kind: .movie,
            page: PageRequest(
                limit: 2,
                sort: CoreModels.SortDescriptor(field: .dateAdded, direction: .descending)
            )
        )

        XCTAssertEqual(page.items.map(\.id), ["movie:new", "movie:old"])
        XCTAssertEqual(
            reader.movieSortRequests,
            [CoreModels.SortDescriptor(field: .dateAdded, direction: .descending)]
        )
    }

    func testIndexedSeriesForwardsSortDescriptorToCatalog() async throws {
        let reader = FakeCatalogReader()
        reader.seriesItems = [
            MediaItem(
                id: "series:short",
                title: "Short",
                kind: .series,
                runtime: 1_800
            ),
            MediaItem(
                id: "series:long",
                title: "Long",
                kind: .series,
                runtime: 3_600
            ),
        ]
        reader.sortedSeriesItems[.runtime] = Array(reader.seriesItems.reversed())
        let provider = ShareProvider(
            session: makeSession(),
            catalogCoordinator: FakeCatalogCoordinator(reader: reader)
        )
        let sort = CoreModels.SortDescriptor(field: .runtime, direction: .descending)

        let page = try await provider.items(
            in: ShareCatalogID.tvLibrary,
            kind: .series,
            page: PageRequest(limit: 1, sort: sort)
        )

        XCTAssertEqual(page.items.map(\.id), ["series:long"])
        XCTAssertEqual(reader.seriesSortRequests, [sort])
    }

    func testMediaAwareBrowseProjectsWholeDirectoryBeforeSortingAndPaging() async throws {
        let reader = FakeCatalogReader()
        reader.browseResult = [
            MediaItem(id: "series:projected", title: "Projected", kind: .series),
            MediaItem(id: "f:a.mkv", title: "A", kind: .movie),
            MediaItem(id: "d:Folder", title: "Folder", kind: .folder),
        ]
        let coordinator = FakeCatalogCoordinator(reader: reader)
        let fileSystem = CapabilityFakeFileSystem(entries: [
            try RemoteFileEntry(relativePath: "Folder", kind: .directory),
            try RemoteFileEntry(relativePath: "A.mkv", kind: .file),
            try RemoteFileEntry(relativePath: "B.mkv", kind: .file),
        ])
        let provider = ShareProvider(
            session: makeSession(),
            sessionFactory: { role in
                try CapabilityFakeSession(fileSystem: fileSystem, role: role)
            },
            catalogCoordinator: coordinator
        )

        let page = try await provider.items(
            in: ShareLibraryStore.rootLibraryID,
            kind: .folder,
            page: PageRequest(startIndex: 1, limit: 1)
        )

        XCTAssertEqual(reader.browseInputs, [[
            "d:Folder",
            "f:A.mkv",
            "f:B.mkv",
        ]])
        XCTAssertEqual(page.items.map(\.id), ["d:Folder"])
        XCTAssertEqual(page.totalCount, 3)
    }

    func testExplicitFileBrowserKeepsNestedFoldersAndEveryOriginalFile() async throws {
        let reader = FakeCatalogReader()
        reader.browseResult = [MediaItem(id: "series:wrong-route", title: "Show", kind: .series)]
        let directory = "TV 100%_O'Brien/Animanimals"
        let fileSystem = CapabilityFakeFileSystem(entries: [], directories: [
            directory: [
                try RemoteFileEntry(relativePath: "Season 01", kind: .directory),
                try RemoteFileEntry(relativePath: "unknown.mp4", kind: .file),
            ],
            "\(directory)/Season 01": [
                try RemoteFileEntry(relativePath: "E01.1080p.mkv", kind: .file),
                try RemoteFileEntry(relativePath: "E01.2160p.mkv", kind: .file),
            ],
        ])
        let provider = ShareProvider(
            session: makeSession(),
            sessionFactory: { role in
                try CapabilityFakeSession(fileSystem: fileSystem, role: role)
            },
            catalogCoordinator: FakeCatalogCoordinator(reader: reader)
        )
        let rootID = ShareCatalogID.fileBrowserID(for: "d:\(directory)")
        let root = try await provider.item(id: rootID)
        XCTAssertEqual(root.id, rootID)
        XCTAssertEqual(root.kind, .folder)
        let page = try await provider.items(
            in: rootID, kind: .folder, page: PageRequest(limit: 10)
        )
        XCTAssertEqual(page.items.map(\.id), [
            "share:files:d:\(directory)/Season 01", "f:\(directory)/unknown.mp4",
        ])
        XCTAssertEqual(page.items.map(\.kind), [.folder, .video])
        XCTAssertEqual(page.items.last?.title, "unknown.mp4")

        let seasonID = try XCTUnwrap(page.items.first?.id)
        let files = try await provider.children(of: seasonID)
        XCTAssertEqual(Set(files.map(\.id)), [
            "f:\(directory)/Season 01/E01.1080p.mkv",
            "f:\(directory)/Season 01/E01.2160p.mkv",
        ])
        XCTAssertEqual(Set(files.map(\.title)), ["E01.1080p.mkv", "E01.2160p.mkv"])
        XCTAssertTrue(files.allSatisfy { $0.kind == .video && !$0.allowsTitleBasedMetadataMatching })
        XCTAssertTrue(reader.browseInputs.isEmpty, "explicit file browsing must not loop back to catalog details")
        XCTAssertEqual(provider.supportedSortFields(in: rootID, kind: .folder), [.name, .dateAdded, .random])

        let firstPage = try await provider.items(
            in: seasonID, kind: .folder, page: PageRequest(limit: 1)
        )
        let secondPage = try await provider.items(
            in: seasonID, kind: .folder, page: PageRequest(startIndex: 1, limit: 1)
        )
        XCTAssertEqual(firstPage.totalCount, 2)
        XCTAssertEqual(secondPage.totalCount, 2)
        XCTAssertNotEqual(firstPage.items.first?.id, secondPage.items.first?.id)
    }

    func testRawBrowseHonorsNameSortWhileKeepingFoldersFirst() async throws {
        let fileSystem = CapabilityFakeFileSystem(entries: [
            try RemoteFileEntry(relativePath: "Middle", kind: .directory),
            try RemoteFileEntry(relativePath: "Alpha.mkv", kind: .file),
            try RemoteFileEntry(relativePath: "Zulu.mkv", kind: .file),
        ])
        let provider = ShareProvider(
            session: makeSession(
                configuration: MediaShareLibraryConfiguration(
                    name: "Family Videos",
                    contentType: .personalVideos
                )
            ),
            sessionFactory: { role in
                try CapabilityFakeSession(fileSystem: fileSystem, role: role)
            },
            catalogCoordinator: FakeCatalogCoordinator(reader: FakeCatalogReader())
        )

        let page = try await provider.items(
            in: ShareLibraryStore.rootLibraryID,
            kind: .folder,
            page: PageRequest(
                limit: 10,
                sort: CoreModels.SortDescriptor(field: .name, direction: .descending)
            )
        )

        XCTAssertEqual(page.items.map(\.id), [
            "d:Middle",
            "f:Zulu.mkv",
            "f:Alpha.mkv",
        ])
    }

    func testRawBrowseHonorsFilesystemDateSort() async throws {
        let fileSystem = CapabilityFakeFileSystem(entries: [
            try RemoteFileEntry(
                relativePath: "Older.mkv",
                kind: .file,
                modifiedAt: Date(timeIntervalSince1970: 100)
            ),
            try RemoteFileEntry(
                relativePath: "Newer.mkv",
                kind: .file,
                modifiedAt: Date(timeIntervalSince1970: 200)
            ),
        ])
        let provider = ShareProvider(
            session: makeSession(
                configuration: MediaShareLibraryConfiguration(
                    name: "Family Videos",
                    contentType: .personalVideos
                )
            ),
            sessionFactory: { role in
                try CapabilityFakeSession(fileSystem: fileSystem, role: role)
            },
            catalogCoordinator: FakeCatalogCoordinator(reader: FakeCatalogReader())
        )

        let page = try await provider.items(
            in: ShareLibraryStore.rootLibraryID,
            kind: .folder,
            page: PageRequest(
                limit: 10,
                sort: CoreModels.SortDescriptor(field: .dateAdded, direction: .descending)
            )
        )

        XCTAssertEqual(page.items.map(\.id), [
            "f:Newer.mkv",
            "f:Older.mkv",
        ])
    }

    func testMediaAwareDateSortCombinesMovieFoldersAndLooseFilesBeforePaging() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        let paths = ["Movies/Older (2000)/Older.mkv", "Movies/Newer (2001).mkv", "Movies/Oldest (1999).mkv"]
        await store.upsert(zip(paths, [("Older", 2000), ("Newer", 2001), ("Oldest", 1999)]).map { path, identity in
            CatalogAsset(
                relPath: path, basename: (path as NSString).lastPathComponent,
                size: 1_000, modifiedAt: Date(), kind: .movie, library: .movies,
                title: identity.0, year: identity.1, seriesTitle: nil, seriesKey: nil,
                season: nil, episode: nil,
                movieKey: ShareCatalogID.movieKey(fromTitle: identity.0, year: identity.1),
                movieTitleKey: ShareCatalogID.movieKey(fromTitle: identity.0, year: nil)
            )
        }, scanID: 1)
        let fileSystem = CapabilityFakeFileSystem(entries: [], directories: [
            "Movies": [
                try RemoteFileEntry(relativePath: "Movies/Undated.mp4", kind: .file),
                try RemoteFileEntry(
                    relativePath: "Movies/Older (2000)", kind: .directory,
                    modifiedAt: Date(timeIntervalSince1970: 900),
                    createdAt: Date(timeIntervalSince1970: 100)
                ),
                try RemoteFileEntry(
                    relativePath: "Movies/Newer (2001).mkv", kind: .file,
                    modifiedAt: Date(timeIntervalSince1970: 50),
                    createdAt: Date(timeIntervalSince1970: 300)
                ),
                try RemoteFileEntry(
                    relativePath: "Movies/Unsorted", kind: .directory,
                    modifiedAt: Date(timeIntervalSince1970: 200)
                ),
                try RemoteFileEntry(
                    relativePath: "Movies/Oldest (1999).mkv", kind: .file,
                    modifiedAt: Date(timeIntervalSince1970: 50)
                ),
            ]
        ])
        let provider = ShareProvider(
            session: makeSession(),
            sessionFactory: { role in
                try CapabilityFakeSession(fileSystem: fileSystem, role: role)
            },
            catalogCoordinator: FakeCatalogCoordinator(reader: FakeCatalogReader()),
            catalogStore: store
        )
        for (direction, expected) in [
            (SortDirection.ascending, ["movie:oldest-1999", "movie:older-2000", "d:Movies/Unsorted", "movie:newer-2001", "f:Movies/Undated.mp4"]),
            (.descending, ["movie:newer-2001", "d:Movies/Unsorted", "movie:older-2000", "movie:oldest-1999", "f:Movies/Undated.mp4"]),
        ] {
            var pagedIDs: [String] = []
            for offset in expected.indices {
                let page = try await provider.items(
                    in: "d:Movies", kind: .folder,
                    page: PageRequest(
                        startIndex: offset, limit: 1,
                        sort: .init(field: .dateAdded, direction: direction)
                    )
                )
                XCTAssertEqual(page.totalCount, expected.count)
                pagedIDs.append(contentsOf: page.items.map(\.id))
            }
            XCTAssertEqual(pagedIDs, expected)
        }
    }

    func testRawAndPersonalDateSortKeepFoldersBeforeFiles() async throws {
        let fileSystem = CapabilityFakeFileSystem(entries: [
            try RemoteFileEntry(
                relativePath: "Older", kind: .directory,
                modifiedAt: Date(timeIntervalSince1970: 100)
            ),
            try RemoteFileEntry(
                relativePath: "Newest.mkv", kind: .file,
                modifiedAt: Date(timeIntervalSince1970: 300)
            ),
            try RemoteFileEntry(
                relativePath: "Newer", kind: .directory,
                modifiedAt: Date(timeIntervalSince1970: 200)
            ),
            try RemoteFileEntry(relativePath: "Undated.mp4", kind: .file),
        ])
        for personal in [false, true] {
            let provider = ShareProvider(
                session: makeSession(configuration: personal
                    ? MediaShareLibraryConfiguration(name: "Personal", contentType: .personalVideos)
                    : nil),
                sessionFactory: { role in
                    try CapabilityFakeSession(fileSystem: fileSystem, role: role)
                },
                catalogCoordinator: FakeCatalogCoordinator(reader: FakeCatalogReader())
            )
            let folderPrefix = personal ? "d:" : "share:files:d:"
            for (direction, folders) in [
                (SortDirection.ascending, ["Older", "Newer"]),
                (.descending, ["Newer", "Older"]),
            ] {
                let page = try await provider.items(
                    in: personal ? ShareLibraryStore.rootLibraryID : "share:files:share:root",
                    kind: .folder,
                    page: PageRequest(limit: 10, sort: .init(field: .dateAdded, direction: direction))
                )
                XCTAssertEqual(
                    page.items.map(\.id),
                    folders.map { folderPrefix + $0 } + ["f:Newest.mkv", "f:Undated.mp4"]
                )
            }
        }
    }

    func testProjectedRawBrowseSortsByRuntimeBeforePaging() async throws {
        let reader = FakeCatalogReader()
        reader.browseResult = [
            MediaItem(id: "movie:long", title: "Long", kind: .movie, runtime: 7_200),
            MediaItem(id: "movie:short", title: "Short", kind: .movie, runtime: 3_600),
        ]
        let fileSystem = CapabilityFakeFileSystem(entries: [
            try RemoteFileEntry(relativePath: "Long.mkv", kind: .file),
            try RemoteFileEntry(relativePath: "Short.mkv", kind: .file),
        ])
        let provider = ShareProvider(
            session: makeSession(),
            sessionFactory: { role in
                try CapabilityFakeSession(fileSystem: fileSystem, role: role)
            },
            catalogCoordinator: FakeCatalogCoordinator(reader: reader)
        )

        let page = try await provider.items(
            in: ShareLibraryStore.rootLibraryID,
            kind: .folder,
            page: PageRequest(
                startIndex: 0,
                limit: 1,
                sort: CoreModels.SortDescriptor(field: .runtime, direction: .ascending)
            )
        )

        XCTAssertEqual(page.items.map(\.id), ["movie:short"])
        XCTAssertEqual(page.totalCount, 2)
    }

    func testRawReleaseSortUsesOneConsistentKeyForDatesAndYears() async throws {
        let items = [
            MediaItem(id: "a", title: "A", kind: .movie, productionYear: 2020),
            MediaItem(
                id: "b", title: "B", kind: .movie, productionYear: 2019,
                releaseDate: Date(timeIntervalSince1970: 1_609_459_200)
            ),
            MediaItem(
                id: "c", title: "C", kind: .movie, productionYear: 2021,
                releaseDate: Date(timeIntervalSince1970: 1_514_764_800)
            ),
            MediaItem(id: "d", title: "D", kind: .movie),
        ]
        let reader = FakeCatalogReader()
        let fileSystem = CapabilityFakeFileSystem(entries: try items.map {
            try RemoteFileEntry(relativePath: "\($0.title).mkv", kind: .file)
        })
        let provider = ShareProvider(
            session: makeSession(),
            sessionFactory: { role in
                try CapabilityFakeSession(fileSystem: fileSystem, role: role)
            },
            catalogCoordinator: FakeCatalogCoordinator(reader: reader)
        )

        for input in [items, Array(items.reversed())] {
            reader.browseResult = input
            for direction in SortDirection.allCases {
                let page = try await provider.items(
                    in: ShareLibraryStore.rootLibraryID,
                    kind: .folder,
                    page: PageRequest(
                        limit: 10,
                        sort: CoreModels.SortDescriptor(field: .releaseDate, direction: direction)
                    )
                )
                XCTAssertEqual(
                    page.items.map(\.id),
                    direction == .ascending ? ["c", "a", "b", "d"] : ["b", "a", "c", "d"]
                )
            }
        }
    }

    func testPersonalVideoRawBrowseBypassesCatalogProjection() async throws {
        let reader = FakeCatalogReader()
        reader.browseResult = [
            MediaItem(id: "movie:stale", title: "Stale Match", kind: .movie),
        ]
        let coordinator = FakeCatalogCoordinator(reader: reader)
        let fileSystem = CapabilityFakeFileSystem(entries: [
            try RemoteFileEntry(relativePath: "Birthday 2026.mkv", kind: .file),
        ])
        let provider = ShareProvider(
            session: makeSession(
                configuration: MediaShareLibraryConfiguration(
                    name: "Family Videos",
                    contentType: .personalVideos
                )
            ),
            sessionFactory: { role in
                try CapabilityFakeSession(fileSystem: fileSystem, role: role)
            },
            catalogCoordinator: coordinator
        )

        let items = try await provider.children(of: ShareLibraryStore.rootLibraryID)

        XCTAssertTrue(reader.browseInputs.isEmpty)
        XCTAssertEqual(items.map(\.id), ["f:Birthday 2026.mkv"])
        XCTAssertEqual(items.map(\.kind), [.video])
        XCTAssertEqual(items.map(\.allowsTitleBasedMetadataMatching), [false])
    }

    func testPersonalVideoItemIgnoresStaleCatalogMatch() async throws {
        let reader = FakeCatalogReader()
        reader.indexedItem["f:Birthday 2026.mkv"] = MediaItem(
            id: "f:Birthday 2026.mkv",
            title: "Birthday",
            kind: .movie
        )
        let fileSystem = CapabilityFakeFileSystem(entries: [])
        let provider = ShareProvider(
            session: makeSession(
                configuration: MediaShareLibraryConfiguration(
                    name: "Family Videos",
                    contentType: .personalVideos
                )
            ),
            sessionFactory: { role in
                try CapabilityFakeSession(fileSystem: fileSystem, role: role)
            },
            catalogCoordinator: FakeCatalogCoordinator(reader: reader)
        )

        let item = try await provider.item(id: "f:Birthday 2026.mkv")

        XCTAssertEqual(item.kind, .video)
        XCTAssertFalse(item.allowsTitleBasedMetadataMatching)
    }

    func testPersonalVideosDoNotExposePreviouslyOpenIndexedLibraries() async throws {
        let reader = FakeCatalogReader()
        reader.movieItems = [MediaItem(id: "movie:stale", title: "Stale Movie", kind: .movie)]
        reader.seriesItems = [MediaItem(id: "series:stale", title: "Stale Show", kind: .series)]
        let coordinator = FakeCatalogCoordinator(reader: reader)
        let provider = ShareProvider(
            session: makeSession(
                configuration: MediaShareLibraryConfiguration(
                    name: "Family Videos",
                    contentType: .personalVideos
                )
            ),
            catalogCoordinator: coordinator
        )

        for id in [
            ShareCatalogID.moviesLibrary, ShareCatalogID.tvLibrary, ShareCatalogID.animeLibrary,
            ShareCatalogID.series("stale"), ShareCatalogID.season("stale", 1),
        ] {
            let page = try await provider.items(
                in: id,
                kind: .folder,
                page: PageRequest(startIndex: 0, limit: 20)
            )
            XCTAssertTrue(page.items.isEmpty)
            XCTAssertEqual(page.totalCount, 0)
        }
        let children = try await provider.children(of: ShareCatalogID.series("stale"))
        XCTAssertTrue(children.isEmpty)
        XCTAssertTrue(coordinator.catalogReaderRequests.isEmpty)
    }

    func testRawFoldersDisableTitleBasedMetadataMatching() async throws {
        let fileSystem = CapabilityFakeFileSystem(entries: [
            try RemoteFileEntry(relativePath: "Avatar", kind: .directory),
        ])
        let provider = ShareProvider(
            session: makeSession(),
            sessionFactory: { role in
                try CapabilityFakeSession(fileSystem: fileSystem, role: role)
            },
            catalogCoordinator: FakeCatalogCoordinator(reader: FakeCatalogReader())
        )

        let items = try await provider.children(of: ShareLibraryStore.rootLibraryID)

        XCTAssertEqual(items.map(\.kind), [.folder])
        XCTAssertEqual(items.map(\.allowsTitleBasedMetadataMatching), [false])
    }

    func testUnmatchedFileInConfiguredTVRootRemainsReachableFromRawBrowse() async throws {
        let reader = FakeCatalogReader()
        let fileSystem = CapabilityFakeFileSystem(entries: [
            try RemoteFileEntry(relativePath: "Unmatched Home Video.mkv", kind: .file),
        ])
        let provider = ShareProvider(
            session: makeSession(
                configuration: MediaShareLibraryConfiguration(
                    name: "Television",
                    contentType: .tvShows
                )
            ),
            sessionFactory: { role in
                try CapabilityFakeSession(fileSystem: fileSystem, role: role)
            },
            catalogCoordinator: FakeCatalogCoordinator(reader: reader)
        )

        let items = try await provider.children(of: ShareLibraryStore.rootLibraryID)

        XCTAssertEqual(items.map(\.id), ["f:Unmatched Home Video.mkv"])
        XCTAssertEqual(items.map(\.kind), [.video])
    }

    // MARK: Provider-from-capabilities

    /// The provider resolves its catalog reads entirely through the injected
    /// coordinating capability's `catalogReader` — no concrete store constructed.
    func testProviderResolvesLatestThroughFakeCapability() async throws {
        let reader = FakeCatalogReader()
        reader.latestItems = [
            MediaItem(id: "f:a.mkv", title: "Alpha", kind: .movie),
            MediaItem(id: "f:b.mkv", title: "Beta", kind: .movie)
        ]
        let coordinator = FakeCatalogCoordinator(reader: reader)
        let provider = ShareProvider(
            session: makeSession(),
            catalogCoordinator: coordinator
        )

        let latest = try await provider.latest(limit: 10)

        XCTAssertEqual(latest.map(\.title), ["Alpha", "Beta"])
        XCTAssertFalse(coordinator.catalogReaderRequests.isEmpty)
        XCTAssertTrue(coordinator.catalogReaderRequests.allSatisfy { $0 == "share:nas.local/Media" })
    }

    func testProviderSearchRoutesThroughReadCapability() async throws {
        let reader = FakeCatalogReader()
        reader.searchItems = [MediaItem(id: "f:c.mkv", title: "Gamma", kind: .movie)]
        let coordinator = FakeCatalogCoordinator(reader: reader)
        let provider = ShareProvider(session: makeSession(), catalogCoordinator: coordinator)

        let hits = try await provider.search(query: "gam", limit: 5)

        XCTAssertEqual(hits.map(\.title), ["Gamma"])
    }

    /// `rescan()` touches the catalog (registering the reader) and then routes to
    /// the coordinating capability's `rescan` — never a downcast to a concrete type.
    func testRescanRoutesThroughCoordinatingCapability() async throws {
        let coordinator = FakeCatalogCoordinator(reader: FakeCatalogReader())
        let provider = ShareProvider(session: makeSession(), catalogCoordinator: coordinator)

        await provider.rescan()

        XCTAssertEqual(coordinator.rescans, ["share:nas.local/Media"])
        XCTAssertEqual(coordinator.catalogReaderRequests, ["share:nas.local/Media"])
    }

    func testInteractiveActivityRoutesThroughCoordinatingCapability() async throws {
        let coordinator = FakeCatalogCoordinator(reader: FakeCatalogReader())
        let provider = ShareProvider(session: makeSession(), catalogCoordinator: coordinator)

        await provider.noteInteractiveBrowseActivity()

        XCTAssertEqual(coordinator.activityCalls, ["share:nas.local/Media"])
    }

    // MARK: ShareWatchStateService direct

    private func makeWatchStore() -> ShareWatchStore {
        ShareWatchStore(
            localMediaContext: LocalMediaContext(
                accountID: "share:nas.local/Media",
                profileID: ProfileStore.defaultProfileID,
                profileNamespace: nil
            ),
            durableStore: nil
        )
    }

    func testWatchStateServiceStampsResumeState() async throws {
        let reader = FakeCatalogReader()
        let watchStore = makeWatchStore()
        await watchStore.setResume(120, itemID: "f:m.mkv", capturedAt: Date(), duration: 600)
        let service = ShareWatchStateService(
            watchStore: watchStore,
            accountID: "share:nas.local/Media",
            catalog: { reader }
        )

        let stamped = await service.stamp(MediaItem(id: "f:m.mkv", title: "Movie", kind: .movie))

        XCTAssertEqual(stamped.resumePosition, 120)
        XCTAssertEqual(stamped.runtime, 600)
        XCTAssertEqual(stamped.playedPercentage ?? 0, 0.2, accuracy: 0.001)
        XCTAssertFalse(stamped.isPlayed)
    }

    /// Containers (series/season/folder/collection) carry no watch record, so
    /// stamping must not mutate them (and must not query the catalog).
    func testWatchStateServiceSkipsContainers() async throws {
        let reader = FakeCatalogReader()
        let service = ShareWatchStateService(
            watchStore: makeWatchStore(),
            accountID: "acct",
            catalog: { reader }
        )
        let series = MediaItem(id: "series:x", title: "Series", kind: .series)

        let stamped = await service.stamp(series)

        XCTAssertNil(stamped.resumePosition)
        XCTAssertFalse(stamped.isPlayed)
    }

    /// Continue Watching folds several legacy per-file records onto one canonical
    /// id, keeping the newest.
    func testWatchStateServiceFoldsLegacyVersionsToNewest() async throws {
        let reader = FakeCatalogReader()
        reader.canonicalMap = ["f:a.mkv": "movie:x", "f:b.mkv": "movie:x"]
        let watchStore = makeWatchStore()
        await watchStore.setResume(30, itemID: "f:a.mkv", capturedAt: Date(timeIntervalSince1970: 100), duration: 600)
        await watchStore.setResume(300, itemID: "f:b.mkv", capturedAt: Date(timeIntervalSince1970: 200), duration: 600)
        let service = ShareWatchStateService(
            watchStore: watchStore,
            accountID: "acct",
            catalog: { reader }
        )

        let folded = await service.allCanonicalRecords()

        XCTAssertEqual(folded.count, 1)
        XCTAssertEqual(folded["movie:x"]?.position, 300)
    }

    func testPersonalVideoWatchStateKeepsRawFileIdentity() async {
        let reader = FakeCatalogReader()
        reader.aliasMap = ["f:Birthday.mkv": "movie:stale"]
        reader.defaultMoviePaths = ["stale": "Birthday.mkv"]
        let watchStore = makeWatchStore()
        await watchStore.setResume(
            45,
            itemID: "movie:stale",
            capturedAt: Date(timeIntervalSince1970: 100),
            duration: 120
        )
        let service = ShareWatchStateService(
            watchStore: watchStore,
            accountID: "acct",
            usesCatalogClassification: false,
            catalog: { reader }
        )

        let records = await service.allCanonicalRecords()
        let stamped = await service.stamp(
            MediaItem(id: "f:Birthday.mkv", title: "Birthday", kind: .video)
        )

        XCTAssertNotNil(records["f:Birthday.mkv"])
        XCTAssertNil(records["movie:stale"])
        XCTAssertEqual(stamped.resumePosition, 45)
    }

    // MARK: Source-inspection gate

    private func providerShareSource(_ file: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent() // ProviderShareTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let source = repoRoot
            .appendingPathComponent("Sources/ProviderShare")
            .appendingPathComponent(file)
        return try String(contentsOf: source, encoding: .utf8)
    }

    /// The facade must not annotate any property/return with the concrete
    /// `ShareCatalogStore`, and must depend on the read capability instead. (The one
    /// permitted mention is a doc-comment naming what it deliberately avoids.)
    func testProviderSourceNamesNoConcreteCatalogStore() throws {
        let source = try providerShareSource("ShareProvider.swift")
        XCTAssertFalse(source.contains(": ShareCatalogStore"), "facade should not annotate a ShareCatalogStore property/param")
        XCTAssertFalse(source.contains("-> ShareCatalogStore"), "facade should not return the concrete store")
        XCTAssertFalse(source.contains("catalogOverride"), "the concrete-store test override was removed")
        XCTAssertTrue(source.contains("any ShareCatalogReading"), "facade should depend on the read capability")
    }

    /// The public initializer accepts the coordinating capability, not the concrete
    /// coordinator, so AppShell/tests can inject a fake.
    func testProviderPublicInitTakesCoordinatingCapability() throws {
        let source = try providerShareSource("ShareProvider.swift")
        XCTAssertTrue(source.contains("catalogCoordinator: any ShareCatalogCoordinating"))
        XCTAssertFalse(source.contains("catalogCoordinator: ShareCatalogCoordinator,"), "public init must not require the concrete coordinator")
    }
}

private final class CapabilityFakeSession: MediaTransportSession, @unchecked Sendable {
    let key: MediaTransportSessionKey
    let fileSystem: any MediaTransportFileSystem

    init(
        fileSystem: any MediaTransportFileSystem,
        role: MediaTransportRole
    ) throws {
        key = MediaTransportSessionKey(
            accountID: "share:nas.local/Media",
            credentialRevision: CredentialRevision(),
            endpoint: try MediaTransportEndpointIdentity(
                transportIdentifier: "smb",
                host: "nas.local",
                rootPath: "/Media"
            ),
            trustRevision: UUID(),
            role: role
        )
        self.fileSystem = fileSystem
    }

    func shutdown() async {}
    func isHealthy() async -> Bool { true }
}

private final class CapabilityFakeFileSystem: MediaTransportFileSystem, @unchecked Sendable {
    private let entries: [RemoteFileEntry]
    private let directories: [String: [RemoteFileEntry]]

    init(entries: [RemoteFileEntry], directories: [String: [RemoteFileEntry]] = [:]) {
        self.entries = entries
        self.directories = directories
    }

    func validate() async throws {}

    func probe() async throws -> MediaTransportProbe {
        MediaTransportProbe(
            capabilities: try MediaTransportCapabilities(
                supportsList: true,
                supportsStat: true,
                supportsBoundedWholeFileRead: false,
                byteRangeBehavior: .unsupported,
                maximumBoundedWholeFileReadBytes: nil,
                consistency: .changeDetecting
            )
        )
    }

    func list(relativePath: String) async throws -> [RemoteFileEntry] {
        relativePath.isEmpty ? entries : directories[relativePath] ?? []
    }

    func stat(relativePath: String) async throws -> RemoteFileEntry {
        throw MediaTransportError.unsupportedCapability("stat")
    }

    func readSmallFile(relativePath: String, maximumBytes: Int) async throws -> Data {
        throw MediaTransportError.unsupportedCapability("bounded read")
    }

    func openSource(for locator: NetworkFileLocator) async throws -> MediaTransportSourceLease {
        throw MediaTransportError.unsupportedCapability("source")
    }
}
