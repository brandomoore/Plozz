import XCTest
import CoreModels
@testable import ProviderPlex

final class PlexHomeLayoutTests: XCTestCase {
    private func session() -> UserSession {
        UserSession(
            server: MediaServer(
                id: "home", name: "Home", baseURL: URL(string: "https://plex.test:32400")!,
                provider: .plex
            ),
            userID: "selected-user", userName: "Viewer", deviceID: "device", accessToken: "TEST_TOKEN"
        )
    }

    private let libraries = """
    {"MediaContainer":{"Directory":[
      {"key":"2","type":"show","title":"Television"},
      {"key":"3","type":"artist","title":"Music"},
      {"key":"1","type":"movie","title":"Movies"}
    ]}}
    """

    private let promoted = """
    {"MediaContainer":{"Hub":[
      {"hubIdentifier":"movie.recentlyadded.1","context":"hub.movie.recentlyadded",
       "title":"Nouveautés","type":"movie","Metadata":[
         {"ratingKey":"one","type":"movie","librarySectionID":1},
         {"ratingKey":"foreign","type":"movie","librarySectionID":9},
         {"ratingKey":"audio","type":"track","librarySectionID":1},
         {"ratingKey":"two","type":"movie","librarySectionID":1}
       ]},
      {"hubIdentifier":"home.continue","title":"Weitersehen","type":"mixed","Metadata":[]},
      {"hubIdentifier":"movie.similar.10","context":"hub.movie.similar",
       "title":"Because you watched something","type":"movie","Metadata":[
         {"ratingKey":"similar","type":"movie","librarySectionID":1}
       ]},
      {"hubIdentifier":"movie.custom","title":"Continue Watching","type":"movie",
       "key":"https://untrusted.test/redirect","Metadata":[
         {"ratingKey":"custom","type":"movie"}
       ]},
      {"hubIdentifier":"music.recent","type":"album","Metadata":[
         {"ratingKey":"album","type":"album","librarySectionID":3}
       ]}
    ]}}
    """

    private let movieLibrary = """
    {"MediaContainer":{"Directory":[{"key":"1","type":"movie","title":"Movies"}]}}
    """

    private let keyedPromotion = """
    {"MediaContainer":{"Hub":[{
      "hubIdentifier":"movie.recentlyadded.1","type":"movie",
      "key":"/library/sections/1/all?type=1&sort=addedAt:desc&X-Plex-Token=UNTRUSTED",
      "size":1,"Metadata":[{"ratingKey":"one","type":"movie","librarySectionID":1}]
    }]}}
    """

    func testDiscoveredShelfSurvivesPersistenceAndRecoversMissingPromotedRow() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/sections", json: movieLibrary)
        stub.stubSequence(pathSuffix: "/hubs/promoted", jsons: [
            keyedPromotion, #"{"MediaContainer":{"Hub":[]}}"#
        ])
        stub.stub(pathSuffix: "/library/sections/1/all", json: """
        {"MediaContainer":{"offset":0,"totalSize":3,"Metadata":[
          {"ratingKey":"one","type":"movie","librarySectionID":1},
          {"ratingKey":"foreign","type":"movie","librarySectionID":9},
          {"ratingKey":"audio","type":"track","librarySectionID":1}
        ]}}
        """)
        let provider = PlexProvider(session: session(), http: stub)
        let layout = try await provider.serverHomeLayout()
        let section = try XCTUnwrap(layout?.sections.first)
        XCTAssertEqual(section.contentKey, "/library/sections/1/all?type=1&sort=addedAt:desc")
        let encoded = try JSONEncoder().encode(section)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("UNTRUSTED"))
        let restored = try JSONDecoder().decode(ServerHomeSection.self, from: encoded)
        let items = try await provider.serverHomeItems(section: restored, limit: 8, excludingLibraryIDs: [])
        XCTAssertEqual(items.map(\.id), ["one"])
        XCTAssertEqual(items.first?.libraryID, "1")
        XCTAssertEqual(stub.sentPaths, [
            "/library/sections", "/hubs/promoted", "/hubs/promoted", "/library/sections/1/all"
        ])
        let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/library/sections/1/all"))
        XCTAssertTrue(query.contains(.init(name: "sort", value: "addedAt:desc")))
        XCTAssertTrue(query.contains(.init(name: "X-Plex-Container-Size", value: "8")))
        XCTAssertFalse(query.contains { $0.name.lowercased() == "x-plex-token" })
        XCTAssertTrue(stub.sentHeaders.allSatisfy { $0["X-Plex-Token"] == "TEST_TOKEN" })
        XCTAssertTrue(stub.sentBaseURLs.allSatisfy { $0.host == "plex.test" })
    }

    func testIncompleteInlineRowsRecoverFromTheirOwnShelf() async throws {
        for payload in [
            #""size":2"#,
            #""size":2,"Metadata":[{"ratingKey":"partial","type":"movie"}]"#,
            #""size":0,"more":true,"Metadata":[]"#,
            #""size":0,"totalSize":2,"Metadata":[]"#
        ] {
            let stub = StubHTTPClient()
            stub.stub(pathSuffix: "/hubs/promoted", json: """
            {"MediaContainer":{"Hub":[{"hubIdentifier":"movie.custom","type":"movie",
              "key":"/library/sections/1/all?genre=123",\(payload)}]}}
            """)
            stub.stub(pathSuffix: "/library/sections/1/all", json: """
            {"MediaContainer":{"offset":0,"totalSize":1,"Metadata":[
              {"ratingKey":"recovered","type":"movie","librarySectionID":1}
            ]}}
            """)
            let items = try await PlexProvider(session: session(), http: stub).serverHomeItems(
                section: .init(id: "plex:1:movie.custom", kind: .recommendations, libraryID: "1"),
                limit: 8, excludingLibraryIDs: []
            )
            XCTAssertEqual(items.map(\.id), ["recovered"], payload)
            XCTAssertEqual(stub.sentPaths, ["/hubs/promoted", "/library/sections/1/all"])
        }
    }

    func testExplicitEmptyShelfDoesNotResurrectItemsFromSavedKey() async throws {
        for payload in [#""size":0"#, #""Metadata":[]"#, #""size":0,"more":false,"Metadata":[]"#] {
            let stub = StubHTTPClient()
            stub.stub(pathSuffix: "/hubs/promoted", json: """
            {"MediaContainer":{"Hub":[{"hubIdentifier":"movie.custom",\(payload)}]}}
            """)
            let items = try await PlexProvider(session: session(), http: stub).serverHomeItems(
                section: .init(
                    id: "plex:1:movie.custom", kind: .recommendations, libraryID: "1",
                    contentKey: "/library/sections/1/all"
                ),
                limit: 8, excludingLibraryIDs: []
            )
            XCTAssertTrue(items.isEmpty)
            XCTAssertEqual(stub.sentPaths, ["/hubs/promoted"])
        }
    }

    func testFolderOnlyPromotionsStayExcludedWithoutAttemptingVideoRecovery() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/hubs/promoted", json: """
        {"MediaContainer":{"Hub":[{"hubIdentifier":"movie.genres","type":"genre","size":1,
          "key":"/library/sections/1/genre","Directory":[{"key":"123","title":"Drama"}]
        }]}}
        """)
        let items = try await PlexProvider(session: session(), http: stub).serverHomeItems(
            section: .init(id: "plex:1:movie.genres", kind: .recommendations, libraryID: "1"),
            limit: 8, excludingLibraryIDs: []
        )
        XCTAssertTrue(items.isEmpty)
        XCTAssertEqual(stub.sentPaths, ["/hubs/promoted"])
    }

    func testShelfRecoveryKeepsHundredItemFilteringWindowBounded() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/hubs/promoted", json: #"{"MediaContainer":{"Hub":[]}}"#)
        let records = (0..<100).map {
            #"{"ratingKey":"\#($0)","type":"movie","librarySectionID":1}"#
        }.joined(separator: ",")
        stub.stub(pathSuffix: "/library/sections/1/all", json: """
        {"MediaContainer":{"offset":0,"totalSize":200,"Metadata":[\(records)]}}
        """)
        let items = try await PlexProvider(session: session(), http: stub).serverHomeItems(
            section: .init(
                id: "plex:1:movie.recentlyadded.1", kind: .recentlyAdded, libraryID: "1",
                contentKey: "/library/sections/1/all"
            ),
            limit: .max, excludingLibraryIDs: []
        )
        XCTAssertEqual(items.count, 100)
        XCTAssertEqual(stub.queryItems(forPathSuffix: "/library/sections/1/all")?
            .first { $0.name == "X-Plex-Container-Size" }?.value, "100")
        XCTAssertEqual(stub.sentPaths.count, 2)
    }

    func testMissingLegacyRowRetriesOnlyOnceAndPreservesOtherRows() async throws {
        for recovered in [true, false] {
            let stub = StubHTTPClient()
            stub.stubSequence(pathSuffix: "/hubs/promoted", jsons: [
                promoted, recovered ? """
                {"MediaContainer":{"Hub":[{"hubIdentifier":"movie.missing","Metadata":[
                  {"ratingKey":"recovered","type":"movie","librarySectionID":1}
                ]}]}}
                """ : #"{"MediaContainer":{"Hub":[]}}"#
            ])
            let provider = PlexProvider(session: session(), http: stub)
            let results = await provider.serverHomeItems(sections: [
                .init(id: "plex:1:movie.custom", kind: .recommendations, libraryID: "1"),
                .init(id: "plex:1:movie.missing", kind: .recommendations, libraryID: "1")
            ], limit: 8, excludingLibraryIDs: [])
            XCTAssertEqual(try XCTUnwrap(results["plex:1:movie.custom"]).get().map(\.id), ["custom"])
            if recovered {
                XCTAssertEqual(try XCTUnwrap(results["plex:1:movie.missing"]).get().map(\.id), ["recovered"])
            } else {
                XCTAssertThrowsError(try XCTUnwrap(results["plex:1:movie.missing"]).get()) {
                    XCTAssertEqual($0 as? AppError, .notFound)
                }
            }
            XCTAssertEqual(stub.sentPaths, ["/hubs/promoted", "/hubs/promoted"])
        }
    }

    func testShelfRecoveryFailureIsIsolatedAndNeverAnEmptySuccess() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/hubs/promoted", json: promoted)
        stub.stub(pathSuffix: "/library/sections/1/all", json: "{}", status: 401)
        let results = await PlexProvider(session: session(), http: stub).serverHomeItems(sections: [
            .init(id: "plex:1:movie.custom", kind: .recommendations, libraryID: "1"),
            .init(
                id: "plex:1:movie.missing", kind: .recentlyAdded, libraryID: "1",
                contentKey: "/library/sections/1/all"
            )
        ], limit: 8, excludingLibraryIDs: [])
        XCTAssertEqual(try XCTUnwrap(results["plex:1:movie.custom"]).get().map(\.id), ["custom"])
        XCTAssertThrowsError(try XCTUnwrap(results["plex:1:movie.missing"]).get()) {
            XCTAssertEqual($0 as? AppError, .unauthorized)
        }
        XCTAssertEqual(stub.sentPaths, ["/hubs/promoted", "/library/sections/1/all"])
    }

    func testFailedLegacyRetryDoesNotDiscardSuccessfulSiblingRows() async throws {
        let stub = StubHTTPClient()
        stub.stubSequence(pathSuffix: "/hubs/promoted", responses: [
            (json: promoted, status: 200), (json: "{}", status: 401)
        ])
        let results = await PlexProvider(session: session(), http: stub).serverHomeItems(sections: [
            .init(id: "plex:1:movie.custom", kind: .recommendations, libraryID: "1"),
            .init(id: "plex:1:movie.missing", kind: .recommendations, libraryID: "1")
        ], limit: 8, excludingLibraryIDs: [])
        XCTAssertEqual(try XCTUnwrap(results["plex:1:movie.custom"]).get().map(\.id), ["custom"])
        XCTAssertThrowsError(try XCTUnwrap(results["plex:1:movie.missing"]).get()) {
            XCTAssertEqual($0 as? AppError, .unauthorized)
        }
        XCTAssertEqual(stub.sentPaths, ["/hubs/promoted", "/hubs/promoted"])
    }

    func testUnrecoverableInlinePayloadIsAnErrorRatherThanEmptyOrPartialItems() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/hubs/promoted", json: """
        {"MediaContainer":{"Hub":[{"hubIdentifier":"movie.custom","size":2,
          "Metadata":[{"ratingKey":"partial","type":"movie","librarySectionID":1}]
        }]}}
        """)
        do {
            _ = try await PlexProvider(session: session(), http: stub).serverHomeItems(
                section: .init(id: "plex:1:movie.custom", kind: .recommendations, libraryID: "1"),
                limit: 8, excludingLibraryIDs: []
            )
            XCTFail("A truncated row must not appear complete")
        } catch { XCTAssertEqual(error as? AppError, .invalidResponse) }
        XCTAssertEqual(stub.sentPaths, ["/hubs/promoted", "/hubs/promoted"])
    }

    func testTruncatedRecoveryResponseDoesNotPublishPartialShelf() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/hubs/promoted", json: #"{"MediaContainer":{"Hub":[]}}"#)
        stub.stub(pathSuffix: "/library/sections/1/all", json: """
        {"MediaContainer":{"size":2,"Metadata":[
          {"ratingKey":"partial","type":"movie","librarySectionID":1}
        ]}}
        """)
        do {
            _ = try await PlexProvider(session: session(), http: stub).serverHomeItems(
                section: .init(
                    id: "plex:1:movie.missing", kind: .recommendations, libraryID: "1",
                    contentKey: "/library/sections/1/all"
                ),
                limit: 8, excludingLibraryIDs: []
            )
            XCTFail("Recovery must not turn a truncated response into success")
        } catch { XCTAssertEqual(error as? AppError, .invalidResponse) }
        XCTAssertEqual(stub.sentPaths, ["/hubs/promoted", "/library/sections/1/all"])
    }

    func testKeyOnlyRowsAreImportedWithStableIdentityWithoutUsingTitles() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/sections", json: movieLibrary)
        let payload = """
        {"MediaContainer":{"Hub":[
          {"key":"/library/sections/1/all?genre=123&X-Plex-Token=UNTRUSTED","title":"First title","type":"movie"},
          {"key":"/library/sections/1/all?genre=456","title":"Same title","type":"movie"},
          {"key":"https://other.invalid/library/sections/1/all","title":"Untrusted","type":"movie"}
        ]}}
        """
        stub.stubSequence(pathSuffix: "/hubs/promoted", jsons: [
            payload, payload.replacingOccurrences(of: "First title", with: "New title")
                .replacingOccurrences(of: "UNTRUSTED", with: "ROTATED")
        ])
        let provider = PlexProvider(session: session(), http: stub)
        let first = try await provider.serverHomeLayout()
        let second = try await provider.serverHomeLayout()
        XCTAssertEqual(first?.sections.count, 2)
        XCTAssertEqual(Set(first?.sections.map(\.id) ?? []).count, 2)
        XCTAssertEqual(first?.sections.map(\.id), second?.sections.map(\.id))
        XCTAssertEqual(first?.sections.first?.contentKey, "/library/sections/1/all?genre=123")
        XCTAssertTrue(first?.sections.allSatisfy { $0.kind == .recommendations } == true)
    }

    func testMalformedPromotionEnvelopeCannotReplaceLayoutWithEmptySuccess() async throws {
        for payload in [
            #"{}"#, #"{"size":1}"#, #"{"size":1,"Hub":[]}"#, #"{"size":0,"totalSize":1}"#
        ] {
            let stub = StubHTTPClient()
            stub.stub(pathSuffix: "/library/sections", json: movieLibrary)
            stub.stub(pathSuffix: "/hubs/promoted", json: #"{"MediaContainer":\#(payload)}"#)
            do {
                _ = try await PlexProvider(session: session(), http: stub).serverHomeLayout()
                XCTFail("An incomplete response must not erase the saved layout")
            } catch {
                XCTAssertEqual(error as? AppError, .invalidResponse)
            }
        }
        for payload in [#"{"size":0}"#, #"{"size":0,"Hub":[]}"#, #"{"Hub":[]}"#] {
            let stub = StubHTTPClient()
            stub.stub(pathSuffix: "/library/sections", json: movieLibrary)
            stub.stub(pathSuffix: "/hubs/promoted", json: #"{"MediaContainer":\#(payload)}"#)
            let layout = try await PlexProvider(session: session(), http: stub).serverHomeLayout()
            XCTAssertEqual(layout?.sections.count, 0)
        }
    }

    func testUnsafeSavedShelfNeverReceivesCredentialsDuringRecovery() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/hubs/promoted", json: #"{"MediaContainer":{"Hub":[]}}"#)
        do {
            _ = try await PlexProvider(session: session(), http: stub).serverHomeItems(
                section: .init(
                    id: "plex:1:missing", kind: .recommendations, libraryID: "1",
                    contentKey: "https://other.invalid/library/sections/1/all"
                ),
                limit: 8, excludingLibraryIDs: []
            )
            XCTFail("An invalid shelf is unavailable, not empty")
        } catch { XCTAssertEqual(error as? AppError, .notFound) }
        XCTAssertEqual(stub.sentPaths, ["/hubs/promoted", "/hubs/promoted"])
        XCTAssertTrue(stub.sentBaseURLs.allSatisfy { $0.host == "plex.test" })
    }

    func testPromotionsUseServerLibraryOrderWithHonestProvenanceAndNoInventedPins() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/sections", json: libraries)
        stub.stub(pathSuffix: "/hubs/promoted", json: promoted)
        let response = try await PlexProvider(session: session(), accountID: "account-one", http: stub)
            .serverHomeLayout()
        let layout = try XCTUnwrap(response)

        XCTAssertEqual(layout.source, .promotedHubs)
        XCTAssertTrue(layout.omitsMusic)
        XCTAssertEqual(layout.sections.map(\.id), [
            "plex:2:movie.recentlyadded.1", "plex:continueWatching",
            "plex:2:recommendation:similar:0", "plex:2:movie.custom",
            "plex:1:movie.recentlyadded.1", "plex:1:recommendation:similar:0", "plex:1:movie.custom"
        ])
        XCTAssertEqual(layout.sections.map(\.kind), [
            .recentlyAdded, .continueWatching, .recommendations, .recommendations,
            .recentlyAdded, .recommendations, .recommendations
        ])
        XCTAssertEqual(layout.sections[3].title, "Continue Watching",
                       "A display title must never classify an unknown hub.")
        XCTAssertTrue(layout.sections[1].includesNextUp)
        XCTAssertNil(layout.sections[1].libraryID)
        XCTAssertEqual(stub.sentPaths, ["/library/sections", "/hubs/promoted", "/hubs/promoted"])
        let queries = Array(stub.sentQueryItems.dropFirst())
        XCTAssertEqual(queries.compactMap { $0.first { $0.name == "contentDirectoryID" }?.value }, ["2", "1"])
        XCTAssertTrue(queries.allSatisfy { $0.contains(.init(name: "count", value: "1")) })
        XCTAssertFalse(queries.joined().contains { $0.name == "pinnedContentDirectoryID" })
        XCTAssertTrue(stub.sentHeaders.allSatisfy {
            $0["X-Plex-Token"] == "TEST_TOKEN" && $0["X-Plex-Client-Identifier"] == "device"
        })
        XCTAssertTrue(stub.sentMethods.allSatisfy { $0 == .get })
    }

    func testNativeRowContentIsBoundedScopedAndPreservesPlaybackIdentity() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/hubs/promoted", json: promoted)
        let provider = PlexProvider(session: session(), http: stub)
        let section = ServerHomeSection(
            id: "plex:1:movie.recentlyadded.1", kind: .recentlyAdded, libraryID: "1"
        )
        let items = try await provider.serverHomeItems(section: section, limit: 1, excludingLibraryIDs: ["9"])
        XCTAssertEqual(items.map(\.id), ["one"])
        XCTAssertEqual(items.first?.libraryID, "1")
        XCTAssertEqual(stub.sentPaths, ["/hubs/promoted"])
        let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/hubs/promoted"))
        XCTAssertTrue(query.contains(.init(name: "contentDirectoryID", value: "1")))
        XCTAssertTrue(query.contains(.init(name: "count", value: "1")))
        XCTAssertFalse(query.contains { $0.name == "pinnedContentDirectoryID" })

        let bounded = try await provider.serverHomeItems(
            section: section, limit: .max, excludingLibraryIDs: []
        )
        XCTAssertEqual(bounded.map(\.id), ["one", "two"])
        XCTAssertEqual(stub.queryItems(forPathSuffix: "/hubs/promoted")?
            .first { $0.name == "count" }?.value, "100")
    }

    func testDynamicRecommendationIdentitySurvivesNewSubjectAndRefetchesNativeContent() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/sections", json: """
        {"MediaContainer":{"Directory":[{"key":"1","type":"movie"}]}}
        """)
        stub.stubSequence(pathSuffix: "/hubs/promoted", jsons: [
            promoted,
            promoted.replacingOccurrences(of: "movie.similar.10", with: "movie.similar.900")
                .replacingOccurrences(of: "Because you watched something", with: "A new subject")
                .replacingOccurrences(of: #""ratingKey":"similar""#, with: #""ratingKey":"new-item""#)
        ])
        let provider = PlexProvider(session: session(), http: stub)
        let response = try await provider.serverHomeLayout()
        let section = try XCTUnwrap(response?.sections.first { $0.id == "plex:1:recommendation:similar:0" })
        let items = try await provider.serverHomeItems(section: section, limit: 8, excludingLibraryIDs: [])
        XCTAssertEqual(items.map(\.id), ["new-item"])
        XCTAssertEqual(stub.sentPaths, ["/library/sections", "/hubs/promoted", "/hubs/promoted"])
    }

    func testContinueWatchingUsesNativeGlobalHubAndExcludesAudioHiddenAndUnattributedItems() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/hubs/continueWatching/items", json: """
        {"MediaContainer":{"totalSize":4,"Metadata":[
          {"ratingKey":"next","type":"episode","librarySectionID":2},
          {"ratingKey":"hidden","type":"movie","librarySectionID":1},
          {"ratingKey":"audio","type":"track","librarySectionID":3},
          {"ratingKey":"unknown-library","type":"movie"}
        ]}}
        """)
        let items = try await PlexProvider(session: session(), http: stub).serverHomeItems(
            section: .init(id: "plex:continueWatching", kind: .continueWatching, includesNextUp: true),
            limit: 10, excludingLibraryIDs: ["1"]
        )
        XCTAssertEqual(items.map(\.id), ["next"])
        XCTAssertEqual(stub.sentPaths, ["/hubs/continueWatching/items"])
        let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/hubs/continueWatching/items"))
        XCTAssertTrue(query.contains(.init(name: "X-Plex-Container-Size", value: "100")))
    }

    func testNativeContinueWatchingDrainsBoundedPagesBeforeFilteringAndPresentationLimit() async throws {
        func page(_ range: Range<Int>, library: Int) -> String {
            let rows = range.map {
                #"{"ratingKey":"\#($0)","type":"movie","librarySectionID":\#(library)}"#
            }.joined(separator: ",")
            return #"{"MediaContainer":{"totalSize":103,"offset":\#(range.lowerBound),"Metadata":[\#(rows)]}}"#
        }
        for (limit, excluded, expected) in [
            (Int.max, Set<String>(), (0..<103).map(String.init)),
            (2, Set(["1"]), ["100", "101"])
        ] {
            let stub = StubHTTPClient()
            stub.stubSequence(pathSuffix: "/hubs/continueWatching/items", jsons: [
                page(0..<100, library: 1), page(100..<103, library: 2)
            ])
            let items = try await PlexProvider(session: session(), http: stub).serverHomeItems(
                section: .init(id: "plex:continueWatching", kind: .continueWatching),
                limit: limit, excludingLibraryIDs: excluded
            )
            XCTAssertEqual(items.map(\.id), expected)
            XCTAssertEqual(stub.sentQueryItems.map {
                $0.first { $0.name == "X-Plex-Container-Start" }?.value
            }, ["0", "100"])
            XCTAssertTrue(stub.sentQueryItems.allSatisfy {
                $0.contains(.init(name: "X-Plex-Container-Size", value: "100"))
            })
        }
    }

    func testHiddenLibraryAndCacheOnlyRowsDoNotStartNetworkRequests() async throws {
        let stub = StubHTTPClient()
        let provider = PlexProvider(session: session(), http: stub)
        for section in [
            ServerHomeSection(id: "plex:1:movie.custom", kind: .recommendations, libraryID: "1"),
            .init(id: "live", kind: .liveTV),
            .init(id: "libraries", kind: .libraries)
        ] {
            let items = try await provider.serverHomeItems(
                section: section, limit: 10, excludingLibraryIDs: ["1"]
            )
            XCTAssertTrue(items.isEmpty)
        }
        XCTAssertTrue(stub.sentPaths.isEmpty)
    }

    func testUnknownRowsUseNativePromotionsNotServerProvidedURLsOrTitleHeuristics() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/hubs/promoted", json: promoted)
        let items = try await PlexProvider(session: session(), http: stub).serverHomeItems(
            section: .init(id: "plex:1:movie.custom", kind: .recommendations, libraryID: "1"),
            limit: 12, excludingLibraryIDs: []
        )
        XCTAssertEqual(items.map(\.id), ["custom"])
        XCTAssertEqual(items.first?.libraryID, "1")
        XCTAssertEqual(stub.sentPaths, ["/hubs/promoted"])
        XCTAssertEqual(stub.sentBaseURLs.map(\.host), ["plex.test"])
    }

    func testPromotionFailuresNeverBecomeSuccessfulFallbackLayouts() async throws {
        for status in [200, 401, 404, 500] {
            let stub = StubHTTPClient()
            stub.stub(pathSuffix: "/library/sections", json: """
            {"MediaContainer":{"Directory":[{"key":"1","type":"movie"}]}}
            """)
            stub.stub(pathSuffix: "/hubs/promoted", json: "[]", status: status)
            do {
                _ = try await PlexProvider(session: session(), http: stub).serverHomeLayout()
                XCTFail("Malformed or failed promotions must throw")
            } catch {
                let expected: AppError = switch status {
                case 200: .decoding
                case 401: .unauthorized
                case 404: .notFound
                default: .invalidResponse
                }
                XCTAssertEqual(error as? AppError, expected)
            }
            XCTAssertFalse(stub.sentPaths.contains { $0.contains("/hubs/sections/") })
        }
    }

    func testTransportFailureDoesNotStartUnrelatedDiscovery() async throws {
        let stub = StubHTTPClient()
        stub.error = .serverUnreachable
        do {
            _ = try await PlexProvider(session: session(), http: stub).serverHomeLayout()
            XCTFail("Transport failure must throw")
        } catch {
            XCTAssertEqual(error as? AppError, .serverUnreachable)
        }
        XCTAssertEqual(stub.sentPaths, ["/library/sections"])
    }

    func testBatchSharesOnePromotedPayloadAndSubsequentBatchFetchesFreshItems() async throws {
        let stub = StubHTTPClient()
        let refreshed = promoted
            .replacingOccurrences(of: #""ratingKey":"one""#, with: #""ratingKey":"fresh-one""#)
            .replacingOccurrences(of: #""ratingKey":"similar""#, with: #""ratingKey":"fresh-similar""#)
            .replacingOccurrences(of: #""ratingKey":"custom""#, with: #""ratingKey":"fresh-custom""#)
        stub.stubSequence(pathSuffix: "/hubs/promoted", jsons: [promoted, refreshed])
        let provider: any MediaProvider = PlexProvider(session: session(), http: stub)
        let sections: [ServerHomeSection] = [
            .init(id: "plex:1:movie.recentlyadded.1", kind: .recentlyAdded, libraryID: "1"),
            .init(id: "plex:1:recommendation:similar:0", kind: .recommendations, libraryID: "1"),
            .init(id: "plex:1:movie.custom", kind: .recommendations, libraryID: "1")
        ]

        let first = await provider.serverHomeItems(sections: sections, limit: 8, excludingLibraryIDs: [])
        XCTAssertEqual(Set(first.keys), Set(sections.map(\.id)))
        XCTAssertEqual(try XCTUnwrap(first[sections[0].id]).get().map(\.id), ["one", "two"])
        XCTAssertEqual(try XCTUnwrap(first[sections[1].id]).get().map(\.id), ["similar"])
        XCTAssertEqual(try XCTUnwrap(first[sections[2].id]).get().map(\.id), ["custom"])
        XCTAssertEqual(stub.sentPaths, ["/hubs/promoted"])

        let second = await provider.serverHomeItems(sections: sections, limit: 8, excludingLibraryIDs: [])
        XCTAssertEqual(try XCTUnwrap(second[sections[0].id]).get().map(\.id), ["fresh-one", "two"])
        XCTAssertEqual(try XCTUnwrap(second[sections[1].id]).get().map(\.id), ["fresh-similar"])
        XCTAssertEqual(try XCTUnwrap(second[sections[2].id]).get().map(\.id), ["fresh-custom"])
        XCTAssertEqual(stub.sentPaths, ["/hubs/promoted", "/hubs/promoted"])
        XCTAssertEqual(stub.sentQueryItems[0], stub.sentQueryItems[1])
        XCTAssertTrue(stub.sentQueryItems.allSatisfy {
            $0.contains(.init(name: "contentDirectoryID", value: "1"))
                && $0.contains(.init(name: "count", value: "8"))
        })
    }

    func testMixedLibraryBatchSharesFailuresWithoutDiscardingOtherLibrariesOrCachingErrors() async throws {
        let stub = StubHTTPClient()
        stub.stubSequence(pathSuffix: "/hubs/promoted", responses: [
            (json: "{}", status: 401), (json: promoted, status: 200), (json: promoted, status: 200)
        ])
        let provider: any MediaProvider = PlexProvider(session: session(), http: stub)
        let sections: [ServerHomeSection] = [
            .init(id: "plex:1:movie.recentlyadded.1", kind: .recentlyAdded, libraryID: "1"),
            .init(id: "plex:1:movie.custom", kind: .recommendations, libraryID: "1"),
            .init(id: "plex:2:movie.custom", kind: .recommendations, libraryID: "2"),
            .init(id: "plex:3:movie.custom", kind: .recommendations, libraryID: "3"),
            .init(id: "live", kind: .liveTV)
        ]
        let first = await provider.serverHomeItems(sections: sections, limit: 8, excludingLibraryIDs: ["3"])
        XCTAssertEqual(Set(first.keys), Set(sections.map(\.id)))
        for section in sections.prefix(2) {
            XCTAssertThrowsError(try XCTUnwrap(first[section.id]).get()) {
                XCTAssertEqual($0 as? AppError, .unauthorized)
            }
        }
        let successful = try XCTUnwrap(first[sections[2].id]).get()
        XCTAssertEqual(successful.map(\.id), ["custom"])
        XCTAssertEqual(successful.first?.libraryID, "2")
        XCTAssertTrue(try XCTUnwrap(first[sections[3].id]).get().isEmpty)
        XCTAssertTrue(try XCTUnwrap(first["live"]).get().isEmpty)
        XCTAssertEqual(stub.sentPaths, ["/hubs/promoted", "/hubs/promoted"])

        let recovered = await provider.serverHomeItems(
            sections: Array(sections.prefix(2)), limit: 8, excludingLibraryIDs: ["3"]
        )
        XCTAssertEqual(try XCTUnwrap(recovered[sections[0].id]).get().map(\.id), ["one", "two"])
        XCTAssertEqual(try XCTUnwrap(recovered[sections[1].id]).get().map(\.id), ["custom"])
        XCTAssertEqual(stub.sentQueryItems.compactMap {
            $0.first { $0.name == "contentDirectoryID" }?.value
        }, ["1", "2", "1"])
    }

    func testBatchWithNoItemWorkDoesNotRequestPromotionsOrLibraries() async throws {
        let stub = StubHTTPClient()
        let provider: any MediaProvider = PlexProvider(session: session(), http: stub)
        let sections: [ServerHomeSection] = [
            .init(id: "plex:1:movie.custom", kind: .recommendations, libraryID: "1"),
            .init(id: "libraries", kind: .libraries),
            .init(id: "live", kind: .liveTV)
        ]
        let hidden = await provider.serverHomeItems(sections: sections, limit: 8, excludingLibraryIDs: ["1"])
        let zeroLimit = await provider.serverHomeItems(sections: sections, limit: 0, excludingLibraryIDs: [])
        for response in [hidden, zeroLimit] {
            XCTAssertEqual(response.count, sections.count)
            for section in sections {
                XCTAssertTrue(try XCTUnwrap(response[section.id]).get().isEmpty)
            }
        }
        XCTAssertTrue(stub.sentPaths.isEmpty)
    }
}
