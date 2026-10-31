import CoreModels
import Foundation
import XCTest
@testable import ProviderPlex

final class PlexLibraryQueryTests: XCTestCase {
    func testBrowseFollowsServerCollectionPolicyWithoutRebuildingMembership() async throws {
        let http = StubHTTPClient()
        http.stubSequence(pathSuffix: "/library/sections/1/all", jsons: [
            #"{"MediaContainer":{"totalSize":2,"Metadata":[{"ratingKey":"set","type":"collection","title":"Cuts","childCount":2}]}}"#,
            #"{"MediaContainer":{"totalSize":2,"Metadata":[{"ratingKey":"movie","type":"movie","title":"Standalone","viewOffset":12000}]}}"#
        ])
        let source = provider(http)
        let request = PageRequest(limit: 1, collectionPresentation: .serverDefault)
        let first = try await source.items(in: "1", kind: .movie, page: request)
        let second = try await source.items(in: "1", kind: .movie, page: request.next())
        XCTAssertEqual(first.items.map(\.kind), [.collection])
        XCTAssertEqual(first.items.map(\.id), ["set"])
        XCTAssertEqual(second.items.map(\.id), ["movie"])
        XCTAssertEqual(second.items.first?.resumePosition, 12)
        XCTAssertEqual(first.totalCount, 2)
        XCTAssertEqual(second.startIndex, 1)
        XCTAssertEqual(second.totalCount, 2)
        XCTAssertEqual(http.sentPaths, Array(repeating: "/library/sections/1/all", count: 2))
        for query in http.sentQueryItems {
            XCTAssertTrue(query.contains(.init(name: "includeCollections", value: "1")))
            XCTAssertTrue(query.contains(.init(name: "includeOptionalElements", value: "Stream")))
            XCTAssertFalse(query.contains { $0.name == "includeElements" })
            XCTAssertTrue(query.contains(.init(name: "type", value: "1")))
        }
    }

    func testOnlyUnfilteredNameSortedMovieBrowseIncludesCollections() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/sections/1/all",
                  json: #"{"MediaContainer":{"totalSize":0,"Metadata":[]}}"#)
        http.stub(pathSuffix: "/library/sections/1/genre",
                  json: #"{"MediaContainer":{"Directory":[{"key":"42","title":"Drama"}]}}"#)
        let source = provider(http)
        let requests: [(MediaItemKind, PageRequest, String)] = [
            (.movie, .init(), "0"),
            (.movie, .init(collectionPresentation: .serverDefault), "1"),
            (.movie, .init(sort: .init(field: .name, direction: .descending), collectionPresentation: .serverDefault), "1"),
            (.movie, .init(sort: .init(field: .dateAdded, direction: .descending), collectionPresentation: .serverDefault), "0"),
            (.movie, .init(filters: .init(filter: .unwatched), collectionPresentation: .serverDefault), "0"),
            (.movie, .init(filters: .init(genre: "Drama"), collectionPresentation: .serverDefault), "0"),
            (.movie, .init(filters: .init(year: 2024), collectionPresentation: .serverDefault), "0"),
            (.series, .init(collectionPresentation: .serverDefault), "0"),
            (.episode, .init(collectionPresentation: .serverDefault), "0")
        ]
        for (kind, request, expected) in requests {
            _ = try await source.items(in: "1", kind: kind, page: request)
            let query = try XCTUnwrap(http.queryItems(forPathSuffix: "/all"))
            XCTAssertEqual(query.first { $0.name == "includeCollections" }?.value, expected)
        }
        _ = try await source.libraryQueryInventory(
            in: "1", kind: .movie, page: .init(collectionPresentation: .serverDefault)
        )
        XCTAssertTrue(try XCTUnwrap(http.queryItems(forPathSuffix: "/all"))
            .contains(.init(name: "includeCollections", value: "0")))
    }

    func testGroupedAlphabetResolvesActualMixedPagePositionsInBothDirections() async throws {
        for direction: SortDirection in [.ascending, .descending] {
            let http = StubHTTPClient()
            let movie = #"{"ratingKey":"movie","type":"movie","title":"Apple"}"#
            let collection = #"{"ratingKey":"set","type":"collection","title":"Zebra cuts"}"#
            let rows = direction == .ascending ? [movie, collection] : [collection, movie]
            http.stubSequence(pathSuffix: "/library/sections/1/all", jsons: rows.map {
                #"{"MediaContainer":{"totalSize":2,"Metadata":["# + $0 + "]}}"
            })
            let source = provider(http)
            let request = PageRequest(
                sort: .init(field: .name, direction: direction), collectionPresentation: .serverDefault
            )
            let entries = try await source.libraryQueryLetterIndex(in: "1", kind: .movie, page: request)
            XCTAssertEqual(entries, LibraryLetterIndex.deferredEntries(direction: direction))
            XCTAssertTrue(http.sentPaths.isEmpty, "Do not scan a library just to show its alphabet rail.")
            let position = try await source.libraryQueryLetterPosition(
                in: "1", kind: .movie, letter: "Z", page: request
            )
            XCTAssertEqual(position, direction == .ascending ? 1 : 0)
            XCTAssertFalse(http.sentPaths.contains { $0.hasSuffix("/firstCharacter") })
            XCTAssertTrue(http.sentQueryItems.allSatisfy {
                $0.contains(.init(name: "includeCollections", value: "1"))
            })
        }
    }

    func testGroupedBrowseRejectsMissingNonemptyMetadata() async {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/sections/1/all", json: #"{"MediaContainer":{"size":1,"totalSize":1}}"#)
        do {
            _ = try await provider(http).items(
                in: "1", kind: .movie, page: .init(collectionPresentation: .serverDefault)
            )
            XCTFail("Missing rows cannot become an empty grouped library.")
        } catch {
            XCTAssertEqual(error as? AppError, .invalidResponse)
        }
    }

    func testEpisodeInventoryRequestsPlexEpisodeType() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/sections/1/all", json: """
        {"MediaContainer":{"totalSize":1,"Metadata":[{
        "ratingKey":"episode","type":"episode","title":"Episode 3",
        "grandparentRatingKey":"show","grandparentTitle":"Show","parentIndex":2,"index":3
        }]}}
        """)
        let source = provider(http)
        let page = try await source.libraryQueryEpisodeInventory(
            in: "1", page: .init(filters: .init(filter: .atmos)))
        let query = try XCTUnwrap(http.queryItems(forPathSuffix: "/all"))
        XCTAssertEqual(query.first { $0.name == "type" }?.value, "4")
        let item = try XCTUnwrap(page.items.first)
        XCTAssertEqual(item.kind, .episode)
        XCTAssertEqual(item.seriesID, "show")
        XCTAssertEqual(item.seasonNumber, 2)
        XCTAssertEqual(item.episodeNumber, 3)
        XCTAssertEqual(page.totalCount, 1)
    }

    func testRandomFilterInventoryUsesStablePagingWithoutChangingNativeRandomBrowse() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/sections/1/all",
                  json: #"{"MediaContainer":{"totalSize":0,"Metadata":[]}}"#)
        let source = provider(http)
        let random = SortDescriptor(field: .random, direction: .descending)
        for offset in [0, 120] {
            _ = try await source.libraryQueryInventory(
                in: "1", kind: .movie,
                page: .init(startIndex: offset, sort: random, filters: .init(filter: .atmos)))
            let query = try XCTUnwrap(http.queryItems(forPathSuffix: "/all"))
            XCTAssertEqual(query.first { $0.name == "sort" }?.value, "titleSort:asc")
        }
        _ = try await source.items(in: "1", kind: .movie, page: .init(sort: random))
        let native = try XCTUnwrap(http.queryItems(forPathSuffix: "/all"))
        XCTAssertEqual(native.first { $0.name == "sort" }?.value, "random")
    }

    func testGenreAndYearFacetsRemainNativeAndLibraryScoped() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/sections/1/genre",
                  json: #"{"MediaContainer":{"Directory":[{"key":"42","title":"Drama"}]}}"#)
        http.stub(pathSuffix: "/library/sections/1/year",
                  json: #"{"MediaContainer":{"Directory":[{"key":"2024","title":"2024"},{"key":"2023","title":"2023"}]}}"#)
        let facets = try await provider(http).libraryQueryFacets(in: "1", kind: .movie)
        XCTAssertEqual(facets.genres, ["Drama"])
        XCTAssertEqual(facets.years, [2024, 2023])
        XCTAssertEqual(Set(http.sentPaths), ["/library/sections/1/genre", "/library/sections/1/year"])
        for suffix in ["/genre", "/year"] {
            XCTAssertTrue(try XCTUnwrap(http.queryItems(forPathSuffix: suffix)).contains(.init(name: "type", value: "1")))
        }
    }

    private func provider(_ http: StubHTTPClient) -> PlexProvider {
        PlexProvider(session: UserSession(
            server: MediaServer(id: "plex", name: "Plex", baseURL: URL(string: "https://plex.test")!, provider: .plex),
            userID: "user", userName: "User", deviceID: "device", accessToken: "test"
        ), http: http)
    }

    func testNativePredicatesUseProviderGenreIDsAndCacheTheirResolution() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/sections/1/genre",
                  json: #"{"MediaContainer":{"Directory":[{"key":"42","title":"Drama"}]}}"#)
        http.stub(pathSuffix: "/library/sections/1/all",
                  json: #"{"MediaContainer":{"totalSize":0,"Metadata":[]}}"#)
        let source = provider(http)
        let request = PageRequest(filters: .init(filter: .unwatched, genre: "Drama", year: 2024))
        _ = try await source.items(in: "1", kind: .movie, page: request)
        _ = try await source.items(in: "1", kind: .movie, page: request.next())
        let query = try XCTUnwrap(http.queryItems(forPathSuffix: "/all"))
        XCTAssertTrue(query.contains(.init(name: "unwatched", value: "1")))
        XCTAssertTrue(query.contains(.init(name: "genre", value: "42")))
        XCTAssertTrue(query.contains(.init(name: "year", value: "2024")))
        XCTAssertEqual(http.sentPaths.filter { $0.hasSuffix("/genre") }.count, 1)
    }

    func testInventoryRejectsAnUnverifiedTotal() async {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/sections/1/all",
                  json: #"{"MediaContainer":{"size":1,"Metadata":[{"ratingKey":"1","title":"Movie","type":"movie"}]}}"#)
        do {
            _ = try await provider(http).libraryQueryInventory(in: "1", kind: .movie, page: .init())
            XCTFail("Missing total must not look like a complete one-item library")
        } catch { XCTAssertEqual(error as? AppError, .invalidResponse) }
    }

    func testInventoryRecognizesAtmosOnANondefaultAudioTrack() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/sections/1/all", json: """
        {"MediaContainer":{"totalSize":1,"Metadata":[{"ratingKey":"1","title":"Movie","type":"movie",
        "Media":[{"id":1,"Part":[{"Stream":[{"streamType":2,"codec":"aac","selected":true},
        {"streamType":2,"codec":"eac3","displayTitle":"English (Dolby Atmos)"}]}]}]}]}}
        """)
        let page = try await provider(http).libraryQueryInventory(in: "1", kind: .movie,
                                                                 page: .init(filters: .init(filter: .atmos)))
        XCTAssertTrue(try XCTUnwrap(page.items.first).librarySortValues?.hasAtmos == true)
    }
}
